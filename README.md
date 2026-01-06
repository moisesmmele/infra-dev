# Docker Development Infrastructure

This repository contains the Docker Compose configuration for a local development infrastructure stack.

> [!WARNING]
> **CRITICAL: HOST NETWORK MODIFICATIONS**
>
> Do not run the `setup.sh` scripts on your personal workstation or laptop. This infrastructure is designed for a **dedicated server or VM only**.
>
> * **Network Override:** The `technitium/setup.sh` script detects your active interface and **overwrites your Netplan configuration** to enforce a static IP.
> * **DNS Changes:** It disables `systemd-resolved` and modifies `/etc/resolv.conf` to free up Port 53.
> * **Security:** Data directories are set to `chmod 777` for compatibility, which is unsafe for production environments exposed to the internet.
> 
> **DO NOT RUN THIS ON YOUR PERSONAL MACHINE (LAPTOP/DESKTOP).**
> 
> **Specially if you're not sure what you're doing.**

## Services

| Service | Protocol/Port | Description |
|---------|---------------|-------------|
| **Portainer** | `:9000` | Container management UI |
| **CloudBeaver** | `:8978` | Database management tool |
| **Redis Insight** | `:5540` | Redis web UI |
| **Mailpit** | `:8025` (Web), `:1025` (SMTP) | Email testing tool |
| **Note: Hoppscotch** | `-` | API testing tool (Disabled by default) |
| **Nginx Proxy Manager** | `:81` (Admin), `:80`/`:443` | Reverse proxy manager |
| **Technitium DNS** | `:5380` (Web), `:53` (DNS) | DNS Server |
| **Homepage** | `:3000` | Dashboard |
| **Cert Server** | `:80` | Serves Root CA certificate |
| **Init Service** | `-` | Automates post-boot configuration |

## Prerequisites

1.  **Docker** and **Docker Compose** installed.
2.  **mkcert** installed (optional, for SSL generation in init service).

## Getting Started

1.  **Configure Environment**:
    Copy `.env.example` to `.env` and adjust variables if needed.
    ```bash
    cp .env.example .env
    ```

2.  **Run Setup Script**:
    Run the setup script to prepare service directories.
    ```bash
    ./setup.sh
    ```

3.  **Start Services**:
    ```bash
    docker compose up -d
    ```

## Initialization & Automation

This stack includes an **Init Service** that runs automatically after all other containers are healthy.
It performs the following actions:
1.  **SSL Generation**: Automatically runs `mkcert` to generate certificates for the configured `DNS_ZONE`.
2.  **CA Serving**: Hosts the Root CA certificate at `http://ca.<DNS_ZONE>` (e.g., `http://ca.dev.local`) for easy client installation.
3.  **NPM Bootstrapping**:
    -   Automatically creates the admin user if the database is empty (skips the welcome screen).
    -   Configures credentials based on `.env` variables (`NPM_ADMIN_EMAIL`, etc.).
4.  **DNS Configuration**:
    -   Creates a primary zone matching `DNS_ZONE`.
    -   Creates a **Wildcard A Record** (`*.dev.local`) pointing to `STATIC_IP` (if set), routing all subdomains to the host.
5.  **Proxy Configuration**: Reads environment variables (e.g., `PORTAINER_CONTAINER_NAME`) to automatically create Proxy Hosts in Nginx Proxy Manager (NPM).
    -   Uses the `DNS_ZONE` (e.g., `app.example.com`).
    -   Configures SSL using the custom certificates generated.

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

4.  **Advanced Network & System Configuration**:
     Scripts can also handle host-level networking (e.g., setting static IPs) if minimal dependencies like `sudo` are available.

     *Example: `technitium/setup.sh`*
     Configures a static IP and gateway for the host if `BASE_DNS`, `STATIC_IP`, and `GATEWAY_IP` are provided in `.env`.
     ```
