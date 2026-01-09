# Docker Development Infrastructure

This repository contains a modular Docker Compose configuration for a local development infrastructure stack. It provides a suite of tools for database management, API testing, email testing, and container orchestration, all accessible through a unified dashboard and automatic reverse proxy system.

> [!WARNING]
> **CRITICAL: SYSTEM MODIFICATIONS**
>
> **Do not run the `setup.sh` script on your personal workstation or laptop.**
>
> This infrastructure is designed for a **dedicated development server or VM**. The setup script performs intrusive system modifications:
> * **Network Override:** Detects your active interface and **overwrites your Netplan configuration** to enforce a static IP.
> * **DNS Changes:** Disables `systemd-resolved` and modifies `/etc/resolv.conf` to free up Port 53 for the DNS server.
> * **Permissions:** Creates data directories with loose permissions (`chmod 777`) to avoid container user mapping issues.
>
> **Run this only in a controlled, disposable environment (e.g., a local VM or Proxmox container).**

## 📦 Services

The stack includes the following services, orchestrated via `docker-compose.yml` and individual service configurations:

| Service | Host Port(s) | Internal URL (Default) | Description |
| :--- | :--- | :--- | :--- |
| **Homepage** | `:3000` | `http://home.dev.local` | Unified dashboard for all services. |
| **Nginx Proxy Manager** | `:81` (Admin)<br>`:80`, `:443` | `http://npm.dev.local` | Reverse proxy and SSL management. |
| **Technitium DNS** | `:5380` (Web)<br>`:53` (DNS) | `http://dns.dev.local` | Local DNS Server & Ad Blocker. |
| **Portainer** | `:9000`, `:9443` | `https://portainer.dev.local` | Docker container management UI. |
| **CloudBeaver** | `:8978` | `http://database.dev.local` | Universal database management tool. |
| **Redis Insight** | `:5540` | `http://redis.dev.local` | GUI for Redis. |
| **Mongoku** | `:3100` | `http://mongoku.dev.local` | MongoDB web interface. |
| **Mailpit** | `:8025` | `http://mail.dev.local` | Email testing tool (SMTP capture). |
| **Restfox** | `:4004` | `http://restfox.dev.local` | Offline-first API testing client. |
| **Cert Server** | `:80` (Direct) | `http://cert-server.dev.local` | Serves the generated Root CA certificate. |

## 🚀 Getting Started

### 1. Configure Environment
Copy the example environment file and configure your network settings.
```bash
cp .env.example .env
```
**Key Variables to Check in `.env`:**
* `DNS_ZONE`: The local domain to use (default: `dev.local`).
* `STATIC_IP`: The static IP you want this server to use.
* `GATEWAY_IP`: Your network gateway.
* `BASE_DNS`: Upstream DNS for the host (e.g., `1.1.1.1`).

### 2. Run System Setup
Execute the setup script to prepare the host. This script will install required directories and configure the host's networking (Static IP + DNS).
```bash
chmod +x ./setup.sh
./setup.sh
```
*Use `./setup.sh --revert` if you need to restore the original network configuration.*

### 3. Start Services
Launch the stack.
```bash
docker compose up -d
```

## 🤖 Automation & Initialization

This stack includes a specialized **`init`** service that runs automatically after the core services are healthy. It handles the "glue" logic to make the environment ready-to-use without manual configuration.

The `init/init.sh` script performs the following:

1.  **SSL Generation**:
    * Uses `mkcert` to generate a valid Root CA and wildcard certificates for your `DNS_ZONE` (e.g., `*.dev.local`).
    * Exposes the Root CA via the **Cert Server** for easy download and installation on your client machine.

2.  **DNS Configuration (Technitium)**:
    * Waits for Technitium to accept connections.
    * Logs in and creates the Primary Zone (`dev.local`).
    * Creates a **Wildcard A Record** (`*.dev.local`) pointing to the server's `STATIC_IP`.

3.  **Proxy Configuration (NPM)**:
    * **Auto-Login**: Creates the admin user/password defined in `.env` (skips the initial setup screen).
    * **Certificate Upload**: Uploads the generated `mkcert` SSL certificates to NPM.
    * **Proxy Host Creation**: loops through the defined services and automatically creates Proxy Hosts in NPM. It maps the service name (e.g., `portainer`) to the domain (e.g., `portainer.dev.local`) and enables SSL.

## 📂 Project Structure

The project uses a modular structure to keep configurations clean:

* **`docker-compose.yml`**: The main entry point. It uses the `include` feature to pull in service configurations.
* **Service Directories** (e.g., `/portainer`, `/npm`):
    * `compose.yml`: Service-specific Docker definition.
    * `data/`: Persistent storage (created by `setup.sh`).
* **`setup.sh`**: The master host preparation script.
* **`init/`**: Contains the Dockerfile and script for the automation container.
* **`homepage/config/`**: Configuration files (`services.yaml`, `widgets.yaml`) for the dashboard.

## 🔧 Client Setup

To access your services using the domain names (e.g., `https://portainer.dev.local`), you must configure your client machine (your laptop/desktop):

1.  **DNS**: Set your computer's DNS to the IP address of this server.
2.  **Trust the CA**:
    * Go to `http://<SERVER_IP>/root-ca.crt` (or via the Cert Server proxy if DNS is working).
    * Download the certificate.
    * Install it into your Trusted Root Certification Authorities store.