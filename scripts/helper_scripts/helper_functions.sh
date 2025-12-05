# Function to get OS and version
get_os_version() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION_ID=$VERSION_ID
    else
        echo "Cannot determine OS version. /etc/os-release not found."
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
            echo "Unsupported version: $VERSION_ID"
            exit 1
        fi
    else
        echo "Unsupported OS: $OS"
        exit 1
    fi
}