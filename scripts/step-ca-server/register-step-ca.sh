#!/bin/bash 

# Pass https://step-ca-server.example.com and xxxxx as arguments
if [ $# -ne 2 ]; then
    echo "Please pass the CA URL and fingerprint as arguments"
    echo "Usage: $0 <ca-url> <fingerprint>"
    exit 1
fi

CA_URL=$1
FINGERPRINT=$2

if ! command -v step >/dev/null 2>&1; then
    wget https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.rpm
    sudo rpm -i step-cli_amd64.rpm
fi

step ca
step ca bootstrap --ca-url ${CA_URL} --fingerprint ${FINGERPRINT}
cat ${HOME}/.step/certs/root_ca.crt
step certificate install $(step path)/certs/root_ca.crt