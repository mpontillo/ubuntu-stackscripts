#!/bin/bash
#
# Ubuntu LTS Cloud Deployment
# Written by Mike Pontillo (oftc, freenode IRC: mpontillo)

# Copyright 2017 Mike Pontillo
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#
# Creates a modern Ubuntu 16.04 "Xenial" LTS build from the Linode image, 
# intended to mimic the behavior of the Ubuntu cloud images.
# 
# Features include:
#  - Allows the installation of arbitrary apt packages.
#  - Installs the latest "enablement" kernel.
#  - Optionally configures ZFS.
#    * Requires GRUB 2 to be set in the configuration profile.
#  - Configures the system hostname and domain name.
#  - Optionally customizes /etc/issue with the external system IPs
#  - Creates a normal (unprivileged) user account.
#    * Allows configuration of user groups.
#    * Allows configuration of GECOS field.
#  - Imports SSH keys.
#  - Enables the firewall.
#    * Enables `ufw`.
#    * Optionally limits incoming SSH connections.
#
# IMPORTANT: After rebuilding or installing a Linode using this script, it
# is intended that you set your Linode's configuration profile to boot with
# GRUB 2. If you are using a Linode-provided kernel, ZFS kernel modules
# will fail to load.
#
# <UDF name="hostname" default="ubuntu" label="Hostname" example="Example: www" />
# <UDF name="domain" default="" label="Domain" example="Example: example.com" />
# <UDF name="username" default="ubuntu" label="Username" example="Username for unprivileged user. If blank, will not create a user. Example: ubuntu" />
# <UDF name="gecos" default="" label="GECOS" example="GECOS field. Example: John Doe,,+1555-555-1212" />
# <UDF name="groups" default="adm,dialout,cdrom,floppy,sudo,audio,dip,video,plugdev,netdev" label="User groups" example="Comma-separated list of groups for the new user. Example: adm,sudo" />
# <UDF name="launchpad_account" default="" label="Launchpad account" example="Will be used to import SSH keys. If SSH keys are imported, root password will be disabled." />
# <UDF name="extra_packages" default="software-properties-common" label="Extra packages" example="Whitespace-separated list of extra packages to install. Example: build-essential git" />
# <UDF name="kernel_package" default="linux-generic-hwe-16.04" label="Kernel package to install" example="linux-image-virtual" />
# <UDF name="reboot" default="true" label="Reboot" example="Note: This is helpful to ensure the installed kernel boots with GRUB 2." oneof="true,false" />
# <UDF name="zfs" default="true" label="ZFS" example="If true, installs ZFS packages." oneof="true,false" />
# <UDF name="configure_firewall" default="true" label="Enable UFW (firewall)" example="If true, enables UFW, only allowing SSH connections." oneof="true,false" />
# <UDF name="limit_ssh" default="true" label="Limit incoming SSH connections" example="If true (and UFW is enabled) limits incoming SSH connections." oneof="true,false" />
# <UDF name="customize_etc_issue" default="true" label="Add IP addresses to /etc/issue" example="If true, customizes /etc/issue with IP address information." oneof="true,false" />
# <UDF name="debug" default="false" label="Debug" example="If true, will output extra debug information." oneof="true,false" />

DEBUG="${DEBUG:-}"

if [ "$DEBUG" != "" ]; then
    set -x
    env
    ip -o addr
    ip -o link
    ip -o route
    ip -o -6 route
fi

function maybe_print() {
    eval VALUE="\$$1"
    if [ "$VALUE" != "" ]; then
        printf "%20s=%s\n" "$1" "$VALUE"
    fi
}

echo "Deploying Linode:"
echo "           LINODE_ID=$LINODE_ID"
echo " LINODE_LISHUSERNAME=$LINODE_LISHUSERNAME"
echo "          LINODE_RAM=$LINODE_RAM" 
echo " LINODE_DATACENTERID=$LINODE_DATACENTERID"
echo ""

# Variables passed in.
HOSTNAME="${HOSTNAME:-ubuntu}"
DOMAIN="${DOMAIN:-}"
LAUNCHPAD_ACCOUNT="${LAUNCHPAD_ACCOUNT}"
KERNEL_PACKAGE="${KERNEL_PACKAGE:-linux-generic-hwe-16.04}"
REBOOT="${REBOOT:-true}"
ZFS="${ZFS:-true}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-software-properties-common}"
USERNAME="${USERNAME:-ubuntu}"
CUSTOMIZE_ETC_ISSUE="${CUSTOMIZE_ETC_ISSUE:-true}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-true}"
LIMIT_SSH="${LIMIT_SSH:-true}"
GECOS="${GECOS:-}"
GROUPS="${GROUPS:-}"

# Derived variables.
if [ "$DOMAIN" != "" ]; then
    FQDN="${HOSTNAME}.${DOMAIN}"
    MAYBE_FQDN="${HOSTNAME}.${DOMAIN}"
