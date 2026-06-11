# Observability Stack — Air-Gapped Ansible Deployment

Deploys **Loki 3.6.x · Grafana 13.0.x · Prometheus 3.11.x · Grafana Alloy 1.9.x** via AWX
(or local `ansible-playbook`) in fully air-gapped environments.

No task touches the internet. All binaries come from `artifacts_base_dir` on the controller/EE.

---

## Prerequisites

### 1. Artifacts (on AWX Execution Environment or controller)

Stage binaries under `artifacts_base_dir` (default `/opt/observability-artifacts`):

```
/opt/observability-artifacts/
├── loki-linux-amd64.zip               # github.com/grafana/loki/releases — 3.6.x
├── grafana-enterprise-<ver>.x86_64.rpm   # RHEL
├── grafana-enterprise_<ver>_amd64.deb    # Ubuntu
├── alloy-<ver>.amd64.rpm              # RHEL
├── alloy-<ver>.amd64.deb              # Ubuntu
├── alloy-installer-windows-amd64.exe  # Windows (if manage_windows: true)
├── prometheus-<ver>.linux-amd64.tar.gz
├── node_exporter-<ver>.linux-amd64.tar.gz  # only if metrics_mode: node_exporter
├── plugins/                           # optional: *.zip per Grafana plugin
│   └── grafana-piechart-panel-<ver>.zip
└── dashboards/                        # JSON dashboard files to import
    ├── node-exporter-full.json
    └── loki-logs.json
```

Fill `artifact_checksums` in `group_vars/all.yml` with the actual SHA256 of each file.
Run `sha256sum <file>` (Linux) or `Get-FileHash <file> -Algorithm SHA256` (Windows PowerShell).

### 2. Collections in AWX Execution Environment

The EE must have these collections pre-installed (no Galaxy calls at runtime):

```
community.general >= 8.0
ansible.posix     >= 1.5
ansible.windows   >= 2.0
community.windows >= 2.0
```

On an internet-connected machine:
```bash
ansible-galaxy collection install -r requirements.yml -p /opt/collections
```
Then bundle `/opt/collections/ansible_collections/` into your EE or copy to the AWX host.

Disable **"Install collections"** on the AWX Project to prevent Galaxy lookups.

### 3. Inventory

Edit `inventories/production/hosts.ini` with real hostnames/IPs and `group_vars/all.yml`
with actual versions, endpoints, SMTP, and checksums.

---

## Running locally

```bash
# Full stack (preflight → server → Linux agents)
ansible-playbook site.yml

# Only preflight
ansible-playbook site.yml --tags preflight

# Only server components
ansible-playbook playbooks/10_observability_server.yml

# Only agents on Linux
ansible-playbook playbooks/20_linux_agents.yml

# Specific role
ansible-playbook site.yml --tags loki
ansible-playbook site.yml --tags alloy

# Dry run
ansible-playbook site.yml --check --diff

# Syntax check
ansible-playbook site.yml --syntax-check
```

---

## AWX Job Templates

Create **four Job Templates** in this order:

| # | Template name           | Playbook                            | Tags      | Notes                          |
|---|-------------------------|-------------------------------------|-----------|--------------------------------|
| 1 | OBS — Preflight         | `playbooks/00_preflight.yml`        | preflight | Run first; fails fast          |
| 2 | OBS — Server            | `playbooks/10_observability_server.yml` | server | Loki + Grafana + Prometheus    |
| 3 | OBS — Linux Agents      | `playbooks/20_linux_agents.yml`     | agents    | Alloy ± Node Exporter          |
| 4 | OBS — Windows Agents    | `playbooks/30_windows_agents.yml`   | agents    | Only when manage_windows=true  |

**AWX Workflow:** chain 1 → 2 → 3 (→ 4 if Windows). Use "On Success" links.

### Survey variables (override per-run)

| Variable                         | Default               | Description                          |
|----------------------------------|-----------------------|--------------------------------------|
| `metrics_mode`                   | `alloy`               | `alloy` (push) or `node_exporter`    |
| `manage_windows`                 | `false`               | Enable Windows agent deployment      |
| `loki_retention_period`          | `720h`                | Log retention                        |
| `prometheus_retention`           | `30d`                 | Metrics retention                    |
| `environment_label`              | `prod`                | Label applied to all telemetry       |
| `loki_endpoint`                  | *(required)*          | Full Loki push URL                   |
| `prometheus_remote_write_endpoint` | *(required)*        | Full Prometheus remote-write URL     |

---

## Architecture

```
                        +----------------+
                        |    Grafana     |  :3000
                        +--------+-------+
                                 |
                   +-------------+-------------+
                   |                           |
                   v                           v
           +---------------+          +---------------+
           |     Loki      | :3100    |  Prometheus   | :9090
           +-------+-------+          +-------+-------+
                   ^                          ^
           Alloy push logs            Alloy remote_write  (metrics_mode=alloy)
           (loki.write)               OR Node Exporter scrape :9100
                   |                          |
          +--------+--------+        +--------+--------+
          |                 |        |                 |
        RHEL 8/9         Ubuntu    RHEL 8/9         Ubuntu
```

---

## Variables requiring team input

These **must** be set before first run. Everything else has a sensible default.

| Variable                  | File               | What to fill                                    |
|---------------------------|--------------------|-------------------------------------------------|
| `artifacts_base_dir`      | `all.yml`          | Path on EE/controller where binaries live       |
| `loki_version`            | `all.yml`          | Exact version string (e.g. `3.6.0`)             |
| `grafana_version`         | `all.yml`          | Exact version string                            |
| `prometheus_version`      | `all.yml`          | Exact version string                            |
| `alloy_version`           | `all.yml`          | Exact version string                            |
| `node_exporter_version`   | `all.yml`          | Exact version string (only if mode=node_exporter)|
| `artifact_checksums.*`    | `all.yml`          | SHA256 of each binary/package                   |
| `loki_endpoint`           | `all.yml`          | `http://OBS_SERVER_IP:3100/loki/api/v1/push`    |
| `prometheus_remote_write_endpoint` | `all.yml` | `http://OBS_SERVER_IP:9090/api/v1/write`        |
| `grafana_smtp_host`       | `all.yml`          | Internal SMTP relay `host:port`                 |
| `grafana_smtp_from`       | `all.yml`          | Sender address                                  |
| `grafana_admin_password`  | **Vault/AWX cred** | Do NOT put plaintext in repo                    |
| hosts in `hosts.ini`      | `hosts.ini`        | Real IPs/FQDNs per group                        |
| `ansible_host` per host   | `hosts.ini`        | IP if DNS not reliable                          |

---

## Security notes

- No secrets in the repo. `grafana_admin_password` must come from AWX credential or Ansible Vault.
- Loki and Prometheus have no built-in auth. Put nginx with basic-auth or restrict by firewall.
- Services run as dedicated non-root users (`loki`, `grafana`, `prometheus`, `alloy`, `node_exporter`).
- Firewall ports to open: `3000/tcp` (Grafana), `3100/tcp` (Loki), `9090/tcp` (Prometheus),
  `9100/tcp` (Node Exporter or Alloy metrics), `12345/tcp` (Alloy UI — optional, local only).
