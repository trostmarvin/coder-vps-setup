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
DEFAULT_CODESERVER_PORT="8443"
SETUP_DIR="/srv/code-server"
COMPOSE_URL="" # Will be prompted

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

# --- Check Root ---
if [ "$(id -u)" -ne 0 ]; then
  print_error "This script must be run as root or with sudo."
fi

# --- Gather User Input ---
read -p "Enter the username for the code-server service [$DEFAULT_USERNAME]: " USERNAME
USERNAME=${USERNAME:-$DEFAULT_USERNAME}

read -p "Enter the SSH port you want to use (numeric) [$DEFAULT_SSH_PORT]: " SSH_PORT
SSH_PORT=${SSH_PORT:-$DEFAULT_SSH_PORT}
# Basic validation for SSH port
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    print_error "Invalid SSH port number entered."
fi

read -p "Enter the port code-server will listen on (numeric) [$DEFAULT_CODESERVER_PORT]: " CODESERVER_PORT
CODESERVER_PORT=${CODESERVER_PORT:-$DEFAULT_CODESERVER_PORT}
# Basic validation for code-server port
if ! [[ "$CODESERVER_PORT" =~ ^[0-9]+$ ]] || [ "$CODESERVER_PORT" -lt 1 ] || [ "$CODESERVER_PORT" -gt 65535 ]; then
    print_error "Invalid code-server port number entered."
fi

while [ -z "$COMPOSE_URL" ]; do
 read -p "Enter the RAW GitHub URL for your docker-compose.yml: " COMPOSE_URL
 if [[ ! "$COMPOSE_URL" =~ ^https?:// ]]; then
    print_warning "URL does not look valid. Please ensure it's the RAW content URL."
    COMPOSE_URL=""
 fi
done

print_info "Starting setup with:"
print_info "  Username: $USERNAME"
print_info "  SSH Port: $SSH_PORT"
print_info "  Code-Server Port: $CODESERVER_PORT"
print_info "  Setup Directory: $SETUP_DIR"
print_info "  Compose URL: $COMPOSE_URL"
read -p "Proceed? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_error "Setup aborted by user."
fi

# --- System Update ---
print_info "Updating package lists and upgrading system..."
apt-get update
apt-get upgrade -y

# --- Install Prerequisites ---
print_info "Installing prerequisites (ufw, curl, wget, gnupg, ca-certificates)..."
apt-get install -y ufw curl wget gnupg ca-certificates

# --- Install Docker ---
print_info "Installing Docker Engine..."
install -m 0755 -d /etc/apt/keyrings
if [ -f /etc/apt/keyrings/docker.gpg ]; then
    rm /etc/apt/keyrings/docker.gpg
fi
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin [[6]]

print_info "Starting and enabling Docker service..."
systemctl enable --now docker

# --- User Setup ---
print_info "Setting up user '$USERNAME'..."
if id "$USERNAME" &>/dev/null; then
    print_warning "User '$USERNAME' already exists."
else
    useradd -m -s /bin/bash "$USERNAME"
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
ufw allow $CODESERVER_PORT/tcp comment 'Code Server Access' [[1]] # Allow code-server port
# Rate limiting SSH can add extra protection
ufw limit $SSH_PORT/tcp
print_info "Enabling UFW..."
ufw enable

# --- SSH Hardening ---
print_info "Hardening SSH configuration..."
SSH_CONFIG="/etc/ssh/sshd_config"
# Change port
sed -i "s/^#*Port .*/Port $SSH_PORT/" $SSH_CONFIG
# Disable root login
sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" $SSH_CONFIG
# Disable password authentication
sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication yes/g" $SSH_CONFIG # Ensure it's uncommented first
sed -i "s/^PasswordAuthentication yes/PasswordAuthentication no/g" $SSH_CONFIG
# Disable empty passwords
sed -i "s/^#*PermitEmptyPasswords .*/PermitEmptyPasswords no/" $SSH_CONFIG
print_info "Restarting SSH service..."
systemctl restart sshd

# --- Application Directory Setup ---
print_info "Creating application directory: $SETUP_DIR"
mkdir -p "$SETUP_DIR"
print_info "Downloading docker-compose.yml from $COMPOSE_URL..."
wget -O "$SETUP_DIR/docker-compose.yml" "$COMPOSE_URL"
if [ $? -ne 0 ]; then
    print_error "Failed to download docker-compose.yml. Check the URL."
fi

print_info "Setting permissions for $SETUP_DIR..."
chown -R "$USERNAME":"$USERNAME" "$SETUP_DIR"
chmod -R 770 "$SETUP_DIR" # User and group have rwx, others have no access

# --- Systemd Service Setup ---
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

# Note: Use 'docker compose' (with space) for the plugin version
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
print_info "1. SSH Access: Connect using 'ssh <your-vps-user>@<your-vps-ip> -p $SSH_PORT'. Ensure your SSH key is configured."
print_info "2. Code Server Access: Access via your browser at http://<your-vps-ip>:$CODESERVER_PORT"
print_info "   - For HTTPS (Recommended): You need to set up a reverse proxy (like Nginx or Caddy) and obtain SSL certificates (e.g., using Certbot)."
print_info "   - Firewall Ports Opened: $SSH_PORT (SSH), 80 (HTTP), 443 (HTTPS), $CODESERVER_PORT (code-server)."
print_info "3. Code Server Password: Check the container logs for the initial password if your compose file doesn't set one:"
print_info "   sudo docker logs <container_name_or_id>  (Find the name/ID with 'docker ps')"
print_info "   (You might need to run 'sudo docker compose -f $SETUP_DIR/docker-compose.yml logs' if the service started quickly)"
print_info "4. Service Management: Use 'sudo systemctl status/start/stop/restart code-server.service' to manage the service."
print_info "5. Project Files: Place your projects inside '$SETUP_DIR/...' (or wherever your compose file maps volumes) - owned by '$USERNAME'."
echo
print_warning "Review the downloaded docker-compose.yml ($SETUP_DIR/docker-compose.yml) to ensure it matches your expectations."
print_warning "For production use, setting up HTTPS with a domain name and a reverse proxy is strongly recommended!"

exit 0
