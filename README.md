# Coder VPS Setup

**Quickly set up a secure `code-server` instance on a fresh Debian or Ubuntu VPS using Docker Compose.**

This project provides a bash script (`setup_entry.sh`) that automates the installation, basic security hardening, and configuration of `code-server` running inside Docker. It dynamically generates the necessary `docker-compose.yml` file using a companion Python script (`generate_compose.py`).

This is designed for users who want a fast, automated setup without needing more complex configuration management tools like Ansible.

**⚠️ Use with caution! Always review the script code (`setup_entry.sh` and `generate_compose.py`) before executing it on your server.**

## Features

*   Updates the system packages.
*   Installs Docker Engine and Docker Compose V2 plugin.
*   Creates a dedicated non-root user (default: `coder`).
*   Copies the SSH public key from the initial user (who runs `sudo`) to the new user for immediate key-based login.
*   Configures UFW firewall (allows specified SSH, HTTP/S, and code-server ports).
*   Hardens SSH configuration (disables root login, disables password authentication, changes default port).
*   Downloads a Python script to dynamically generate `docker-compose.yml`.
*   Sets up `code-server` in a Docker container.
*   Configures a systemd service for `code-server` to start automatically on boot.

## Prerequisites

*   A fresh VPS running a recent Debian or Ubuntu version.
*   SSH access to the VPS using the *initial* user provided by your host (e.g., `root`, `ubuntu`, `debian`).
*   An SSH key pair on your *local* machine.
*   The `ssh-copy-id` utility on your *local* machine (recommended) OR knowledge of how to manually add your public key to the server's `authorized_keys` file.

## Usage Instructions

1.  **Log in to your new VPS:**
    Use the initial credentials provided by your VPS host.
    ```bash
    ssh <initial_vps_user>@<your_vps_ip>
    ```

2.  **Copy your SSH Public Key (CRITICAL STEP):**
    From your ***local machine***, copy your public SSH key to the initial user on the VPS. This allows the setup script to later copy this key for the new user (`coder`) it creates, ensuring you can log in after SSH is hardened.
    ```bash
    # Run this on your LOCAL computer
    # Replace ~/.ssh/your_public_key.pub with the actual path to your public key
    ssh-copy-id -i ~/.ssh/your_public_key.pub <initial_vps_user>@<your_vps_ip>
    ```
    You might be prompted for the `<initial_vps_user>`'s password.

3.  **Download the Setup Script:**
    Back in your SSH session *on the VPS*, download the main setup script:
    ```bash
    # Option 1: wget
    wget https://raw.githubusercontent.com/trostmarvin/coder-vps-setup/main/setup_entry.sh -O setup_entry.sh

    # Option 2: curl
    curl -Lo setup_entry.sh https://raw.githubusercontent.com/trostmarvin/coder-vps-setup/main/setup_entry.sh
    ```

4.  **Make the Script Executable:**
    ```bash
    chmod +x setup_entry.sh
    ```

5.  **Run the Script:**
    Execute the script using `sudo`. It will prompt you for configuration details.
    ```bash
    sudo ./setup_entry.sh
    ```

6.  **Follow the Prompts:**
    *   **New Username:** Enter the desired username for running `code-server` (default: `coder`).
    *   **New SSH Port:** Enter the port SSH should listen on (default: `2222`).
    *   **Code Server Host Port:** Enter the port you want to access `code-server` through in your browser (default: `8443`).
    *   **Python Script URL:** Paste the **RAW** URL for the `generate_compose.py` script. The default is:
        ```
        https://raw.githubusercontent.com/trostmarvin/coder-vps-setup/main/generate_compose.py
        ```
    *   **Mount Docker Socket:** Confirm if you need to manage Docker *from within* the `code-server` container (use with caution).
    *   **Proceed:** Confirm to start the setup process.

## Post-Installation Access

*   **SSH:** Connect using the *new username* and *new SSH port* you configured. Your SSH key (copied in Step 2) should allow access.
    ```bash
    # Example using default username 'coder' and a custom port
    ssh -p <NEW_SSH_PORT> coder@<your_vps_ip>
    ```
*   **Code Server:** Access the `code-server` web interface in your browser:
    ```
    http://<your_vps_ip>:<CODESERVER_HOST_PORT>
    ```
    *   If you didn't configure a password in the `generate_compose.py` template (it's commented out by default), check the container logs for the automatically generated password:
        ```bash
        sudo docker logs code-server
        ```

## Security Considerations

*   **Review Code:** Seriously, read the scripts before running them. You are giving them `sudo` access.
*   **HTTPS Recommended:** The default setup uses HTTP. For secure access, especially over the internet, **strongly consider** setting up a reverse proxy (like Nginx or Caddy) with SSL/TLS certificates (e.g., from Let's Encrypt via Certbot).
*   **Firewall:** The script opens the SSH port, code-server port, and standard HTTP/S ports (80/443). Review UFW rules (`sudo ufw status numbered`) and tighten them if necessary.
*   **Docker Socket:** Mounting the Docker socket (`/var/run/docker.sock`) into the container gives it root-level access to the host system via Docker. Only enable this if you understand the risks.
*   **Updates:** Regularly update your VPS operating system (`sudo apt update && sudo apt upgrade -y`) and the `code-server` Docker image (`sudo docker compose -f /srv/code-server/docker-compose.yml pull && sudo docker compose -f /srv/code-server/docker-compose.yml up -d`).
