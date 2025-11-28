#!/bin/bash
#export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
#set -x
# https://github.com/quay/mirror-registry
# Usage: ./configure-quay.sh domain quay_version ca_url fingerprint

if [ $# -ne 5 ]; then
    echo "Usage: $0 <domain> <quay_version> <ca_url> <fingerprint> <password>"
    exit 1
fi

DOMAIN=${1}
QUAY_VERSION=${2}
CA_URL=${3}
FINGERPRINT=${4}
SSH_PASSWORD=${5}

# Check if the user is root, if not exit
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root"
    exit 1
fi

sudo dnf update -y
sudo dnf install curl wget tar jq skopeo httpd-tools openssl nano nfs-utils bash-completion bind-utils ansible-core vim libvirt firewalld acl policycoreutils-python-utils -y
sudo dnf -y install \
  podman \
  skopeo \
  buildah \
  sshpass

# IP address of the target machine
IP_ADDRESS=$(hostname -I | awk '{print $1}')
echo "Attempting to SSH to ${IP_ADDRESS}"

# Define the user and the SSH key directory for root
SSH_USER="cloud-user"
SSH_KEY_DIR="/root/.ssh"
KEY_PATH="${SSH_KEY_DIR}/id_rsa"

# Function to check if the host is known
check_known_host() {
    local host=$1
    local known_hosts="${SSH_KEY_DIR}/known_hosts"
    ssh-keygen -F "$host" -f "$known_hosts" >/dev/null
    return $?
}

# Attempt to check the known_hosts file for the target host
if check_known_host "$IP_ADDRESS"; then
    echo "Host ${IP_ADDRESS} is known. Trying to connect."
    # Try to connect using existing keys
    if sudo ssh -o BatchMode=yes -o ConnectTimeout=5 ${SSH_USER}@"${IP_ADDRESS}" exit 2>/dev/null; then
        echo "SSH connection successful, exiting."
    else
        echo "SSH connection failed, but host is known. Check authentication."
        exit 1
    fi
else
    echo "Host ${IP_ADDRESS} is not known. Proceeding with key setup."

    # Check if SSH key exists, if not generate one
    if [ ! -f "${KEY_PATH}" ]; then
        echo "No SSH key found, generating one."
        # Ensure SSH key directory exists
        sudo mkdir -p "${SSH_KEY_DIR}"
        sudo chmod 700 "${SSH_KEY_DIR}"
        rm -rf /root/.ssh/id_rsa 
        ssh-keygen -f  /root/.ssh/id_rsa -t rsa -N '' || exit $?
    else
        echo "SSH key already exists at ${KEY_PATH}."
        sudo chmod 600 "${KEY_PATH}" # Ensure the key has correct permissions
    fi

    # Copy the SSH key to the target machine
    if ! sshpass -p "$SSH_PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no cloud-user@"${IP_ADDRESS}"; then
        echo "Failed to copy SSH key to ${IP_ADDRESS}"
        exit 1
    fi
fi

#==============================================================================
# Non-root podman hacks
sudo chmod 4755 /usr/bin/newgidmap
sudo chmod 4755 /usr/bin/newuidmap

sudo dnf reinstall -yq shadow-utils

cat > /tmp/xdg_runtime_dir.sh <<EOF
export XDG_RUNTIME_DIR="\$HOME/.run/containers"
EOF

sudo mv /tmp/xdg_runtime_dir.sh /etc/profile.d/xdg_runtime_dir.sh
sudo chmod a+rx /etc/profile.d/xdg_runtime_dir.sh
sudo cp /etc/profile.d/xdg_runtime_dir.sh /etc/profile.d/xdg_runtime_dir.zsh


cat > /tmp/ping_group_range.conf <<EOF
net.ipv4.ping_group_range=0 2000000
EOF
sudo mv /tmp/ping_group_range.conf /etc/sysctl.d/ping_group_range.conf

sudo sysctl --system

if ! grep -q "0" /proc/sys/net/ipv4/ip_unprivileged_port_start; then
    sudo tee "/proc/sys/net/ipv4/ip_unprivileged_port_start" <<< "0"
fi


if ! command -v step >/dev/null 2>&1; then
    wget https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.rpm
    sudo rpm -i step-cli_amd64.rpm
fi

hostnamectl set-hostname mirror-registry.${DOMAIN}

if [ ! -f /root/.step/config/defaults.json ];
then 
    step ca bootstrap --ca-url ${CA_URL} --fingerprint ${FINGERPRINT} || exit $?
    step certificate install $(step path)/certs/root_ca.crt
fi

# Create password file for Step-CA
mkdir -p /etc/step
if [ -f /tmp/initial_password ]; then
    cp /tmp/initial_password /etc/step/initial_password
else
    # Use SSH_PASSWORD as fallback for Step-CA provisioner password
    echo "${SSH_PASSWORD}" > /etc/step/initial_password
fi
chmod 600 /etc/step/initial_password

if [ ! -f /root/quay-certs/mirror-registry.${DOMAIN}.crt ];
then
  mkdir -p /root/quay-certs
  cd /root/quay-certs
  echo "[INFO] Requesting certificate from Step-CA..."
  # Use admin@example.com provisioner (default Step-CA JWK provisioner)
  TOKEN=$(step ca token mirror-registry.${DOMAIN} --password-file=/etc/step/initial_password --provisioner="admin@example.com")
  # Use 24h duration (Step-CA default max)
  step ca certificate --token $TOKEN --not-after=24h mirror-registry.${DOMAIN} mirror-registry.${DOMAIN}.crt mirror-registry.${DOMAIN}.key || {
      echo "[ERROR] Failed to get certificate from Step-CA"
      exit 1
  }
  echo "[OK] Certificate obtained"
fi


if [  ! -f /root/mirror-registry-offline.tar.gz ];
then
    cd /root/
    curl -OL "https://github.com/quay/mirror-registry/releases/download/${QUAY_VERSION}/mirror-registry-offline.tar.gz"
    tar -zxvf mirror-registry-offline.tar.gz || exit $?
fi 

sudo mkdir -p /registry/
sudo chmod -R 775 /registry/
sudo chown cloud-user:cloud-user  -R  /registry/
sudo chown cloud-user:cloud-user  -R /home/cloud-user 


echo "[INFO] Installing mirror-registry with Step-CA certificate..."
cd /root

# Ensure tarball is extracted
if [ ! -f /root/mirror-registry ]; then
    tar -zxvf mirror-registry-offline.tar.gz || exit 1
fi
chmod +x /root/mirror-registry

# Create cloud-user .run directory for podman
mkdir -p /home/cloud-user/.run/containers
chown -R cloud-user:cloud-user /home/cloud-user/.run

# Install with Step-CA certs
./mirror-registry install \
    --quayRoot /registry/ \
    --quayHostname mirror-registry.${DOMAIN} \
    --sslCert /root/quay-certs/mirror-registry.${DOMAIN}.crt \
    --sslKey /root/quay-certs/mirror-registry.${DOMAIN}.key \
    --targetUsername cloud-user \
    --ssh-key ~/.ssh/id_rsa \
    --initPassword ${SSH_PASSWORD} \
    --verbose 2>&1 | tee /root/mirror-registry-offline.log

if [ $? -eq 0 ]; then
    echo "[OK] Mirror-registry installed successfully"
else
    echo "[ERROR] Mirror-registry installation failed - check /root/mirror-registry-offline.log"
    exit 1
fi
