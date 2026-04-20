# Guia PostgreSQL — Ansible & AWX

Referência completa para instalação, configuração e gestão de usuários PostgreSQL via Ansible e AWX.

> **Para iniciantes:** PostgreSQL (ou "Postgres") é um banco de dados relacional open-source. Este guia explica como instalar e gerenciar usuários automaticamente usando Ansible — sem precisar digitar comandos no servidor manualmente.

Parte do conjunto: [`general_guide.md`](general_guide.md) · [`mysql_guide.md`](mysql_guide.md) · [`postgres_guide.md`](postgres_guide.md) · [`sqlserver_guide.md`](sqlserver_guide.md) · [`oracle_guide.md`](oracle_guide.md)

---

## Como o fluxo funciona (visão geral)

```
AWX Job Template
    └── survey preenchido pelo operador
         └── variáveis flat (pg_username, pg_user_password, ...)
              └── role postgres_manage_users
                   └── converte vars → lista db_users
                        └── manage_user.yml (executa 1 vez por usuário)
                             ├── CREATE/ALTER ROLE via psql
                             ├── CREATE DATABASE (opcional)
                             ├── GRANT CONNECT
                             ├── GRANT pg_read_all_data (opcional)
                             ├── pg_hba.conf (acesso por IP)
                             └── DROP ROLE (se state=absent)
```

---

## Playbook — deploy_postgres.yml

O playbook principal tem 3 fases. Você pode rodar todas juntas ou só uma fase por vez usando tags.

```
Phase 1: postgres_install       → tags: postgres, postgres_install
Phase 2: postgres_manage_users  → tags: postgres, postgres_users  (ativado quando postgres_manage_users_enabled=true)
Phase 3: db_patches             → tags: postgres, db_patches      (ativado quando db_patches_enabled=true)
```

### Comandos de execução

```bash
# Rodar tudo (instalar + usuários + patches)
ansible-playbook playbooks/deploy_postgres.yml

# Só instalar o PostgreSQL
ansible-playbook playbooks/deploy_postgres.yml --tags postgres_install

# Só gerenciar usuários (sem reinstalar)
ansible-playbook playbooks/deploy_postgres.yml --tags postgres_users

# Só descoberta de patches
ansible-playbook playbooks/deploy_postgres.yml --tags db_patches

# Limitado a um host específico
ansible-playbook playbooks/deploy_postgres.yml -l postgresvm

# Modo dry-run (simula sem executar)
ansible-playbook playbooks/deploy_postgres.yml --check

# Rodar só usuários em um host, dry-run
ansible-playbook playbooks/deploy_postgres.yml --tags postgres_users -l postgresvm --check
```

---

## Variáveis de Instalação — `roles/postgres_install/defaults/main.yml`

Essas variáveis controlam como o PostgreSQL é instalado e configurado no servidor.

| Variável | Tipo | Padrão | Descrição | Exemplo |
|---|---|---|---|---|
| `postgres_port` | int | `15432` | Porta TCP onde o PostgreSQL escuta. Porta não padrão por design (padrão seria 5432). | `15432` |
| `postgres_bind_address` | string | IP da VM | Endereço IP onde o servidor aceita conexões. Default usa o IP principal da VM via fact. | `192.168.137.158` |
| `postgres_max_connections` | int | `300` | Máximo de conexões simultâneas. Cada conexão usa memória. | `300` |
| `postgres_shared_buffers` | string | `512MB` | Memória cache do PostgreSQL. Recomendado: ~25% da RAM total do servidor. | `1GB` |
| `postgres_work_mem` | string | `16MB` | Memória por operação de sort/hash por conexão. Cuidado: multiplica pelo número de conexões paralelas. | `32MB` |
| `postgres_password_encryption` | string | `scram-sha-256` | Algoritmo de hash de senhas. SCRAM é mais seguro que MD5. Não altere em instalações novas. | `scram-sha-256` |
| `postgres_log_connections` | string | `on` | Registra no log toda nova conexão aceita. | `on` |
| `postgres_log_disconnections` | string | `on` | Registra no log todo encerramento de conexão. | `on` |
| `postgres_hba_cidr` | string | `0.0.0.0/0` | CIDR de origem que pode se conectar. Em produção, restringir ao range da aplicação. | `10.0.1.0/24` |
| `postgres_hba_method` | string | `scram-sha-256` | Método de autenticação no pg_hba.conf global. | `scram-sha-256` |
| `create_initial_db` | bool | `false` | Se `true`, cria um banco inicial após a instalação. | `true` |
| `postgres_initial_db_name` | string | `appdb` | Nome do banco criado quando `create_initial_db=true`. | `myapp` |

