# Guia Geral — Ansible & AWX

Visão geral da arquitetura, configuração base e comandos essenciais do projeto.

> **Para iniciantes:** Este guia explica como o projeto funciona como um todo antes de entrar nos detalhes de cada banco de dados.

---

## O que este projeto faz

Automação completa do ciclo de vida de bancos de dados via **AWX** (Red Hat Ansible Automation Platform):

- Instala e configura bancos de dados (MySQL, PostgreSQL, SQL Server, Oracle 19c)
- Gerencia usuários e permissões de banco via formulários AWX
- Aplica hardening de segurança automaticamente
- Descobre patches disponíveis (sem aplicação automática — por segurança)

---

## Arquitetura do Projeto

```
┌─────────────────────────────────────────────────────────────┐
│  Operador                                                   │
│  (preenche survey no AWX)                                   │
└──────────────────┬──────────────────────────────────────────┘
                   │ variáveis do survey
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  AWX (192.168.137.153)                                      │
│  Job Template → Playbook → Role → Tasks                     │
└──────┬──────────────────────┬───────────────────────────────┘
       │ SSH (user_aap)       │
       ▼                      ▼
┌─────────────┐    ┌─────────────────────────────────────────┐
│  mysqlvm    │    │  postgresvm  oraclevm  sqlservervm       │
│  :13306     │    │  :15432      :1521     :1433             │
└─────────────┘    └─────────────────────────────────────────┘
       │
       ▼ (todos rodam em)
┌─────────────────────────────────────────────────────────────┐
│  Proxmox (192.168.137.145) no VMware Workstation local      │
└─────────────────────────────────────────────────────────────┘
```

---

## Hosts do Inventário

Arquivo: `inventory/LINUX.yml`

| Host | IP | Porta do banco | Função |
|---|---|---|---|
| `mysqlvm` | 192.168.137.160 | 13306 (MySQL) | Servidor MySQL |
| `postgresvm` | 192.168.137.158 | 15432 (PostgreSQL) | Servidor PostgreSQL |
| `oraclevm` | 192.168.137.163 | 1521 (Oracle) | Servidor Oracle 19c |
| `awxvm` | 192.168.137.153 | — | Controller AWX (k3s) |
| `repositoryvm` | 192.168.137.148 | 8080 (HTTP) | Mirror de binários |
| `zabbixvm` | 192.168.137.159 | — | Monitoramento Zabbix |
| `proxmox` | 192.168.137.145 | — | Hypervisor |

> **Portas não padrão** (13306, 15432): reduz ruído de scanners automáticos. Não é segurança real, mas complementa firewall e ACLs.

---

## Mapeamento Playbook → Roles

### Playbooks de provisionamento (deploy)

| Playbook | Roles executadas (em ordem) |
|---|---|
| `00_linux_guide.yml` | baseline_system → shell_environment → hardening_security → monitoring_logs |
| `deploy_mysql.yml` | baseline_system → shell_environment → **mysql_install** → mysql_manage_users → db_patches |
| `deploy_postgres.yml` | baseline_system → shell_environment → **postgres_install** → postgres_manage_users → db_patches |
| `deploy_sqlserver.yml` | storage_setup → security_hardening → sql_pre_reqs → **sql_install** → sql_post_config → sql_manage_users → db_patches |
| `deploy_oracle.yml` | **oracle_install** (6 sub-fases) → oracle_manage_users → db_patches |
| `01_db_provisioning.yml` | Seleciona engine via `db_type` variable (mysql/postgres/oracle) |

### Playbooks de gestão de usuários (day-2)

| Playbook | Role | Quando usar |
|---|---|---|
| `manage_mysql_users.yml` | mysql_manage_users | Gerenciar usuários sem reinstalar MySQL |
| `manage_postgres_users.yml` | postgres_manage_users | Gerenciar usuários sem reinstalar PostgreSQL |
| `manage_sqlserver_users.yml` | sql_manage_users | Gerenciar logins/usuários sem reinstalar SQL Server |
| `manage_oracle_users.yml` | oracle_manage_users | Gerenciar schemas sem reinstalar Oracle |

### Fases opcionais

As fases de usuários e patches são **opcionais** — ativadas por variáveis booleanas:

| Variável | Default | Efeito |
|---|---|---|
| `mysql_manage_users_enabled` | `false` | Ativa gestão de usuários MySQL |
| `postgres_manage_users_enabled` | `false` | Ativa gestão de usuários PostgreSQL |
| `sql_manage_users_enabled` | `false` | Ativa gestão de usuários SQL Server |
| `oracle_manage_users_enabled` | `false` | Ativa gestão de usuários Oracle |
| `db_patches_enabled` | `false` | Ativa descoberta de patches |

