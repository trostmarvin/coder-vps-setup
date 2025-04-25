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
print_info "Installing Docker Engine and Compose Plugin..."
# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
if [ -f /etc/apt/keyrings/docker.gpg ]; then
    rm /etc/apt/keyrings/docker.gpg
fi
# Determine OS ID (e.g., "ubuntu" or "debian")
OS_ID=$(. /etc/os-release && echo "$ID")
print_info "Detected OS ID: $OS_ID"

# Download the GPG key using the detected OS ID
curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Set up the repository using the detected OS ID and codename
print_info "Adding Docker repository for $OS_ID $(. /etc/os-release && echo "$VERSION_CODENAME")"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update apt package index again after adding new repo
apt-get update

# Install Docker Engine, CLI, Containerd, and Compose plugin
print_info "Installing Docker packages..."
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

print_info "Starting and enabling Docker service..."
systemctl enable --now docker

# --- User Setup ---
print_info "Setting up user '$USERNAME'..."
if id "$USERNAME" &>/dev/null; then
    print_warning "User '$USERNAME' already exists."
else
    # Create user with a home directory and bash shell
    useradd -m -s /bin/bash "$USERNAME"
    # Create a group with the same name as the user (common practice)
    groupadd "$USERNAME" || true # Don't fail if group exists
    usermod -g "$USERNAME" "$USERNAME" # Set primary group
    print_info "User '$USERNAME' created."
fi
print_info "Adding user '$USERNAME' to the 'docker' group..."
usermod -aG docker "$USERNAME"

# --- Firewall Setup (UFW) ---
print_info "Configuring Firewall (UFW)..."
ufw default deny incoming
ufw default allow outgoing
ufw allow $SSH_PORT/tcp comment 'SSH Access'
ufw allow 80/tcp comment 'HTTP (for potential Certbot)'
ufw allow 443/tcp comment 'HTTPS (for potential reverse proxy/SSL)'
ufw allow $CODESERVER_HOST_PORT/tcp comment 'Code Server Access'
ufw limit $SSH_PORT/tcp comment 'Rate limit SSH'
print_info "Enabling UFW..."
# Use --force to avoid interaction if UFW is already enabled/disabled
ufw --force enable

# --- SSH Hardening ---
print_info "Hardening SSH configuration..."
SSH_CONFIG="/etc/ssh/sshd_config"
# Backup original config
cp "$SSH_CONFIG" "${SSH_CONFIG}.bak_$(date +%F_%T)"
# Change port
sed -i "s/^#*Port .*/Port $SSH_PORT/" $SSH_CONFIG
# Disable root login
sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" $SSH_CONFIG
# Disable password authentication (ensure key-based auth is set up!)
sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication yes/g" $SSH_CONFIG # Ensure it's uncommented first
sed -i "s/^PasswordAuthentication yes/PasswordAuthentication no/g" $SSH_CONFIG
# Disable empty passwords
sed -i "s/^#*PermitEmptyPasswords .*/PermitEmptyPasswords no/" $SSH_CONFIG
# Allow only specific user(s) if desired (more secure)
# echo "AllowUsers $USERNAME your_admin_user" >> $SSH_CONFIG
print_info "Restarting SSH service..."
systemctl restart sshd

# --- Application Directory and Compose File Generation ---
print_info "Creating application directory: $SETUP_DIR"
mkdir -p "$SETUP_DIR"

print_info "Downloading Python compose generator from $PYTHON_GENERATOR_URL..."
wget -O "$TEMP_PYTHON_SCRIPT" "$PYTHON_GENERATOR_URL"
if [ $? -ne 0 ]; then
    print_error "Failed to download Python script. Check the URL."
fi
chmod +x "$TEMP_PYTHON_SCRIPT"

print_info "Generating docker-compose.yml using Python script..."
COMPOSE_FILE_PATH="$SETUP_DIR/docker-compose.yml"
# Execute Python script, passing arguments
python3 "$TEMP_PYTHON_SCRIPT" \
    --output "$COMPOSE_FILE_PATH" \
    --host-port "$CODESERVER_HOST_PORT" \
    --container-port "$DEFAULT_CODESERVER_CONTAINER_PORT" \
    --user "$USERNAME" \
    $MOUNT_DOCKER_SOCKET_ARG # Add docker socket arg only if confirmed

if [ ! -f "$COMPOSE_FILE_PATH" ]; then
    print_error "Python script failed to generate docker-compose.yml at $COMPOSE_FILE_PATH"
fi

print_info "Setting permissions for $SETUP_DIR..."
# Create subdirs defined in Python script if they don't exist, before chown
mkdir -p "$SETUP_DIR/projects" "$SETUP_DIR/config/local-share"
# Set ownership to the user and their primary group
chown -R "$USERNAME":"$USERNAME" "$SETUP_DIR"
# Set permissions: User=rwx, Group=rwx, Other=---
chmod -R 770 "$SETUP_DIR"

# --- Systemd Service Setup ---
print_info "Creating systemd service for code-server..."
SERVICE_FILE="/etc/systemd/system/code-server.service"

cat << EOF > $SERVICE_FILE
[Unit]
Description=Code Server container stack managed by Docker Compose
Requires=docker.service
After=docker.service

[Service]
# Run docker compose commands as the user who owns the files/directory
User=$USERNAME
Group=docker # Needs docker group access to interact with the daemon via socket
WorkingDirectory=$SETUP_DIR
Restart=always
Type=simple

# Use 'docker compose' (with space) for the plugin version
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
print_info "-----------------------------------------------------"
print_info "Setup Complete!"
print_info "-----------------------------------------------------"
echo
print_info "Important Notes:"
print_info "1. SSH Access: Connect using 'ssh $USERNAME@<your-vps-ip> -p $SSH_PORT'. Ensure your SSH key is configured for the '$USERNAME' user."
print_info "   (If you need root access, SSH as '$USERNAME' first, then use 'sudo -i')"
print_info "2. Code Server Access: Access via your browser at http://<your-vps-ip>:$CODESERVER_HOST_PORT"
print_info "   - For HTTPS (Recommended): Set up a reverse proxy (Nginx, Caddy) and use Certbot."
print_info "   - Firewall Ports Opened: $SSH_PORT (SSH), 80 (HTTP), 443 (HTTPS), $CODESERVER_HOST_PORT (code-server)."
print_info "3. Code Server Password: If you didn't set a PASSWORD environment variable in the Python script's template,"
print_info "   check the container logs for the initial password:"
print_info "   sudo docker logs code-server"
print_info "   (Or run as the user: sudo -u $USERNAME docker compose -f $SETUP_DIR/docker-compose.yml logs)"
print_info "4. Service Management: Use 'sudo systemctl status/start/stop/restart code-server.service' to manage the service."
print_info "5. Project Files: Place your projects inside '$SETUP_DIR/projects'. They will be owned by '$USERNAME'."
echo
print_warning "Review the generated docker-compose.yml ($COMPOSE_FILE_PATH) to ensure it matches your expectations."
print_warning "For production use, setting up HTTPS with a domain name and a reverse proxy is strongly recommended!"

# Cleanup is handled by the trap EXIT
exit 0
