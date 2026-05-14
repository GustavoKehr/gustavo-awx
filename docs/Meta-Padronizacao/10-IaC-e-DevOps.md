# 10 — Infrastructure as Code e DevOps para Bancos de Dados

## Principios Gerais

| Principio | Descricao |
|-----------|-----------|
| **Tudo como codigo** | Infraestrutura, configuracao e schema em repositorio Git |
| **Idempotencia** | Executar o mesmo codigo N vezes produz o mesmo resultado |
| **Imutabilidade** | Em vez de modificar um servidor existente, substituir por um novo com configuracao correta |
| **Auditabilidade** | Todo historico de mudanca preservado no Git (quem, o que, quando, por que) |
| **Automacao** | Nenhuma configuracao manual em producao — toda mudanca via pipeline |
| **Revisao** | Toda mudanca passa por Pull Request com revisao antes de aplicar em producao |
| **Segredos** | Nenhuma senha, chave ou token em repositorio Git — usar secrets manager |

---

## Terraform — Provisionamento de Infraestrutura

### Responsabilidade do Terraform

- Criar VMs, instancias RDS, clusters de banco (nao o software de BD)
- Configurar redes, subnets, security groups, VPCs
- Criar volumes de disco, buckets S3 para backup
- Gerenciar certificados SSL/TLS, DNS, load balancers
- Definir IAM roles e permissoes
- Outputs para passar IPs/endpoints ao Ansible

### Estrutura de Projeto Recomendada

```
terraform/
├── environments/
│   ├── prod/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── terraform.tfvars      # valores de producao (nao commitar secrets!)
│   │   └── outputs.tf
│   ├── staging/
│   │   └── ...
│   └── dev/
│       └── ...
├── modules/
│   ├── postgresql/               # modulo reutilizavel para PostgreSQL
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── mysql/
│   ├── redis/
│   ├── oracle/
│   └── common/
│       ├── security_group.tf     # SGs reutilizaveis por BD
│       └── monitoring.tf         # alarmes CloudWatch/Azure Monitor
└── backend.tf                    # state no S3 + DynamoDB locking
```

### Exemplos por Banco de Dados

```hcl
# modules/postgresql/main.tf — RDS PostgreSQL (AWS)
resource "aws_db_subnet_group" "postgres" {
  name       = "${var.environment}-postgres-subnet"
  subnet_ids = var.private_subnet_ids
  tags       = local.common_tags
}

resource "aws_db_parameter_group" "postgres" {
  family = "postgres${var.pg_major_version}"
  name   = "${var.environment}-postgres-params"

  # Parametros de seguranca e performance
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"  # log queries > 1 segundo
  }
  parameter {
    name  = "rds.force_ssl"
    value = "1"  # exigir TLS em todas as conexoes
  }
}

resource "aws_db_instance" "postgres" {
  identifier        = "${var.environment}-postgres-${var.instance_num}"
  engine            = "postgres"
  engine_version    = var.pg_version
  instance_class    = var.instance_class
  allocated_storage = var.storage_gb
  max_allocated_storage = var.max_storage_gb  # auto-scaling de storage

  db_name  = var.database_name
  username = var.db_username
  password = var.db_password  # referenciar aws_secretsmanager_secret_version

  # HA
  multi_az             = var.environment == "prod" ? true : false
  db_subnet_group_name = aws_db_subnet_group.postgres.name

  # Seguranca
  storage_encrypted      = true
  kms_key_id             = var.kms_key_arn
  deletion_protection    = var.environment == "prod" ? true : false
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.postgres.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name

  # Backup
  backup_retention_period   = var.backup_retention_days
  backup_window             = "02:00-03:00"
  maintenance_window        = "sun:04:00-sun:05:00"
  copy_tags_to_snapshot     = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.environment}-postgres-final-${formatdate("YYYYMMDD", timestamp())}"

  # Monitoramento
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  performance_insights_enabled    = true
  performance_insights_retention_period = 7

  tags = local.common_tags
}

# Security Group para PostgreSQL
resource "aws_security_group" "postgres" {
  name_prefix = "${var.environment}-postgres-"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs  # apenas IPs das aplicacoes
    description = "PostgreSQL from application tier"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

output "endpoint" {
  value = aws_db_instance.postgres.endpoint
}
output "port" {
  value = aws_db_instance.postgres.port
}
```

