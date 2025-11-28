#!/bin/bash
#Harbor on Ubuntu 18.04
# https://gist.github.com/kacole2/95e83ac84fec950b1a70b0853d6594dc
# https://github.com/goharbor/harbor/releases # v2.10.1
set -x 

if [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" ]]; then
    if [[ "$VERSION_ID" == 8* ]]; then
        ANSIBLE_PLAYBOOK="sudo -E /usr/local/bin/ansible-playbook"
    elif [[ "$VERSION_ID" == 9* ]]; then
        ANSIBLE_PLAYBOOK="sudo -E /usr/bin/ansible-playbook"
    else
        echo "Unsupported version: $VERSION_ID"
        exit 1
    fi
fi

check_and_start_docker() {
    if ! command -v docker &> /dev/null; then
        # Docker is not installed, install it
        echo "Docker is not installed. Installing..."
        sudo apt update
        sudo apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
        sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu jammy stable"
        sudo apt-get update
        sudo apt-get install -y docker-ce

        # Install Docker Compose
        sudo curl -L https://github.com/docker/compose/releases/latest/download/docker-compose-Linux-x86_64 -o /usr/local/bin/docker-compose &
        wait $!
        sudo chmod +x /usr/local/bin/docker-compose
        sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
    fi

    # Check if Docker service is running
    if ! sudo systemctl is-active --quiet docker; then
        # Docker service is not running, start it
        echo "Docker service is not running. Starting Docker..."
        sudo systemctl start docker
    fi
}

# Support both Let's Encrypt and Step-CA modes
# Usage: harbor.sh <domain> <harbor-version> [step-ca|letsencrypt] [aws_access_key_id] [aws_secret_access_key] [email]

DOMAIN=${1}
HARBORVERSION=${2}
CERT_MODE=${3:-letsencrypt}

if [ "$CERT_MODE" == "step-ca" ]; then
    # Step-CA mode - certs should already be at /etc/harbor/certs/
    if [ ! -f /etc/harbor/certs/harbor.crt ]; then
        echo "[ERROR] Step-CA mode requires certificates at /etc/harbor/certs/"
        exit 1
    fi
    GUID="${4:-harbor}"
elif [ "$CERT_MODE" == "letsencrypt" ]; then
    AWS_ACCESS_KEY_ID=${4}
    AWS_SECRET_ACCESS_KEY=${5}
    EMAIL=${6}
    GUID=${7:-harbor}
    
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$EMAIL" ]; then
        echo "Usage for Let's Encrypt: $0 <domain> <harbor-version> letsencrypt <aws_key> <aws_secret> <email> [guid]"
        exit 1
    fi
else
    echo "Usage: $0 <domain> <harbor-version> <step-ca|letsencrypt> [additional params...]"
    exit 1
fi

if [ -z $HARBORVERSION ]; then
    HARBORVERSION=$(curl -s https://api.github.com/repos/goharbor/harbor/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
fi


hostnamectl set-hostname harbor.${DOMAIN}

check_and_start_docker

# Handle certificates based on mode
if [ "$CERT_MODE" == "step-ca" ]; then
    echo "[INFO] Using Step-CA certificates from /etc/harbor/certs/"
    CERT_PATH="/etc/harbor/certs/harbor.crt"
    KEY_PATH="/etc/harbor/certs/harbor.key"
    ls -la /etc/harbor/certs/
elif [ "$CERT_MODE" == "letsencrypt" ]; then
    if [ ! -f /etc/letsencrypt/live/harbor.${DOMAIN}/fullchain.pem ]; then
        echo "[INFO] Requesting Let's Encrypt certificate..."
        mkdir -p /etc/letsencrypt/
        docker run --rm -i \
            --env AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
            --env AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
            -v "/etc/letsencrypt:/etc/letsencrypt" \
            certbot/dns-route53 \
            certonly \
            --dns-route53 \
            -d "harbor.${DOMAIN}" \
            --agree-tos \
            --email "${EMAIL}" \
            --non-interactive
    fi
    CERT_PATH="/etc/letsencrypt/live/harbor.${DOMAIN}/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/harbor.${DOMAIN}/privkey.pem"
    ls -lath /etc/letsencrypt/live/harbor.${DOMAIN}/
fi

IPorFQDN=$(hostname -f)
# Housekeeping
apt update -y
swapoff --all
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

# Allow incoming traffic on HTTP (port 80) and HTTPS (port 443)
ufw allow 80/tcp
ufw allow 443/tcp

# Allow incoming traffic on Harbor HTTP (port 8080) and HTTPS (port 8443)
ufw allow 8080/tcp
ufw allow 8443/tcp
# Allow incoming traffic on SSH (port 22)
ufw allow ssh

# Enable UFW
ufw --force enable
echo "Housekeeping done"

echo "Starting Harbor install"
echo "Harbor Version: $HARBORVERSION"

#Install Latest Stable Harbor Release


if [ -f /root/harbor-online-installer-$HARBORVERSION.tgz ]; then
    echo "Harbor $HARBORVERSION already exists"
    cd /root
    tar xvf harbor-online-installer-$HARBORVERSION.tgz || exit $?
else
    #curl -s https://api.github.com/repos/goharbor/harbor/releases/latest | grep browser_download_url | grep online | cut -d '"' -f 4 | wget -qi -
    cd /root
    curl -OL https://github.com/goharbor/harbor/releases/download/$HARBORVERSION/harbor-online-installer-$HARBORVERSION.tgz
    tar xvf harbor-online-installer-$HARBORVERSION.tgz || exit $?
fi

cd /root/harbor
cp harbor.yml.tmpl harbor.yml
sed -i "s/reg.mydomain.com/$IPorFQDN/g" harbor.yml
sed -i "s|# external_url:.*|external_url: https://$IPorFQDN|g" harbor.yml
sed -i "s|certificate: /your/certificate/path|certificate: ${CERT_PATH}|" harbor.yml
sed -i "s|private_key: /your/private/key/path|private_key: ${KEY_PATH}|" harbor.yml
cat harbor.yml
./install.sh

echo ""
echo "========================================"
echo "Harbor Installation Complete"
echo "========================================"
echo "URL: https://$IPorFQDN"
echo "Username: admin"
echo "Password: Harbor12345"
echo ""
echo "To login: docker login -u admin -p Harbor12345 $IPorFQDN"
echo "========================================"
