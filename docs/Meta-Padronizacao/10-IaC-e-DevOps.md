# 10 — Infrastructure as Code e DevOps para Bancos de Dados

## Principios Gerais

| Principio | Descricao |
|-----------|-----------|
| **Tudo como codigo** | Infraestrutura, configuracao e schema em repositorio Git |
| **Idempotencia** | Executar o mesmo codigo N vezes produz o mesmo resultado |
| **Imutabilidade** | Em vez de modificar um servidor, substituir por um novo com configuracao correta |
| **Auditabilidade** | Todo historico de mudanca preservado no Git (quem, o que, quando, por que) |
| **Automacao** | Nenhuma configuracao manual em producao |
| **Revisao** | Toda mudanca passa por Pull Request com revisao |

---

## Terraform — Provisionamento de Infraestrutura

### Responsabilidade do Terraform
- Criar VMs, instancias RDS, clusters de banco
- Configurar redes, subnets, security groups
- Criar volumes de disco, buckets S3 para backup
- Gerenciar certificados, DNS, load balancers
- Outputs para passar IPs/endpoints ao Ansible

### Estrutura de Projeto Recomendada

```
terraform/
├── environments/
│   ├── prod/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── terraform.tfvars      # valores de producao (nao comitar secrets)
│   │   └── outputs.tf
│   ├── staging/
│   │   └── ...
│   └── dev/
│       └── ...
├── modules/
│   ├── postgresql/
│   │   ├── main.tf               # RDS PostgreSQL ou EC2+PostgreSQL
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── mysql/
│   ├── redis/
│   └── common/
│       ├── security_group.tf
│       └── monitoring.tf
└── backend.tf                    # state no S3 + DynamoDB locking
```

### Exemplo — RDS PostgreSQL com Terraform

```hcl
# modules/postgresql/main.tf

resource "aws_db_subnet_group" "postgres" {
  name       = "${var.environment}-postgres-subnet"
  subnet_ids = var.private_subnet_ids
}

resource "aws_db_instance" "postgres" {
  identifier             = "${var.environment}-postgres-${var.instance_num}"
  engine                 = "postgres"
  engine_version         = var.pg_version
  instance_class         = var.instance_class
  allocated_storage      = var.storage_gb
  max_allocated_storage  = var.max_storage_gb

  db_name  = var.database_name
  username = var.db_username
  password = var.db_password  # usar aws_secretsmanager_secret_version

  # HA
  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.postgres.name

  # Seguranca
  storage_encrypted      = true
  kms_key_id             = var.kms_key_arn
  deletion_protection    = var.environment == "prod" ? true : false
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.postgres.id]

  # Backup
  backup_retention_period = var.backup_retention_days
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  # Monitoramento
  monitoring_interval    = 60
  monitoring_role_arn    = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  performance_insights_enabled    = true

  tags = local.common_tags
}

output "endpoint" {
  value = aws_db_instance.postgres.endpoint
}
```

### Gerenciamento de State

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket         = "terraform-state-mycompany"
    key            = "databases/prod/postgres.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"  # previne concurrent apply
  }
}
```

---

## Ansible — Configuracao de Banco de Dados

### Responsabilidade do Ansible
- Instalar pacotes do banco de dados
- Aplicar configuracao baseline (postgresql.conf, my.cnf, etc.)
- Criar usuarios e permissoes iniciais
- Configurar autenticacao (pg_hba.conf, etc.)
- Configurar backup automatico
- Registrar no monitoramento
- Aplicar patches e atualizacoes

### Estrutura de Roles

```
roles/
├── postgresql/
│   ├── defaults/main.yml        # valores padrao (sobrescritos por vars)
│   ├── vars/main.yml            # variaveis fixas
│   ├── tasks/
│   │   ├── main.yml
│   │   ├── install.yml
│   │   ├── configure.yml
│   │   ├── users.yml
│   │   ├── backup.yml
│   │   └── monitoring.yml
│   ├── handlers/main.yml        # restart postgresql
│   ├── templates/
│   │   ├── postgresql.conf.j2
│   │   └── pg_hba.conf.j2
│   └── meta/main.yml
├── mysql/
├── redis/
└── oracle/
```

### Exemplo — Role PostgreSQL

```yaml
# roles/postgresql/defaults/main.yml
postgresql_version: "16"
postgresql_port: 5432
postgresql_data_dir: "/var/lib/postgresql/{{ postgresql_version }}/main"
postgresql_conf_dir: "/etc/postgresql/{{ postgresql_version }}/main"