### Pacotes instalados por sistema operacional

| SO | Pacotes |
|---|---|
| RedHat / RHEL | `postgresql-server`, `postgresql`, `python3-psycopg2` |
| Debian / Ubuntu | `postgresql`, `postgresql-contrib`, `python3-psycopg2` |

> **Por que `python3-psycopg2`?** Os módulos `community.postgresql.*` usam a biblioteca Python psycopg2 para comunicar com o banco. Sem ela, qualquer task Ansible de PostgreSQL falha com erro de dependência.

### Diretórios de configuração por SO

| SO | Diretório |
|---|---|
| RedHat | `/var/lib/pgsql/data/` |
| Debian | `/etc/postgresql/16/main/` |

---

## Variáveis de Gestão de Usuários — `roles/postgres_manage_users/defaults/main.yml`

Essas variáveis definem os usuários que serão criados/modificados/removidos.

| Variável do Schema | Tipo | Padrão | Obrigatório | Descrição |
|---|---|---|---|---|
| `username` | string | — | **Sim** | Nome da role/usuário no PostgreSQL. |
| `password` | string | `""` | Sim (quando state=present) | Senha de login. Nunca aparece em logs (`no_log: true`). |
| `state` | string | `present` | Não | `present` = criar/atualizar. `absent` = remover a role completamente. |
| `databases` | list ou string | `[]` | Não | Bancos onde conceder privilégios. Lista ou string separada por vírgula. |
| `privileges` | string | `CONNECT` | Não | Privilégios a nível de banco (ver seção abaixo). |
| `role_attr_flags` | string | `LOGIN` | Não | Atributos da role (ver seção abaixo). Separados por espaço ou vírgula — vírgulas são convertidas automaticamente. |
| `pg_roles` | string | `""` | Não | Roles predefinidas do PostgreSQL a conceder via `GRANT role TO user` (ver seção abaixo). |
| `revoke` | bool | `false` | Não | Se `true`, revoga os `privileges` em vez de conceder. |
| `manage_databases` | bool | `false` | Não | Se `true`, cria os bancos listados antes de conceder privilégios. |
| `allowed_ips` | list | `[]` | Não | IPs/CIDRs a adicionar no `pg_hba.conf` para este usuário. Append-only (nunca remove). |

---

## Conceitos Fundamentais do PostgreSQL

### Roles vs. Usuários

No PostgreSQL, **usuários e grupos são o mesmo objeto: roles**. A diferença é o atributo `LOGIN`:
- Role com `LOGIN` → pode autenticar (= usuário)
- Role sem `LOGIN` → é um grupo de permissões

```sql
-- Role que pode logar (= usuário)
CREATE ROLE appuser WITH LOGIN PASSWORD 'senha';

-- Role de grupo (não loga, serve para agrupar permissões)
CREATE ROLE readonly;
GRANT readonly TO appuser;
```

### role_attr_flags — Atributos da Role

Controlam o que a role pode fazer além de logar. Passados como string separada por espaço (ou vírgula — convertida automaticamente).

