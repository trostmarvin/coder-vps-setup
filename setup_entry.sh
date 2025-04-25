#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipe failures should exit the script
set -o pipefail

# --- Configuration ---
DEFAULT_USERNAME="coder"
DEFAULT_SSH_PORT="2222"
DEFAULT_CODESERVER_HOST_PORT="8443"
DEFAULT_CODESERVER_CONTAINER_PORT="8443" # Default internal port for code-server image
SETUP_DIR="/srv/code-server"
PYTHON_GENERATOR_URL="" # Will be prompted
TEMP_PYTHON_SCRIPT="/tmp/generate_compose.py"

# --- Helper Functions ---
print_info() {
    echo "[INFO] $1"
}

print_warning() {
    echo "[WARNING] $1"
}

print_error() {
    echo "[ERROR] $1" >&2
    exit 1
}

cleanup() {
    print_info "Cleaning up temporary files..."
    rm -f "$TEMP_PYTHON_SCRIPT"
}

# Register cleanup function to run on exit
trap cleanup EXIT

# --- Check Root ---
if [ "$(id -u)" -ne 0 ]; then
  print_error "This script must be run as root or with sudo."
fi

# --- Check SUDO_USER ---
# This script relies on copying the SSH key from the user who invoked sudo.
if [ -z "${SUDO_USER:-}" ]; then
    print_warning "SUDO_USER environment variable is not set."
    print_warning "This might happen if you logged in directly as root."
    print_warning "Attempting to copy keys from /root/.ssh/authorized_keys."
    INITIAL_USER="root"
    INITIAL_USER_HOME="/root"
else
    INITIAL_USER="$SUDO_USER"
    INITIAL_USER_HOME=$(eval echo ~$INITIAL_USER) # Get home dir reliably
    print_info "Script invoked via sudo by user: $INITIAL_USER"
fi

INITIAL_AUTHORIZED_KEYS="$INITIAL_USER_HOME/.ssh/authorized_keys"

# --- Gather User Input ---
read -p "Enter the username for the code-server service [$DEFAULT_USERNAME]: " USERNAME
USERNAME=${USERNAME:-$DEFAULT_USERNAME}

read -p "Enter the SSH port you want to use (numeric) [$DEFAULT_SSH_PORT]: " SSH_PORT
SSH_PORT=${SSH_PORT:-$DEFAULT_SSH_PORT}
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    print_error "Invalid SSH port number entered."
fi

read -p "Enter the HOST port code-server should listen on (numeric) [$DEFAULT_CODESERVER_HOST_PORT]: " CODESERVER_HOST_PORT
CODESERVER_HOST_PORT=${CODESERVER_HOST_PORT:-$DEFAULT_CODESERVER_HOST_PORT}
if ! [[ "$CODESERVER_HOST_PORT" =~ ^[0-9]+$ ]] || [ "$CODESERVER_HOST_PORT" -lt 1 ] || [ "$CODESERVER_HOST_PORT" -gt 65535 ]; then
    print_error "Invalid code-server host port number entered."
fi

