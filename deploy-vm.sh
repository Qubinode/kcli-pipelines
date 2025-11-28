#!/bin/bash
set -euo pipefail
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -x
export ANSIBLE_HOST_KEY_CHECKING=False


# Checks if a virtual machine with the given name exists.
# Arguments:
#   vm_name: The name of the virtual machine to check.
# Returns:
#   0 if the virtual machine exists, 1 otherwise.
function vm_exists() {
    local vm_name=$1
    local exists=$(sudo kcli list vm | grep -c $vm_name)
    return $exists
}


# This function checks if an IDM (Identity Management) service is reachable over HTTPS.
# Arguments:
#   $1 - The hostname or IP address of the IDM service.
# Usage:
#   check_idm <idm_hostname_or_ip>
# Example:
#   check_idm idm.example.com
# If the IDM service is reachable, it prints a success message.
# If the IDM service is not reachable, it prints an error message and exits with status 1.
function check_idm() {
  local idm="$1"
  if curl --head --insecure --silent "https://$idm" > /dev/null; then
    echo "IDM is reachable over HTTPS."
  else
    echo "IDM is not reachable over HTTPS. Exiting."
    exit 1
  fi
}


# This function returns the default cloud user for a given VM name.
# Usage: return_cloud_user <vm_name>
# Arguments:
#   vm_name: The name of the virtual machine.
# Returns:
#   The default cloud user for the specified VM name.
#   - "fedora" for VMs named "mirror-registry" or "openshift-jumpbox".
#   - "cloud-user" for VMs named "microshift-demos", "device-edge-workshops", "ansible-aap", "rhel9-pxe", "rhel9-step-ca", "rhel9", or "rhel8".
#   - "Unknown VM name" for any other VM names.
function return_cloud_user() {
    local vm_name=$1
    case $vm_name in
        mirror-registry|openshift-jumpbox)
            echo "fedora"
            ;;
        microshift-demos|device-edge-workshops|ansible-aap|rhel9-pxe|rhel9-step-ca|rhel9|rhel8|rhel10)
            echo "cloud-user"
            ;;
        *)
            echo "Unknown VM name"
            ;;
    esac
}


# This function configures the IDM container for a given VM.
# It takes two arguments:
#   1. vm_name: The name of the virtual machine.
#   2. dns_forwarder: The DNS forwarder to be used.
# The function performs the following steps:
#   - Retrieves the domain name from the ANSIBLE_ALL_VARIABLES file using yq.
#   - If the vm_name is "freeipa", it retrieves the IP address of the VM.
#   - Checks if the IP address is already present in the /etc/hosts file.
#     - If not, it adds the IP address with the IDM domain to the /etc/hosts file.
#   - Checks if the IP address is already present in the /etc/resolv.conf file.
#     - If not, it updates the /etc/resolv.conf file with the IDM domain, DNS forwarder, and other options.
function configure_idm_container() {
  local vm_name="$1"
  local dns_forwarder="$2"
  local domain_name=$(yq eval '.domain' "${ANSIBLE_ALL_VARIABLES}")

  if [ "$vm_name" == "freeipa" ]; then
    local ip_address=$(sudo kcli info vm "$vm_name" "$vm_name" | grep ip: | awk '{print $2}' | head -1)
    echo "VM $vm_name created with IP address $ip_address"

    if grep -q "$ip_address" /etc/hosts; then
      echo "$ip_address already exists in the hosts file."
    else
      sudo tee -a /etc/hosts <<EOF
$ip_address idm.${domain_name}
EOF
      echo "Added $ip_address to the hosts file."
    fi

    if grep -q "nameserver $ip_address" /etc/resolv.conf; then
      echo "$ip_address already exists in the resolv.conf file."
    else
      sudo tee /etc/resolv.conf <<EOF
search ${domain_name}
domain ${domain_name}
nameserver $ip_address
nameserver $dns_forwarder
options rotate timeout:1
EOF
      echo "Added $ip_address to the resolv.conf file."
    fi
  fi
}


