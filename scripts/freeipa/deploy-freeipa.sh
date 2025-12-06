#!/bin/bash
#export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
#set -xe
if [ -f ../helper_scripts/default.env ];
then 
  source ../helper_scripts/default.env
elif [ -f helper_scripts/default.env  ];
then 
  source helper_scripts/default.env 
else
  echo "default.env file does not exist"
  exit 1
fi

if [ $TARGET_SERVER == "rhel9-equinix" ] || [ $TARGET_SERVER == "rhel8-equinix" ];
then 
  ANSIBLE_GALAXY=/root/.local/bin/ansible-galaxy
else 
  ANSIBLE_GALAXY=/usr/local/bin/ansible-galaxy
fi


cd $KCLI_SAMPLES_DIR


if [ ! -d /opt/freeipa-workshop-deployer ];
then 
  cd /opt/
  git clone https://github.com/tosin2013/freeipa-workshop-deployer.git
  cd freeipa-workshop-deployer
else
  cd /opt/freeipa-workshop-deployer
  git config pull.rebase false
  git pull
fi 

cp example.vars.sh vars.sh
sed -i 's/INFRA_PROVIDER=.*/INFRA_PROVIDER="kcli"/' vars.sh
sed -i 's/INVENTORY=.*/INVENTORY='${INVENTORY}'/' vars.sh
sed -i 's/KCLI_NETWORK=.*/KCLI_NETWORK="'${NET_NAME}'"/' vars.sh

# Check if the argument is "create" or "destroy"
if [ "$1" == "create" ]; then
    echo "Creating..."
    export COMMUNITY_VERSION="${COMMUNITY_VERSION}"
    /opt/freeipa-workshop-deployer/1_kcli/create.sh
    /opt/freeipa-workshop-deployer/2_ansible_config/configure.sh
    /opt/qubinode-pipelines/configure-dns.sh
elif [ "$1" == "destroy" ]; then
    echo "Destroying..."
   /opt/freeipa-workshop-deployer/1_kcli/destroy.sh
else
    echo "Invalid argument. Usage: $0 [create|destroy]"
    exit 1
fi