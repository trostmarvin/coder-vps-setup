# coder-vps-setup

automatically setup only coder with docker compose. not using ansible etc., used to setup a vps with coder quickly.
use with caution, check the code before executing.

1. ssh into your vps

2. run
wget https://raw.githubusercontent.com/trostmarvin/coder-vps-setup/refs/heads/main/setup_entry.sh -O setup_entry.sh
OR
curl -Lo setup_entry.sh https://raw.githubusercontent.com/trostmarvin/coder-vps-setup/refs/heads/main/setup_entry.sh

4. run
chmod +x setup_entry.sh

6. run script
sudo ./setup_entry.sh


Enter the desired username (e.g., coder).
Enter the desired SSH port (e.g., 2222).
Enter the desired host port for code-server (e.g., 8443).
Paste the RAW URL for generate_compose.py script when prompted.
Confirm if you want to mount the Docker socket.
Confirm to proceed with the setup.


If prompted for the python script url:
https://raw.githubusercontent.com/trostmarvin/coder-vps-setup/refs/heads/main/generate_compose.py

The server will be reachable from the new port/user.

# Example from your local machine:
ssh coder@<your_vps_ip> -p <NEW_SSH_PORT>
