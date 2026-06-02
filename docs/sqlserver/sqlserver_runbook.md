# SQL Server — AWX Operational Runbook

Reference for SQL Server deploy and user management via AWX Job Templates.

---

## Deploy Prerequisites

Before running the SQL Server deploy job template (JT 10 — "SQL Server - DB Provisioning"):

### 1. Windows VM Requirements

| Requirement | Detail |
|---|---|
| OS | Windows Server 2022 |
| RAM | ≥4 GB (2 GB minimum, 4+ recommended for SQL Server) |
| Disk 0 | System drive (C:) |
| Disk 1 | Raw/uninitialized disk (≥100 GB) — role formats as E: |
| SSH | OpenSSH Server installed and running |
| User | `user_aap` with password `$RFVbgt5` and administrator rights |
| Firewall | SSH port 22 allowed (or Windows Firewall disabled) |

### 2. Repository Server Requirements

The deploy downloads SQL Server ISO and SSMS from an internal HTTP server.

| File | Path on Repo Server |
|---|---|
| SQL Server 2025 ISO | `/sqlserver/SQLServer2025-x64-ENU.iso` |
| SSMS Installer | `/sqlserver/SSMS-Setup-ENU.exe` |

Default repo URL: `http://192.168.137.148:8080` (repositoryvm).
Override via survey var `sql_repo_base_url` for production.

> **Lab note:** The Proxmox `repositoryvm` (192.168.137.148) runs a Python HTTP server on port 8080.
> Start it with: `cd /opt && python3 -m http.server 8080`

### 3. AWX Inventory

`sqlservervm` must be defined in the Windows inventory (AWX inventory ID 2) with:
```yaml
ansible_host: 192.168.137.157
ansible_connection: ssh
ansible_shell_type: powershell
ansible_user: user_aap
win_disk_number: 1          # REQUIRED: disk index for data volume (usually 1)
```

---

## Deploy Job Template (JT 10)

| Field | Value |
|---|---|
| **Name** | `SQL Server - DB Provisioning` |
| **Playbook** | `playbooks/deploy_sqlserver.yml` |
| **Inventory** | `SQL Server` (inventory ID 2) |
| **Credentials** | `user_aap` (password auth) |
| **Limit** | `sqlservervm` |

### Survey Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `sql_sa_password` | No | — | SA account password |
| `win_disk_number` | No | — | Disk index for E: drive (integer, typically 1) |
| `sql_login_name` | Yes | — | Login to create/manage |
| `sql_login_type` | Yes | `sql` | Login type: `sql` or `windows` |
| `sql_login_password` | Yes | — | Login password |
| `sql_login_state` | Yes | `present` | `present` or `absent` |
| `sql_login_default_db` | Yes | `master` | Default database |
| `sql_target_database` | Yes | — | Database for user mapping |
| `sql_revoke_access` | Yes | `false` | Revoke roles if true |
| `sql_manage_database_user` | Yes | `true` | Create DB user mapping |
| `db_patches_enabled` | Yes | `false` | Run patch discovery |

### Deploy Phases (Tags)

| Tag | Phase | Description |
|---|---|---|
| `storage` | Phase 1 | Initialize disk, create E: partition (NTFS 64K, SQL_DATA label) via diskpart |
| `security` | Phase 2 | Windows Firewall + IPsec rules |
| `sql_pre` | Phase 3 | Download ISO/SSMS from repo, mount ISO — REQUIRED before sql_install |
| `sql_install` | Phase 4 | Silent SQL Server 2025 install from ISO, SSMS install |
| `sql_post` | Phase 5 | Enable mixed auth, create initial database (sqldb), cleanup |
| `sql_users` | Phase 6 | User management (optional) |
| `db_patches` | Phase 7 | Patch discovery (never auto-applies) |

**Full deploy:** `job_tags: storage,sql_pre,sql_install,sql_post`

**Post-config only (SQL Server already installed):** `job_tags: sql_post`

> **Note:** `sql_pre` must always be included with `sql_install` — it mounts the ISO and registers `disk_iso_mount` variable used by the install task.

### Required API Launch Parameters

```json
{
  "job_tags": "storage,sql_pre,sql_install,sql_post",
  "limit": "sqlservervm",
  "extra_vars": {
    "sql_sa_password": "SqlAdmin@2025!",
    "sql_login_name": "sa_deploy",
    "sql_login_type": "sql",
    "sql_login_password": "Deploy@1234!",
    "sql_login_state": "present",
    "sql_login_default_db": "master",
    "sql_target_database": "master",
    "sql_revoke_access": "false",
    "sql_manage_database_user": "false",
    "db_patches_enabled": "false",
    "sql_manage_users_enabled": "false"
  }
}
```