| Atributo | Descrição | Exemplo de uso |
|---|---|---|
| `LOGIN` | Permite autenticação. Obrigatório para usuários. | Qualquer usuário de aplicação |
| `SUPERUSER` | Poder total — ignora todas as restrições. Usar com cautela. | DBA de desenvolvimento |
| `CREATEDB` | Pode criar novos bancos de dados. | Usuário de CI/CD |
| `CREATEROLE` | Pode criar outras roles. | Administrador delegado |
| `REPLICATION` | Pode iniciar replicação (streaming). | Usuário de réplica |
| `BYPASSRLS` | Ignora políticas de Row Level Security. | Usuário de backup/ETL |
| `NOLOGIN` | Explicitamente proíbe login (role de grupo). | Grupos de permissão |

**Exemplo de combinações comuns:**

```
"LOGIN"                           → usuário básico
"LOGIN CREATEDB"                  → usuário que cria bancos
"LOGIN SUPERUSER CREATEDB"        → DBA completo
"NOLOGIN"                         → grupo de permissões
```

> **Atenção:** O PostgreSQL exige atributos separados por **espaço** no SQL. Este projeto aceita vírgulas no survey (`LOGIN,SUPERUSER,CREATEDB`) e converte automaticamente para espaços antes de executar.

### pg_privileges — Privilégios a Nível de Banco

Controlam o que o usuário pode fazer dentro de um banco específico. Diferentes de privilégios de tabela.

| Privilégio | O que permite |
|---|---|
| `CONNECT` | Conectar ao banco. Sem isso, conexão é recusada. |
| `CREATE` | Criar schemas dentro do banco. |
| `TEMP` | Criar tabelas temporárias. |

> **Atenção:** `CONNECT` apenas permite entrar no banco — não lê tabelas. Para ler tabelas, o usuário precisa de `USAGE` no schema e `SELECT` nas tabelas via SQL adicional.

### pg_predefined_roles — Roles Predefinidas (PostgreSQL 14+)

São roles do sistema que o PostgreSQL fornece prontas para casos de uso comuns. **Não são privilégios de banco** — são roles que você concede ao usuário via `GRANT role TO user`.

| Role | O que concede | Caso de uso |
|---|---|---|
| `pg_read_all_data` | SELECT em todas as tabelas, views e sequences de todos os bancos | Usuário de BI/relatórios read-only |
| `pg_write_all_data` | INSERT, UPDATE, DELETE em todas as tabelas de todos os bancos | Usuário de ETL/cargas |
| `pg_monitor` | Acesso a views de monitoramento (pg_stat_*, pg_locks, etc.) | Usuário do Zabbix/Prometheus |
| `pg_signal_backend` | Pode cancelar queries e terminar conexões de outros usuários | DBA auxiliar |
| `pg_read_all_settings` | Ver todos os parâmetros de configuração | Auditoria |
| `pg_read_all_stats` | Ver estatísticas de atividade e I/O | Monitoramento |

**Como usar no survey AWX:**

```
pg_predefined_roles: "pg_read_all_data"                    → read-only em tudo
pg_predefined_roles: "pg_read_all_data,pg_write_all_data"  → leitura e escrita em tudo
pg_predefined_roles: "pg_monitor,pg_read_all_stats"        → monitoramento completo
```

**Diferença entre `pg_privileges` e `pg_predefined_roles`:**

| Campo | SQL gerado | Quando usar |
|---|---|---|
| `pg_privileges: "CONNECT"` | `GRANT CONNECT ON DATABASE barcelona TO appuser;` | Controle de acesso ao banco |
| `pg_predefined_roles: "pg_read_all_data"` | `GRANT pg_read_all_data TO appuser;` | Acesso a tabelas de forma simplificada |

### pg_hba.conf — Controle de Acesso por Host

O `pg_hba.conf` (Host-Based Authentication) define **de onde** cada usuário pode se conectar. O playbook adiciona entradas automaticamente via `allowed_ips`.

