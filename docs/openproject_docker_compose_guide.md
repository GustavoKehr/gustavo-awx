# OpenProject — Installation & Configuration via Docker Compose (Ubuntu 22.04)

> **Reference:** [Official OpenProject Docker Compose Docs](https://www.openproject.org/docs/installation-and-operations/installation/docker-compose/)
> **Version:** OpenProject stable/17 | Docker Compose v2
> **Architecture:** OpenProject containers + external PostgreSQL DBaaS (RDS, Cloud SQL, Azure DB, etc.)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [System Requirements](#2-system-requirements)
3. [Prepare the External PostgreSQL Database](#3-prepare-the-external-postgresql-database)
4. [Install Docker & Docker Compose](#4-install-docker--docker-compose)
5. [Clone the OpenProject Compose Repository](#5-clone-the-openproject-compose-repository)
6. [Disable the Built-in DB Container](#6-disable-the-built-in-db-container)
7. [Configure Environment Variables](#7-configure-environment-variables)
8. [Create Required Host Directories](#8-create-required-host-directories)
9. [Start OpenProject](#9-start-openproject)
10. [First Login & Initial Setup](#10-first-login--initial-setup)
11. [Production Considerations](#11-production-considerations)
12. [Useful Operations](#12-useful-operations)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Architecture Overview

```
┌─────────────────────────────────┐        ┌──────────────────────────┐
│       Ubuntu 22.04 Host         │        │   External DBaaS         │
│                                 │        │   (RDS / Cloud SQL /     │
│  ┌──────────────────────────┐   │        │    Azure DB / etc.)      │
│  │  docker compose stack    │   │        │                          │
│  │                          │   │  TCP   │  PostgreSQL 16+          │
│  │  proxy  →  web           │◄──┼──5432──►  database: openproject   │
│  │           worker         │   │        │  user: openproject        │
│  │           cron           │   │        │                          │
│  │           cache (Redis)  │   │        └──────────────────────────┘
│  │           fbullboard     │   │
│  └──────────────────────────┘   │
└─────────────────────────────────┘
```

**What runs on the host:** all OpenProject application containers.
**What runs externally:** PostgreSQL only — no `db` container in the compose stack.

---

## 2. System Requirements

### Host server

| Resource | Minimum | Recommended (≤200 users) |
|----------|---------|--------------------------|
| CPU | Quad Core ≥ 2GHz | 4 cores |
| RAM | 4 GB | 4–8 GB |
| Disk | 20 GB free | 40 GB+ (attachments grow) |
| OS | Ubuntu 22.04 LTS (64-bit) | Ubuntu 22.04 LTS |
| Docker Engine | 24.x+ | Latest stable |
| Docker Compose | v2.x (`docker compose`) | Latest stable |

### External PostgreSQL DBaaS

| Requirement | Detail |
|-------------|--------|
| Version | PostgreSQL **16+** (13–15 may work, unsupported) |
| Extensions | `pg_trgm`, `btree_gist`, `unaccent` — must be installable |
| Network | DBaaS must be reachable from host on port 5432 |
| User privileges | Must be able to CREATE extensions and run migrations |

> **AWS RDS / Aurora:** assign `rds_superuser` role to the OpenProject user so it can install extensions. On Cloud SQL, enable extensions via the `cloudsqlsuperuser` role.

---

## 3. Prepare the External PostgreSQL Database

Connect to your DBaaS as an admin user and run:

```sql
-- Create dedicated user
CREATE USER openproject WITH PASSWORD 'strongpassword';

-- Create database owned by that user
CREATE DATABASE openproject OWNER openproject ENCODING 'UTF8';

-- Connect to the new database
\c openproject

-- Install required extensions (run as superuser/admin)
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- Grant all privileges on the database
GRANT ALL PRIVILEGES ON DATABASE openproject TO openproject;
```

> **Note:** OpenProject runs its own migrations on first boot. The user needs CREATE/ALTER/DROP table privileges — not just SELECT/INSERT. On managed services, granting ownership of the database is the simplest approach.

### Test connectivity from the host before proceeding

```bash
# Install psql client if not present
sudo apt-get install -y postgresql-client

# Test connection
psql "postgresql://openproject:strongpassword@<db-host>:5432/openproject" -c "SELECT version();"
```

If this fails, fix network/firewall rules between host and DBaaS before continuing.

---

## 4. Install Docker & Docker Compose

Remove any old Docker packages first:

```bash
sudo apt-get remove -y docker docker-engine docker.io containerd runc
```

Install prerequisites:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release
```

Add Docker's official GPG key and repository:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

Install Docker Engine and Compose plugin:

```bash
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

Enable Docker on boot and add your user to the `docker` group:

```bash
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker
```

Verify:

```bash
docker version
docker compose version
```

---

## 5. Clone the OpenProject Compose Repository

```bash
git clone https://github.com/opf/openproject-docker-compose.git \
  --depth=1 \
  --branch=stable/17 \
  openproject

cd openproject
```

> `--depth=1` fetches only the latest commit (faster). `--branch=stable/17` pins to OpenProject 17 (latest stable).

Repository structure:

```
openproject/
├── docker-compose.yml                  # Main file — do NOT edit directly
├── docker-compose.override.yml.example # Template for local overrides
├── .env.example                        # Template for all env vars
└── ...
```

---

## 6. Disable the Built-in DB Container

The default `docker-compose.yml` includes a `db` service (PostgreSQL container). Since you're using an external DBaaS, disable it via the override file.

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
```

Open `docker-compose.override.yml` and add a section to **remove the `db` service** and break the dependency:

```yaml
# docker-compose.override.yml

services:
  db:
    # Disable the built-in PostgreSQL container — using external DBaaS
    profiles:
      - disabled

  web:
    depends_on: []

  worker:
    depends_on: []

  seeder:
    depends_on: []
```

> **Why `profiles: [disabled]`?** Assigning an inactive profile prevents Docker Compose from starting the `db` container without removing it from the file — cleaner than deleting the service definition.

Verify the `db` service will not start:

```bash
docker compose config --services
```

Output should list: `web`, `worker`, `proxy`, `cache`, `cron`, `fbullboard`, `seeder` — but **not** `db`.

---

## 7. Configure Environment Variables

Copy the example file:

```bash
cp .env.example .env
nano .env
```

### Critical variables

| Variable | Description | Notes |
|----------|-------------|-------|
| `DATABASE_URL` | Full PostgreSQL connection string | **Required** — points to external DBaaS |
| `SECRET_KEY_BASE` | Rails app encryption key | Generate: `openssl rand -hex 64` |
| `OPENPROJECT_HTTPS` | HTTPS enforcement | `false` for lab, `true` for production |
| `PORT` | Host port for OpenProject | `8080` default |
| `COLLABORATIVE_SERVER_SECRET` | Real-time collaboration secret | Generate: `openssl rand -hex 32` |
| `OPENPROJECT_HOST__NAME` | Hostname in generated URLs | e.g. `openproject.yourdomain.com` |

### DATABASE_URL format

```
postgresql://USER:PASSWORD@HOST:PORT/DATABASE?sslmode=require&pool=20
```

| Parameter | Description |
|-----------|-------------|
| `sslmode=require` | Enforce TLS to DBaaS — **recommended** |
| `pool=20` | Connection pool size — tune to DBaaS max_connections |
| `encoding=unicode` | Optional but recommended |
| `reconnect=true` | Auto-reconnect on dropped connections |

Full example:

```
postgresql://openproject:strongpassword@mydb.rds.amazonaws.com:5432/openproject?sslmode=require&pool=20&encoding=unicode&reconnect=true
```

### Generate secure secrets

```bash
# SECRET_KEY_BASE
openssl rand -hex 64

# COLLABORATIVE_SERVER_SECRET
openssl rand -hex 32
```

### Complete `.env` example

```dotenv
# Database — external DBaaS
DATABASE_URL=postgresql://openproject:strongpassword@mydb.rds.amazonaws.com:5432/openproject?sslmode=require&pool=20&encoding=unicode&reconnect=true

# Application secrets
SECRET_KEY_BASE=<paste-64-char-hex-here>
COLLABORATIVE_SERVER_SECRET=<paste-32-char-hex-here>

# Network
OPENPROJECT_HTTPS=false
PORT=8080
OPENPROJECT_HOST__NAME=localhost

# Image version
TAG=17
```

> **Double underscore convention:** `OPENPROJECT_HOST__NAME` maps to `host.name` in Rails config. Two underscores (`__`) = a dot (`.`) in the config key hierarchy.

---

## 8. Create Required Host Directories

OpenProject needs a host directory for persistent file attachments:

```bash
sudo mkdir -p /var/openproject/assets
sudo chown 1000:1000 -R /var/openproject/assets
```

> UID `1000` = user inside the OpenProject container. Required for the app to write uploads, exports, and backups.

No database directory needed — data lives entirely in the external DBaaS.

---

## 9. Start OpenProject

```bash
docker compose up -d --build --pull always
```

| Flag | Effect |
|------|--------|
| `-d` | Detached — runs in background |
| `--build` | Builds any locally-defined images |
| `--pull always` | Pulls latest image versions before starting |

### Watch startup logs

```bash
docker compose logs -f
```

First boot takes 2–3 minutes. OpenProject runs database migrations automatically on startup. Watch for:

```
web_1     | => Booting Puma
web_1     | => Rails ... application starting in production
web_1     | * Listening on ...
```

### Check container status

```bash
docker compose ps
```

Expected output — no `db` container:

```
NAME                        STATUS
openproject-cache-1         Up
openproject-seeder-1        Exited (0) ...   ← normal, runs once
openproject-web-1           Up (healthy)
openproject-worker-1        Up
openproject-cron-1          Up
openproject-proxy-1         Up
openproject-fbullboard-1    Up
```

> `seeder` exiting with code `0` is **expected** — seeds initial data once, then stops.

---

## 10. First Login & Initial Setup

Navigate to:

```
http://<server-ip>:8080
```

| Field | Value |
|-------|-------|
| Username | `admin` |
| Password | `admin` |

**Password change is enforced on first login.**

### Recommended post-login steps

1. **Change admin password** (required on first login)
2. **Set hostname** — Administration → System Settings → General → Host name
3. **Configure SMTP** — Administration → Email → Outgoing emails
4. **Create first project** — Projects → + New Project

---

## 11. Production Considerations

### 11.1 TLS / HTTPS

Use a reverse proxy in front of OpenProject — it does not manage TLS certificates itself.

**Nginx example:**

```nginx
server {
    listen 443 ssl;
    server_name openproject.yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/openproject.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/openproject.yourdomain.com/privkey.pem;

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
    }
}
```

Set in `.env`:

```dotenv
OPENPROJECT_HTTPS=true
PORT=127.0.0.1:8080
OPENPROJECT_HOST__NAME=openproject.yourdomain.com
```

### 11.2 SMTP (outgoing email)

Add to `.env`:

```dotenv
OPENPROJECT_SMTP__ADDRESS=smtp.yourdomain.com
OPENPROJECT_SMTP__PORT=587
OPENPROJECT_SMTP__USER__NAME=no-reply@yourdomain.com
OPENPROJECT_SMTP__PASSWORD=yourpassword
OPENPROJECT_SMTP__AUTHENTICATION=plain
OPENPROJECT_SMTP__ENABLE__STARTTLS__AUTO=true
OPENPROJECT_MAIL__FROM=no-reply@yourdomain.com
OPENPROJECT_MAIL__DELIVERY__METHOD=smtp
```

Then restart: `docker compose up -d`

### 11.3 Firewall

```bash
sudo ufw allow 22/tcp      # SSH
sudo ufw allow 443/tcp     # HTTPS via reverse proxy
sudo ufw enable
# Do NOT expose port 8080 directly in production
```

### 11.4 Backups

Since PostgreSQL runs externally, **use your DBaaS provider's backup mechanisms** as the primary strategy (RDS automated backups, Cloud SQL snapshots, etc.).

For manual/portable backups from the host:

```bash
# Requires postgresql-client installed on host (see Section 3)
pg_dump "postgresql://openproject:strongpassword@<db-host>:5432/openproject" \
  --no-password \
  -Fc \
  -f openproject_db_$(date +%F).dump
```

> `-Fc` = custom format (compressed, supports parallel restore with `pg_restore`).

**Attachments backup:**

```bash
tar -czf openproject_assets_$(date +%F).tar.gz /var/openproject/assets
```

**Schedule with cron:**

```bash
crontab -e
```

```
0 2 * * * pg_dump "postgresql://openproject:strongpassword@<db-host>:5432/openproject" -Fc -f /backup/openproject_db_$(date +\%F).dump
0 3 * * * tar -czf /backup/openproject_assets_$(date +\%F).tar.gz /var/openproject/assets
```

---

## 12. Useful Operations

### Stop OpenProject

```bash
docker compose down
```

### Stop and remove local volumes (attachment data — use with caution)

```bash
docker compose down -v
```

> This does **not** affect the external database. Only local Docker volumes (Redis cache, assets) are removed.

### Restart specific service

```bash
docker compose restart web
docker compose restart worker
```

### View logs

```bash
docker compose logs -f           # all services
docker compose logs -f web       # web only
docker compose logs -f worker    # worker only
```

### Rails console (admin debugging)

```bash
docker compose exec web bundle exec rails console
```

### Update OpenProject

```bash
git pull
docker compose up -d --build --pull always
```

> Migrations run automatically on startup. Back up the database before any major version upgrade.

### Check OpenProject version

```bash
docker compose exec web cat /app/VERSION
```

### Verify resolved environment variables (debug)

```bash
docker compose config
```

---

## 13. Troubleshooting

### OpenProject cannot connect to database

Check `DATABASE_URL` is correct and reachable:

```bash
# Test from host
psql "$DATABASE_URL" -c "SELECT 1;"

# Test from inside the web container
docker compose exec web sh -c 'psql "$DATABASE_URL" -c "SELECT 1;"'
```

Common causes:
- DBaaS security group / firewall blocking port 5432 from the host IP
- Wrong hostname, port, or credentials in `DATABASE_URL`
- SSL mode mismatch (`sslmode=require` vs DBaaS requiring `verify-full`)

### Migration fails on first boot — extension not found

```
PG::UndefinedObject: ERROR: extension "pg_trgm" does not exist
```

Extensions must be created **before** starting OpenProject, and the DB user must have permission to install them. Re-run Section 3 as a DBaaS admin user.

### `web` container crashes — `SECRET_KEY_BASE` missing

```bash
docker compose config | grep SECRET_KEY_BASE
```

If empty, regenerate and set in `.env`:

```bash
openssl rand -hex 64
```

### Container fails to write attachments — permission denied

```bash
sudo chown -R 1000:1000 /var/openproject/assets
docker compose restart web worker
```

### SMTP email not sending — DNS resolution failure inside container

Add DNS to the worker service in `docker-compose.override.yml`:

```yaml
services:
  worker:
    dns:
      - 8.8.8.8
      - 1.1.1.1
```

Then: `docker compose up -d`

### Login page redirects to wrong URL

`OPENPROJECT_HOST__NAME` in `.env` must match exactly what the browser uses. Update and restart.

### `db` container still appears in `docker compose ps`

Check `docker-compose.override.yml` — verify the `profiles: [disabled]` block is present and indented correctly under `db:`. Then run `docker compose down && docker compose up -d`.

---

## Quick Reference

| Task | Command |
|------|---------|
| Start | `docker compose up -d --pull always` |
| Stop | `docker compose down` |
| Logs | `docker compose logs -f` |
| Status | `docker compose ps` |
| Update | `git pull && docker compose up -d --build --pull always` |
| DB Backup | `pg_dump "$DATABASE_URL" -Fc -f backup_$(date +%F).dump` |
| DB Restore | `pg_restore -d "$DATABASE_URL" --no-owner backup.dump` |
| Rails console | `docker compose exec web bundle exec rails console` |
| Test DB conn | `psql "$DATABASE_URL" -c "SELECT version();"` |

---

*Sources:*
- *[OpenProject Docker Compose Docs](https://www.openproject.org/docs/installation-and-operations/installation/docker-compose/)*
- *[OpenProject Custom Database Configuration](https://www.openproject.org/docs/installation-and-operations/configuration/database/)*
- *[OpenProject System Requirements](https://www.openproject.org/docs/installation-and-operations/system-requirements/)*
- *[OpenProject Advanced Configuration](https://www.openproject.org/docs/installation-and-operations/configuration/)*
