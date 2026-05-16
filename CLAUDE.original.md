# CLAUDE.md

Guidance to Claude Code (claude.ai/code) for this repository.

## What this project does

Ansible project: automated DB provisioning via AWX (Red Hat Ansible Automation Platform). Installs + hardens SQL Server, MySQL, PostgreSQL on Linux VMs. Manages DB users through AWX job templates driven by survey variables.

## Running playbooks

```bash
# Full DB deploy (no tags)
ansible-playbook playbooks/deploy_mysql.yml
ansible-playbook playbooks/deploy_postgres.yml
ansible-playbook playbooks/deploy_sqlserver.yml

# Single phase by tag (e.g. install only, skip user management)
ansible-playbook playbooks/deploy_mysql.yml --tags mysql_install
ansible-playbook playbooks/deploy_mysql.yml --tags mysql_users

# Limit to specific host
ansible-playbook playbooks/deploy_mysql.yml -l mysqlvm

# Dry run
ansible-playbook playbooks/deploy_mysql.yml --check

# Install required collections (internet-connected machine; then copy to AWX host)
ansible-galaxy collection install -r collections/requirements.yml -p /opt/collections
```

`ansible.cfg` points inventory to `./inventory/`, roles to `./roles/`. Remote user: `user_aap`. Collections load from `/opt/collections` first (offline-first for AWX).

## Architecture

### Playbook → Role mapping

| Playbook | Roles invoked (in order) |
|---|---|
| `deploy_sqlserver.yml` | storage_setup → security_hardening → sql_pre_reqs → sql_install → sql_post_config → sql_manage_users (optional) → db_patches (optional) |
| `deploy_mysql.yml` | mysql_install → mysql_manage_users (optional) → db_patches (optional) |
| `deploy_postgres.yml` | postgres_install → postgres_manage_users (optional) → db_patches (optional) |
| `01_db_provisioning.yml` | Unified entry point; selects engine via `db_type` survey var (`mysql`/`postgres`/`oracle`) |

Optional phases (user management, patching) gated by boolean extra vars (`mysql_manage_users_enabled`, `postgres_manage_users_enabled`, `sql_manage_users_enabled`, `db_patches_enabled`) or by tag.

### Survey-driven variables

User-management roles share common variable schema from AWX surveys:
- `db_username`, `db_user_host`, `db_password`, `db_privileges`, `db_target_databases`, `db_user_state` (`present`/`absent`), `db_revoke_access`, `db_append_privileges`, `db_manage_databases`

SQL Server own schema: `sql_login_name`, `sql_login_password`, `sql_login_type`, `sql_target_database`, `sql_database_roles`, etc.

AWX survey JSON specs in `playbooks/awx_survey_*.json`. Playbook→survey→tag mapping in `docs/awx_surveys.md`.

### Key defaults to know

- MySQL binds port **13306** (non-standard); PostgreSQL **15432**.
- `db_patch_apply_enabled` hardcoded `false` — patch discovery runs, never auto-applies.
- `mysql_root_password` has default in `roles/mysql_install/defaults/main.yml`; override per host/group in production.

### Collections required

`ansible.windows`, `community.windows`, `community.mysql`, `community.postgresql` — declared in `collections/requirements.yml`. Offline AWX: copy expanded collection trees to `/opt/collections/ansible_collections/` on AWX/EE host; disable "Install collections" on AWX Project to prevent Galaxy calls.

### Documentation

Runbooks + reference docs in `docs/`:
- `docs/mysql_runbook.md` — MySQL tag map, survey vars, AWX template patterns
- `docs/sqlserver_runbook.md` — SQL Server tag map, survey vars, AWX template patterns
- `docs/postgres_runbook.md` — PostgreSQL tag map, survey vars, AWX template patterns
- `docs/awx_surveys.md` — master matrix: playbook → survey file → tag mappings

### Lab infrastructure

All VMs inside **Proxmox** hypervisor (192.168.137.145) running on VMware Workstation on local machine. VMs unreachable → start VMware Workstation, boot Proxmox VM first.

**VM credentials (all nodes):** user `user_aap`, password `$RFVbgt5`. Firewall disabled, SSH pre-configured. Matches `ansible.cfg` remote user.

**OS templates in Proxmox:**
- `templateRH9` — RHEL 9 base image
- `templateWServer2022` — Windows Server 2022 base image

AWX automation controller (`awxvm`) on Proxmox cluster — entry point for all job template execution. Target hosts in `inventory/LINUX.yml`.

Obisian Vault is in D:\claudevault\claudvault\DocClaude\00_INDEX