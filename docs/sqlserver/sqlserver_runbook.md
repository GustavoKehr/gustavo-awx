# SQL Server — Runbook Operacional AWX

Guia prático para executar operações de gestão de usuários SQL Server via AWX Job Templates.

> **Para iniciantes:** Este runbook contém os passos exatos para criar, modificar e remover logins e usuários no SQL Server usando o AWX.

---

## Pré-requisitos

1. **SQL Server instalado** no host Windows alvo
2. **AWX sincronizado** com o repositório GitHub
3. **Credencial Machine** para Windows (WinRM) configurada
4. **Job Template** configurado com survey correto

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
