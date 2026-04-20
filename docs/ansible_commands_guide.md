# Guia de Comandos Ansible — Referência Rápida

Referência rápida de comandos, operações no AWX e links para documentação detalhada.

---

## Índice de Documentação

| Arquivo | Conteúdo |
|---|---|
| [`general_guide.md`](general_guide.md) | Arquitetura, ansible.cfg, inventário, módulos universais, conceitos |
| [`linux_guide.md`](linux_guide.md) | Baseline RHEL — pacotes, NTP, hardening, Zabbix (00_linux_guide.yml) |
| [`utility_playbooks_guide.md`](utility_playbooks_guide.md) | Playbooks utilitários — provisionamento, backup, patches, ping, Zabbix |
| [`mysql_guide.md`](mysql_guide.md) | MySQL — variáveis, módulos, exemplos, troubleshooting |
| [`mysql_runbook.md`](mysql_runbook.md) | MySQL — operações no AWX, cenários práticos |
| [`postgres_guide.md`](postgres_guide.md) | PostgreSQL — variáveis, módulos, exemplos, troubleshooting |
| [`postgres_runbook.md`](postgres_runbook.md) | PostgreSQL — operações no AWX, cenários práticos |
| [`sqlserver_guide.md`](sqlserver_guide.md) | SQL Server — variáveis, módulos Windows, exemplos |
| [`sqlserver_runbook.md`](sqlserver_runbook.md) | SQL Server — operações no AWX, cenários práticos |
| [`oracle_guide.md`](oracle_guide.md) | Oracle 19c — 6 fases, variáveis, exemplos |
| [`oracle_runbook.md`](oracle_runbook.md) | Oracle — pré-requisitos, execução no AWX |
| [`awx_surveys.md`](awx_surveys.md) | Matriz de templates, surveys e variáveis |
| [`offline_requirements.md`](offline_requirements.md) | Preparar ambiente sem internet |

---

## Comandos Mais Usados

### Testar conectividade

```bash
# Todos os hosts:
ansible all -m ping

# Só banco específico:
ansible postgresvm -m ping

# Grupo inteiro:
ansible database_servers -m ping
```

---

### Executar playbooks

```bash
# Instalação completa (MySQL):
ansible-playbook playbooks/deploy_mysql.yml

# Só instalar (sem usuários/patches):
ansible-playbook playbooks/deploy_mysql.yml --tags mysql_install

# Só gerenciar usuários:
ansible-playbook playbooks/deploy_mysql.yml --tags mysql_users \
  -e "mysql_manage_users_enabled=true"

# Limitado a um host:
ansible-playbook playbooks/deploy_mysql.yml -l mysqlvm

# Dry-run (não executa nada):
ansible-playbook playbooks/deploy_mysql.yml --check

# Dry-run + ver diffs de arquivos:
ansible-playbook playbooks/deploy_mysql.yml --check --diff

# Verbosidade para debug:
ansible-playbook playbooks/deploy_mysql.yml -v    # verbose
ansible-playbook playbooks/deploy_mysql.yml -vvv  # muito verbose
```

---

### Diagnóstico antes de executar

```bash
# Ver quais hosts serão afetados:
ansible-playbook playbooks/deploy_mysql.yml --list-hosts

# Ver quais tasks serão executadas:
ansible-playbook playbooks/deploy_mysql.yml --list-tasks

# Ver quais tags estão disponíveis:
ansible-playbook playbooks/deploy_mysql.yml --list-tags

# Ver inventário completo (JSON):
ansible-inventory --list

# Ver hierarquia de grupos:
ansible-inventory --graph
```

---

### Coletar informações dos hosts (facts)

```bash
# Tudo sobre um host:
ansible postgresvm -m setup

# Filtrar só OS:
ansible postgresvm -m setup -a "filter=ansible_os_family"

# IP principal:
ansible postgresvm -m setup -a "filter=ansible_default_ipv4"

# Distribuição e versão:
ansible postgresvm -m setup -a "filter=ansible_distribution*"
```

---

### Ad-hoc commands (comandos rápidos sem playbook)

```bash
# Verificar espaço em disco:
ansible postgresvm -m shell -a "df -h" --become

# Verificar serviço PostgreSQL:
ansible postgresvm -m shell -a "systemctl status postgresql" --become

# Verificar portas em uso:
ansible postgresvm -m shell -a "ss -tlnp | grep 15432" --become

# Verificar processo MySQL:
ansible mysqlvm -m shell -a "systemctl status mysqld" --become

# Reiniciar serviço (cuidado em produção):
ansible postgresvm -m service -a "name=postgresql state=restarted" --become
```

---

### Coleções

```bash
# Instalar coleções (máquina com internet):
ansible-galaxy collection install -r collections/requirements.yml -p /opt/collections

# Listar coleções instaladas:
ansible-galaxy collection list

# Listar de um path específico:
ansible-galaxy collection list --collections-path /opt/collections
```

---

## Operações no AWX via kubectl

Para operações diretas no AWX (quando a API não funciona ou para automação):

### Pré-requisito: descobrir nome do pod

```bash
ssh user_aap@192.168.137.153 "sudo /usr/local/bin/kubectl get pods -n awx"
# Copiar o nome do pod awx-server-web-*
```

### Executar Python no AWX (shell_plus)

