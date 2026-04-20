# AWX Surveys — Matriz de Templates e Variáveis

Referência central: qual playbook, tags e arquivo de survey usar para cada operação.

> **Como funciona:** No AWX, cada Job Template pode ter um Survey associado — um formulário com campos que o operador preenche antes de executar o job. As respostas viram variáveis Ansible automaticamente.

---

## Mapeamento Rápido: Job Template → Survey

| Job Template | Playbook | Tag | Survey |
|---|---|---|---|
| `MYSQL \| Deploy Base` | `deploy_mysql.yml` | *(vazio)* | Não obrigatório |
| `MYSQL \| Manage Users` | `manage_mysql_users.yml` | `mysql_users` | `awx_survey_mysql_manage_users.json` |
| `POSTGRES \| Deploy Base` | `deploy_postgres.yml` | *(vazio)* | Não obrigatório |
| `POSTGRES \| Manage Users` | `manage_postgres_users.yml` | `postgres_users` | `awx_survey_postgres_manage_users.json` |
| `SQLSERVER \| Deploy Base` | `deploy_sqlserver.yml` | *(vazio)* | Não obrigatório |
| `SQLSERVER \| Manage Users` | `manage_sqlserver_users.yml` | `sql_users` | `awx_survey_sqlserver_manage_users.json` |
| `ORACLE \| Deploy` | `deploy_oracle.yml` | *(vazio — all phases)* | `awx_survey_oracle_install.json` |
| `ORACLE \| Manage Users` | `manage_oracle_users.yml` | `oracle_users` | `awx_survey_oracle_manage_users.json` |
| `DB \| Patch Discovery` | qualquer engine | `db_patches` | *(vars manuais)* |

---

## Como Associar Survey a um Job Template no AWX

1. AWX → **Templates** → selecionar o Job Template
2. Aba **Survey** → Enable Survey → Add
3. Ou importar via API: clicar em "Preview" → copiar JSON do survey

---

## Survey: MySQL — Manage Users

Arquivo: `playbooks/awx_survey_mysql_manage_users.json`

| Campo | Variável | Tipo | Padrão | Obrigatório | Descrição |
|---|---|---|---|---|---|
| MySQL username | `db_username` | text | — | **Sim** | Nome do usuário MySQL a gerenciar |
| Host de acesso | `db_user_host` | text | `%` | Não | Host de onde o usuário conecta. `%` = qualquer IP |
| Password | `db_password` | password | — | Não | Senha (omitir = não altera senha existente) |
| User state | `db_user_state` | multiplechoice | `present` | **Sim** | `present` = criar/atualizar; `absent` = remover |
| Privileges | `db_privileges` | text | `SELECT` | **Sim** | Privilégios MySQL (ex: `SELECT,INSERT,UPDATE`) |
| Target databases | `db_target_databases` | textarea | `appdb` | Não | Bancos alvo, separados por vírgula |
| Revoke access | `db_revoke_access` | multiplechoice | `false` | **Sim** | `true` = revogar ao invés de conceder |
| Append privileges | `db_append_privileges` | multiplechoice | `true` | **Sim** | `true` = adicionar sem substituir grants existentes |
| Create databases | `db_manage_databases` | multiplechoice | `false` | **Sim** | `true` = criar bancos antes de conceder acesso |

**Extra var obrigatória no Job Template:**
```yaml
mysql_manage_users_enabled: true
```

---

## Survey: PostgreSQL — Manage Users

Arquivo: `playbooks/awx_survey_postgres_manage_users.json`

| Campo | Variável | Tipo | Padrão | Obrigatório | Descrição |
|---|---|---|---|---|---|
| PostgreSQL username | `pg_username` | text | — | **Sim** | Nome da role PostgreSQL |
| Password | `pg_user_password` | password | — | Não | Senha da role (obrigatório quando state=present) |
| User state | `pg_user_state` | multiplechoice | `present` | **Sim** | `present` ou `absent` |
| Role attribute flags | `pg_role_attr_flags` | text | `LOGIN` | **Sim** | Atributos da role. Aceita vírgulas: `LOGIN,SUPERUSER,CREATEDB` |
| Privileges | `pg_privileges` | text | `CONNECT` | **Sim** | Privilégios de banco: `CONNECT`, `TEMP`, `CREATE` |
| Target databases | `pg_target_databases` | textarea | `appdb` | Não | Bancos alvo, separados por vírgula |
| Revoke access | `pg_revoke_access` | multiplechoice | `false` | **Sim** | `true` = revogar privileges |
| Create databases | `pg_manage_databases` | multiplechoice | `false` | **Sim** | `true` = criar bancos |
| **Predefined roles** | `pg_predefined_roles` | text | — | Não | Roles predefinidas a conceder: `pg_read_all_data,pg_write_all_data` |
| Allowed IPs | `pg_allowed_ips` | textarea | — | Não | IPs para pg_hba.conf, separados por vírgula |

> **Diferença pg_privileges vs pg_predefined_roles:**
> - `pg_privileges`: controla acesso ao banco (`GRANT CONNECT ON DATABASE x TO user`)
> - `pg_predefined_roles`: concede roles do sistema (`GRANT pg_read_all_data TO user`) — acesso a tabelas sem grants granulares

**Extra var obrigatória:**
```yaml
postgres_manage_users_enabled: true
```

---

## Survey: SQL Server — Manage Users

Arquivo: `playbooks/awx_survey_sqlserver_manage_users.json`

