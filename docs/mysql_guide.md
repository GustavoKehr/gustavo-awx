# Guia MySQL — Ansible & AWX

Referência completa para instalação, configuração e gestão de usuários MySQL via Ansible e AWX.

> **Para iniciantes:** MySQL é um banco de dados relacional muito usado em aplicações web. Este guia explica como instalar e gerenciar usuários automaticamente usando Ansible — sem precisar digitar comandos no servidor manualmente.

Parte do conjunto: [`general_guide.md`](general_guide.md) · [`mysql_guide.md`](mysql_guide.md) · [`postgres_guide.md`](postgres_guide.md) · [`sqlserver_guide.md`](sqlserver_guide.md) · [`oracle_guide.md`](oracle_guide.md)

---

## Como o fluxo funciona (visão geral)

```
AWX Job Template
    └── survey preenchido pelo operador
         └── variáveis flat (db_username, db_password, ...)
              └── role mysql_manage_users
                   └── converte vars → lista db_users
                        └── manage_user.yml (executa 1 vez por usuário)
                             ├── Validação de entrada
                             ├── Normaliza lista de bancos
                             ├── CREATE DATABASE (opcional)
                             ├── CREATE USER + GRANT (ou UPDATE)
                             ├── REVOKE (se revoke=true)
                             └── DROP USER (se state=absent)
```

---

## Playbook — deploy_mysql.yml

O playbook principal tem 3 fases. Você pode rodar todas juntas ou só uma fase por vez usando tags.

```
Phase 1: mysql_install       → tags: mysql, mysql_install
Phase 2: mysql_manage_users  → tags: mysql, mysql_users  (ativado quando mysql_manage_users_enabled=true)
Phase 3: db_patches          → tags: mysql, db_patches   (ativado quando db_patches_enabled=true)
```

### Comandos de execução

```bash
# Rodar tudo (instalar + usuários + patches)
ansible-playbook playbooks/deploy_mysql.yml

# Só instalar o MySQL
ansible-playbook playbooks/deploy_mysql.yml --tags mysql_install

# Só gerenciar usuários (sem reinstalar)
ansible-playbook playbooks/deploy_mysql.yml --tags mysql_users

# Só descoberta de patches
ansible-playbook playbooks/deploy_mysql.yml --tags db_patches

# Limitado a um host específico
ansible-playbook playbooks/deploy_mysql.yml -l mysqlvm

# Modo dry-run (simula sem executar)
ansible-playbook playbooks/deploy_mysql.yml --check

# Rodar só usuários em um host, dry-run
ansible-playbook playbooks/deploy_mysql.yml --tags mysql_users -l mysqlvm --check
```

---

## Variáveis de Instalação — `roles/mysql_install/defaults/main.yml`

Essas variáveis controlam como o MySQL é instalado e configurado no servidor.

| Variável | Tipo | Padrão | Descrição | Exemplo |
|---|---|---|---|---|
| `mysql_port` | int | `13306` | Porta TCP onde o MySQL escuta. Porta não padrão por design (padrão seria 3306). | `13306` |
| `mysql_bind_address` | string | IP da VM | Endereço IP onde o servidor aceita conexões. Default usa o IP principal da VM via fact. | `192.168.137.160` |
| `mysql_max_connections` | int | `300` | Máximo de conexões simultâneas. | `300` |
| `mysql_innodb_buffer_pool_size` | string | `1G` | Principal cache de dados do InnoDB. Recomendado: 70-80% da RAM em servidores dedicados. | `4G` |
| `mysql_sql_mode` | string | `STRICT_TRANS_TABLES,...` | Modo de validação SQL. Padrão é restritivo — evita inserções silenciosas com dados inválidos. | *(manter padrão)* |
| `mysql_skip_name_resolve` | bool | `true` | Desabilita resolução DNS. Hosts no `mysql.user.host` devem ser IPs ou `%`. | `true` |
| `mysql_local_infile` | int | `0` | Segurança — desabilita `LOAD DATA LOCAL INFILE` (vetor de ataque). | `0` |
| `mysql_symbolic_links` | int | `0` | Segurança — desabilita links simbólicos em tablespaces. | `0` |
| `mysql_root_password` | string | `Admin#!123` | **Alterar em produção** via `host_vars` ou Ansible Vault. | *(use senha forte)* |
| `mysql_remove_anonymous_users` | bool | `true` | Remove usuário anônimo criado por padrão. Vetor de segurança comum. | `true` |
| `mysql_remove_test_database` | bool | `true` | Remove banco `test` criado por padrão. | `true` |
| `mysql_disallow_remote_root` | bool | `true` | Impede root de logar remotamente. | `true` |
| `create_initial_db` | bool | `false` | Se `true`, cria banco inicial após instalação. | `true` |
| `mysql_initial_db_name` | string | `appdb` | Nome do banco criado quando `create_initial_db=true`. | `myapp` |