# This script defines a function `create_vm` that creates and configures a virtual machine (VM) based on the provided VM name.
# 
# Usage:
#   create_vm <vm_name> <action>
# 
# Parameters:
#   vm_name: The name of the VM to be created.
#   action: The action to be performed (currently not used in the function).
# 
# The function performs the following steps:
# 1. Retrieves the domain name from the ANSIBLE_ALL_VARIABLES file using `yq`.
# 2. Checks the VM name and performs specific actions based on the VM name:
#    - For "freeipa": If the VM exists, it runs the deploy-freeipa.sh script; otherwise, it configures DNS and exits.
#    - For "kcli-openshift4-baremetal": Runs the deploy.sh script for OpenShift 4 bare metal.
#    - For "ocp4-disconnected-helper": Runs the deploy.sh script for OpenShift 4 disconnected helper.
#    - For "openshift-agent-install": Runs the deploy.sh script for OpenShift agent install.
#    - For "ceph-cluster": Runs the deploy.sh script for Ceph cluster.
#    - For "kubernetes": Runs the deploy.sh script for Kubernetes.
#    - For "vyos-router": Runs the deploy.sh script for VyOS router.
#    - For other VM names: 
#      - Checks if the IDM server is available.
#      - Retrieves the DNS address and DNS forwarder from the ANSIBLE_ALL_VARIABLES file.
#      - If the VM exists, it creates the VM using `kcli` with the specified profile and DNS settings.
#      - Retrieves the IP address of the created VM.
#      - Adds an IPA entry for the VM using an Ansible playbook.
#      - Updates the hosts file with the VM details.
#      - Runs an Ansible playbook to update DNS settings.
# 
# Dependencies:
# - yq: A command-line YAML processor.
# - kcli: A command-line tool for managing VMs.
# - Ansible: An IT automation tool.
# - sudo: Allows a permitted user to execute a command as the superuser or another user.
# 
# Note:
# - The function assumes that certain environment variables (e.g., ANSIBLE_ALL_VARIABLES, ANSIBLE_VAULT_FILE, ANSIBLE_PLAYBOOK) are set.
# - The function uses `sudo` to execute commands with elevated privileges.
function create_vm() {
    local vm_name="$1"
    local action="$2"
    local domain_name=$(yq eval '.domain' "${ANSIBLE_ALL_VARIABLES}")

    if [[ $vm_name == "freeipa" ]]; then
        if vm_exists "$vm_name"; then
          sudo -E /opt/kcli-pipelines/freeipa/deploy-freeipa.sh create
        else
          echo "VM $vm_name already exists."
          sudo -E  /opt/kcli-pipelines/configure-dns.sh
          exit 0
        fi
    elif [[ $vm_name == "kcli-openshift4-baremetal" ]]; then
      sudo -E kcli-openshift4-baremetal/deploy.sh create
    elif [[ $vm_name == "ocp4-disconnected-helper" ]]; then
      sudo -E ocp4-disconnected-helper/deploy.sh create
    elif [[ $vm_name == "openshift-agent-install" ]]; then
      sudo -E openshift-agent-install/deploy.sh
    elif [[ $vm_name == "ceph-cluster" ]]; then
      sudo -E ceph-cluster/deploy.sh create
    elif [[ $vm_name == "kubernetes" ]]; then
      sudo -E kubernetes/deploy.sh create
    elif [[ $vm_name == "vyos-router" ]]; then
      sudo -E vyos-router/deploy.sh create
    else
        check_idm idm.$domain_name || exit $?
        local dns_address=$(sudo kcli info vm freeipa freeipa | grep ip: | awk '{print $2}' | head -1)
        local dns_forwarder=$(yq eval '.dns_forwarder' "${ANSIBLE_ALL_VARIABLES}")
        echo "Using DNS server $dns_address"
        if vm_exists "$vm_name"; then
          sudo kcli create vm -p $VM_PROFILE $vm_name -P dns=${dns_address} --wait  || exit $?
        else
          echo "VM $vm_name already exists."
        fi
        local ip_address=$(sudo kcli info vm $vm_name $vm_name | grep ip: | awk '{print $2}' | head -1)
        echo "VM $vm_name created with IP address $ip_address"
        $ANSIBLE_PLAYBOOK /opt/kcli-pipelines/helper_scripts/add_ipa_entry.yaml \
            --vault-password-file /root/.vault_password \
            --extra-vars "@${ANSIBLE_VAULT_FILE}" \
            --extra-vars "@${ANSIBLE_ALL_VARIABLES}" \
            --extra-vars "key=${vm_name}" \
            --extra-vars "freeipa_server_fqdn=idm.${domain_name}" \
            --extra-vars "value=${ip_address}" \
            --extra-vars "freeipa_server_domain=${domain_name}" \
            --extra-vars "action=present" -vvv
        sleep 25
        dig ${vm_name}
        local file_path="/opt/kcli-pipelines/helper_scripts/hosts"
        if [ -f "$file_path" ]; then
            if grep -q "^\[$vm_name\]$" "$file_path"; then
                sudo sed -i "s/^\[$vm_name\]\n.*$/"'[$vm_name]\n'"$ip_address"/ "$file_path"
            else
                echo "[$vm_name]" | sudo tee -a  "$file_path"
                local target_user=$(return_cloud_user $vm_name)
                echo "$vm_name ansible_host=${ip_address} ansible_user=$target_user ansible_ssh_private_key_file=/root/.ssh/id_rsa" | sudo tee -a  "$file_path"
            fi
        else
            echo "[$vm_name]" | sudo tee  "$file_path"
            local target_user=$(return_cloud_user $vm_name)
            echo "$vm_name ansible_host=${ip_address} ansible_user=$target_user ansible_ssh_private_key_file=/root/.ssh/id_rsa" | sudo tee -a  "$file_path"
        fi
        $ANSIBLE_PLAYBOOK /opt/kcli-pipelines/helper_scripts/update_dns.yaml -i /opt/kcli-pipelines/helper_scripts/hosts \
            --extra-vars "target_hosts=${vm_name}" \
            --extra-vars "dns_server=${dns_address}" \
            --extra-vars "dns_server_two=${dns_forwarder}"
    fi
}