```
# Formato de uma linha no pg_hba.conf:
# tipo  banco     usuário   endereço          método
host    barcelona  appuser   192.168.1.10/32   scram-sha-256
host    all        dbadmin   10.0.0.0/24       scram-sha-256
```

- Entradas são **append-only** — o playbook nunca remove linhas existentes
- IPs sem máscara de rede recebem `/32` automaticamente (ex: `192.168.1.10` → `192.168.1.10/32`)
- Após adicionar entradas, o PostgreSQL recebe `reload` automático (sem reiniciar o serviço)

### Por que usamos `psql` shell em vez do módulo `postgresql_user`?

O módulo `community.postgresql.postgresql_user` conecta via TCP (127.0.0.1) por padrão. Neste ambiente, o PostgreSQL escuta na porta `15432` no IP da VM — não em `127.0.0.1`. O módulo falha ao tentar conectar.

A solução: usar `ansible.builtin.shell` com `psql` diretamente, com `become_user: postgres`. O usuário `postgres` do SO tem **peer authentication** via unix socket — conecta sem senha, independente de onde o processo escuta na rede.

```bash
# Equivalente ao que o Ansible executa internamente:
sudo -u postgres psql -p 15432 -c "CREATE ROLE appuser WITH LOGIN PASSWORD '...'"
```

---

## Variáveis do Survey AWX — `postgres_manage_users`

Estas são as variáveis preenchidas no formulário do AWX ao lançar um job de gestão de usuários.

| Variável AWX | Tipo | Padrão | Obrigatório | Descrição | Exemplo |
|---|---|---|---|---|---|
| `pg_username` | text | — | **Sim** | Nome da role a criar/modificar/remover. | `appuser` |
| `pg_user_password` | password | — | Sim (quando present) | Senha. Não aparece em logs. | `MinhaSenh@123` |
| `pg_user_state` | multiplechoice | `present` | **Sim** | `present` = criar/atualizar. `absent` = remover. | `present` |
| `pg_role_attr_flags` | text | `LOGIN` | **Sim** | Atributos da role. Vírgulas aceitas. | `LOGIN,CREATEDB` |
| `pg_privileges` | text | `CONNECT` | **Sim** | Privilégios de banco. | `CONNECT` |
| `pg_target_databases` | textarea | `appdb` | Não | Bancos alvo, separados por vírgula. | `appdb,logs` |
| `pg_revoke_access` | multiplechoice | `false` | **Sim** | `true` = revoga privilégios em vez de conceder. | `false` |
| `pg_manage_databases` | multiplechoice | `false` | **Sim** | `true` = cria os bancos se não existirem. | `true` |
| `pg_predefined_roles` | text | — | Não | Roles predefinidas a conceder (separadas por vírgula). | `pg_read_all_data` |
| `pg_allowed_ips` | textarea | — | Não | IPs/CIDRs para pg_hba.conf (separados por vírgula). | `192.168.1.10` |

---

## Exemplos Práticos

### Exemplo 1: Usuário de aplicação básico

Usuário `webapp` que conecta ao banco `appdb` de qualquer IP da LAN.

```yaml
# Variáveis do survey AWX:
pg_username: "webapp"
pg_user_password: "App#Secure2024"
pg_user_state: "present"
pg_role_attr_flags: "LOGIN"
pg_privileges: "CONNECT"
pg_target_databases: "appdb"
pg_revoke_access: "false"
pg_manage_databases: "false"
pg_predefined_roles: ""
pg_allowed_ips: "192.168.1.0/24"
```

**O que acontece:**
1. Cria a role `webapp` com atributo `LOGIN` e senha
2. Concede `CONNECT` no banco `appdb`
3. Adiciona linha no `pg_hba.conf` para o range `192.168.1.0/24`
4. Recarrega o PostgreSQL

### Exemplo 2: DBA com poderes totais

Usuário `dbadmin` com `SUPERUSER` para administração.