### Pacotes instalados por sistema operacional

| SO | Pacotes |
|---|---|
| RedHat / RHEL | `mysql-server`, `python3-PyMySQL` |
| Debian / Ubuntu | `mysql-server`, `python3-pymysql` |

> **Por que `python3-PyMySQL`?** Os módulos `community.mysql.*` usam a biblioteca Python PyMySQL para comunicar com o banco. Sem ela, qualquer task Ansible de MySQL falha com erro: `"A MySQL module is required: for Python 2.7 PyMySQL or MySQLdb"`.

### Paths de configuração por SO

| SO | Arquivo de config | Socket |
|---|---|---|
| RedHat | `/etc/my.cnf` | `/var/lib/mysql/mysql.sock` |
| Debian | `/etc/mysql/mysql.conf.d/mysqld.cnf` | `/var/run/mysqld/mysqld.sock` |

---

## Variáveis de Gestão de Usuários — `roles/mysql_manage_users/defaults/main.yml`

Essas variáveis definem os usuários que serão criados/modificados/removidos.

| Variável do Schema | Tipo | Padrão | Obrigatório | Descrição |
|---|---|---|---|---|
| `username` | string | — | **Sim** | Nome do usuário no MySQL. |
| `password` | string | `""` | Não (omitir = sem alteração de senha) | Senha. Nunca aparece em logs. |
| `state` | string | `present` | Não | `present` = criar/atualizar. `absent` = remover. |
| `host` | string | `%` | Não | Host de onde o usuário pode conectar. `%` = qualquer host. |
| `databases` | list ou string | `[]` | Não | Bancos alvo. Lista ou string separada por vírgula. |
| `privileges` | string | `SELECT,INSERT` | Não | Privilégios MySQL (ver seção abaixo). |
| `append_privileges` | bool | `true` | Não | `true` = adiciona sem remover grants existentes. `false` = substitui. |
| `revoke` | bool | `false` | Não | Se `true`, revoga os privilégios em vez de conceder. |
| `manage_databases` | bool | `false` | Não | Se `true`, cria os bancos listados antes de conceder privilégios. |

---

## Conceitos Fundamentais do MySQL

### O campo `host` — de onde o usuário pode conectar

No MySQL, um usuário é identificado por `'username'@'host'`. O mesmo username com hosts diferentes são usuários completamente distintos.

| Valor de `host` | Significado |
|---|---|
| `%` | Qualquer host (sem restrição de IP) |
| `localhost` | Apenas conexões locais (unix socket) |
| `192.168.1.10` | Apenas deste IP específico |
| `192.168.1.%` | Qualquer IP no range 192.168.1.0/24 |

> **Importante:** Com `mysql_skip_name_resolve: true` (padrão neste projeto), use sempre IPs — não nomes de host. O MySQL não resolve DNS e o nome seria tratado como literal.

### Privilégios MySQL — formato `priv`

O parâmetro `privileges` usa o formato de privilégios do MySQL:

```
"SELECT"                            → só leitura
"SELECT,INSERT,UPDATE"              → leitura e escrita
"SELECT,INSERT,UPDATE,DELETE"       → CRUD completo
"ALL"                               → todos os privilégios no banco
"ALL PRIVILEGES"                    → equivalente ao ALL
```

