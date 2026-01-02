# Docker Development Infrastructure

This repository contains the Docker Compose configuration for a local development infrastructure stack.

## Services

| Service | Protocol/Port | Description |
|---------|---------------|-------------|
| **Portainer** | `:9000` | Container management UI |
| **CloudBeaver** | `:8978` | Database management tool |
| **Redis Insight** | `:5540` | Redis web UI |
| **Mailpit** | `:8025` (Web), `:1025` (SMTP) | Email testing tool |
| **Hoppscotch** | `:3100` | API testing tool (offset to avoid port 3000) |
| **Nginx Proxy Manager** | `:81` (Admin), `:80`/`:443` | Reverse proxy manager |
| **Technitium DNS** | `:5380` (Web), `:53` (DNS) | DNS Server |
| **Homepage** | `:3000` | Dashboard |

## Prerequisites

1.  **Docker** and **Docker Compose** installed.
2.  **External Network**: You must create the `dev-net` network before starting the stack.
    ```bash
    docker network create dev-net
    ```

## Getting Started

1.  **Configure Environment**:
    Copy `.env.example` to `.env` and adjust variables if needed.
    ```bash
    cp .env.example .env
    ```

2.  **Start Services**:
    ```bash
    docker compose up -d
    ```

## Data Persistence

All data is persisted in local directories within the repository (e.g., `./portainer/data`). These directories are bind-mounted into the containers. Use `.gitignore` to keep them out of version control.

## Modular Configuration

This project uses a modular setup system to prepare the environment for each service before Docker Compose starts.

### Root Setup Script

The root `setup.sh` script automates the initialization process by:
1.  Creating the external network (`dev-net`) if it doesn't exist.
2.  Scanning all service subdirectories (e.g., `./cloudbeaver`, `./technitium`).
3.  Executing the `setup.sh` script inside each directory if found.

### Service-Specific Setup

You can create a `setup.sh` file in any service directory to handle pre-launch tasks. The script is executed **relative to the service directory**.

**Common Use Cases:**

1.  **Creating Data Directories**:
     Ensure directories exist and have the correct ownership before the container starts. This is critical for containers running as a specific user ID (UID).

     *Example: `cloudbeaver/setup.sh`*
     ```bash
     #!/bin/bash
     # Create data directory so it is owned by the current user (likely UID 1000)
     # This prevents Docker from creating it as root, which causes permission denied errors for the container user.
     mkdir -p data
     ```

2.  **Generating Configuration**:
     Create dynamic config files based on environment variables.

     *Example:*
     ```bash
     #!/bin/bash
     # Generate auth config if not exists
     if [ ! -f config/auth.json ]; then
         echo '{"admin": true}' > config/auth.json
     fi
     ```

3.  **Setting Specific UID/GID**:
     If a container requires a specific UID (e.g., 5050) that implies `chmod`/`chown` might be needed.
    
     *Example:*
     ```bash
     #!/bin/bash
     mkdir -p pgadmin_data
     # Note: chmod/chown usually requires sudo or being the owner.
     # If running strictly as user, ensure the directory is writable.
     chmod 777 pgadmin_data
     ```