```yaml
pg_username: "dbadmin"
pg_user_password: "DBA#Admin2024!"
pg_user_state: "present"
pg_role_attr_flags: "LOGIN,SUPERUSER,CREATEDB,CREATEROLE"
pg_privileges: "CONNECT"
pg_target_databases: "appdb"
pg_revoke_access: "false"
pg_manage_databases: "false"
pg_predefined_roles: ""
pg_allowed_ips: "192.168.137.1"
```

### Exemplo 3: Usuário read-only para BI via pg_predefined_roles

Usuário `bi_reader` que pode ler todas as tabelas sem permissões granulares.

```yaml
pg_username: "bi_reader"
pg_user_password: "BI#Read2024"
pg_user_state: "present"
pg_role_attr_flags: "LOGIN"
pg_privileges: "CONNECT"
pg_target_databases: "appdb"
pg_revoke_access: "false"
pg_manage_databases: "false"
pg_predefined_roles: "pg_read_all_data"
pg_allowed_ips: "10.0.5.20"
```

**O que acontece além do normal:**
- `GRANT pg_read_all_data TO bi_reader;` — acesso de leitura a todas as tabelas do cluster

### Exemplo 4: Criar banco + usuário juntos

Usuário `newapp` e banco `newappdb` criados simultaneamente.

```yaml
pg_username: "newapp"
pg_user_password: "New#App2024"
pg_user_state: "present"
pg_role_attr_flags: "LOGIN"
pg_privileges: "CONNECT"
pg_target_databases: "newappdb"
pg_revoke_access: "false"
pg_manage_databases: "true"
pg_predefined_roles: ""
pg_allowed_ips: "192.168.1.50"
```

### Exemplo 5: Remover usuário completamente

```yaml
pg_username: "olduser"
pg_user_password: ""
pg_user_state: "absent"
pg_role_attr_flags: "LOGIN"
pg_privileges: "CONNECT"
pg_target_databases: "appdb"
pg_revoke_access: "false"
pg_manage_databases: "false"
pg_predefined_roles: ""
pg_allowed_ips: ""
```

**O que acontece internamente:**
1. `DROP OWNED BY olduser;` — remove todos os privilégios e objetos do usuário
2. `DROP ROLE olduser;` — remove a role

> O `DROP OWNED BY` é obrigatório antes do `DROP ROLE`. Se o usuário tem qualquer privilégio de banco concedido, o PostgreSQL rejeita o `DROP ROLE` com erro: `role "X" cannot be dropped because some objects depend on it`.

---

## Tags Disponíveis

| Tag | O que executa |
|---|---|
| `postgres` | Todas as tasks PostgreSQL |
| `postgres_install` | Fase de instalação completa |
| `postgres_users` | Toda a fase de gestão de usuários |
| `postgres_users_validate` | Validação das variáveis de entrada |
| `postgres_user` | Criação/atualização da role via psql |
| `postgres_db` | Criação dos bancos de dados |
| `postgres_grants` | Concessão de privilégios |
| `postgres_pg_roles` | Concessão de roles predefinidas |
| `postgres_revoke` | Revogação de privilégios |
| `postgres_hba` | Adição de entradas no pg_hba.conf |
| `postgres_remove_user` | Remoção da role (DROP ROLE) |
| `db_patches` | Descoberta de patches |

---

## Módulos Ansible Utilizados

