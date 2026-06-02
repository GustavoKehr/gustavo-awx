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
| `storage` | Phase 1 | Initialize disk, create E: partition (NTFS 64K, SQL_DATA label) |
| `security` | Phase 2 | Windows Firewall + IPsec rules |
| `sql_pre` | Phase 3 | Download ISO/SSMS from repo, mount ISO |
| `sql_install` | Phase 4 | Silent SQL Server install from ISO |
| `sql_post` | Phase 5 | Initial database creation |
| `sql_users` | Phase 6 | User management (optional) |
| `db_patches` | Phase 7 | Patch discovery (never auto-applies) |

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

### E: Partition Already in Use

**Symptom:** `The requested access path is already in use` on partition creation.

**Root cause:** CD-ROM/DVD virtual drive was using drive letter E:.

**Fix applied (June 2026):** `storage_setup` role now detects CD-ROM on E: and reassigns it to X: before creating the data partition. Idempotent on re-runs.

---

### Format Task Fails (win_format module)

**Symptom:** `Unhandled exception: Size Not Supported` on NTFS 64K format.

**Root cause:** `community.windows.win_format` module bug with `allocation_unit_size: 65536`.

**Fix applied (June 2026):** Replaced with `win_shell` PowerShell `Format-Volume`. Idempotent (skips if already labeled SQL_DATA).

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
