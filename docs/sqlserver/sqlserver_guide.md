# Guia SQL Server — Ansible & AWX

Referência completa para instalação e gestão de usuários SQL Server via Ansible e AWX.

> **Para iniciantes:** SQL Server é o banco de dados relacional da Microsoft, que roda em Windows. Este guia explica como instalar e gerenciar usuários automaticamente usando Ansible — sem precisar acessar o servidor manualmente.

Parte do conjunto: [`general_guide.md`](general_guide.md) · [`mysql_guide.md`](mysql_guide.md) · [`postgres_guide.md`](postgres_guide.md) · [`sqlserver_guide.md`](sqlserver_guide.md) · [`oracle_guide.md`](oracle_guide.md)

---

## Como o fluxo funciona (visão geral)

```
AWX Job Template
    └── survey preenchido pelo operador
         └── variáveis flat (sql_login_name, sql_login_password, ...)
              └── role sql_manage_users
                   └── converte vars → lista db_users
                        └── manage_user.yml (executa 1 vez por usuário)
                             ├── Validação de entrada
                             ├── CREATE LOGIN (server-level)
                             ├── CREATE USER (database-level)
                             ├── GRANT/REVOKE database roles
                             ├── IPsec filter (se allowed_ips definido)
                             └── DROP LOGIN (se state=absent)
```

**Importante — dois níveis de acesso:**

No SQL Server, acesso é um processo de **dois níveis**:

```
Nível 1: SERVER LOGIN  → quem pode se conectar ao servidor SQL
    └── Nível 2: DATABASE USER  → quem pode operar dentro de um banco
                 └── DATABASE ROLES  → o que o usuário pode fazer no banco
```

Um login sem database user não consegue fazer nada em um banco. O playbook gerencia os dois níveis automaticamente.

---

## Playbook — deploy_sqlserver.yml

O playbook tem 7 fases, refletindo a complexidade de uma instalação Windows.

```
Phase 1: storage_setup      → tags: storage    → particionar disco, formatar NTFS 64K, ACLs
Phase 2: security_hardening → tags: security   → configurar IPsec via netsh
Phase 3: sql_pre_reqs       → tags: sql_pre    → desabilitar firewall, baixar ISO/SSMS, montar ISO
Phase 4: sql_install        → tags: sql_install → instalação silenciosa + SSMS
Phase 5: sql_post_config    → tags: sql_post   → criar banco inicial, limpeza
Phase 6: sql_manage_users   → tags: sql_users  → criar logins e usuários de banco
Phase 7: db_patches         → tags: db_patches → descoberta de patches (não aplica)
```

### Comandos de execução

```bash
# Instalação completa (todas as 7 fases)
ansible-playbook playbooks/deploy_sqlserver.yml

# Só o storage (preparação de disco)
ansible-playbook playbooks/deploy_sqlserver.yml --tags storage

# Só instalar o SQL Server
ansible-playbook playbooks/deploy_sqlserver.yml --tags sql_install

# Só gerenciar usuários (day-2 operation)
ansible-playbook playbooks/deploy_sqlserver.yml --tags sql_users

# Limitado a um host
ansible-playbook playbooks/deploy_sqlserver.yml -l sqlservervm

# Dry-run
ansible-playbook playbooks/deploy_sqlserver.yml --check
```

---

## Variáveis de Instalação — `roles/sql_post_config/defaults/main.yml`

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `create_initial_db` | bool | `true` | Se `true`, cria um banco inicial após a instalação. |
| `sql_initial_db_name` | string | `sqldb` | Nome do banco criado quando `create_initial_db=true`. |

---

## Variáveis de Gestão de Usuários — `roles/sql_manage_users/defaults/main.yml`