# Performance defaults (sobrescritos por group_vars/producao)
postgresql_shared_buffers: "256MB"
postgresql_work_mem: "4MB"
postgresql_wal_level: "replica"
postgresql_max_connections: 100
postgresql_ssl: "on"
postgresql_log_min_duration_statement: 1000
```

```yaml
# roles/postgresql/tasks/configure.yml
---
- name: Configure postgresql.conf
  template:
    src: postgresql.conf.j2
    dest: "{{ postgresql_conf_dir }}/postgresql.conf"
    owner: postgres
    group: postgres
    mode: '0644'
  notify: restart postgresql

- name: Configure pg_hba.conf
  template:
    src: pg_hba.conf.j2
    dest: "{{ postgresql_conf_dir }}/pg_hba.conf"
    owner: postgres
    group: postgres
    mode: '0640'
  notify: reload postgresql

- name: Ensure postgresql is running and enabled
  systemd:
    name: "postgresql-{{ postgresql_version }}"
    state: started
    enabled: yes
```

```jinja2
# roles/postgresql/templates/postgresql.conf.j2
# Gerenciado por Ansible — nao editar manualmente

listen_addresses = '*'
port = {{ postgresql_port }}

# Memoria
shared_buffers = {{ postgresql_shared_buffers }}
work_mem = {{ postgresql_work_mem }}
maintenance_work_mem = {{ postgresql_maintenance_work_mem | default('256MB') }}

# WAL / Replicacao
wal_level = {{ postgresql_wal_level }}
max_wal_senders = {{ postgresql_max_wal_senders | default(10) }}
archive_mode = {{ postgresql_archive_mode | default('off') }}
{% if postgresql_archive_mode == 'on' %}
archive_command = '{{ postgresql_archive_command }}'
{% endif %}

# Seguranca
ssl = {{ postgresql_ssl }}
password_encryption = scram-sha-256

# Logging
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_min_duration_statement = {{ postgresql_log_min_duration_statement }}
log_connections = on
log_disconnections = on
log_statement = '{{ postgresql_log_statement | default("ddl") }}'
```

### Inventario Dinamico com Terraform Outputs

```python
#!/usr/bin/env python3
# inventory/terraform_inventory.py
import subprocess, json

def get_terraform_outputs():
    result = subprocess.run(
        ['terraform', '-chdir=terraform/environments/prod', 'output', '-json'],
        capture_output=True, text=True
    )
    return json.loads(result.stdout)

outputs = get_terraform_outputs()
inventory = {
    'postgresql': {
        'hosts': [outputs['postgres_endpoint']['value']],
        'vars': {
            'ansible_user': 'ubuntu',
            'postgresql_version': '16'
        }
    }
}
print(json.dumps(inventory))
```

---

## GitOps para Bancos de Dados

### Fluxo GitOps

```
Developer                  Git Repository           CI/CD Pipeline          Database
    │                           │                        │                     │
    ├── create branch ──────────►                        │                     │
    ├── edit migration file ────►                        │                     │
    ├── open Pull Request ──────►                        │                     │
    │                           ├── run schema tests ───►                     │
    │                           ├── security scan ──────►                     │
    │                           │   (lint + SAST)        │                     │
    ├── peer review ────────────►                        │                     │
    ├── approve PR ─────────────►                        │                     │
    │                           ├── merge to main ───────►                     │
    │                           │                        ├── deploy to staging►│
    │                           │                        ├── run tests ────────►│
    │                           │                        ├── deploy to prod ───►│
    │                           │                        │                     │
```

### Branch Strategy para Schema

```
main ─────────────────────────────────────────────────►
  │                                                    │
  ├── feature/add-user-table ─► PR ─► merge ──────────►
  ├── fix/index-performance ───► PR ─► merge ──────────►
  └── release/v2.1 ────────────► tag ─► deploy ────────►
```

---

## CI/CD Pipeline para Bancos de Dados

### Stages do Pipeline

```yaml
# .gitlab-ci.yml ou GitHub Actions example

stages:
  - validate
  - test
  - security
  - deploy-staging
  - deploy-prod

# Stage 1: Validacao de schema
validate-schema:
  stage: validate
  script:
    - flyway validate -url=jdbc:postgresql://dev-db:5432/mydb
    - sqlfluff lint migrations/ --dialect postgres