**Como o playbook monta o scope de privilégios:**

```
username: appuser
databases: ["appdb", "logs"]
privileges: "SELECT,INSERT"

→ scope final: "appdb.*:SELECT,INSERT/logs.*:SELECT,INSERT"
```

Isso é passado ao módulo `community.mysql.mysql_user` no parâmetro `priv`.

### append_privileges vs revoke

| Configuração | Comportamento |
|---|---|
| `append_privileges: true, revoke: false` | Adiciona os privilégios sem remover os existentes |
| `append_privileges: false, revoke: false` | **Substitui** todos os grants existentes pelos novos |
| `revoke: true` | Remove os privilégios listados (sem remover o usuário) |

### Hardening automático na instalação

O role `mysql_install` executa segurança equivalente ao `mysql_secure_installation`:

1. Remove usuário anônimo (`''@''`)
2. Remove banco `test`
3. Desabilita login remoto do root
4. Define senha do root

---

## Variáveis do Survey AWX — `mysql_manage_users`

Estas são as variáveis preenchidas no formulário do AWX ao lançar um job.

| Variável AWX | Tipo | Padrão | Obrigatório | Descrição | Exemplo |
|---|---|---|---|---|---|
| `db_username` | text | — | **Sim** | Nome do usuário MySQL. | `appuser` |
| `db_user_host` | text | `%` | Não | Host de acesso. | `%` ou `192.168.1.10` |
| `db_password` | password | — | Não | Senha. Não aparece em logs. | `MinhaSenh@123` |
| `db_user_state` | multiplechoice | `present` | **Sim** | `present` = criar/atualizar. `absent` = remover. | `present` |
| `db_privileges` | text | `SELECT` | **Sim** | Privilégios MySQL. | `SELECT,INSERT,UPDATE` |
| `db_target_databases` | textarea | `appdb` | Não | Bancos alvo, separados por vírgula. | `appdb,logs` |
| `db_revoke_access` | multiplechoice | `false` | **Sim** | `true` = revoga privilégios. | `false` |
| `db_append_privileges` | multiplechoice | `true` | **Sim** | `true` = adiciona sem substituir. | `true` |
| `db_manage_databases` | multiplechoice | `false` | **Sim** | `true` = cria os bancos. | `false` |

---

## Exemplos Práticos

### Exemplo 1: Usuário de aplicação read-only

```yaml
# Variáveis do survey AWX:
db_username: "webapp_reader"
db_user_host: "%"
db_password: "Reader#2024!"
db_user_state: "present"
db_privileges: "SELECT"
db_target_databases: "appdb"
db_revoke_access: "false"
db_append_privileges: "true"
db_manage_databases: "false"
```

**SQL equivalente executado:**
```sql
CREATE USER 'webapp_reader'@'%' IDENTIFIED BY '***';
GRANT SELECT ON appdb.* TO 'webapp_reader'@'%';
FLUSH PRIVILEGES;
```

---

### Exemplo 2: Usuário de aplicação com CRUD completo

```yaml
db_username: "webapp"
db_user_host: "192.168.1.50"
db_password: "App#Secure2024!"
db_user_state: "present"
db_privileges: "SELECT,INSERT,UPDATE,DELETE"
db_target_databases: "appdb"
db_revoke_access: "false"
db_append_privileges: "false"
db_manage_databases: "false"
```

---

### Exemplo 3: DBA com acesso total

```yaml
db_username: "dbadmin"
db_user_host: "192.168.137.1"
db_password: "DBA#Admin2024!"
db_user_state: "present"
db_privileges: "ALL"
db_target_databases: "appdb"
db_revoke_access: "false"
db_append_privileges: "false"
db_manage_databases: "false"
```

---

### Exemplo 4: Criar banco + usuário ao mesmo tempo

```yaml
db_username: "newapp"
db_user_host: "%"
db_password: "NewApp#2024"
db_user_state: "present"
db_privileges: "SELECT,INSERT,UPDATE,DELETE"
db_target_databases: "newappdb"
db_revoke_access: "false"
db_append_privileges: "true"
db_manage_databases: "true"
```