| Variável do Schema | Tipo | Padrão | Obrigatório | Descrição |
|---|---|---|---|---|
| `username` | string | — | **Sim** | Nome do login no SQL Server. |
| `password` | string | `""` | Sim (quando login_type=sql e state=present) | Senha. Não aparece em logs. |
| `login_type` | string | `sql` | **Sim** | `sql` = autenticação SQL (usuário+senha). `windows` = autenticação Windows/AD. |
| `state` | string | `present` | Não | `present` = criar/atualizar. `absent` = remover login. |
| `default_db` | string | `master` | Não | Banco padrão quando o login se conecta sem especificar banco. |
| `databases` | list ou string | `[]` | Não | Bancos onde criar o database user. |
| `db_user` | string | `""` | Não | Nome do database user — se vazio, usa o mesmo nome do login. |
| `roles` | list ou string | `[]` | Não | Roles de banco a conceder (ver tabela abaixo). |
| `revoke` | bool | `false` | Não | Se `true`, revoga as roles em vez de conceder. |
| `manage_db_user` | bool | `true` | Não | Se `true`, cria o database user e gerencia roles. |
| `allowed_ips` | list | `[]` | Não | IPs a adicionar no filtro IPsec para a porta 1433. |

---

## Conceitos Fundamentais do SQL Server

### SQL Login vs Windows Login

| Tipo | Como funciona | Quando usar |
|---|---|---|
| **SQL Login** (`login_type: sql`) | Usuário + senha armazenados no SQL Server. Autenticação mista (Mixed Mode). | Aplicações que não usam Active Directory |
| **Windows Login** (`login_type: windows`) | Usa conta do Windows/Active Directory. Sem senha no banco. | Ambientes corporativos com AD |

```sql
-- SQL Login (criado pelo playbook quando login_type=sql):
CREATE LOGIN [webapp] WITH PASSWORD = '***',
  CHECK_POLICY = ON, DEFAULT_DATABASE = [appdb]

-- Windows Login (criado quando login_type=windows):
CREATE LOGIN [DOMAIN\webapp] FROM WINDOWS WITH DEFAULT_DATABASE = [appdb]
```

### Database Roles do SQL Server

Roles fixas que controlam o que o usuário pode fazer dentro de um banco:

| Role | O que permite |
|---|---|
| `db_owner` | Controle total do banco — equivalente a DBA no banco |
| `db_datareader` | `SELECT` em todas as tabelas e views |
| `db_datawriter` | `INSERT`, `UPDATE`, `DELETE` em todas as tabelas |
| `db_ddladmin` | `CREATE`, `ALTER`, `DROP` de objetos (tabelas, procedures, etc.) |
| `db_securityadmin` | Gerenciar permissões e logins |
| `db_backupoperator` | Executar backups do banco |
| `db_denydatareader` | **NEGA** leitura — tem precedência sobre outras roles |
| `db_denydatawriter` | **NEGA** escrita — tem precedência sobre outras roles |
| `db_accessadmin` | Gerenciar quais logins têm acesso ao banco |
| `db_executor` | Executar stored procedures e functions |

> **Nota:** `db_owner` já inclui todos os outros — não precisa combinar.

### Por que NTFS com cluster de 64 KB?

O SQL Server lê/escreve dados em **páginas de 8 KB** (8 páginas = 1 extent de 64 KB). Quando o cluster NTFS do disco coincide com o extent do SQL Server:
- 1 operação de I/O = 1 extent inteiro
- Sem padding nem operações extras

Com cluster padrão de 4 KB, são 16 operações de disco por extent — muito menos eficiente para bancos de dados.

### Por que IPsec em vez do Windows Firewall?

O role `security_hardening` desabilita o Windows Firewall na Phase 2 (necessário para a instalação silenciosa). IPsec opera em nível inferior ao Firewall — funciona mesmo com o firewall desabilitado. O `allowed_ips` adiciona regras de filtro IPsec para a porta 1433.

### Por que baixar de repositoryvm (192.168.137.148)?

O ambiente de lab não tem internet. O `repositoryvm` é um mirror HTTP interno com todos os binários (ISO SQL Server, SSMS, patches). Todos os downloads apontam para `http://192.168.137.148:8080/`.

---

## Variáveis do Survey AWX — `sql_manage_users`

