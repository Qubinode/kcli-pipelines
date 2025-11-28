#!/bin/bash
# Jumpserver Configuration Script
# Installs GUI desktop and tools on the jumpserver VM
#
# Usage: ./configure-jumpserver.sh <domain> <dns_ip> <password>

set -euo pipefail
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

DOMAIN="${1:-example.com}"
DNS_IP="${2:-8.8.8.8}"
PASSWORD="${3:-password}"

echo "========================================"
echo "Jumpserver Configuration"
echo "========================================"
echo "Domain: ${DOMAIN}"
echo "DNS: ${DNS_IP}"
echo "========================================"

# Detect OS
if [ -f /etc/redhat-release ]; then
    if grep -q "CentOS" /etc/redhat-release; then
        OS="centos"
    else
        OS="rhel"
    fi
else
    OS="unknown"
fi
echo "[INFO] Detected OS: ${OS}"

# Set hostname
echo "[INFO] Setting hostname..."
hostnamectl set-hostname jumpserver.${DOMAIN}

# Configure DNS
echo "[INFO] Configuring DNS..."
CONN=$(nmcli -t -f NAME connection show --active | head -1)
if [ -n "$CONN" ]; then
    nmcli connection modify "$CONN" ipv4.dns "${DNS_IP},1.1.1.1"
    nmcli connection down "$CONN" && nmcli connection up "$CONN"
fi

# Update system
echo "[INFO] Updating system packages..."
dnf update -y

# Install EPEL for CentOS (needed for some packages)
if [ "$OS" == "centos" ]; then
    echo "[INFO] Installing EPEL repository..."
    dnf install -y epel-release
fi

# Install GNOME Desktop Environment
echo "[INFO] Installing GNOME Desktop Environment..."
echo "[INFO] This will take several minutes..."
dnf groupinstall -y "Server with GUI" --skip-broken || \
    dnf groupinstall -y "Workstation" --skip-broken || \
    dnf groupinstall -y "GNOME Desktop" --skip-broken || \
    echo "[WARN] Could not install full desktop, trying minimal..."

# Set graphical target as default
systemctl set-default graphical.target

# Install development and admin tools
echo "[INFO] Installing development tools..."
dnf install -y \
    git vim nano unzip wget tar curl jq tmux \
    bind-utils net-tools nmap-ncat \
    python3 python3-pip python3-devel \
    gcc make \
    bash-completion htop tree \
    || echo "[WARN] Some packages may not have installed"

# Install container tools
echo "[INFO] Installing container tools..."
dnf install -y podman podman-compose skopeo buildah || true

# Install VNC server
echo "[INFO] Installing VNC server..."
dnf install -y tigervnc-server || true

# Install xrdp for RDP access
echo "[INFO] Installing xrdp for RDP access..."
dnf install -y xrdp || true
systemctl enable xrdp || true
systemctl start xrdp || true

# Install web browser
echo "[INFO] Installing Firefox..."
dnf install -y firefox || true

# Install terminal emulator (if not present)
dnf install -y gnome-terminal || true

# Configure firewall
echo "[INFO] Configuring firewall..."
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-service=vnc-server || true
firewall-cmd --permanent --add-port=3389/tcp  # RDP
firewall-cmd --permanent --add-port=5901/tcp  # VNC
firewall-cmd --permanent --add-port=5902/tcp  # VNC display 2
firewall-cmd --reload

# Install kubectl
echo "[INFO] Installing kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/

# Install helm
echo "[INFO] Installing helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || true

# Install step CLI
echo "[INFO] Installing step CLI..."
wget -q https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.rpm -O /tmp/step-cli.rpm
rpm -i /tmp/step-cli.rpm 2>/dev/null || rpm -U /tmp/step-cli.rpm || true

# Install oc CLI (OpenShift)
echo "[INFO] Installing OpenShift CLI..."
cd /tmp
curl -OL https://raw.githubusercontent.com/tosin2013/openshift-4-deployment-notes/master/pre-steps/configure-openshift-packages.sh
chmod +x configure-openshift-packages.sh
./configure-openshift-packages.sh -i 2>/dev/null || echo "[WARN] OpenShift CLI install completed with warnings"

# Configure user
USER="cloud-user"
echo "[INFO] Configuring user ${USER}..."

# Create .vnc directory and set VNC password
mkdir -p /home/${USER}/.vnc
echo "${PASSWORD}" | vncpasswd -f > /home/${USER}/.vnc/passwd
chmod 600 /home/${USER}/.vnc/passwd
chown -R ${USER}:${USER} /home/${USER}/.vnc

# Create VNC xstartup script
cat > /home/${USER}/.vnc/xstartup << 'XSTARTUP'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec /etc/X11/xinit/xinitrc
XSTARTUP
chmod +x /home/${USER}/.vnc/xstartup
chown ${USER}:${USER} /home/${USER}/.vnc/xstartup

# Create systemd service for VNC
cat > /etc/systemd/system/vncserver@.service << 'VNCSERVICE'
[Unit]
Description=Remote desktop service (VNC)
After=syslog.target network.target

[Service]
Type=simple
User=%i
PAMName=login
PIDFile=/home/%i/.vnc/%H%i.pid
ExecStartPre=/bin/sh -c '/usr/bin/vncserver -kill :1 > /dev/null 2>&1 || :'
ExecStart=/usr/bin/vncserver :1 -geometry 1920x1080 -depth 24
ExecStop=/usr/bin/vncserver -kill :1

[Install]
WantedBy=multi-user.target
VNCSERVICE

systemctl daemon-reload

# Set ownership
chown -R ${USER}:${USER} /home/${USER}/

echo ""
echo "========================================"
echo "Jumpserver Configuration Complete"
echo "========================================"
echo ""
echo "Desktop: GNOME"
echo "User: ${USER}"
echo ""
echo "Access Methods:"
echo "  1. SSH: ssh ${USER}@<IP>"
echo ""
echo "  2. VNC (recommended):"
echo "     - Start VNC: vncserver :1 -geometry 1920x1080"
echo "     - Connect to: <IP>:5901"
echo "     - Password: ${PASSWORD}"
echo ""
echo "  3. RDP (if xrdp installed):"
echo "     - Connect to: <IP>:3389"
echo "     - Use system credentials"
echo ""
echo "  4. Console (via kcli):"
echo "     - kcli console jumpserver"
echo ""
echo "IMPORTANT: Reboot the VM to start the graphical desktop:"
echo "  sudo reboot"
echo ""
echo "========================================"