---

## Como funciona o Survey AWX

O AWX usa **surveys** para substituir variáveis em playbooks. Quando o operador preenche o formulário e clica "Launch":

```
Survey (formulário AWX)
    ↓ gera variáveis flat
pg_username = "webapp"
pg_user_password = "senha"
    ↓ role converte para lista estruturada
db_users:
  - username: "webapp"
    password: "senha"
    state: "present"
    ↓ manage_user.yml processa cada item da lista
```

Este modelo permite:
- Interface simples para operadores (um campo por variável)
- Flexibilidade técnica (a role converte internamente)

---

## Conceitos Ansible para Iniciantes

### O que é uma Role?

Uma role é uma unidade reutilizável de automação. Exemplo: a role `mysql_install` sabe instalar e configurar MySQL em qualquer servidor RHEL ou Debian.

```
roles/
└── mysql_install/
    ├── defaults/main.yml   ← valores padrão das variáveis
    ├── tasks/main.yml      ← o que fazer (passo a passo)
    ├── templates/          ← arquivos de configuração com variáveis
    └── handlers/main.yml   ← ações que rodam quando algo muda (ex: reload service)
```

### O que é `become: true`?

Equivalente ao `sudo`. Escalona privilégios para root antes de executar o comando.

```yaml
- name: Instalar mysql-server
  dnf:
    name: mysql-server
  become: true          # roda como root
```

### O que é `become_user: postgres`?

Muda para um usuário específico (não root). Necessário para operações de banco que exigem autenticação via unix socket do próprio usuário do SO.

```yaml
- name: Criar banco PostgreSQL
  community.postgresql.postgresql_db:
    name: appdb
  become: true
  become_user: postgres    # roda como usuário 'postgres' do SO
```

### O que é `no_log: true`?

Suprime o output da task inteira nos logs. Usado em tasks que manipulam senhas — sem `no_log`, a senha aparece em texto plano no AWX, journald e sistemas de auditoria.

```yaml
- name: Criar usuário com senha
  community.mysql.mysql_user:
    name: webapp
    password: "senha_secreta"
  no_log: true    # não registra nada — a senha não vai para os logs
```

### O que são Tags?

Tags permitem executar só uma parte do playbook. Sem tags, roda tudo.

```bash
# Rodar só a instalação (pula usuários e patches):
ansible-playbook playbooks/deploy_mysql.yml --tags mysql_install

# Rodar tudo menos os patches:
ansible-playbook playbooks/deploy_mysql.yml --skip-tags db_patches
```

---

## Configuração — ansible.cfg

```ini
[defaults]
host_key_checking = False
inventory = ./inventory/
roles_path = ./roles
remote_user = user_aap
deprecation_warnings = False
collections_paths = /opt/collections:~/.ansible/collections
```

| Configuração | Valor | Por quê |
|---|---|---|
| `host_key_checking` | `False` | Lab — evita prompt de confirmação de novo host |
| `remote_user` | `user_aap` | Usuário com sudo NOPASSWD em todos os VMs |
| `collections_paths` | `/opt/collections` primeiro | Offline-first — sem internet nas execuções |

---

## Collections Necessárias

Arquivo: `collections/requirements.yml`

| Collection | Para que serve |
|---|---|
| `community.mysql` | Módulos MySQL (mysql_user, mysql_db) |
| `community.postgresql` | Módulos PostgreSQL (postgresql_privs, postgresql_pg_hba, postgresql_db) |
| `ansible.windows` | Módulos Windows (win_package, win_shell, win_acl) |
| `community.windows` | Módulos Windows extras (win_format) |
| `community.general` | Módulos gerais extras |

**Instalação online (em máquina com internet):**
```bash
ansible-galaxy collection install -r collections/requirements.yml -p /opt/collections
```

**Uso offline (AWX/EE):** Copiar o diretório `/opt/collections/ansible_collections/` para o EE. Ver [`offline_requirements.md`](offline_requirements.md).

---

## Comandos de Diagnóstico e Execução

### Verificação antes de executar

```bash
# Testar conectividade com todos os hosts:
ansible all -m ping

# Testar só o grupo de bancos:
ansible database_servers -m ping

# Ver hierarquia de grupos:
ansible-inventory --graph

# Simular sem executar (dry-run):
ansible-playbook playbooks/deploy_mysql.yml --check

# Dry-run + ver diffs de arquivos:
ansible-playbook playbooks/deploy_mysql.yml --check --diff

# Ver quais hosts serão afetados:
ansible-playbook playbooks/deploy_mysql.yml --list-hosts

# Ver quais tasks serão executadas:
ansible-playbook playbooks/deploy_mysql.yml --list-tasks

# Ver quais tags estão disponíveis:
ansible-playbook playbooks/deploy_mysql.yml --list-tags
```