| Variável AWX | Tipo | Padrão | Obrigatório | Descrição | Exemplo |
|---|---|---|---|---|---|
| `sql_login_name` | text | — | **Sim** | Nome do login no SQL Server. | `webapp` |
| `sql_login_type` | multiplechoice | `sql` | **Sim** | `sql` ou `windows`. | `sql` |
| `sql_login_password` | password | — | Sim (se sql + present) | Senha do login SQL. | `App#Secure2024!` |
| `sql_login_state` | multiplechoice | `present` | **Sim** | `present` ou `absent`. | `present` |
| `sql_login_default_db` | text | `master` | **Sim** | Banco padrão do login. | `appdb` |
| `sql_target_database` | text | — | Não | Banco onde criar o database user. | `appdb` |
| `sql_database_user` | text | — | Não | Nome do DB user (vazio = mesmo nome do login). | `webapp` |
| `sql_database_roles` | textarea | `db_datareader,db_datawriter` | Não | Roles a conceder/revogar (vírgula-separadas). | `db_datareader` |
| `sql_revoke_access` | multiplechoice | `false` | **Sim** | `true` = revoga roles. | `false` |
| `sql_manage_database_user` | multiplechoice | `true` | **Sim** | `true` = gerencia o DB user. | `true` |
| `sql_allowed_ips` | textarea | — | Não | IPs para filtro IPsec porta 1433. | `192.168.1.50` |

---

## Exemplos Práticos

### Exemplo 1: Criar login SQL com acesso read-only

```yaml
sql_login_name: "webapp_reader"
sql_login_type: "sql"
sql_login_password: "Reader#2024!"
sql_login_state: "present"
sql_login_default_db: "appdb"
sql_target_database: "appdb"
sql_database_user: ""
sql_database_roles: "db_datareader"
sql_revoke_access: "false"
sql_manage_database_user: "true"
sql_allowed_ips: "192.168.1.50"
```

**O que o playbook executa:**
```sql
-- Nível 1: Server Login
CREATE LOGIN [webapp_reader] WITH PASSWORD = '***',
  CHECK_POLICY = ON, DEFAULT_DATABASE = [appdb]

-- Nível 2: Database User (dentro do banco appdb)
USE [appdb]
CREATE USER [webapp_reader] FOR LOGIN [webapp_reader]
ALTER ROLE [db_datareader] ADD MEMBER [webapp_reader]
```

---

### Exemplo 2: Criar login com escrita completa

```yaml
sql_login_name: "webapp"
sql_login_type: "sql"
sql_login_password: "App#Secure2024!"
sql_login_state: "present"
sql_login_default_db: "appdb"
sql_target_database: "appdb"
sql_database_user: ""
sql_database_roles: "db_datareader,db_datawriter"
sql_revoke_access: "false"
sql_manage_database_user: "true"
sql_allowed_ips: ""
```

---

### Exemplo 3: Login Windows (Active Directory)

```yaml
sql_login_name: "DOMAIN\\webapp"
sql_login_type: "windows"
sql_login_password: ""
sql_login_state: "present"
sql_login_default_db: "appdb"
sql_target_database: "appdb"
sql_database_user: ""
sql_database_roles: "db_datareader,db_datawriter"
sql_revoke_access: "false"
sql_manage_database_user: "true"
sql_allowed_ips: ""
```

```sql
-- Gerado pelo playbook:
CREATE LOGIN [DOMAIN\webapp] FROM WINDOWS WITH DEFAULT_DATABASE = [appdb]
```

---

### Exemplo 4: DBA com controle total de banco

```yaml
sql_login_name: "dbadmin"
sql_login_type: "sql"
sql_login_password: "DBA#Admin2024!"
sql_login_state: "present"
sql_login_default_db: "master"
sql_target_database: "appdb"
sql_database_user: ""
sql_database_roles: "db_owner"
sql_revoke_access: "false"
sql_manage_database_user: "true"
sql_allowed_ips: "192.168.137.1"
```

---

### Exemplo 5: Revogar roles sem remover login

```yaml
sql_login_name: "webapp"
sql_login_type: "sql"
sql_login_password: ""
sql_login_state: "present"
sql_login_default_db: "appdb"
sql_target_database: "appdb"
sql_database_user: ""
sql_database_roles: "db_datawriter"
sql_revoke_access: "true"
sql_manage_database_user: "true"
sql_allowed_ips: ""
```

```sql
-- Gerado:
ALTER ROLE [db_datawriter] DROP MEMBER [webapp]
```

---

### Exemplo 6: Remover login completamente

```yaml
sql_login_name: "webapp"
sql_login_type: "sql"
sql_login_password: ""
sql_login_state: "absent"
sql_login_default_db: "master"
sql_target_database: ""
sql_database_user: ""
sql_database_roles: ""
sql_revoke_access: "false"
sql_manage_database_user: "false"
sql_allowed_ips: ""
```