```hcl
# modules/redis/main.tf — ElastiCache Redis (AWS)
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.environment}-redis"
  description          = "Redis HA for ${var.environment}"

  node_type            = var.node_type
  num_cache_clusters   = var.environment == "prod" ? 3 : 1  # 1 primary + 2 replicas em prod
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.redis.name
  subnet_group_name    = aws_elasticache_subnet_group.redis.name

  # HA: Multi-AZ com failover automatico
  automatic_failover_enabled = var.environment == "prod" ? true : false
  multi_az_enabled           = var.environment == "prod" ? true : false

  # Seguranca
  at_rest_encryption_enabled    = true
  transit_encryption_enabled    = true  # TLS
  auth_token                    = var.redis_auth_token
  security_group_ids            = [aws_security_group.redis.id]

  # Backup
  snapshot_retention_limit = 7
  snapshot_window          = "03:00-04:00"

  # Manutencao
  maintenance_window       = "sun:05:00-sun:06:00"
  auto_minor_version_upgrade = true

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis_slow.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }

  tags = local.common_tags
}

resource "aws_elasticache_parameter_group" "redis" {
  family = "redis7"
  name   = "${var.environment}-redis-params"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
  parameter {
    name  = "timeout"
    value = "300"
  }
  parameter {
    name  = "tcp-keepalive"
    value = "60"
  }
}
```

```hcl
# modules/mysql/main.tf — RDS MySQL (AWS)
resource "aws_db_instance" "mysql" {
  identifier        = "${var.environment}-mysql"
  engine            = "mysql"
  engine_version    = var.mysql_version
  instance_class    = var.instance_class
  allocated_storage = var.storage_gb

  db_name  = var.database_name
  username = var.db_username
  password = var.db_password

  multi_az             = var.environment == "prod"
  db_subnet_group_name = aws_db_subnet_group.mysql.name

  storage_encrypted   = true
  kms_key_id          = var.kms_key_arn
  deletion_protection = var.environment == "prod"
  publicly_accessible = false

  # Binlog para PITR e replicacao
  backup_retention_period = 14
  backup_window           = "02:00-03:00"

  enabled_cloudwatch_logs_exports = ["general", "error", "slowquery", "audit"]
  performance_insights_enabled    = true

  tags = local.common_tags
}
```

```hcl
# Gerenciamento de State remoto com locking
terraform {
  backend "s3" {
    bucket         = "terraform-state-empresa"
    key            = "databases/prod/postgres.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"  # previne concurrent apply
    kms_key_id     = "arn:aws:kms:..."  # encrypt state file com KMS
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Variaveis sensiveis via AWS Secrets Manager (nunca no tfvars commitado)
data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = "/prod/postgres/master_password"
}

locals {
  common_tags = {
    Environment = var.environment
    Team        = var.team
    CostCenter  = var.cost_center
    ManagedBy   = "Terraform"
    DatabaseType = "postgresql"
  }
}
```