else
    FQDN=""
    MAYBE_FQDN="${HOSTNAME}"
fi

if [ "$ZFS" == "true" ]; then
    EXTRA_PACKAGES="zfsutils-linux $EXTRA_PACKAGES"
fi

function wait_for_ipv6() {
    seconds=0
    while ! ip -6 -o addr | grep -v tentative | grep -q 'scope global'; do
        sleep 1
        let seconds=$seconds+1
    done
    echo "Waited $seconds second(s) for an IPv6 address."
}

# Useful constants.
EXTERNAL_IP="$(ip r g 8.8.8.8 | grep -o 'src.*' | awk '{ print $2 }')"

# Wait for a router advertisement, just in case.
# Linode seems to send them every ~5 seconds.
wait_for_ipv6

EXTERNAL_IPV6="$(ip r g 2001:: | grep -o 'src.*' | awk '{ print $2 }')"

maybe_print DEBUG
maybe_print HOSTNAME
maybe_print DOMAIN
maybe_print FQDN
maybe_print USERNAME
maybe_print GECOS
maybe_print LAUNCHPAD_ACCOUNT
maybe_print REBOOT
maybe_print KERNEL_PACKAGE
maybe_print EXTRA_PACKAGES
maybe_print EXTERNAL_IP
maybe_print EXTERNAL_IPV6
maybe_print ZFS
maybe_print CONFIGURE_FIREWALL
maybe_print LIMIT_SSH
maybe_print CUSTOMIZE_ETC_ISSUE
maybe_print GROUPS

echo ""

# Global environment passed to child scripts.
export DEBIAN_FRONTEND=noninteractive

function set_hostname() {
    echo "$MAYBE_FQDN" > /etc/hostname
    hostname -F /etc/hostname
    sed "s/127.0.1.1.*//" -i /etc/hosts
    echo "$EXTERNAL_IP $FQDN $HOSTNAME" >> /etc/hosts
}

function set_etc_issue() {
    sed "s/\(Ubuntu.*\)/\1 $EXTERNAL_IP $EXTERNAL_IPV6/" -i /etc/issue
}

function configure_apt() {
    # Work around connectivity issues; the Linode will hit the
    # public Ubuntu security mirror using IPv6 without this, which
    # sometimes has intermittent connectivity.
    cat > /etc/apt/apt.conf.d/99force-ipv4 << EOF
Acquire::ForceIPv4 "true";
EOF
}

function install_grub() {
    # This allows apt to run unattended.
    grub-install /dev/sda
    update-grub
}

function apt_upgrade() {
    # Non-interactive apt upgrade.
    apt-get update
    apt-get -yu \
        -o Dpkg::Options::="--force-confold" \
        dist-upgrade
}

function install_packages() {
    # Install any additional packages, plus the latest hardware enablement kernel.
    # According to https://wiki.ubuntu.com/Kernel/LTSEnablementStack --
    # "These newer enablement stacks are meant for desktop and server and even
    # recommended for cloud or virtual images."
    apt-get -yu install --install-recommends \
        "${KERNEL_PACKAGE}" \
        $EXTRA_PACKAGES
}

function import_ssh() {
    # Switch from password login to SSH login.
    if [ "$USERNAME" != "" ]; then
        IMPORT_COMMAND="sudo -Hu ${USERNAME} ssh-import-id"
    else
        IMPORT_COMMAND=ssh-import-id
    fi
    if [ "$LAUNCHPAD_ACCOUNT" != "" ]; then
        if $IMPORT_COMMAND "${LAUNCHPAD_ACCOUNT}"; then
            sudo usermod -p '!' root
        else
            echo ""
            echo " *** SSH import failed: use root password for fallback. ***" 
        fi
    else
        echo ""
        echo " *** No Launchpad account specified: use password instead. ***" 
    fi
}

function configure_firewall() {
    if [ "$LIMIT_SSH" == "true" ]; then
        ufw limit ssh
    else
        ufw allow ssh
    fi
    ufw enable
}

function configure_user() {
    adduser --disabled-password --gecos "$GECOS" "$USERNAME"
    if [ "$GROUPS" != "" ]; then
        usermod -G "$GROUPS" "$USERNAME"
    fi
    cat > /etc/sudoers.d/linode << EOF
    $USERNAME ALL = NOPASSWD: ALL
EOF
}

function reboot() {
    /sbin/shutdown -r now
}

if [ "$USERNAME" != "" ]; then
    configure_user
fi

import_ssh

set_hostname

if [ "$CUSTOMIZE_ETC_ISSUE" == "true" ]; then
    set_etc_issue
fi

configure_apt
install_grub
apt_upgrade
install_packages

if [ "$CONFIGURE_FIREWALL" == "true" ]; then
    configure_firewall
fi

if [ "$REBOOT" == "true" ]; then
    # Use a trap here so that this script can be sourced.
    trap reboot EXIT
fi