```yaml
# Configurar parâmetros em postgresql.conf
community.postgresql.postgresql_set:
  name: shared_buffers
  value: "512MB"
become_user: postgres

# Editar pg_hba.conf (autenticação por host)
community.postgresql.postgresql_pg_hba:
  dest: /var/lib/pgsql/data/pg_hba.conf
  contype: host
  databases: "appdb"
  users: "appuser"
  source: "192.168.1.0/24"       # SEMPRE com máscara CIDR
  method: scram-sha-256
  state: present
become_user: postgres
# NOTA: este módulo edita o arquivo como texto — NÃO aceita parâmetros de conexão ao banco

# Criar/alterar role via psql (método usado neste projeto)
ansible.builtin.shell: |
  psql -p {{ postgres_port }} -v ON_ERROR_STOP=1 -c "
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'appuser') THEN
      EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L', 'appuser', 'senha');
    ELSE
      EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', 'appuser', 'senha');
    END IF;
  END;
  \$\$;"
become: true
become_user: postgres
no_log: true

# Criar banco de dados
community.postgresql.postgresql_db:
  name: "appdb"
  login_unix_socket: /var/run/postgresql
  login_port: "{{ postgres_port }}"
  state: present
become: true
become_user: postgres

# Conceder privilégios de banco
community.postgresql.postgresql_privs:
  database: "appdb"
  roles: "appuser"
  type: database
  privs: "CONNECT"
  login_unix_socket: /var/run/postgresql
  login_port: "{{ postgres_port }}"
  state: present
become: true
become_user: postgres
```

---

## Troubleshooting

### Erro: `"censored": "the output has been hidden due to the fact that 'no_log: true' was specified"`

**Causa:** A task de criação/alteração de role falhou, mas `no_log: true` oculta os detalhes para não expor a senha.

**Como investigar:**
1. Verificar no AWX o job que falhou → clique na task → botão "Output"
2. SSH no servidor e testar manualmente:
   ```bash
   sudo -u postgres psql -p 15432 -c "\du"                          # listar roles
   sudo -u postgres psql -p 15432 -c "CREATE ROLE test WITH LOGIN PASSWORD 'Teste#123';"
   ```
3. Verificar se `psycopg2` está instalado: `python3 -c "import psycopg2; print(psycopg2.__version__)"`

---

### Erro: `role "X" cannot be dropped because some objects depend on it`

**Causa:** Tentativa de `DROP ROLE` sem remover privilégios antes.

**Solução:** O playbook já executa `DROP OWNED BY X` antes do `DROP ROLE`. Se o erro ocorrer manualmente:
```sql
GRANT postgres TO postgres;  -- garante que postgres pode fazer DROP OWNED BY
DROP OWNED BY olduser;
DROP ROLE olduser;
```

---

### Erro: `bare ip-address without a CIDR suffix needs a netmask`

**Causa:** IP passado em `pg_allowed_ips` sem máscara de rede (ex: `192.168.1.10` em vez de `192.168.1.10/32`).

**Solução:** O playbook converte automaticamente. Se ocorrer manualmente no pg_hba.conf, adicione `/32` para IPs individuais.

---

### Erro: `FATAL: Peer authentication failed for user "postgres"`

**Causa:** Tentando conectar ao PostgreSQL como usuário diferente de `postgres` via unix socket, sem credencial.

**Solução:** Usar `become_user: postgres` nas tasks, ou adicionar opção `-U postgres` no psql.

---

### Erro: `connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed`

**Causa:** Porta padrão 5432, mas o servidor está na 15432.

**Solução:** Sempre especificar `-p 15432` no psql, ou usar `login_port: "{{ postgres_port }}"` nos módulos.

---

### Erro: `invalid attribute in role option list: "LOGIN,SUPERUSER"`

**Causa:** PostgreSQL não aceita vírgulas em atributos de role no SQL — precisa de espaços.

**Solução:** O playbook já converte automaticamente (filtro `| replace(",", " ")`). Se executar manualmente:
```sql
-- Errado:
CREATE ROLE x WITH LOGIN,SUPERUSER PASSWORD 'y';

-- Correto:
CREATE ROLE x WITH LOGIN SUPERUSER PASSWORD 'y';
```

---

## Ver Também

- [`postgres_runbook.md`](postgres_runbook.md) — Guia operacional para rodar jobs no AWX
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
- [`general_guide.md`](general_guide.md) — Arquitetura geral do projeto
- [`offline_requirements.md`](offline_requirements.md) — Como preparar o ambiente offline
