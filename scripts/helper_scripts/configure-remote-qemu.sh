#!/bin/bash

if [ $# -ne 2 ]; then
  echo "Usage: $0 <user_name> <ip_address>"
  exit 1
fi
USER_NAME=$1
IP_ADDRESS=$2



echo "ssh-keygen -t rsa -b 4096 -f ~/.ssh/cluster-key -N ''"
echo "ssh-copy-id -i ~/.ssh/cluster-key ${USER_NAME}@${IP_ADDRESS}"

# Step 1: Create the libvirt group
sudo groupadd libvirt

# Step 2: Update the libvirt configuration
sudo sed -i 's/#unix_sock_group = "libvirt"/unix_sock_group = "libvirt"/g' /etc/libvirt/libvirtd.conf
sudo sed -i 's/#unix_sock_rw_perms = "0770"/unix_sock_rw_perms = "0770"/g' /etc/libvirt/libvirtd.conf
sudo service libvirtd restart

# Step 3: Manage group membership
sudo usermod -G libvirt -a $USER_NAME

virsh -c qemu+ssh://$USER_NAME@$IP_ADDRESS/system
