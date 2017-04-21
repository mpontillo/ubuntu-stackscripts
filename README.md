# Ubuntu StackScripts

This repository contains my Linode StackScript for deploying Ubuntu.

## Ubuntu LTS Cloud Deployment

Creates a modern Ubuntu 16.04 "Xenial" LTS build from the Linode image, intended to mimic the behavior of the Ubuntu cloud images.

### Features
 - Allows the installation of arbitrary apt packages.
 - Installs the latest "enablement" kernel.
 - Optionally configures ZFS.
   * Requires GRUB 2 to be set in the configuration profile.
 - Configures the system hostname and domain name.
 - Optionally customizes /etc/issue with the external system IPs
 - Creates a normal (unprivileged) user account.
   * Allows configuration of user groups.
   * Allows configuration of GECOS field.
 - Imports SSH keys from Launchpad.
 - Enables the firewall.
   * Enables `ufw`.
   * Optionally limits incoming SSH connections.

**IMPORTANT:** After rebuilding or installing a Linode using this script, it is intended that you set your Linode's configuration profile to boot with GRUB 2. If you are using a Linode-provided kernel, ZFS kernel modules will fail to load.
