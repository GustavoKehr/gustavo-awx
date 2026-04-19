# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

Ansible project for automated database provisioning via AWX (Red Hat Ansible Automation Platform). It installs and hardens SQL Server, MySQL, and PostgreSQL on Linux VMs and manages database users through AWX job templates driven by survey variables.

## Running playbooks

```bash
# Full DB deploy (no tags)
ansible-playbook playbooks/deploy_mysql.yml
ansible-playbook playbooks/deploy_postgres.yml
ansible-playbook playbooks/install_sql_playbook.yml

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

`ansible.cfg` points inventory to `./inventory/` and roles to `./roles/`. The remote user is `user_aap`; collections are loaded from `/opt/collections` first (offline-first for AWX).

## Architecture

### Playbook → Role mapping

| Playbook | Roles invoked (in order) |
|---|---|
| `install_sql_playbook.yml` | storage_setup → security_hardening → sql_pre_reqs → sql_install → sql_post_config → sql_manage_users (optional) → db_patches (optional) |
| `deploy_mysql.yml` | mysql_install → mysql_manage_users (optional) → db_patches (optional) |
| `deploy_postgres.yml` | postgres_install → postgres_manage_users (optional) → db_patches (optional) |
| `01_db_provisioning.yml` | Unified entry point; selects engine via `db_type` survey var (`mysql`/`postgres`/`oracle`) |

Optional phases (user management, patching) are gated by boolean extra vars (`mysql_manage_users_enabled`, `postgres_manage_users_enabled`, `sql_manage_users_enabled`, `db_patches_enabled`) or by running with the corresponding tag directly.

### Survey-driven variables

User-management roles share a common variable schema sourced from AWX surveys:
- `db_username`, `db_user_host`, `db_password`, `db_privileges`, `db_target_databases`, `db_user_state` (`present`/`absent`), `db_revoke_access`, `db_append_privileges`, `db_manage_databases`

SQL Server has its own schema: `sql_login_name`, `sql_login_password`, `sql_login_type`, `sql_target_database`, `sql_database_roles`, etc.

AWX survey JSON specs live in `playbooks/awx_survey_*.json`. The mapping of playbooks to survey files and tags is documented in `docs/awx_surveys.md`.

### Key defaults to know

- MySQL binds on port **13306** (non-standard); PostgreSQL on **15432**.
- `db_patch_apply_enabled` is hardcoded `false` — patch discovery runs but patches are never applied automatically.
- `mysql_root_password` has a default in `roles/mysql_install/defaults/main.yml`; override it per host/group in production.

### Collections required

`ansible.windows`, `community.windows`, `community.mysql`, `community.postgresql` — declared in `collections/requirements.yml`. In offline AWX, copy expanded collection trees to `/opt/collections/ansible_collections/` on the AWX/EE host; disable "Install collections" on the AWX Project to prevent Galaxy calls.

### Documentation

All operational runbooks and reference docs live in `docs/`:
- `docs/mysql_runbook.md` — MySQL tag map, survey vars, AWX template patterns
- `docs/sqlserver_runbook.md` — SQL Server tag map, survey vars, AWX template patterns
- `docs/postgres_runbook.md` — PostgreSQL tag map, survey vars, AWX template patterns
- `docs/awx_surveys.md` — master matrix of playbook → survey file → tag mappings

### Lab infrastructure

All VMs run inside a **Proxmox** hypervisor (192.168.137.145) which itself runs on VMware Workstation on the local machine. If VMs are unreachable, start VMware Workstation and boot the Proxmox VM first.

**VM credentials (all nodes):** user `user_aap`, password `$RFVbgt5`. Firewall disabled, SSH pre-configured. The `ansible.cfg` remote user (`user_aap`) matches.

**OS templates in Proxmox:**
- `templateRH9` — RHEL 9 base image
- `templateWServer2022` — Windows Server 2022 base image

The AWX automation controller (`awxvm`) lives on the Proxmox cluster and is the entry point for all job template execution. Target hosts are in `inventory/LINUX.yml`.