---

## Módulos Windows Utilizados

| Módulo | Uso |
|---|---|
| `win_get_url` | Download do ISO SQL Server (~5 GB) e SSMS do repositoryvm |
| `win_disk_image` | Montar/desmontar ISO após download |
| `win_partition` | Criar partição no disco de dados (drive E:) |
| `win_format` | Formatar NTFS com `allocation_unit_size: 65536` (64 KB) |
| `win_acl` | Conceder Full Control para Network Service (SID `S-1-5-20`) |
| `win_package` | Instalação silenciosa com arquivo de configuração |
| `win_shell` | PowerShell para sqlcmd, IPsec netsh, disco |
| `win_firewall` | Desabilitar Windows Firewall (Phase 3) |

```yaml
# Formatar disco E: com NTFS 64KB:
community.windows.win_format:
  drive_letter: E
  file_system: ntfs
  new_label: SQL_DATA
  allocation_unit_size: 65536

# ACL usando SID (independente do idioma do Windows):
ansible.windows.win_acl:
  path: E:\SQLServer_Root
  user: S-1-5-20     # SID do Network Service — PT-BR seria "Serviço de Rede"
  rights: FullControl
  type: allow
  inherit: ContainerInherit,ObjectInherit

# Criar login SQL via sqlcmd:
ansible.windows.win_shell: |
  $sqlcmd = (Get-ChildItem "C:\Program Files\Microsoft SQL Server" -Recurse -Filter "sqlcmd.exe").FullName | Select-Object -First 1
  & $sqlcmd -S localhost -Q "
    IF NOT EXISTS (SELECT name FROM sys.server_principals WHERE name = '{{ login_name }}')
    CREATE LOGIN [{{ login_name }}] WITH PASSWORD = '***', CHECK_POLICY = ON"
no_log: true
```

---

## Tags Disponíveis

| Tag | O que executa |
|---|---|
| `storage` | Preparação de disco (Phase 1) |
| `security` | Configuração IPsec (Phase 2) |
| `sql_pre` | Pré-requisitos Windows (Phase 3) |
| `sql_install` | Instalação do SQL Server (Phase 4) |
| `sql_post` | Configuração pós-instalação (Phase 5) |
| `sql_users` | Todo o ciclo de gestão de usuários (Phase 6) |
| `sql_users_validate` | Validação das variáveis |
| `sql_login` | Criação/atualização do server login |
| `sql_db_user` | Criação do database user |
| `sql_grants` | Concessão de database roles |
| `sql_revoke` | Revogação de database roles |
| `sql_ipsec` | Adição de regras IPsec |
| `sql_remove_user` | Remoção do login (DROP LOGIN) |
| `db_patches` | Descoberta de patches |

---

## Troubleshooting

### Instalação SQL Server falha com "ISO não encontrado"

**Causa:** ISO não disponível em `repositoryvm` (192.168.137.148) ou repositoryvm está offline.

**Verificar:**
```bash
ping 192.168.137.148
curl http://192.168.137.148:8080/
```

---

### `sqlcmd` não encontrado após instalação

**Causa:** Instalação falhou silenciosamente ou caminho diferente.

**Verificar no servidor Windows:**
```powershell
Get-ChildItem "C:\Program Files\Microsoft SQL Server" -Recurse -Filter "sqlcmd.exe" | Select-Object FullName
```

---

### Login criado mas não consegue conectar

**Causa 1:** Autenticação mista (Mixed Mode) não habilitada.
```sql
-- Verificar no SQL Server:
SELECT SERVERPROPERTY('IsIntegratedSecurityOnly')
-- 0 = Mixed Mode habilitado (correto)
-- 1 = Somente Windows (SQL login não funciona)
```

**Causa 2:** Database user não criado no banco alvo.
```sql
USE appdb
SELECT name FROM sys.database_principals WHERE type = 'S'
```

---

## Ver Também

- [`sqlserver_runbook.md`](sqlserver_runbook.md) — Guia operacional para rodar jobs no AWX
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
- [`general_guide.md`](general_guide.md) — Arquitetura geral do projeto
