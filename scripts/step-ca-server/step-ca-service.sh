#!/bin/bash

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

jq '.authority.provisioners[0].claims = {"minTLSCertDuration": "5m", "maxTLSCertDuration": "2000h", "defaultTLSCertDuration": "2000h"}' .step/config/ca.json > .step/config/ca.json.tmp
mv .step/config/ca.json .step/config/ca.json.bak
mv .step/config/ca.json.tmp .step/config/ca.json

# Create the systemd service file
cat > /etc/systemd/system/step-ca.service << EOF
[Unit]
Description=Smallstep CA Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/step-ca /root/.step/config/ca.json --password-file=/etc/step/initial_password
StandardOutput=file:/var/log/step-ca.log
StandardError=file:/var/log/step-ca.log
Restart=always
RestartSec=10s
User=root
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd to recognize new or changed units
systemctl daemon-reload

# Enable the step-ca service to start at boot
systemctl enable step-ca

# Start the service right now
systemctl start step-ca

# Display status
systemctl status step-ca