while [ -z "$PYTHON_GENERATOR_URL" ]; do
 read -p "Enter the RAW GitHub URL for the Python 'generate_compose.py' script: " PYTHON_GENERATOR_URL
 if [[ ! "$PYTHON_GENERATOR_URL" =~ ^https?:// ]]; then
    print_warning "URL does not look valid. Please ensure it's the RAW content URL."
    PYTHON_GENERATOR_URL=""
 fi
done

read -p "Mount the Docker socket into the code-server container? (y/N): " MOUNT_DOCKER_SOCKET_CONFIRM
MOUNT_DOCKER_SOCKET_ARG=""
if [[ "$MOUNT_DOCKER_SOCKET_CONFIRM" =~ ^[Yy]$ ]]; then
    MOUNT_DOCKER_SOCKET_ARG="--use-docker-socket"
    print_warning "Mounting the Docker socket has security implications. Use with caution."
fi


print_info "Starting setup with:"
print_info "  Username: $USERNAME"
print_info "  SSH Port: $SSH_PORT"
print_info "  Code-Server Host Port: $CODESERVER_HOST_PORT"
print_info "  Setup Directory: $SETUP_DIR"
print_info "  Python Generator URL: $PYTHON_GENERATOR_URL"
print_info "  Mount Docker Socket: ${MOUNT_DOCKER_SOCKET_ARG:+Yes}"
print_info "  Will attempt to copy SSH keys from: $INITIAL_AUTHORIZED_KEYS"
read -p "Proceed? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_error "Setup aborted by user."
fi

# --- System Update ---
print_info "Updating package lists and upgrading system..."
apt-get update
apt-get upgrade -y

# --- Install Prerequisites ---
print_info "Installing prerequisites (ufw, curl, wget, gnupg, ca-certificates, python3, python3-pip)..."
apt-get install -y ufw curl wget gnupg ca-certificates python3 python3-pip

# --- Install Docker ---
# (Keep the corrected Docker install section from the previous step)
print_info "Installing Docker Engine and Compose Plugin..."
install -m 0755 -d /etc/apt/keyrings
if [ -f /etc/apt/keyrings/docker.gpg ]; then
    print_warning "Removing existing Docker GPG key..."
    rm -f /etc/apt/keyrings/docker.gpg
fi
OS_ID=$(. /etc/os-release && echo "$ID")
print_info "Detected OS ID: $OS_ID"
print_info "Downloading Docker GPG key for $OS_ID..."
curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
print_info "Adding Docker repository for $OS_ID $(. /etc/os-release && echo "$VERSION_CODENAME")"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
print_info "Verifying content of docker.list:"
cat /etc/apt/sources.list.d/docker.list
print_info "Updating package list after adding Docker repo..."
apt-get update
print_info "Installing Docker packages..."
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

print_info "Starting and enabling Docker service..."
systemctl enable --now docker

# --- User Setup & SSH Key Copy ---
print_info "Setting up user '$USERNAME'..."
if id "$USERNAME" &>/dev/null; then
    print_warning "User '$USERNAME' already exists. Skipping user creation."
    # Ensure docker group membership even if user exists
    print_info "Ensuring user '$USERNAME' is in the 'docker' group..."
    usermod -aG docker "$USERNAME"
else
    # Create user with a home directory and bash shell
    useradd -m -s /bin/bash "$USERNAME"
    # Create a group with the same name as the user (common practice)
    groupadd "$USERNAME" || true # Don't fail if group exists
    usermod -g "$USERNAME" "$USERNAME" # Set primary group
    print_info "User '$USERNAME' created."
    print_info "Adding user '$USERNAME' to the 'docker' group..."
    usermod -aG docker "$USERNAME"
fi

# Define target SSH directory and file
TARGET_SSH_DIR="/home/$USERNAME/.ssh"
TARGET_AUTHORIZED_KEYS="$TARGET_SSH_DIR/authorized_keys"

print_info "Attempting to copy SSH authorized_keys from '$INITIAL_AUTHORIZED_KEYS' to '$TARGET_AUTHORIZED_KEYS'..."
if [ -f "$INITIAL_AUTHORIZED_KEYS" ]; then
    print_info "Source authorized_keys file found."
    mkdir -p "$TARGET_SSH_DIR"
    cp "$INITIAL_AUTHORIZED_KEYS" "$TARGET_AUTHORIZED_KEYS"
    if [ $? -eq 0 ]; then
        print_info "Successfully copied authorized_keys."
        # Set correct ownership and permissions
        chown -R "$USERNAME":"$USERNAME" "$TARGET_SSH_DIR"
        chmod 700 "$TARGET_SSH_DIR"
        chmod 600 "$TARGET_AUTHORIZED_KEYS"
        print_info "Set permissions for $TARGET_SSH_DIR (700) and $TARGET_AUTHORIZED_KEYS (600)."
    else
        print_error "Failed to copy authorized_keys file. Please add the key manually to $TARGET_AUTHORIZED_KEYS later."
    fi
else
    print_warning "Source authorized_keys file '$INITIAL_AUTHORIZED_KEYS' not found."
    print_warning "This is expected if you didn't use 'ssh-copy-id' for the initial user '$INITIAL_USER' before running this script."
    print_warning "You will need to manually add your public SSH key to '$TARGET_AUTHORIZED_KEYS' for user '$USERNAME'."
    # Create the directory anyway, with correct permissions, so manual addition is easier
    mkdir -p "$TARGET_SSH_DIR"
    chown -R "$USERNAME":"$USERNAME" "$TARGET_SSH_DIR"
    chmod 700 "$TARGET_SSH_DIR"
fi

# --- Firewall Setup (UFW) ---
# (Firewall setup remains the same)
print_info "Configuring Firewall (UFW)..."
ufw default deny incoming
ufw default allow outgoing
ufw allow $SSH_PORT/tcp comment 'SSH Access'
ufw allow 80/tcp comment 'HTTP (for potential Certbot)'
ufw allow 443/tcp comment 'HTTPS (for potential reverse proxy/SSL)'
ufw allow $CODESERVER_HOST_PORT/tcp comment 'Code Server Access'
ufw limit $SSH_PORT/tcp comment 'Rate limit SSH'
print_info "Enabling UFW..."
ufw --force enable

# --- SSH Hardening ---
# (SSH hardening remains the same, but now runs AFTER the key should be in place)
print_info "Hardening SSH configuration..."
SSH_CONFIG="/etc/ssh/sshd_config"
cp "$SSH_CONFIG" "${SSH_CONFIG}.bak_$(date +%F_%T)"
sed -i "s/^#*Port .*/Port $SSH_PORT/" $SSH_CONFIG
sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" $SSH_CONFIG
sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication yes/g" $SSH_CONFIG
sed -i "s/^PasswordAuthentication yes/PasswordAuthentication no/g" $SSH_CONFIG
sed -i "s/^#*PermitEmptyPasswords .*/PermitEmptyPasswords no/" $SSH_CONFIG
# Add the new user to AllowUsers if you want maximum restriction
# echo "AllowUsers $USERNAME" >> $SSH_CONFIG # Uncomment and potentially add other admin users if needed
print_info "Restarting SSH service..."
systemctl restart sshd

# --- Application Directory and Compose File Generation ---
# (This section remains the same)
print_info "Creating application directory: $SETUP_DIR"
mkdir -p "$SETUP_DIR"
print_info "Downloading Python compose generator from $PYTHON_GENERATOR_URL..."
wget -O "$TEMP_PYTHON_SCRIPT" "$PYTHON_GENERATOR_URL"
if [ $? -ne 0 ]; then print_error "Failed to download Python script. Check the URL."; fi
chmod +x "$TEMP_PYTHON_SCRIPT"
print_info "Generating docker-compose.yml using Python script..."
COMPOSE_FILE_PATH="$SETUP_DIR/docker-compose.yml"
python3 "$TEMP_PYTHON_SCRIPT" \
    --output "$COMPOSE_FILE_PATH" \
    --host-port "$CODESERVER_HOST_PORT" \
    --container-port "$DEFAULT_CODESERVER_CONTAINER_PORT" \
    --user "$USERNAME" \
    $MOUNT_DOCKER_SOCKET_ARG
if [ ! -f "$COMPOSE_FILE_PATH" ]; then print_error "Python script failed to generate docker-compose.yml"; fi
print_info "Setting permissions for $SETUP_DIR..."
mkdir -p "$SETUP_DIR/projects" "$SETUP_DIR/config/local-share"
chown -R "$USERNAME":"$USERNAME" "$SETUP_DIR"
chmod -R 770 "$SETUP_DIR"

# --- Systemd Service Setup ---
# (This section remains the same)
print_info "Creating systemd service for code-server..."
SERVICE_FILE="/etc/systemd/system/code-server.service"
cat << EOF > $SERVICE_FILE
[Unit]
Description=Code Server container stack managed by Docker Compose
Requires=docker.service
After=docker.service
[Service]
User=$USERNAME
Group=docker
WorkingDirectory=$SETUP_DIR
Restart=always
Type=simple
ExecStart=/usr/bin/docker compose up --remove-orphans
ExecStop=/usr/bin/docker compose down
[Install]
WantedBy=multi-user.target
EOF
print_info "Reloading systemd daemon, enabling and starting code-server service..."
systemctl daemon-reload
systemctl enable code-server.service
systemctl start code-server.service

# --- Final Instructions ---
# (Instructions updated to reflect the new workflow)
print_info "-----------------------------------------------------"
print_info "Setup Complete!"
print_info "-----------------------------------------------------"
echo
print_info "Important Notes:"
print_info "1. SSH Access: You should now be able to connect directly as the '$USERNAME' user using your SSH key:"
print_info "   ssh -p $SSH_PORT $USERNAME@<your_vps_ip>"
print_info "   (Ensure the key copied from '$INITIAL_USER' is the one you want to use for '$USERNAME')."
print_info "   (If login fails, check '$TARGET_AUTHORIZED_KEYS' on the server)."
print_info "2. Code Server Access: Access via your browser at http://<your_vps_ip>:$CODESERVER_HOST_PORT"
print_info "   - For HTTPS (Recommended): Set up a reverse proxy (Nginx, Caddy) and use Certbot."
print_info "   - Firewall Ports Opened: $SSH_PORT (SSH), 80 (HTTP), 443 (HTTPS), $CODESERVER_HOST_PORT (code-server)."
print_info "3. Code Server Password: If not set via environment variables, check logs:"
print_info "   sudo docker logs code-server"
print_info "4. Service Management: Use 'sudo systemctl status/start/stop/restart code-server.service'."
print_info "5. Project Files: Place projects inside '$SETUP_DIR/projects'."
echo
print_warning "Review the generated docker-compose.yml ($COMPOSE_FILE_PATH)."
print_warning "Setting up HTTPS with a domain name is strongly recommended!"

exit 0
