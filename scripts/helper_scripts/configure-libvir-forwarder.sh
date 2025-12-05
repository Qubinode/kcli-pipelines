#!/bin/bash

# Check if two arguments are passed
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <network-name> <forwarder-ip>"
    exit 1
fi

# Assign arguments to variables
NETWORK_NAME="$1"
FORWARDER_IP="$2"

# Check if the network exists
virsh net-info "$NETWORK_NAME" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Network $NETWORK_NAME does not exist."
    exit 1
fi

# Get the current network XML
NETWORK_XML=$(virsh net-dumpxml "$NETWORK_NAME")

# Check for xmlstarlet and install if needed
if ! command -v xmlstarlet &> /dev/null; then
    echo "xmlstarlet could not be found, attempting to install it."
    # Attempt to install xmlstarlet. Uncomment the line for your distribution.
    # sudo apt-get install xmlstarlet   # For Ubuntu/Debian
    # sudo yum install xmlstarlet       # For CentOS/RHEL
    # sudo dnf install xmlstarlet       # For Fedora
    # sudo pacman -S xmlstarlet         # For Arch Linux
    # return to the start if install was successful
    command -v xmlstarlet &> /dev/null && exec "$0" "$@"
    # exit if install failed
    exit 1
fi

# Use 'xmlstarlet' to add the forwarder
echo "$NETWORK_XML" | xmlstarlet ed --subnode "/network/dns" --type elem -n forwarder -v "" \
  --insert "/network/dns/forwarder[not(@addr)]" --type attr -n addr -v "$FORWARDER_IP" > /tmp/network_with_forwarder.xml

# Define the network with the new changes
virsh net-define /tmp/network_with_forwarder.xml

# Clean up
rm /tmp/network_with_forwarder.xml

echo "DNS forwarder $FORWARDER_IP added to network $NETWORK_NAME. Please restart the network to apply changes."