---

## Known Issues & Troubleshooting

### Windows SSH Instability

**Symptom:** `Connection timed out during banner exchange`

**Cause:** Windows OpenSSH service crashes or becomes unresponsive. More common with 2GB RAM.

**Fix:**
```bash
# Restart VM via Proxmox (clean shutdown + start):
ssh root@192.168.137.145 "qm stop 103 --timeout 60 && qm start 103"
# Wait ~2min for Windows boot, then retry the AWX job
```

**Production recommendation:** Increase VM RAM to ≥4 GB. Consider WinRM instead of SSH.

---

### E: Drive Letter Stolen by Virtual CD-ROM

**Symptom:** `Cannot find drive. A drive with the name 'E' does not exist.` in pre-req folder creation.

**Root cause (multi-layer):**

1. **Ansible module context vs shell context**: `win_shell` tasks run in interactive SSH session. Ansible modules (`win_file`, `win_get_url`, `win_acl`) run in a NonInteractive PowerShell process. Drive letters set via `Add-PartitionAccessPath` in the interactive session are NOT visible to the NonInteractive module runner.

2. **CD-ROM PnP re-detection**: Even after `Disable-PnpDevice`, Windows PnP re-enables the virtual CD-ROM between Ansible task executions and reassigns E: from MountedDevices registry.

**Fix applied (June 2026):**
- All drive letter assignments now use `diskpart` which writes directly to the Windows storage stack — visible to ALL process contexts immediately.
- `storage_setup` role uses `diskpart assign letter=E` with partition number.
- `sql_pre_reqs` role has a guard task that repeats CD-ROM removal and E: re-assignment at start.
- ISO was ejected from Proxmox VM config (`qm set 103 --ide1 none,media=cdrom`) to prevent CD-ROM from being re-registered.

**diskpart approach:**
```powershell
$diskNum = 1
$partNum = (Get-Partition -DiskNumber $diskNum | Where-Object {$_.Type -eq "Basic"}).PartitionNumber
$null = & mountvol E: /D 2>&1     # remove any current E: assignment
"select disk $diskNum`r`nselect partition $partNum`r`nassign letter=E`r`nexit" | diskpart
```

---

### Ansible Parse Error in win_shell Block

**Symptom:** `ERROR! failed at splitting arguments, either an unbalanced jinja2 block or quotes`

**Root cause:** Several PowerShell patterns inside `win_shell: |` YAML block scalars confuse Ansible 2.15's argument tokenizer:
- Backslash before closing quote: `"E:\"` or `'E:\'`
- Multi-line PowerShell pipelines with `|` at end of line
- Single-quoted PS strings like `'SQL_DATA'` combined with `{{ }}` Jinja2 in same script