```bash
# Método confiável: criar script Python → scp → kubectl exec
cat > /tmp/script.py << 'EOF'
from awx.main.models import JobTemplate, ProjectUpdate

# Sincronizar projeto
p = ProjectUpdate.objects.filter(project__name__icontains='gustavo').order_by('-id').first()
print(f"Last sync: {p.status}")
EOF

scp /tmp/script.py user_aap@192.168.137.153:/tmp/script.py

ssh user_aap@192.168.137.153 \
  "cat /tmp/script.py | sudo /usr/local/bin/kubectl exec -i -n awx awx-server-web-dfd584888-cls7c -- awx-manage shell_plus --plain" 2>&1 | grep -v "^from\|^#\|^import\|InteractiveConsole\|Shell Plus"
```

### Sincronizar projeto no AWX

```python
# /tmp/awx_sync.py
from awx.main.models import Project
import time

p = Project.objects.get(name__icontains='gustavo')
pu = p.update()
print(f"Sync started: {pu}")
time.sleep(5)
pu.refresh_from_db()
print(f"Status: {pu.status}")
```

### Lançar job template no AWX

```python
# /tmp/awx_launch.py
from awx.main.models import JobTemplate
import time

jt = JobTemplate.objects.get(name__icontains='POSTGRES | Manage Users')

extra_vars = {
    "postgres_manage_users_enabled": True,
    "pg_username": "testuser",
    "pg_user_password": "Test#2024!",
    "pg_user_state": "present",
    "pg_role_attr_flags": "LOGIN",
    "pg_privileges": "CONNECT",
    "pg_target_databases": "appdb",
    "pg_revoke_access": False,
    "pg_manage_databases": False,
    "pg_predefined_roles": "",
    "pg_allowed_ips": ""
}

job = jt.create_unified_job(extra_vars=extra_vars, limit="postgresvm")
print(f"Job created: {job.id}")
job.signal_start()
time.sleep(5)
job.refresh_from_db()
print(f"Status: {job.status}")
```

### Verificar último job

```python
# /tmp/awx_check_job.py
from awx.main.models import Job, JobTemplate
jt = JobTemplate.objects.get(name__icontains='POSTGRES | Manage Users')
jobs = list(Job.objects.filter(job_template=jt).order_by('-id')[:3])
for j in jobs:
    print(f"Job {j.id}: {j.status} — {str(j.created)[:19]}")
```

---

## Tags Cross-Engine (deploy_mysql, deploy_postgres, deploy_oracle)

Estas tags existem nos playbooks `deploy_mysql.yml`, `deploy_postgres.yml` e `deploy_oracle.yml` para selecionar grupos de fases independente do engine.

| Tag | Fases incluídas | Quando usar |
|---|---|---|
| `os_prep` | baseline_system + shell_environment | Replicar só a preparação do SO sem instalar banco |
| `bootstrap` | baseline_system + shell_environment + *_install | Instalação completa do zero (OS + banco) |
| `post_install` | *_manage_users | Só gestão de usuários, após banco já instalado |
| `patching` | db_patches | Só descoberta de patches |

```bash
# Só preparar OS (sem instalar banco):
ansible-playbook playbooks/deploy_mysql.yml --tags os_prep

# Instalar tudo do zero:
ansible-playbook playbooks/deploy_mysql.yml --tags bootstrap

# Só gerenciar usuários (banco já existe):
ansible-playbook playbooks/deploy_mysql.yml \
  --tags post_install \
  -e "mysql_manage_users_enabled=true"

# Só descoberta de patches:
ansible-playbook playbooks/deploy_mysql.yml \
  --tags patching \
  -e "db_patches_enabled=true"
```

---

## Referência de Tags por Engine

### MySQL

| Tag | Fase |
|---|---|
| `mysql` | Todas |
| `mysql_install` | Instalação completa |
| `mysql_users` | Gestão de usuários |
| `mysql_grants` | Só grants |
| `mysql_revoke` | Só revogação |
| `mysql_remove_user` | Só remoção |

### PostgreSQL

| Tag | Fase |
|---|---|
| `postgres` | Todas |
| `postgres_install` | Instalação completa |
| `postgres_users` | Gestão de usuários |
| `postgres_user` | Criar/alterar role |
| `postgres_grants` | Privilégios de banco |
| `postgres_pg_roles` | Roles predefinidas |
| `postgres_hba` | pg_hba.conf |
| `postgres_remove_user` | DROP ROLE |

### SQL Server

| Tag | Fase |
|---|---|
| `storage` | Disco (Phase 1) |
| `security` | IPsec (Phase 2) |
| `sql_install` | Instalação (Phase 4) |
| `sql_users` | Gestão de usuários |
| `sql_login` | Server login |
| `sql_db_user` | Database user |
| `sql_grants` | Roles |
| `sql_remove_user` | DROP LOGIN |

### Oracle

| Tag | Fase |
|---|---|
| `oracle_prereqs` | Phase 1 |
| `oracle_dirs` | Phase 2 |
| `oracle_transfer` | Phase 3 (~30 min) |
| `oracle_install_sw` | Phase 4 (~40 min) |
| `oracle_patches` | Phase 5 (~60 min) |
| `oracle_dbcreate` | Phase 6 (~40 min) |
| `oracle_users` | Gestão de usuários |

---

## Ver Também

- [`general_guide.md`](general_guide.md) — Conceitos e arquitetura detalhada
- [`awx_surveys.md`](awx_surveys.md) — Templates e surveys AWX
