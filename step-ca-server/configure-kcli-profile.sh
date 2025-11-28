#!/bin/bash
#export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -x

# Function to get OS and version
get_os_version() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION_ID=$VERSION_ID
    else
        log "Cannot determine OS version. /etc/os-release not found."
        exit 1
    fi
}

# Function to determine the command based on the OS and version
determine_command_yaml() {
    get_os_version

    if [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" ]]; then
        if [[ "$VERSION_ID" == 8* ]]; then
            COMMAND="update-yaml"
        elif [[ "$VERSION_ID" == 9* ]]; then
            COMMAND="update_yaml"
        else
            log "Unsupported version: $VERSION_ID"
            exit 1
        fi
    else
        log "Unsupported OS: $OS"
        exit 1
    fi
}

if [ -f /opt/kcli-pipelines/helper_scripts/default.env ];
then 
  source /opt/kcli-pipelines/helper_scripts/default.env
elif [ -f helper_scripts/default.env  ];
then 
  source helper_scripts/default.env 
else
  echo "default.env file does not exist"
  exit 1
fi
source helper_scripts/helper_functions.sh

cd $KCLI_SAMPLES_DIR

/usr/local/bin/ansiblesafe -f "${ANSIBLE_VAULT_FILE}" -o 1
/usr/local/bin/ansiblesafe -f "${ANSIBLE_VAULT_FILE}" -o 2
PASSWORD=$(yq eval '.admin_user_password' "${ANSIBLE_VAULT_FILE}")
RHSM_ORG=$(yq eval '.rhsm_org' "${ANSIBLE_VAULT_FILE}")
RHSM_ACTIVATION_KEY=$(yq eval '.rhsm_activationkey' "${ANSIBLE_VAULT_FILE}")
OFFLINE_TOKEN=$(yq eval '.offline_token' "${ANSIBLE_VAULT_FILE}")
PULL_SECRET=$(yq eval '.openshift_pull_secret' "${ANSIBLE_VAULT_FILE}")
VM_NAME=rhel9-step-ca-$(echo $RANDOM | md5sum | head -c 5; echo;)
IMAGE_NAME=rhel9
DNS_FORWARDER=$(yq eval '.dns_forwarder' "${ANSIBLE_ALL_VARIABLES}")
DOMAIN=$(yq eval '.domain' "${ANSIBLE_ALL_VARIABLES}")
DISK_SIZE=200
KCLI_USER=$(yq eval '.admin_user' "${ANSIBLE_ALL_VARIABLES}")
# FreeIPA DNS ADDRESS
export vm_name="freeipa"
export ip_address=$(sudo kcli info vm "$vm_name" "$vm_name" | grep ip: | awk '{print $2}' | head -1)

COMMUNITY_VERSION="$(echo -e "${COMMUNITY_VERSION}" | tr -d '[:space:]')"

echo "COMMUNITY_VERSION is set to: $COMMUNITY_VERSION"

if [ "$COMMUNITY_VERSION" == "true" ]; then
  echo "Community version"
  export IMAGE_NAME=centos9stream
  export TEMPLATE_NAME=template-centos.yaml
  export LOGIN_USER=cloud-user
  echo "IMAGE_NAME: $IMAGE_NAME"
  echo "TEMPLATE_NAME: $TEMPLATE_NAME"
elif [ "$COMMUNITY_VERSION" == "false" ]; then
  echo "Enterprise version"
  export IMAGE_NAME=rhel9
  export TEMPLATE_NAME=template.yaml
  export LOGIN_USER=cloud-user
  echo "IMAGE_NAME: $IMAGE_NAME"
  echo "TEMPLATE_NAME: $TEMPLATE_NAME"
else
  echo "Correct $COMMUNITY_VERSION not set"
  exit 1
fi


if [ -z "${INITIAL_PASSWORD}"];
then 
  INITIAL_PASSWORD="password"
else
  echo "INITIAL_PASSWORD is set to ${INITIAL_PASSWORD}"
fi 

sudo rm -rf kcli-profiles.yml
if [ -f /home/${KCLI_USER}/.kcli/profiles.yml ]; then
  sudo cp  /home/${KCLI_USER}/.kcli/profiles.yml kcli-profiles.yml
else 
    sudo mkdir -p /home/${KCLI_USER}/.kcli
    sudo mkdir -p /root/.kcli
fi
if [ -d /home/${KCLI_USER}/.generated/vmfiles ]; then
  echo "generated directory already exists"
else
  sudo mkdir -p  /home/${KCLI_USER}/.generated/vmfiles
  sudo mkdir -p  /root/.generated/vmfiles
fi

if [ "$IMAGE_NAME" == "centos9stream" ]; then
  echo "Using community version (CentOS 9 Stream)"
cat >/tmp/vm_vars.yaml<<EOF
image: ${IMAGE_NAME}
user: ${LOGIN_USER}
user_password: ${PASSWORD}
disk_size: ${DISK_SIZE} 
numcpus: 4
memory: 8192
net_name: ${NET_NAME} 
reservedns: ${DNS_FORWARDER}
domainname: ${DOMAIN}
initial_password: ${INITIAL_PASSWORD}
freeipa_dns: ${ip_address}
EOF
  determine_command_yaml
  sudo python3 profile_generator/profile_generator.py $COMMAND  step-ca-server step-ca-server/template-centos.yaml --vars-file /tmp/vm_vars.yaml
elif [ "$IMAGE_NAME" == "rhel9" ]; then
  echo "Using RHEL 9 version"
cat >/tmp/vm_vars.yaml<<EOF
image: ${IMAGE_NAME}
user: ${LOGIN_USER}
user_password: ${PASSWORD}
disk_size: ${DISK_SIZE} 
numcpus: 4
memory: 8192
net_name: ${NET_NAME} 
reservedns: ${DNS_FORWARDER}
domainname: ${DOMAIN}
offline_token: ${OFFLINE_TOKEN}
rhnorg: ${RHSM_ORG}
rhnactivationkey: ${RHSM_ACTIVATION_KEY} 
initial_password: ${INITIAL_PASSWORD}
freeipa_dns: ${ip_address}
EOF
  determine_command_yaml
  sudo python3 profile_generator/profile_generator.py $COMMAND step-ca-server step-ca-server/template.yaml  --vars-file /tmp/vm_vars.yaml
else
  echo "Correct IMAGE_NAME: $IMAGE_NAME not set"
  exit 1
fi

#cat  kcli-profiles.yml
/usr/local/bin/ansiblesafe -f "${ANSIBLE_VAULT_FILE}" -o 1
sudo cp kcli-profiles.yml /home/${KCLI_USER}/.kcli/profiles.yml
sudo cp kcli-profiles.yml /root/.kcli/profiles.yml
#echo "Creating VM ${VM_NAME}"
#sudo kcli create vm -p rhel9 ${VM_NAME} --wait