# This function deletes a virtual machine (VM) based on the provided VM name.
# It handles specific VM names with custom deletion scripts and uses kcli for others.
# 
# Arguments:
#   $1 - The name of the VM to delete.
#
# The function performs the following steps:
# 1. Retrieves the domain name from the ANSIBLE_ALL_VARIABLES file using yq.
# 2. Checks if the VM name matches specific cases and calls the corresponding deletion script.
# 3. If the VM name does not match any specific cases, it:
#    a. Retrieves the target VM name and IP address using kcli.
#    b. Deletes the VM using kcli if it exists.
#    c. Removes the VM entry from FreeIPA using an Ansible playbook.
#    d. Removes the VM entry from the hosts file.
function delete_vm() {
    local vm_name="$1"
    local domain_name=$(yq eval '.domain' "${ANSIBLE_ALL_VARIABLES}")

    if [[ $vm_name == "kcli-openshift4-baremetal" ]]; then
      kcli-openshift4-baremetal/deploy.sh delete
    elif [[ $vm_name == "freeipa" ]]; then
      /opt/kcli-pipelines/freeipa/deploy-freeipa.sh destroy
    elif [[ $vm_name == "ocp4-disconnected-helper" ]]; then
      /opt/kcli-pipelines/ocp4-disconnected-helper/destroy.sh
    elif [[ $vm_name == "vyos-router" ]]; then
       vyos-router/deploy.sh delete
    elif [[ $vm_name == "openshift-agent-install" ]]; then
      openshift-agent-install/deploy.sh destroy
    else
      local target_vm=$(sudo kcli list vm  | grep  ${vm_name} | awk '{print $2}')
      local ip_address=$(sudo kcli info vm $vm_name $vm_name | grep ip: | awk '{print $2}' | head -1)
      echo "Deleting VM $target_vm"
      if [ ! -z "$target_vm" ]; then
        sudo kcli delete vm $target_vm -y
      else
        echo "VM $vm_name does not exist."
      fi

    export free_ip_address=$(sudo kcli info vm "freeipa" "freeipa" | grep ip: | awk '{print $2}' | head -1)
    if [ ! -z $free_ip_address ];
    then 
      $ANSIBLE_PLAYBOOK /opt/kcli-pipelines/helper_scripts/add_ipa_entry.yaml \
            --vault-password-file /root/.vault_password \
            --extra-vars "@${ANSIBLE_VAULT_FILE}" \
            --extra-vars "@${ANSIBLE_ALL_VARIABLES}" \
            --extra-vars "key=${vm_name}" \
            --extra-vars "freeipa_server_fqdn=idm.${domain_name}" \
            --extra-vars "value=${ip_address}" \
            --extra-vars "freeipa_server_domain=${domain_name}" \
            --extra-vars "action=absent" -vvv
        sudo sed -i  '/\['$vm_name'\]/,+2d' /opt/kcli-pipelines/helper_scripts/hosts
      else
        echo "Freeipa server not found"
      fi 
    fi
}