**Fix applied (June 2026):**
- All `E:\` path strings use `[char]92` concatenation: `"E:" + [string][char]92`
- Multi-line pipelines collapsed to single lines
- All single-quoted PS strings (`'NTFS'`, `'SQL_DATA'`, `'Basic'`) converted to double-quoted
- Em dash comments removed from script bodies

---

### SQL Server Install Task Skipped (no tags)

**Symptom:** `sqlcmd.exe` not found after install phase; install task not visible in job output.

**Root cause:** `sql_install/tasks/main.yml` task "Instalacao silenciosa do SQL Server 2025" had no `tags:` directive. When running with `--tags sql_install`, tasks without tags are skipped.

**Fix applied (June 2026):** Added `tags: [sql_install, sql_execute]` to the SQL Server install task.

---

### `disk_iso_mount` Undefined in sql_install

**Symptom:** `'disk_iso_mount' is undefined` when running `sql_install` tag without `sql_pre`.

**Root cause:** `disk_iso_mount` is registered in `sql_pre_reqs` task "monta imagem". If `sql_pre` is not included in job tags, this variable is never set.

**Fix:** Always include `sql_pre` in job tags when running `sql_install`:
```
job_tags: sql_pre,sql_install,sql_post
```

---

### ISO Already Mounted Error

**Symptom:** `Unable to retrieve drive letter from mounted image` on remount.

**Root cause:** `community.windows.win_disk_image state: present` fails when the ISO is already mounted from a previous failed run (it cannot return the drive letter of an already-attached image).

**Fix applied (June 2026):** Added `state: absent` (unmount) task before the mount task. The unmount uses `ignore_errors: true` so it succeeds even if the ISO is not mounted.

---

### Recursive Template Error on create_initial_db

**Symptom:** `recursive loop detected in template string: {{ create_initial_db | default(true) | bool }}`

**Root cause:** `deploy_sqlserver.yml` FASE 5 had `vars: create_initial_db: "{{ create_initial_db | default(true) | bool }}"` — self-referential template causes Ansible 2.15 infinite recursion.

**Fix applied (June 2026):** Removed the `vars:` block. Role `defaults/main.yml` already has `create_initial_db: true`.

---

### ISO Not Found

**Symptom:** `win_get_url` fails downloading ISO.

**Check:**
```bash
curl -s http://192.168.137.148:8080/sqlserver/
# Should list SQLServer2025-x64-ENU.iso and SSMS-Setup-ENU.exe
```

If empty: start the HTTP server on repositoryvm and ensure files are at `/opt/sqlserver/`.

---

## User Management Job Template

| Campo AWX | Valor |
|---|---|
| **Name** | `SQLSERVER \| Manage Users` |
| **Playbook** | `playbooks/manage_sqlserver_users.yml` |
| **Inventory** | `SQL Server` |
| **Credentials** | `user_aap` |
| **Extra Variables** | `sql_manage_users_enabled: true` |

---

## Tag Map (User Management)

| Tag | O que executa |
|---|---|
| `sql_users` | Ciclo completo de gestão de usuários |
| `sql_users_validate` | Validação de variáveis |
| `sql_login` | Criação/atualização do server login |
| `sql_db_user` | Criação do database user |
| `sql_grants` | Concessão de database roles |
| `sql_revoke` | Revogação de database roles |
| `sql_ipsec` | Adição de filtros IPsec |
| `sql_remove_user` | Remoção do login |
| `db_patches` | Descoberta de patches |

---

## Job Template AWX — Configuração

| Campo AWX | Valor |
|---|---|
| **Name** | `SQLSERVER \| Manage Users` |
| **Playbook** | `playbooks/manage_sqlserver_users.yml` |
| **Inventory** | `LINUX` (ou inventory Windows separado) |
| **Credentials** | `Machine: user_aap` |
| **Extra Variables** | `sql_manage_users_enabled: true` |
| **Survey** | Associar `awx_survey_sqlserver_manage_users.json` |

---

## Tag Map

| Tag | O que executa |
|---|---|
| `storage` | Preparação de disco (Phase 1 — instalação) |
| `security` | Configuração IPsec (Phase 2 — instalação) |
| `sql_pre` | Pré-requisitos (Phase 3 — instalação) |
| `sql_install` | Instalação do motor SQL Server (Phase 4) |
| `sql_post` | Banco inicial pós-instalação (Phase 5) |
| `sql_users` | Ciclo completo de gestão de usuários |
| `sql_users_validate` | Validação de variáveis |
| `sql_login` | Criação/atualização do server login |
| `sql_db_user` | Criação do database user |
| `sql_grants` | Concessão de database roles |
| `sql_revoke` | Revogação de database roles |
| `sql_ipsec` | Adição de filtros IPsec |
| `sql_remove_user` | Remoção do login |
| `db_patches` | Descoberta de patches |

---

## Cenários de Uso

### Cenário 1: Criar login SQL para aplicação (leitura)

| Campo | Valor |
|---|---|
| Login name | `webapp_reader` |
| Login type | `sql` |
| Password | `Reader#2024!` |
| Login state | `present` |
| Default database | `appdb` |
| Target database | `appdb` |
| Database user | *(deixar vazio = mesmo nome)* |
| Database roles | `db_datareader` |
| Revoke access | `false` |
| Manage DB user | `true` |
| Allowed IPs | `192.168.1.50` |

**O que o playbook executa:**
```sql
-- Nível 1: Server Login
CREATE LOGIN [webapp_reader] WITH PASSWORD = '***',
  CHECK_POLICY = ON, DEFAULT_DATABASE = [appdb]

-- Nível 2: Database User
USE [appdb]
CREATE USER [webapp_reader] FOR LOGIN [webapp_reader]
ALTER ROLE [db_datareader] ADD MEMBER [webapp_reader]
```

