#!/usr/bin/env python3

import argparse
import os
import pwd
import grp
import sys

def generate_compose_yaml(output_path, host_port, container_port, user_name, projects_subdir, config_subdir, use_docker_socket):
    """Generates the docker-compose.yml content."""

    # Try to get UID/GID for the specified user to set ownership within the container
    try:
        uid = pwd.getpwnam(user_name).pw_uid
        gid = grp.getgrnam(user_name).gr_gid # Assuming user has a group with the same name
        user_directive = f"user: \"{uid}:{gid}\""
    except KeyError:
        print(f"[Warning] User '{user_name}' not found locally when generating compose. "
              f"Container might run as default user. Ensure '{user_name}' exists on the host.", file=sys.stderr)
        user_directive = "# user: \"<uid>:<gid>\" # Set manually if needed"

    # --- YAML Content ---
    # Using triple quotes and f-string interpolation. Indentation is crucial for YAML.
    compose_content = f"""
services:
  code-server:
    image: codercom/code-server:latest # Official image
    container_name: code-server
    command: ["--cert"]
    environment:
      # Optional: Set passwords via environment variables if desired
      # - PASSWORD=your_strong_password_here # Set a fixed password
      # - SUDO_PASSWORD=optional_sudo_password # If you need sudo inside
      - TZ=Etc/UTC
    volumes:
      # Map config dir from host (relative to compose file) to container
      - ./{config_subdir}:/home/coder/.config 
      # Map local settings dir from host (relative to compose file) to container
      - ./{config_subdir}/local-share:/home/coder/.local/share/code-server
      # Map projects dir from host (relative to compose file) to container
      - ./{projects_subdir}:/home/coder/projects
      # Optional: Mount docker socket (use with caution)
      {f'- /var/run/docker.sock:/var/run/docker.sock' if use_docker_socket else '# - /var/run/docker.sock:/var/run/docker.sock'}
    ports:
      # Map host port to container port
      - "{host_port}:{container_port}"
    restart: unless-stopped
    # Run the container process as the host user for correct volume permissions
    {user_directive}

networks:
  default:
    name: code-server_network

"""
    # --- End YAML Content ---

    try:
        # Ensure the directory for the output file exists
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        with open(output_path, 'w') as f:
            f.write(compose_content)
        print(f"[Info] docker-compose.yml successfully generated at: {output_path}")
    except IOError as e:
        print(f"[Error] Failed to write docker-compose.yml to {output_path}: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate docker-compose.yml for code-server.")
    parser.add_argument('--output', required=True, help="Path to save the generated docker-compose.yml file.")
    parser.add_argument('--host-port', type=int, default=8443, help="Host port to expose code-server on.")
    parser.add_argument('--container-port', type=int, default=8443, help="Container port code-server listens on.")
    parser.add_argument('--user', required=True, help="Host username to map for volume permissions.")
    parser.add_argument('--projects-subdir', default='projects', help="Subdirectory name for projects volume (relative to compose file).")
    parser.add_argument('--config-subdir', default='config', help="Subdirectory name for config volume (relative to compose file).")
    parser.add_argument('--use-docker-socket', action='store_true', help="Mount the Docker socket into the container.")

    args = parser.parse_args()

    generate_compose_yaml(
        output_path=args.output,
        host_port=args.host_port,
        container_port=args.container_port,
        user_name=args.user,
        projects_subdir=args.projects_subdir,
        config_subdir=args.config_subdir,
        use_docker_socket=args.use_docker_socket
    )