# Stage 2: Testes automaticos
test-migrations:
  stage: test
  services:
    - postgres:16
  script:
    - flyway migrate -url=jdbc:postgresql://localhost:5432/testdb
    - python tests/test_schema.py
    - python tests/test_data_integrity.py

# Stage 3: Varredura de seguranca
security-scan:
  stage: security
  script:
    - sqlcheck -v migrations/  # detecta SQL injection patterns
    - checkov -d terraform/ --framework terraform  # IaC security

# Stage 4: Deploy staging
deploy-staging:
  stage: deploy-staging
  script:
    - ansible-playbook -i inventory/staging playbooks/migrate.yml
    - python tests/smoke_tests.py --env staging
  only:
    - main

# Stage 5: Deploy prod (com aprovacao manual)
deploy-prod:
  stage: deploy-prod
  script:
    - ansible-playbook -i inventory/prod playbooks/migrate.yml
    - python tests/smoke_tests.py --env prod
  when: manual
  only:
    - main
```

---

## Liquibase — Gerenciamento de Schema

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
</databaseChangeLog>
```

```xml
<!-- db/changelog/v1/001-create-users.xml -->
<databaseChangeLog ...>
    <changeSet id="001" author="gustavo">
        <createTable tableName="user_account">
            <column name="user_account_id" type="BIGINT" autoIncrement="true">
                <constraints primaryKey="true" nullable="false"/>
            </column>
            <column name="email" type="VARCHAR(255)">
                <constraints unique="true" nullable="false"/>
            </column>
            <column name="created_at" type="TIMESTAMPTZ" defaultValueComputed="NOW()">
                <constraints nullable="false"/>
            </column>
        </createTable>

        <rollback>
            <dropTable tableName="user_account"/>
        </rollback>
    </changeSet>
</databaseChangeLog>
```

---

## Secrets Management

### Nunca em codigo ou repositorio
```bash
# ERRADO — nunca fazer isso:
postgresql_password: "minhasenha123"  # em YAML comitado no Git

# CORRETO — referenciar o secret manager:
postgresql_password: "{{ lookup('aws_ssm', '/prod/postgres/password') }}"
```

### Ansible Vault (para segredos locais)
```bash
# Criar arquivo de segredos criptografado
ansible-vault create group_vars/prod/vault.yml

# Editar segredos criptografados
ansible-vault edit group_vars/prod/vault.yml

# Executar playbook com vault
ansible-playbook site.yml --vault-password-file ~/.vault_pass
```

### HashiCorp Vault (para ambientes enterprise)
```yaml
# Exemplo: buscar credencial do Vault no Ansible
- name: Get database credentials from Vault
  community.hashi_vault.vault_read:
    path: "secret/data/prod/postgres"
    auth_method: approle
    role_id: "{{ vault_role_id }}"
    secret_id: "{{ vault_secret_id }}"
  register: db_creds

- name: Configure application
  template:
    src: app.conf.j2
    dest: /etc/app/app.conf
  vars:
    db_password: "{{ db_creds.data.data.password }}"
```

---

## Checklist DevOps para Bancos de Dados

### Repositorio
- [ ] Todo arquivo de configuracao de banco em repositorio Git
- [ ] Branches protegidas (nao pode pushear diretamente em main)
- [ ] PR obrigatorio com minimo 1 revisor
- [ ] Nenhum secret em texto plano no repositorio

### Pipeline CI/CD
- [ ] Validacao de syntax de migration no CI
- [ ] Testes automaticos de schema em banco efemero
- [ ] Scan de seguranca automatico (SQLCheck, Checkov, Trivy)
- [ ] Deploy automatico em staging; manual em prod
- [ ] Smoke tests automaticos pos-deploy

### Terraform
- [ ] State armazenado remotamente (S3 + DynamoDB)
- [ ] `terraform plan` em PR antes do apply
- [ ] Deletion protection habilitado em recursos de banco de producao
- [ ] Tags obrigatorias: environment, team, cost-center, banco

### Ansible
- [ ] Roles idempotentes (playbook pode ser re-executado)
- [ ] Variaveis de ambiente separadas por env (group_vars/)
- [ ] Handlers para restart/reload apenas quando necessario
- [ ] Molecule para testes de roles

### Monitoramento de Mudancas
- [ ] Alertas de mudanca de schema em producao (DDL audit)
- [ ] Integracao com CMDB para registrar versao do banco
- [ ] Notificacao no canal de operacoes para todo deploy em producao