### Execução controlada

```bash
# Limitado a um host específico:
ansible-playbook playbooks/deploy_mysql.yml -l mysqlvm

# Só uma fase (por tag):
ansible-playbook playbooks/deploy_mysql.yml --tags mysql_install

# Múltiplas tags:
ansible-playbook playbooks/deploy_mysql.yml --tags mysql_install,mysql_users

# Pular uma fase:
ansible-playbook playbooks/deploy_mysql.yml --skip-tags db_patches

# Passar variável extra (override de survey):
ansible-playbook playbooks/deploy_mysql.yml -e "mysql_manage_users_enabled=true" -e "db_username=webapp"

# Verbosidade crescente para debug:
ansible-playbook playbooks/deploy_mysql.yml -v     # verbose
ansible-playbook playbooks/deploy_mysql.yml -vv    # mais verbose
ansible-playbook playbooks/deploy_mysql.yml -vvv   # muito verbose (inclui conexão SSH)
```

### Debug de variáveis

```bash
# Ad-hoc: coletar facts de um host:
ansible postgresvm -m setup | grep -E "ansible_os_family|ansible_default_ipv4"

# Inspecionar variável durante playbook (task temporária):
- name: Debug variável
  debug:
    var: db_users
    verbosity: 1    # só mostra com -v ou maior
```

### Playbook unificado

```bash
# Selecionar engine via variável db_type:
ansible-playbook playbooks/01_db_provisioning.yml -e "db_type=mysql"
ansible-playbook playbooks/01_db_provisioning.yml -e "db_type=postgres"
ansible-playbook playbooks/01_db_provisioning.yml -e "db_type=oracle"
```

---

## Decisões de Design Globais

### Por que `db_patch_apply_enabled: false` hardcoded?

Patches de banco são operações de alto risco que requerem:
- Janela de manutenção aprovada
- Backup verificado
- Plano de rollback
- Review do conteúdo do patch

A descoberta é segura para automatizar (só lista arquivos). A aplicação **exige** revisão humana. Por isso, `db_patch_apply_enabled` é `false` no código e não é exposto no survey.

### Por que coleções offline?

O ambiente AWX está em `awxvm` (192.168.137.153), que não tem acesso à internet. O `repositoryvm` (192.168.137.148) funciona como mirror HTTP para binários, e as coleções Ansible ficam em `/opt/collections` no Execution Environment.

### Por que usar `changed_when: true` em tasks shell?

Algumas tasks `shell` (como criar role PostgreSQL via psql) sempre "mudam" algo, mas o Ansible não consegue detectar automaticamente. `changed_when: true` garante que o AWX marque a task como `changed` para auditoria.

---

## Playbooks de Utilidade

| Playbook | Função | Documentação |
|---|---|---|
| `01_db_provisioning.yml` | Provisionamento unificado multi-engine via `db_type` | [`utility_playbooks_guide.md`](utility_playbooks_guide.md#01_db_provisioningyml) |
| `db_backup_restore_validate.yml` | Backup, restore e validação de dados em sandbox | [`utility_playbooks_guide.md`](utility_playbooks_guide.md#db_backup_restore_validateyml) |
| `db_patch_discovery.yml` | Descoberta de patches disponíveis (nunca aplica) | [`utility_playbooks_guide.md`](utility_playbooks_guide.md#db_patch_discoveryyml) |
| `ping.yml` | Teste de conectividade cross-platform (Linux + Windows) | [`utility_playbooks_guide.md`](utility_playbooks_guide.md#pingyml) |
| `zabbix_installation.yml` | Instalar Zabbix Agent 5.0 em EL9 | [`utility_playbooks_guide.md`](utility_playbooks_guide.md#zabbix_installationyml) |

---

## Ver Também

- [`linux_guide.md`](linux_guide.md) — Baseline RHEL e hardening (00_linux_guide.yml)
- [`utility_playbooks_guide.md`](utility_playbooks_guide.md) — Playbooks utilitários detalhados
- [`mysql_guide.md`](mysql_guide.md) — MySQL completo
- [`postgres_guide.md`](postgres_guide.md) — PostgreSQL completo
- [`sqlserver_guide.md`](sqlserver_guide.md) — SQL Server completo
- [`oracle_guide.md`](oracle_guide.md) — Oracle 19c completo
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
- [`offline_requirements.md`](offline_requirements.md) — Ambiente offline