**Fontes Terraform**:
- [Terraform — AWS RDS Module](https://registry.terraform.io/modules/terraform-aws-modules/rds/aws/latest)
- [Terraform — Best Practices](https://developer.hashicorp.com/terraform/cloud-docs/recommended-practices)
- [HashiCorp — Managing Secrets with Terraform](https://developer.hashicorp.com/terraform/tutorials/configuration-language/sensitive-variables)

---

## Ansible — Configuracao de Banco de Dados

### Responsabilidade do Ansible

- Instalar pacotes do banco de dados no SO
- Aplicar configuracao baseline (postgresql.conf, my.cnf, oracle SPFILE, etc.)
- Criar usuarios e permissoes iniciais (DBA, monitoramento, aplicacao)
- Configurar autenticacao (pg_hba.conf, SSL, etc.)
- Configurar backup automatico (cron jobs, scripts)
- Registrar no sistema de monitoramento
- Aplicar patches e atualizacoes de versao menor
- Hardening de seguranca (CIS Benchmarks)

### Estrutura de Roles Completa

```
roles/
├── postgresql/
│   ├── defaults/main.yml         # valores padrao (sobrescritos por group_vars)
│   ├── vars/main.yml             # variaveis fixas (nao sobrescritas)
│   ├── tasks/
│   │   ├── main.yml              # include das subtasks
│   │   ├── install.yml           # instalacao do pacote
│   │   ├── configure.yml         # aplicar postgresql.conf, pg_hba.conf
│   │   ├── users.yml             # criar usuarios e roles
│   │   ├── backup.yml            # configurar pgBackRest
│   │   ├── monitoring.yml        # instalar e configurar postgres_exporter
│   │   └── hardening.yml         # CIS Benchmark hardening
│   ├── handlers/main.yml         # restart/reload postgresql
│   ├── templates/
│   │   ├── postgresql.conf.j2    # template de configuracao
│   │   └── pg_hba.conf.j2        # template de autenticacao
│   ├── files/
│   │   └── cis_pg_audit.sql      # script de audit roles
│   └── meta/main.yml             # dependencias de role
├── mysql/
│   ├── tasks/
│   │   ├── install.yml
│   │   ├── configure.yml
│   │   ├── replication.yml
│   │   └── hardening.yml
│   └── templates/
│       └── my.cnf.j2
├── redis/
│   ├── tasks/
│   │   ├── install.yml
│   │   ├── configure.yml
│   │   └── sentinel.yml
│   └── templates/
│       ├── redis.conf.j2
│       └── sentinel.conf.j2
└── oracle/
    ├── tasks/
    │   ├── install.yml            # Oracle silent install
    │   ├── database_create.yml    # dbca silent create
    │   └── configure.yml         # SPFILE parameters
    └── templates/
        └── dbca.rsp.j2            # Database Configuration Assistant response file
```

### Exemplos de Roles por Banco

```yaml
# roles/postgresql/defaults/main.yml
postgresql_version: "16"
postgresql_port: 5432
postgresql_data_dir: "/var/lib/postgresql/{{ postgresql_version }}/main"
postgresql_conf_dir: "/etc/postgresql/{{ postgresql_version }}/main"
postgresql_log_dir: "/var/log/postgresql"

# Performance defaults
postgresql_shared_buffers_ratio: 0.25     # 25% da RAM
postgresql_work_mem: "4MB"
postgresql_maintenance_work_mem: "256MB"
postgresql_effective_cache_size_ratio: 0.75  # 75% da RAM
postgresql_wal_level: "replica"
postgresql_max_connections: 200
postgresql_max_wal_senders: 10

# Seguranca
postgresql_ssl: "on"
postgresql_password_encryption: "scram-sha-256"
postgresql_log_connections: "on"
postgresql_log_disconnections: "on"
postgresql_log_min_duration_statement: 1000

# Usuarios (sobrescrever em group_vars)
postgresql_users:
  - name: app_user
    password: "{{ vault_app_db_password }}"
    role_attr_flags: "NOSUPERUSER,NOCREATEDB,NOCREATEROLE,LOGIN"
    db: "{{ postgresql_app_database }}"
    priv: "CONNECT"
  - name: monitoring_user
    password: "{{ vault_monitoring_db_password }}"
    role_attr_flags: "NOSUPERUSER,NOCREATEDB,NOCREATEROLE,LOGIN"
```

```yaml
# roles/postgresql/tasks/configure.yml
---
- name: Calculate shared_buffers based on total RAM
  set_fact:
    postgresql_shared_buffers: "{{ (ansible_memtotal_mb * postgresql_shared_buffers_ratio) | int }}MB"
    postgresql_effective_cache_size: "{{ (ansible_memtotal_mb * postgresql_effective_cache_size_ratio) | int }}MB"

- name: Deploy postgresql.conf
  template:
    src: postgresql.conf.j2
    dest: "{{ postgresql_conf_dir }}/postgresql.conf"
    owner: postgres
    group: postgres
    mode: '0644'
    backup: yes
  notify: reload postgresql

- name: Deploy pg_hba.conf
  template:
    src: pg_hba.conf.j2
    dest: "{{ postgresql_conf_dir }}/pg_hba.conf"
    owner: postgres
    group: postgres
    mode: '0640'
    backup: yes
  notify: reload postgresql

- name: Ensure PostgreSQL is started and enabled
  systemd:
    name: "postgresql@{{ postgresql_version }}-main"
    state: started
    enabled: yes
    daemon_reload: yes
```

```yaml
# roles/mysql/tasks/configure.yml
---
- name: Calculate innodb_buffer_pool_size (80% of RAM)
  set_fact:
    mysql_innodb_buffer_pool_size: "{{ (ansible_memtotal_mb * 0.80) | int }}M"
    mysql_innodb_buffer_pool_instances: "{{ [8, (ansible_memtotal_mb / 1024) | int] | min }}"

- name: Deploy my.cnf from template
  template:
    src: my.cnf.j2
    dest: /etc/mysql/mysql.conf.d/mysqld.cnf
    owner: root
    group: root
    mode: '0644'
    backup: yes
  notify: restart mysql

- name: Secure MySQL installation (equivalent to mysql_secure_installation)
  mysql_user:
    login_unix_socket: /var/run/mysqld/mysqld.sock
    name: root
    host_all: yes
    password: "{{ vault_mysql_root_password }}"
    check_implicit_admin: yes
    state: present
  no_log: yes

- name: Remove anonymous MySQL users
  mysql_user:
    name: ''
    host_all: yes
    state: absent
    login_user: root
    login_password: "{{ vault_mysql_root_password }}"

- name: Remove MySQL test database
  mysql_db:
    name: test
    state: absent
    login_user: root
    login_password: "{{ vault_mysql_root_password }}"
```

```yaml
# roles/redis/tasks/configure.yml
---
- name: Set Redis max memory to 80% of total RAM
  set_fact:
    redis_maxmemory: "{{ (ansible_memtotal_mb * 0.80) | int }}mb"

- name: Deploy redis.conf
  template:
    src: redis.conf.j2
    dest: /etc/redis/redis.conf
    owner: redis
    group: redis
    mode: '0640'
    backup: yes
  notify: restart redis

- name: Configure kernel parameters for Redis
  sysctl:
    name: "{{ item.name }}"
    value: "{{ item.value }}"
    state: present
    reload: yes
  loop:
    - { name: vm.overcommit_memory, value: '1' }
    - { name: net.core.somaxconn, value: '65535' }
    - { name: net.ipv4.tcp_max_syn_backlog, value: '65535' }

- name: Disable Transparent Huge Pages (Redis performance)
  shell: echo never > /sys/kernel/mm/transparent_hugepage/enabled
  changed_when: false

- name: Persist THP disable in rc.local
  lineinfile:
    path: /etc/rc.local
    line: 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
    create: yes
    mode: '0755'
```

### Templates Jinja2

```jinja2
{# roles/postgresql/templates/postgresql.conf.j2 #}
# Gerenciado por Ansible — nao editar manualmente
# Ultima atualizacao: {{ ansible_date_time.iso8601 }} por Ansible

listen_addresses = '{{ postgresql_listen_addresses | default("*") }}'
port = {{ postgresql_port }}
max_connections = {{ postgresql_max_connections }}

# ---- Memoria ----
shared_buffers = {{ postgresql_shared_buffers }}
effective_cache_size = {{ postgresql_effective_cache_size }}
work_mem = {{ postgresql_work_mem }}
maintenance_work_mem = {{ postgresql_maintenance_work_mem }}
huge_pages = {{ postgresql_huge_pages | default('try') }}

# ---- WAL e Replicacao ----
wal_level = {{ postgresql_wal_level }}
max_wal_senders = {{ postgresql_max_wal_senders }}
wal_keep_size = {{ postgresql_wal_keep_size | default('1GB') }}
max_replication_slots = {{ postgresql_max_replication_slots | default(10) }}
{% if postgresql_archive_mode == 'on' %}
archive_mode = on
archive_command = '{{ postgresql_archive_command }}'
archive_cleanup_command = '{{ postgresql_archive_cleanup_command | default("pg_archivecleanup /backup/wal %r") }}'
{% endif %}

# ---- Performance I/O ----
checkpoint_completion_target = 0.9
wal_buffers = 64MB
default_statistics_target = 100
random_page_cost = {{ postgresql_random_page_cost | default('1.1') }}  # 1.1 para SSD, 4.0 para HDD
effective_io_concurrency = {{ postgresql_effective_io_concurrency | default(200) }}

# ---- Seguranca ----
ssl = {{ postgresql_ssl }}
{% if postgresql_ssl == 'on' %}
ssl_cert_file = '/etc/postgresql/ssl/server.crt'
ssl_key_file = '/etc/postgresql/ssl/server.key'
ssl_ca_file = '/etc/postgresql/ssl/ca.crt'
ssl_min_protocol_version = 'TLSv1.2'
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL'
{% endif %}
password_encryption = {{ postgresql_password_encryption }}

# ---- Logging ----
log_destination = 'stderr'
logging_collector = on
log_directory = '{{ postgresql_log_dir }}'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_messages = warning
log_min_error_statement = error
log_min_duration_statement = {{ postgresql_log_min_duration_statement }}
log_connections = {{ postgresql_log_connections }}
log_disconnections = {{ postgresql_log_disconnections }}
log_line_prefix = '%m [%p] %q%u@%d '
log_statement = '{{ postgresql_log_statement | default("ddl") }}'
log_lock_waits = on
```

```ini
{# roles/mysql/templates/my.cnf.j2 #}
[mysqld]
# Gerenciado por Ansible — nao editar manualmente

# ---- Basico ----
server_id = {{ mysql_server_id | default(ansible_default_ipv4.address | regex_replace('\\.', '') | int % 65535) }}
port = {{ mysql_port | default(3306) }}
bind-address = {{ mysql_bind_address | default('0.0.0.0') }}
datadir = {{ mysql_datadir | default('/var/lib/mysql') }}
socket = {{ mysql_socket | default('/var/run/mysqld/mysqld.sock') }}

# ---- InnoDB ----
innodb_buffer_pool_size = {{ mysql_innodb_buffer_pool_size }}
innodb_buffer_pool_instances = {{ mysql_innodb_buffer_pool_instances }}
innodb_flush_log_at_trx_commit = 1
innodb_flush_method = O_DIRECT
innodb_log_file_size = {{ mysql_innodb_log_file_size | default('512M') }}
innodb_log_files_in_group = 2
innodb_io_capacity = {{ mysql_innodb_io_capacity | default(2000) }}
innodb_io_capacity_max = {{ mysql_innodb_io_capacity_max | default(4000) }}
innodb_file_per_table = ON
innodb_autoinc_lock_mode = 2

# ---- Replicacao / Binary Log ----
log_bin = {{ mysql_log_bin | default('/var/log/mysql/mysql-bin') }}
binlog_format = ROW
binlog_row_image = FULL
sync_binlog = 1
expire_logs_days = {{ mysql_expire_logs_days | default(14) }}
gtid_mode = ON
enforce_gtid_consistency = ON
log_replica_updates = ON

# ---- Seguranca ----
require_secure_transport = ON
ssl_ca = /etc/mysql/ssl/ca.pem
ssl_cert = /etc/mysql/ssl/server-cert.pem
ssl_key = /etc/mysql/ssl/server-key.pem
tls_version = TLSv1.2,TLSv1.3

# ---- Performance Geral ----
max_connections = {{ mysql_max_connections | default(500) }}
thread_cache_size = {{ mysql_thread_cache_size | default(50) }}
table_open_cache = {{ mysql_table_open_cache | default(4096) }}
query_cache_type = 0
tmp_table_size = {{ mysql_tmp_table_size | default('128M') }}
max_heap_table_size = {{ mysql_max_heap_table_size | default('128M') }}

# ---- Slow Query Log ----
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
log_queries_not_using_indexes = 1
```

```yaml
# roles/postgresql/handlers/main.yml
---
- name: restart postgresql
  systemd:
    name: "postgresql@{{ postgresql_version }}-main"
    state: restarted
  listen: "restart postgresql"

- name: reload postgresql
  systemd:
    name: "postgresql@{{ postgresql_version }}-main"
    state: reloaded
  listen: "reload postgresql"
```

### Inventario Dinamico com Terraform Outputs

```python
#!/usr/bin/env python3
# inventory/terraform_inventory.py
import subprocess, json, sys, os

def get_terraform_outputs(env_path):
    result = subprocess.run(
        ['terraform', f'-chdir={env_path}', 'output', '-json'],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        sys.stderr.write(f"Terraform output error: {result.stderr}\n")
        sys.exit(1)
    return json.loads(result.stdout)

env = os.environ.get('ENVIRONMENT', 'prod')
outputs = get_terraform_outputs(f'terraform/environments/{env}')

inventory = {
    '_meta': {'hostvars': {}},
    'postgresql': {
        'hosts': [outputs['postgres_endpoint']['value']],
        'vars': {
            'ansible_user': 'ubuntu',
            'postgresql_version': '16',
            'postgresql_environment': env
        }
    },
    'mysql': {
        'hosts': [outputs['mysql_endpoint']['value']],
        'vars': {
            'ansible_user': 'ubuntu',
            'mysql_version': '8.4'
        }
    },
    'redis': {
        'hosts': [outputs['redis_endpoint']['value']],
        'vars': {
            'ansible_user': 'ubuntu'
        }
    }
}

if '--list' in sys.argv:
    print(json.dumps(inventory))
elif '--host' in sys.argv:
    host = sys.argv[sys.argv.index('--host') + 1]
    print(json.dumps({}))
```

**Fontes Ansible**:
- [Ansible — Best Practices for Playbooks](https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html)
- [Ansible — Role Development Guide](https://docs.ansible.com/ansible/latest/dev_guide/developing_modules_general.html)
- [Ansible Galaxy — Community Database Roles](https://galaxy.ansible.com/ui/search/?keywords=postgresql)
- [Ansible — Vault for Secrets](https://docs.ansible.com/ansible/latest/vault_guide/index.html)

---

## GitOps para Bancos de Dados

### Fluxo GitOps

```
Desenvolvedor                Git (main)           CI/CD Pipeline        Banco Producao
     │                           │                     │                      │
     ├─ git checkout -b feat ────►                     │                      │
     ├─ Escrever migration file ─►                     │                      │
     ├─ git push origin feat ────►                     │                      │
     ├─ Abrir Pull Request ──────►                     │                      │
     │                           ├─ CI: validate ──────►                     │
     │                           ├─ CI: test on temp DB►                     │
     │                           ├─ CI: security scan ─►                     │
     ├─ Code Review ─────────────►                     │                      │
     ├─ Aprovar PR ──────────────►                     │                      │
     │                           ├─ Merge to main ─────►                     │
     │                           │                     ├─ Deploy to staging──►│
     │                           │                     ├─ Smoke tests ────────►│
     │                           │                     ├─ Aguardar aprovacao  │
     │                           │                     ├─ Deploy to prod ──────►│
     │                           │                     │                      │
```

### Branches e Tags

```bash
# Estrutura de branches para schema
git checkout -b feature/add-payments-table    # nova feature
git checkout -b fix/index-performance         # correcao de performance
git checkout -b hotfix/prod-critical-fix      # hotfix urgente para producao

# Tagging de releases de schema
git tag -a v2.1.0-schema -m "Add payments table and indexes"
git push origin v2.1.0-schema

# Deploy de release especifica
flyway migrate -target=2.1.0
```

---

## CI/CD Pipeline para Bancos de Dados

### Pipeline GitHub Actions Completo

```yaml
# .github/workflows/database-deploy.yml
name: Database Schema Deploy

on:
  push:
    branches: [main]
    paths: ['migrations/**', 'flyway.conf']
  pull_request:
    branches: [main]
    paths: ['migrations/**', 'flyway.conf']

env:
  FLYWAY_VERSION: "10.10.0"

jobs:
  # ---- Stage 1: Validar Migrations ----
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Flyway Validate
        run: |
          docker run --rm \
            -v ${{ github.workspace }}/migrations:/flyway/sql \
            flyway/flyway:${{ env.FLYWAY_VERSION }} \
            -url=jdbc:postgresql://localhost:5432/test \
            -user=postgres \
            -password=${{ secrets.TEST_DB_PASSWORD }} \
            validate

      - name: SQLFluff Lint
        run: |
          pip install sqlfluff
          sqlfluff lint migrations/ --dialect postgres --processes 4

  # ---- Stage 2: Testes em Banco Efemero ----
  test:
    runs-on: ubuntu-latest
    needs: validate
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: test_password
          POSTGRES_DB: test_db
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 5432:5432

    steps:
      - uses: actions/checkout@v4

      - name: Apply Migrations to Test DB
        run: |
          docker run --rm \
            --network host \
            -v ${{ github.workspace }}/migrations:/flyway/sql \
            flyway/flyway:${{ env.FLYWAY_VERSION }} \
            -url="jdbc:postgresql://localhost:5432/test_db" \
            -user=postgres \
            -password=test_password \
            migrate

      - name: Run Schema Tests
        run: |
          pip install pytest psycopg2
          pytest tests/schema/ -v --tb=short

      - name: Verify Data Integrity
        run: |
          python tests/verify_constraints.py --env test

  # ---- Stage 3: Scan de Seguranca ----
  security:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@v4

      - name: SQLCheck — SQL Injection Patterns
        run: |
          pip install sqlfluff
          sqlfluff lint migrations/ --templater jinja \
            --rules LT01,LT02,ST03,ST06,AM01,AM02

      - name: Checkov — IaC Security Scan
        run: |
          pip install checkov
          checkov -d terraform/ --framework terraform \
            --check CKV_AWS_17,CKV_AWS_16,CKV_AWS_157 \
            --compact

      - name: Trivy — Container/IaC Vulnerability Scan
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: 'config'
          scan-ref: 'terraform/'
          severity: 'HIGH,CRITICAL'

  # ---- Stage 4: Deploy em Staging ----
  deploy-staging:
    runs-on: ubuntu-latest
    needs: security
    if: github.ref == 'refs/heads/main'
    environment: staging
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: Run Migrations on Staging
        run: |
          ansible-playbook \
            -i inventory/staging \
            playbooks/migrate.yml \
            --extra-vars "target_env=staging"

      - name: Run Smoke Tests Staging
        run: python tests/smoke_tests.py --env staging

  # ---- Stage 5: Deploy em Producao (aprovacao manual) ----
  deploy-prod:
    runs-on: ubuntu-latest
    needs: deploy-staging
    if: github.ref == 'refs/heads/main'
    environment:
      name: production
      url: "https://app.empresa.com"
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID_PROD }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY_PROD }}
          aws-region: us-east-1

      - name: Run Migrations on Production
        run: |
          ansible-playbook \
            -i inventory/prod \
            playbooks/migrate.yml \
            --extra-vars "target_env=prod"

      - name: Run Smoke Tests Production
        run: python tests/smoke_tests.py --env prod

      - name: Notify Success
        if: success()
        uses: slackapi/slack-github-action@v1
        with:
          channel-id: '#db-deployments'
          slack-message: "Schema migration deployed to PROD: ${{ github.sha }}"
        env:
          SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
```

---

## Flyway — Gerenciamento de Schema

```bash
# Estrutura de diretorios
migrations/
├── V1__create_users_table.sql        # versioned migration
├── V2__add_orders_table.sql
├── V2.1__add_order_indexes.sql
├── V3__add_payment_columns.sql
├── R__recreate_reports_view.sql      # repeatable migration (re-executada quando muda)
└── U2__undo_orders_table.sql         # undo migration (Flyway Teams)
```

```sql
-- migrations/V1__create_users_table.sql
-- Criar tabela de usuarios com constraints completas
CREATE TABLE user_account (
    user_account_id   BIGINT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email             VARCHAR(255)    NOT NULL,
    username          VARCHAR(100)    NOT NULL,
    password_hash     VARCHAR(255)    NOT NULL,
    is_active         BOOLEAN         NOT NULL DEFAULT true,
    created_at        TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ     NOT NULL DEFAULT now(),
    last_login_at     TIMESTAMPTZ,
    CONSTRAINT uq_user_email    UNIQUE (email),
    CONSTRAINT uq_user_username UNIQUE (username),
    CONSTRAINT ck_user_email    CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

CREATE INDEX CONCURRENTLY idx_user_account_email ON user_account (email);
CREATE INDEX CONCURRENTLY idx_user_account_last_login ON user_account (last_login_at) WHERE last_login_at IS NOT NULL;
```

```bash
# flyway.conf
flyway.url=jdbc:postgresql://localhost:5432/mydb
flyway.user=flyway_user
flyway.password=${FLYWAY_DB_PASSWORD}
flyway.locations=filesystem:migrations
flyway.encoding=UTF-8
flyway.validateOnMigrate=true
flyway.outOfOrder=false
flyway.cleanDisabled=true         # NUNCA limpar banco em producao
flyway.baselineOnMigrate=false
flyway.connectRetries=10
flyway.lockRetryCount=50

# Comandos principais
flyway info      # listar migrations e status
flyway validate  # validar migrations sem executar
flyway migrate   # executar migrations pendentes
flyway repair    # reparar checksum de migrations

# MySQL — configuracao adicional
flyway.url=jdbc:mysql://localhost:3306/mydb?useSSL=true&requireSSL=true
flyway.placeholders.schema_name=mydb

# Oracle
flyway.url=jdbc:oracle:thin:@//localhost:1521/ORCL
flyway.oracle.walletLocation=/opt/oracle/wallet

# SQL Server
flyway.url=jdbc:sqlserver://localhost:1433;databaseName=MeuBanco;encrypt=true;trustServerCertificate=false
```

---

## Liquibase — Alternativa ao Flyway

```xml
<!-- db/changelog/db.changelog-master.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<databaseChangeLog
    xmlns="http://www.liquibase.org/xml/ns/dbchangelog"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog
        http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-4.0.xsd">

    <include file="db/changelog/v1/001-create-users.xml"/>
    <include file="db/changelog/v1/002-add-indexes.xml"/>
    <include file="db/changelog/v2/001-add-orders.xml"/>
    <include file="db/changelog/v2/002-add-payments.xml"/>
</databaseChangeLog>
```

```xml
<!-- db/changelog/v1/001-create-users.xml -->
<databaseChangeLog ...>
    <changeSet id="v1-001" author="gustavo" labels="v1.0" context="prod,staging">
        <preConditions onFail="MARK_RAN">
            <not><tableExists tableName="user_account"/></not>
        </preConditions>

        <createTable tableName="user_account">
            <column name="user_account_id" type="BIGINT" autoIncrement="true">
                <constraints primaryKey="true" nullable="false"/>
            </column>
            <column name="email" type="VARCHAR(255)">
                <constraints unique="true" nullable="false"/>
            </column>
            <column name="is_active" type="BOOLEAN" defaultValueBoolean="true">
                <constraints nullable="false"/>
            </column>
            <column name="created_at" type="TIMESTAMPTZ" defaultValueComputed="NOW()">
                <constraints nullable="false"/>
            </column>
        </createTable>

        <createIndex indexName="idx_user_email" tableName="user_account" unique="true">
            <column name="email"/>
        </createIndex>

        <rollback>
            <dropTable tableName="user_account"/>
        </rollback>
    </changeSet>
</databaseChangeLog>
```

```bash
# liquibase.properties
url=jdbc:postgresql://localhost:5432/mydb
username=liquibase_user
password=${LIQUIBASE_DB_PASSWORD}
changeLogFile=db/changelog/db.changelog-master.xml
logLevel=INFO

# Suporte multi-banco (mesmo changelog, diferentes adaptacoes)
# Para MySQL:
url=jdbc:mysql://localhost:3306/mydb
driver=com.mysql.cj.jdbc.Driver

# Comandos
liquibase status          # migrations pendentes
liquibase update          # aplicar migrations pendentes
liquibase rollback-count 1  # reverter ultima migration
liquibase generate-changelog  # gerar changelog de banco existente
liquibase diff            # comparar dois bancos
```

**Fontes Flyway e Liquibase**:
- [Flyway Documentation](https://flywaydb.org/documentation/)
- [Liquibase Documentation](https://docs.liquibase.com/)
- [Flyway vs Liquibase Comparison](https://www.baeldung.com/liquibase-vs-flyway)

---

## Secrets Management

### Hierarquia de Gerenciamento de Segredos

```bash
# ---- Nunca em codigo ou repositorio ----
# ERRADO — jamais fazer isso:
postgresql_password: "minhasenha123"    # em YAML commitado no Git
DB_PASSWORD=minhasenha123              # em .env commitado

# CORRETO — referenciar o secrets manager
postgresql_password: "{{ lookup('aws_ssm', '/prod/postgres/password') }}"

# Prevenir acidentes com git-secrets ou pre-commit hooks
pip install detect-secrets
detect-secrets scan > .secrets.baseline
detect-secrets audit .secrets.baseline
```

```yaml
# Ansible Vault para segredos locais (desenvolvimento/staging)
# Criar arquivo de segredos
ansible-vault create group_vars/prod/vault.yml
# Editor abre — adicionar:
# vault_db_password: "SenhaSegura@123!"

# Editar segredos
ansible-vault edit group_vars/prod/vault.yml

# Executar playbook com vault
ansible-playbook site.yml --vault-password-file ~/.vault_pass
# ou via ANSIBLE_VAULT_PASSWORD_FILE env var
```

```yaml
# HashiCorp Vault para environments enterprise/producao
# Buscar credencial do Vault no Ansible
- name: Get database credentials from Vault
  community.hashi_vault.vault_kv2_get:
    path: "prod/postgres"
    auth_method: approle
    role_id: "{{ vault_role_id }}"
    secret_id: "{{ vault_secret_id }}"
    mount_point: "database"
  register: db_creds
  no_log: yes

- name: Configure postgresql connection
  template:
    src: pgpass.j2
    dest: /home/postgres/.pgpass
    mode: '0600'
    owner: postgres
  vars:
    db_password: "{{ db_creds.data.data.password }}"
  no_log: yes

# HashiCorp Vault Database Secrets Engine (rotacao automatica de senhas)
# vault secrets enable database
# vault write database/config/postgres
#   plugin_name=postgresql-database-plugin
#   connection_url="postgresql://{{username}}:{{password}}@pg-host:5432/mydb"
#   allowed_roles="app-role"
#   username="vault"
#   password="{{ vault_db_password }}"

# vault write database/roles/app-role
#   db_name=postgres
#   creation_statements="CREATE ROLE "{{name}}" WITH LOGIN ENCRYPTED PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO "{{name}}";"
#   default_ttl="1h"
#   max_ttl="24h"
```

---

## Checklist DevOps para Bancos de Dados

### Repositorio

- [ ] Todo arquivo de configuracao de banco em repositorio Git
- [ ] Branches protegidas (nao pode push diretamente em `main`)
- [ ] PR obrigatorio com minimo 1 revisor antes de merge
- [ ] Nenhum secret em texto plano no repositorio (git-secrets ou detect-secrets configurado)
- [ ] `.gitignore` inclui arquivos de credenciais (`.env`, `*.key`, `vault.yml` nao-criptografados)
- [ ] Pre-commit hooks para validacao de SQL e deteccao de segredos

### Pipeline CI/CD

- [ ] Validacao de syntax de migration no CI (Flyway validate / sqlfluff)
- [ ] Testes automaticos de schema em banco efemero (serviço no CI)
- [ ] Scan de seguranca automatico (SQLCheck, Checkov, Trivy)
- [ ] Deploy automatico em staging; manual (com aprovacao) em prod
- [ ] Smoke tests automaticos pos-deploy
- [ ] Notificacao no canal de operacoes para todo deploy em producao
- [ ] Rollback automatico se smoke tests falharem

### Terraform

- [ ] State armazenado remotamente (S3 + DynamoDB ou Terraform Cloud)
- [ ] `terraform plan` revisado em PR antes do `apply`
- [ ] `deletion_protection = true` em recursos de banco de producao
- [ ] Tags obrigatorias: `environment`, `team`, `cost-center`, `db-type`
- [ ] Variaveis sensiveis via Secrets Manager (nao no tfvars commitado)
- [ ] `terraform fmt` e `tflint` no CI

### Ansible

- [ ] Roles idempotentes (playbook pode ser re-executado sem efeitos colaterais)
- [ ] Variaveis de ambiente separadas por ambiente (group_vars/prod, group_vars/staging)
- [ ] Handlers para restart/reload apenas quando necessario (nao em toda execucao)
- [ ] `ansible-lint` no CI para validar syntax e boas praticas
- [ ] Molecule para testes de roles em ambiente isolado
- [ ] `no_log: yes` em todas as tasks que manipulam segredos

### Flyway / Liquibase

- [ ] `cleanDisabled=true` em todos os ambientes (nunca limpar banco em producao)
- [ ] `validateOnMigrate=true` (detectar mudancas em migrations ja executadas)
- [ ] Nomes de arquivo seguem padrao de versao (V1__, V2.1__, etc.)
- [ ] Migrations testadas com rollback (para Flyway Teams / Liquibase Pro)
- [ ] Migrations `CONCURRENTLY` para criacao de indices em PostgreSQL producao

### Monitoramento de Mudancas

- [ ] Alertas de mudanca de schema em producao (DDL audit log)
- [ ] Integracao com CMDB para registrar versao do schema
- [ ] Notificacao no canal de operacoes para todo deploy em producao
- [ ] Backup automatico antes de migrations criticas

**Fontes Gerais IaC e DevOps**:
- [HashiCorp Terraform — Best Practices](https://developer.hashicorp.com/terraform/cloud-docs/recommended-practices)
- [HashiCorp Vault — Database Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/databases)
- [Ansible — Database Automation](https://www.ansible.com/use-cases/database-automation)
- [GitOps — Principles and Patterns](https://opengitops.dev/)
- [DORA — DevOps Research and Assessment Metrics](https://dora.dev/research/)
- [NIST SP 800-204D — DevSecOps Fundamentals](https://csrc.nist.gov/publications/detail/sp/800-204d/final)