---

### Exemplo 5: Revogar privilégios sem remover usuário

```yaml
db_username: "webapp"
db_user_host: "%"
db_password: ""
db_user_state: "present"
db_privileges: "SELECT,INSERT"
db_target_databases: "appdb"
db_revoke_access: "true"
db_append_privileges: "true"
db_manage_databases: "false"
```

---

### Exemplo 6: Remover usuário completamente

```yaml
db_username: "webapp"
db_user_host: "%"
db_password: ""
db_user_state: "absent"
db_privileges: "SELECT"
db_target_databases: "appdb"
db_revoke_access: "false"
db_append_privileges: "true"
db_manage_databases: "false"
```

---

## Tags Disponíveis

| Tag | O que executa |
|---|---|
| `mysql` | Todas as tasks MySQL |
| `mysql_install` | Fase de instalação completa |
| `mysql_users` | Todo o ciclo de gestão de usuários |
| `mysql_users_validate` | Validação das variáveis de entrada |
| `mysql_db` | Criação dos bancos de dados |
| `mysql_grants` | Concessão de privilégios |
| `mysql_revoke` | Revogação de privilégios |
| `mysql_remove_user` | Remoção do usuário |
| `db_patches` | Descoberta de patches |

---

## Módulos Ansible Utilizados

```yaml
# Criar/atualizar usuário e grants em uma operação
community.mysql.mysql_user:
  login_unix_socket: "{{ mysql_login_unix_socket[ansible_os_family] }}"
  name: "{{ db_user.username }}"
  host: "{{ db_user.host | default('%') }}"
  password: "{{ db_user.password }}"
  priv: "{{ mysql_priv_scope }}"          # "appdb.*:SELECT,INSERT/logs.*:SELECT"
  state: present
  append_privs: "{{ db_user.append_privileges | default(true) | bool }}"
  subtract_privs: "{{ db_user.revoke | default(false) | bool }}"
no_log: true

# Criar banco
community.mysql.mysql_db:
  login_unix_socket: "{{ mysql_login_unix_socket[ansible_os_family] }}"
  name: "{{ item }}"
  state: present

# Remover usuário
community.mysql.mysql_user:
  login_unix_socket: "{{ mysql_login_unix_socket[ansible_os_family] }}"
  name: "{{ db_user.username }}"
  host: "{{ db_user.host | default('%') }}"
  state: absent
```

---

## Troubleshooting

### Erro: `A MySQL module is required: for Python 2.7 PyMySQL or MySQLdb`

**Causa:** Biblioteca Python PyMySQL não instalada.

**Solução:**
```bash
# RedHat/RHEL:
sudo dnf install python3-PyMySQL

# Debian/Ubuntu:
sudo apt install python3-pymysql
```

---

### Erro: `Access denied for user 'root'@'localhost'`

**Causa:** Senha do root incorreta no `mysql_root_password`.

**Solução:** Verificar/atualizar a variável `mysql_root_password` no `host_vars/mysqlvm.yml` ou no Ansible Vault.

---

### Erro: Usuário criado mas não consegue conectar

**Causa comum:** Host do usuário não corresponde ao IP de origem.

**Diagnóstico:**
```bash
# Verificar usuário e host no MySQL:
mysql -u root -p -e "SELECT user, host FROM mysql.user WHERE user='webapp';"

# Testar conexão do IP correto com o usuário correto:
mysql -u webapp -p -h 192.168.137.160 -P 13306 appdb
```

---

### Erro: `Can't connect to MySQL server on '...' (111)`

**Causa:** Porta incorreta ou servidor parado.

**Verificar:**
```bash
# Verificar se o MySQL está rodando:
systemctl status mysqld

# Verificar porta que está escutando:
ss -tlnp | grep 13306
```

---

## Ver Também

- [`mysql_runbook.md`](mysql_runbook.md) — Guia operacional para rodar jobs no AWX
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
- [`general_guide.md`](general_guide.md) — Arquitetura geral do projeto