# Main function
# This script is used to manage the deployment of virtual machines (VMs) using KCLI.
# It performs actions such as creating, deleting, or deploying applications on VMs.
#
# Usage:
#   - Ensure the required RHEL images are downloaded on the server.
#   - Set the VM_NAME environment variable to specify the name of the VM.
#   - Set the ACTION environment variable to specify the action to perform (create, delete, deploy_app).
#
# Environment Variables:
#   VM_NAME: Name of the VM to deploy.
#   ACTION: Action to perform (create, delete, deploy_app).
#   TARGET_SERVER: Target server for deployment (e.g., equinix).
#
# Actions:
#   - create: Creates a new VM with the specified name.
#   - delete: Deletes the VM with the specified name.
#   - deploy_app: Deploys an application on the specified VM.
#
# The script performs the following steps:
#   1. Checks if the required RHEL image path exists.
#   2. Verifies that the VM_NAME and ACTION environment variables are set.
#   3. Installs Ansible if the target server is "equinix" and Ansible is not already installed.
#   4. Changes the working directory to /opt/kcli-pipelines.
#   5. Checks if the default.env file exists and creates a default version if it does not.
#   6. Sources the default.env file to load environment variables.
#   7. Retrieves the domain name from the Ansible variables file.
#   8. Executes the specified action (create, delete, deploy_app) based on the ACTION variable.
function main() {
    IMAGE_PATH="/var/lib/libvirt/images/rhel8"

    # Check if the file or directory exists
    if [ -e "$IMAGE_PATH" ]; then
        echo "Success: '$IMAGE_PATH' exists."
    else
        echo "Error: '$IMAGE_PATH' does not exist."
        echo ""
        echo "Please SSH into the appropriate server and run the following commands to download the required RHEL images:"
        echo ""
        echo "  sudo kcli download image rhel8"
        echo "  sudo kcli download image rhel9"
        echo ""
        exit 1  # Exit with a non-zero status to indicate failure
    fi

    if [ -z "$VM_NAME" ]; then
        echo "Error: Please provide the name of the VM to deploy by setting the VM_NAME environment variable."
        echo "Example: export VM_NAME=my-vm"
        exit 1
    fi

    if [ -z "$ACTION" ]; then
        echo "Error: Please provide an action to perform by setting the ACTION environment variable to create, delete, or deploy_app."
        echo "Example: export ACTION=deploy_app"
        exit 1
    fi

    if [ $TARGET_SERVER == "equinix" ]; then
        if [ ! -f /home/lab-user/.local/bin/ansible-playbook ]; then
          pip3 install  --user ansible
        fi
        ANSIBLE_PLAYBOOK="sudo -E /home/lab-user/.local/bin/ansible-playbook"
    else
      ANSIBLE_PLAYBOOK="sudo -E ansible-playbook"
    fi

    cd /opt/kcli-pipelines
    DEFAULT_ENV_PATH="/opt/kcli-pipelines/helper_scripts/default.env"

    # Check if default.env exists, if not, create a default version
    if [ ! -f "${DEFAULT_ENV_PATH}" ]; then
      echo "default.env file does not exist, creating a default version..."
      cat <<EOF
    # Environment Variables for all scripts 

    KCLI_SAMPLES_DIR="/opt/kcli-pipelines/"
    NET_NAME=qubinet # qubinet default bridge name default for internal network
    export INVENTORY=localhost
    ANSIBLE_VAULT_FILE="/opt/qubinode_navigator/inventories/\${INVENTORY}/group_vars/control/vault.yml"
    ANSIBLE_ALL_VARIABLES="/opt/qubinode_navigator/inventories/\${INVENTORY}/group_vars/all.yml"
EOF
    fi

    # Source the default.env file
    source "${DEFAULT_ENV_PATH}"
    local domain_name=$(yq eval '.domain' "${ANSIBLE_ALL_VARIABLES}")
    echo "DOMAIN NAME: $domain_name" || exit $?

    case $ACTION in
        create)
            create_vm "$VM_NAME" "$ACTION"
            ;;
        delete)
            delete_vm "$VM_NAME"
            ;;
        deploy_app)
            echo "deploy app"
            ;;
        *)
            echo "Invalid action. Please set ACTION to create, delete, or deploy_app."
            exit 1
            ;;
    esac
}

main