---

### Cenário 2: Login SQL com leitura + escrita

| Campo | Valor |
|---|---|
| Login name | `webapp` |
| Login type | `sql` |
| Password | `App#Secure2024!` |
| Login state | `present` |
| Default database | `appdb` |
| Target database | `appdb` |
| Database user | *(vazio)* |
| Database roles | `db_datareader,db_datawriter` |
| Revoke access | `false` |
| Manage DB user | `true` |
| Allowed IPs | *(vazio)* |

---

### Cenário 3: Login Windows (Active Directory)

| Campo | Valor |
|---|---|
| Login name | `DOMAIN\webapp` |
| **Login type** | `windows` |
| Password | *(deixar vazio — não usa)* |
| Login state | `present` |
| Default database | `appdb` |
| Target database | `appdb` |
| Database user | *(vazio)* |
| Database roles | `db_datareader` |
| Revoke access | `false` |
| Manage DB user | `true` |
| Allowed IPs | *(vazio)* |

```sql
-- Gerado pelo playbook:
CREATE LOGIN [DOMAIN\webapp] FROM WINDOWS WITH DEFAULT_DATABASE = [appdb]
```

> **Nota:** Para Windows login, o campo password é ignorado. A autenticação é feita pelo Active Directory.

---

### Cenário 4: DBA com controle total

| Campo | Valor |
|---|---|
| Login name | `dbadmin` |
| Login type | `sql` |
| Password | `DBA#Admin2024!` |
| Login state | `present` |
| Default database | `master` |
| Target database | `appdb` |
| Database user | *(vazio)* |
| Database roles | `db_owner` |
| Revoke access | `false` |
| Manage DB user | `true` |
| Allowed IPs | `192.168.137.1` |

> `db_owner` já inclui todos os outros roles — não precisa combinar com datareader/datawriter.

---

### Cenário 5: Revogar roles sem remover login

| Campo | Valor |
|---|---|
| Login name | `webapp` |
| Login type | `sql` |
| Password | *(vazio)* |
| Login state | `present` |
| Target database | `appdb` |
| Database roles | `db_datawriter` |
| **Revoke access** | `true` |
| Manage DB user | `true` |
| Allowed IPs | *(vazio)* |

```sql
-- Gerado:
USE [appdb]
ALTER ROLE [db_datawriter] DROP MEMBER [webapp]
```

---

### Cenário 6: Remover login completamente

| Campo | Valor |
|---|---|
| Login name | `webapp` |
| Login type | `sql` |
| Password | *(qualquer)* |
| **Login state** | `absent` |
| Target database | *(vazio)* |
| Database roles | *(vazio)* |
| Revoke access | `false` |
| Manage DB user | `false` |
| Allowed IPs | *(vazio)* |

```sql
-- Gerado:
USE [appdb]
DROP USER [webapp]    -- remove database user primeiro
DROP LOGIN [webapp]   -- depois remove o server login
```

---

## Checklist de Verificação Pós-Job

```powershell
# Via sqlcmd no servidor Windows:
# Verificar login criado:
sqlcmd -S localhost -Q "SELECT name, type_desc FROM sys.server_principals WHERE name = 'webapp'"

# Verificar database user:
sqlcmd -S localhost -d appdb -Q "SELECT name, type_desc FROM sys.database_principals WHERE name = 'webapp'"

# Verificar roles do usuário:
sqlcmd -S localhost -d appdb -Q "SELECT r.name role, m.name member FROM sys.database_role_members rm JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id WHERE m.name = 'webapp'"
```

---

## Troubleshooting

### Login criado mas não consegue conectar

**Verificar autenticação mista:**
```sql
SELECT SERVERPROPERTY('IsIntegratedSecurityOnly')
-- Retornar 0 = Mixed Mode (correto para SQL logins)
-- Retornar 1 = Windows Only (SQL login não funciona)
```

**Verificar se database user existe:**
```sql
USE appdb
SELECT name FROM sys.database_principals WHERE name = 'webapp'
```

---

### Erro: `Cannot find user in login table`

**Causa:** Tentando criar database user antes do server login.

**O playbook resolve isso automaticamente** — sempre cria o login antes do user.

---

### Filtro IPsec não funciona

**Verificar regras IPsec:**
```cmd
netsh ipsec static show filterlist
```

---

## Ver Também

- [`sqlserver_guide.md`](sqlserver_guide.md) — Documentação técnica completa
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