| Campo | Variável | Tipo | Padrão | Obrigatório | Descrição |
|---|---|---|---|---|---|
| Login name | `sql_login_name` | text | — | **Sim** | Nome do server login |
| Login type | `sql_login_type` | multiplechoice | `sql` | **Sim** | `sql` = senha; `windows` = Active Directory |
| Password | `sql_login_password` | password | — | Não | Obrigatório quando login_type=sql e state=present |
| Login state | `sql_login_state` | multiplechoice | `present` | **Sim** | `present` ou `absent` |
| Default database | `sql_login_default_db` | text | `master` | **Sim** | Banco padrão do login |
| Target database | `sql_target_database` | text | — | Não | Banco para criar DB user e gerenciar roles |
| Database user | `sql_database_user` | text | — | Não | Nome do DB user (vazio = mesmo nome do login) |
| Database roles | `sql_database_roles` | textarea | `db_datareader,db_datawriter` | Não | Roles de banco a conceder (vírgula-separadas) |
| Revoke access | `sql_revoke_access` | multiplechoice | `false` | **Sim** | `true` = revogar roles |
| Manage DB user | `sql_manage_database_user` | multiplechoice | `true` | **Sim** | `true` = gerenciar database user |
| Allowed IPs | `sql_allowed_ips` | textarea | — | Não | IPs para filtro IPsec porta 1433 |

**Extra var obrigatória:**
```yaml
sql_manage_users_enabled: true
```

---

## Survey: Oracle — Install

Arquivo: `playbooks/awx_survey_oracle_install.json`

| Campo | Variável | Tipo | Padrão | Obrigatório | Descrição |
|---|---|---|---|---|---|
| Oracle SID | `oracle_sid` | text | `TSTOR` | **Sim** | Identificador do banco |
| SYS password | `oracle_sys_password` | password | — | **Sim** | Senha do superusuário SYS |
| SYSTEM password | `oracle_system_password` | password | — | **Sim** | Senha do usuário SYSTEM |
| SGA target | `oracle_sga_target` | text | `2G` | **Sim** | Tamanho da SGA (ex: `2G`, `4G`, `1024M`) |
| PGA target | `oracle_pga_target` | text | `512m` | **Sim** | Memória por sessão |
| HugePages count | `oracle_hugepages` | text | `0` | Não | `0` = calcular automaticamente |
| Create DB | `create_initial_db` | multiplechoice | `true` | **Sim** | `true` = criar banco após instalar software |

---

## Survey: Oracle — Manage Users

Arquivo: `playbooks/awx_survey_oracle_manage_users.json`

| Campo | Variável | Tipo | Padrão | Obrigatório | Descrição |
|---|---|---|---|---|---|
| Oracle username | `oracle_username` | text | — | **Sim** | Nome do usuário Oracle (convencão: MAIÚSCULAS) |
| Oracle password | `oracle_password` | password | — | Não | Senha (obrigatório quando state=present) |
| User state | `oracle_user_state` | multiplechoice | `present` | **Sim** | `present` ou `absent` |
| Privileges | `oracle_privileges` | text | `CONNECT,RESOURCE` | Não | System privileges separados por vírgula |
| Roles | `oracle_roles` | text | — | Não | Oracle roles separadas por vírgula (ex: `DBA`) |
| Revoke access | `oracle_revoke_access` | multiplechoice | `false` | **Sim** | `true` = revogar privileges |
| Default tablespace | `oracle_default_tablespace` | text | `USERS` | Não | Tablespace padrão |
| Temp tablespace | `oracle_temp_tablespace` | text | `TEMP` | Não | Tablespace temporária |
| Allowed IPs | `oracle_allowed_ips` | textarea | — | Não | IPs para sqlnet.ora TCP.INVITED_NODES |

**Extra var obrigatória:**
```yaml
oracle_manage_users_enabled: true
```

---

## Survey: Patch Discovery (todos os engines)

Não tem arquivo JSON dedicado — variáveis passadas como Extra Vars no Job Template.

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `db_patches_enabled` | bool | `false` | Ativar a fase de patches |
| `db_patches_root` | string | `/opt/patches` | Diretório raiz dos patches no AWX VM |
| `db_patch_apply_enabled` | bool | `false` | **Manter sempre false** — aplicação de patch bloqueada por design |

> **Por que patch apply é sempre false?** Patches de banco requerem janela de manutenção, backup verificado e plano de rollback aprovado. A automação descobre patches disponíveis — a aplicação exige revisão humana.

---

## Notas para Operadores

- Templates de usuários sempre precisam da extra var `*_manage_users_enabled: true`
- Para gestão de usuários, usar os playbooks `manage_*_users.yml` (não os `deploy_*.yml`)
- O `limit` deve sempre apontar para o host correto (ex: `postgresvm`, `mysqlvm`)
- Surveys substituem vars flat → roles convertem internamente para lista `db_users`

---

## Requisitos Offline

Todos os artefatos devem estar disponíveis localmente — este ambiente não tem internet durante execução:

1. **Coleções Ansible** em `/opt/collections/ansible_collections/`
2. **Pacotes RPM** via `repositoryvm` (192.168.137.148:8080)
3. **Binários Oracle** em `/opt/oracle/` no AWX VM
4. **Imagem EE** do AWX carregada localmente no Podman

Ver [`offline_requirements.md`](offline_requirements.md) para o passo a passo completo.
