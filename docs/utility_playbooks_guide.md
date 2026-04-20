# Guia de Playbooks Utilitários

Referência para os playbooks de suporte do projeto: provisionamento unificado, backup/restore, descoberta de patches, conectividade e monitoramento.

Parte do conjunto: [`general_guide.md`](general_guide.md) · [`linux_guide.md`](linux_guide.md) · [`mysql_guide.md`](mysql_guide.md) · [`postgres_guide.md`](postgres_guide.md) · [`oracle_guide.md`](oracle_guide.md)

---

## Índice

| Playbook / Role | O que faz |
|---|---|
| [`01_db_provisioning.yml`](#01_db_provisioningyml) | Provisionamento unificado — seleciona engine via `db_type` |
| [`db_backup_restore_validate.yml`](#db_backup_restore_validateyml) | Backup, restore e validação de dados em sandbox |
| [`db_patch_discovery.yml`](#db_patch_discoveryyml) | Descoberta de patches disponíveis (sem aplicação) |
| [`ping.yml`](#pingyml) | Teste de conectividade cross-platform |
| [`zabbix_installation.yml`](#zabbix_installationyml) | Instalação do Zabbix Agent 5.0 em EL9 |
| [Role `db_index_maintenance`](#role-db_index_maintenance) | Manutenção de índices cross-engine (ANALYZE/VACUUM/REINDEX/REBUILD) |
| [Role `db_log_rotation`](#role-db_log_rotation) | Rotação e limpeza de logs de banco cross-engine |

---

## 01_db_provisioning.yml

### O que faz

Playbook unificado que substitui os `deploy_*.yml` individuais quando o engine de banco é selecionado via survey AWX. O operador passa `db_type` e o playbook decide qual role executar. Útil quando um único Job Template AWX precisa cobrir múltiplos engines.

```
Survey AWX: db_type = "postgres"
    ↓
Playbook seleciona: postgres_install
    ↓ (se postgres_manage_users_enabled=true)
Playbook também executa: postgres_manage_users
```

### Quando usar este vs deploy_*.yml

| Cenário | Playbook recomendado |
|---|---|
| Provisionar MySQL num host específico | `deploy_mysql.yml` — controle total de tags e fases |
| Um template AWX que suporte MySQL, PostgreSQL e Oracle | `01_db_provisioning.yml` — usa `db_type` para selecionar |
| Provisionar Oracle com todas as 6 fases | `deploy_oracle.yml` — suporte completo a tags de fase |

> **Limitação:** `01_db_provisioning.yml` não suporta SQL Server (Windows) nem tem controle de tags por fase. Para Oracle, usa `oracle_install` mas sem as fases granulares do `deploy_oracle.yml`.

### Como executar

```bash
# Provisionamento MySQL:
ansible-playbook playbooks/01_db_provisioning.yml \
  -e "db_type=mysql" -l mysqlvm

# Provisionamento PostgreSQL:
ansible-playbook playbooks/01_db_provisioning.yml \
  -e "db_type=postgres" -l postgresvm

# Provisionamento Oracle:
ansible-playbook playbooks/01_db_provisioning.yml \
  -e "db_type=oracle" -l oraclevm

# PostgreSQL + criar usuários em seguida:
ansible-playbook playbooks/01_db_provisioning.yml \
  -e "db_type=postgres" \
  -e "postgres_manage_users_enabled=true" \
  -e "pg_username=webapp" \
  -e "pg_user_password=App#2024!" \
  -l postgresvm
```

### Variáveis de controle

| Variável | Tipo | Padrão | Obrigatório | Descrição |
|---|---|---|---|---|
| `db_type` | string | — | **Sim** | Engine alvo. Valores: `mysql`, `postgres`, `oracle`. |
| `postgres_manage_users_enabled` | bool | `false` | Não | Se `true`, executa `postgres_manage_users` após `postgres_install`. Só válido com `db_type=postgres`. |

> **Nota:** Para MySQL e Oracle, gestão de usuários não está implementada neste playbook. Usar `manage_mysql_users.yml` ou `manage_oracle_users.yml` após o provisionamento.

---

## db_backup_restore_validate.yml

### O que faz

Executa um ciclo completo de backup → transferência → restore → validação de dados:

```
Host de origem (ex: mysqlvm)
    └── Fase 1: backup do banco db_name → backup_path/
    └── Fase 2: copiar backup para sandbox_host
Sandbox (ex: sandboxvm)
    └── Fase 3: restore do backup
    └── Fase 4: criar tabela de teste (validation_table)
    └── Fase 5: inserir validation_row_count linhas
    └── Fase 6: contar linhas — sucesso se == validation_row_count
```

A validação é destrutiva no sandbox (cria e remove tabela de teste). Nunca afeta o banco de produção.

### Pré-requisito

O `sandbox_host` **deve**:
- Existir no inventário no grupo `[sandbox]`
- Ter o mesmo engine de banco instalado e rodando
- Ter o `backup_path` disponível com espaço suficiente

### Como executar

```bash
# MySQL — backup de appdb no mysqlvm, restore no sandboxvm:
ansible-playbook playbooks/db_backup_restore_validate.yml \
  -e "db_type=mysql db_name=appdb sandbox_host=sandboxvm" \
  -l mysqlvm

# PostgreSQL:
ansible-playbook playbooks/db_backup_restore_validate.yml \
  -e "db_type=postgres db_name=appdb sandbox_host=sandboxvm" \
  -l postgresvm

# Oracle — schema APPUSER no TSTOR:
ansible-playbook playbooks/db_backup_restore_validate.yml \
  -e "db_type=oracle db_schema=APPUSER oracle_sid=TSTOR sandbox_host=sandboxvm" \
  -l oraclevm

# SQL Server — backup para C:\SQLBackups:
ansible-playbook playbooks/db_backup_restore_validate.yml \
  -e "db_type=sqlserver db_name=appdb sandbox_host=sandboxvm" \
  -l sqlservervm

# Dry-run (não faz backup real):
ansible-playbook playbooks/db_backup_restore_validate.yml \
  -e "db_type=mysql db_name=appdb sandbox_host=sandboxvm" \
  -l mysqlvm --check
```

### Variáveis — `roles/db_backup_restore/defaults/main.yml`

| Variável | Tipo | Padrão | Obrigatório | Descrição |
|---|---|---|---|---|
| `db_type` | string | `mysql` | **Sim** | Engine de banco. Valores: `mysql`, `postgres`, `oracle`, `sqlserver`. |
| `db_name` | string | `appdb` | **Sim** | Nome do banco a fazer backup. Para Oracle, use `db_schema`. |
| `sandbox_host` | string | `""` | **Sim** | Hostname do sandbox para restore. Deve estar no grupo `[sandbox]` do inventário. |
| `backup_path` | string | `/opt/backups` | Não | Diretório local no host de origem onde o backup é salvo antes de copiar. |
| `db_schema` | string | `APPUSER` | Não (Oracle) | Nome do schema Oracle a exportar com Data Pump. Não usado por outros engines. |
| `validation_table` | string | `ansible_validate_test` | Não | Nome da tabela temporária criada no sandbox para validação. Removida após o teste. |
| `validation_row_count` | int | `5` | Não | Número de linhas inseridas e contadas na validação. Se count divergir, playbook falha. |
| `oracle_sid` | string | `TSTOR` | Não (Oracle) | SID Oracle do banco de origem. |
| `oracle_home` | string | `/oracle/{{ oracle_sid }}/19.0.0` | Não (Oracle) | ORACLE_HOME do banco de origem. Derivado automaticamente de `oracle_sid`. |
| `oracle_data_pump_dir` | string | `DATA_PUMP_DIR` | Não (Oracle) | Directory Oracle para Data Pump export/import. |
| `oracle_data_pump_path` | string | `/oracle/{{ oracle_sid }}/datapump` | Não (Oracle) | Caminho do sistema de arquivos mapeado ao `oracle_data_pump_dir`. |
| `sql_server_backup_path` | string | `C:\SQLBackups` | Não (SQL Server) | Diretório Windows onde o backup `.bak` é gerado. |

---

## db_patch_discovery.yml

### O que faz

Varre o diretório de patches no `repositoryvm` (192.168.137.148) em busca de arquivos de patch para o engine configurado. **Nunca aplica nada** — `db_patch_apply_enabled` é forçado para `false` no playbook.

O resultado é um relatório dos patches disponíveis (arquivos `.sql`, `.ps1`, `.sh`) encontrados em `/opt/patches/` no host alvo, com informações de nome, tamanho e data.

```
repositoryvm:8080/patches/mysql/
    patch_001_fix_schema.sql
    patch_002_add_index.sql
    ↓
Playbook lista → exibe no AWX/stdout → não aplica
```

### Por que a aplicação está bloqueada

Patches de banco requerem janela de manutenção, backup verificado e review do conteúdo antes de qualquer execução. A flag `db_patch_apply_enabled: false` está hardcoded no playbook via `vars:` — não pode ser sobrescrita por survey AWX. Para aplicar um patch, é necessário executar diretamente via `ansible-playbook -e "db_patch_apply_enabled=true"` de forma explícita e consciente.

### Como executar

```bash
# Descoberta para MySQL:
ansible-playbook playbooks/db_patch_discovery.yml \
  -e "db_patch_platform=mysql" -l mysqlvm

# Descoberta para PostgreSQL:
ansible-playbook playbooks/db_patch_discovery.yml \
  -e "db_patch_platform=postgres" -l postgresvm

# Descoberta para Oracle:
ansible-playbook playbooks/db_patch_discovery.yml \
  -e "db_patch_platform=oracle" -l oraclevm

# Descoberta para SQL Server:
ansible-playbook playbooks/db_patch_discovery.yml \
  -e "db_patch_platform=sqlserver" -l sqlservervm

# Filtrar só arquivos SQL (sobrescrever extensões):
ansible-playbook playbooks/db_patch_discovery.yml \
  -e "db_patch_platform=mysql" \
  -e '{"db_patch_extensions": ["*.sql"]}' \
  -l mysqlvm
```

### Variáveis — `roles/db_patches/defaults/main.yml`

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `db_patch_platform` | string | `generic` | Engine alvo. Valores: `mysql`, `postgres`, `oracle`, `sqlserver`, `generic`. Controla qual subdiretório de patches é varrido. |
| `db_patches_root` | string | `/opt/patches` | Diretório raiz de patches no host alvo. O role varre `{{ db_patches_root }}/{{ db_patch_platform }}/`. |
| `db_patch_apply_enabled` | bool | `false` | **Nunca mudar via survey.** Se `true`, aplica os patches encontrados. Bloqueado para `false` no playbook `db_patch_discovery.yml`. |
| `db_patch_extensions` | list | `[*.sql, *.ps1, *.sh]` | Extensões de arquivo consideradas como patch. |
| `db_patch_repo_host` | string | `192.168.137.148` | IP do repositoryvm onde os patches são servidos por HTTP. |
| `db_patch_repo_port` | int | `8080` | Porta HTTP do repositoryvm. |
| `db_patch_repo_path` | string | `/patches` | Caminho HTTP raiz dos patches no repositoryvm. |

---

## ping.yml

### O que faz

Testa conectividade Ansible com todos os hosts do inventário. Detecta automaticamente o sistema operacional e usa o módulo correto:

- Linux/RHEL: `ansible.builtin.ping` (testa SSH + Python)
- Windows: `ansible.windows.win_ping` (testa WinRM + PowerShell)

Não precisa de `become`. Não instala nada. Retorna `pong` se o host está acessível.

### Como executar

```bash
# Testar todos os hosts:
ansible-playbook playbooks/ping.yml

# Testar um host específico:
ansible-playbook playbooks/ping.yml -l postgresvm

# Testar um grupo:
ansible-playbook playbooks/ping.yml -l database_servers

# Testar Windows:
ansible-playbook playbooks/ping.yml -l sqlservervm

# Ad-hoc equivalente (mais rápido):
ansible all -m ping
ansible postgresvm -m ping
```

### Por que usar este playbook vs `ansible all -m ping`?

O comando ad-hoc `ansible -m ping` usa o módulo Linux e falha em hosts Windows. Este playbook detecta o OS via `ansible_os_family` e usa `win_ping` automaticamente — ideal para verificar inventários mistos (Linux + Windows).

---

## zabbix_installation.yml

### O que faz

Instala e configura o Zabbix Agent 5.0 em hosts EL9 (RHEL 9 / Rocky 9 / AlmaLinux 9) usando o RPM servido pelo `repositoryvm` (sem acesso à internet).

O playbook:
1. Instala o RPM do Zabbix Agent via DNF diretamente da URL interna
2. Configura `Server=` e `ServerActive=` com o IP do servidor Zabbix
3. Configura `Hostname=` com o nome do host via fact `ansible_hostname`
4. Habilita e inicia o serviço `zabbix-agent`

### Como executar

```bash
# Instalar em todos os hosts Linux:
ansible-playbook playbooks/zabbix_installation.yml

# Limitar a um host:
ansible-playbook playbooks/zabbix_installation.yml -l postgresvm

# Sobrescrever servidor Zabbix (outro ambiente):
ansible-playbook playbooks/zabbix_installation.yml \
  -e "zabbix_server_ip=192.168.1.200"

# Sobrescrever URL do RPM:
ansible-playbook playbooks/zabbix_installation.yml \
  -e "zabbix_repo_url=http://192.168.137.148:8080/zabbix/zabbix-agent-5.0.47-1.el9.x86_64.rpm"

# Dry-run:
ansible-playbook playbooks/zabbix_installation.yml --check
```

### Variáveis inline (definidas no próprio playbook)

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `zabbix_server_ip` | string | `192.168.137.159` | IP do servidor Zabbix. Configurado em `Server=` e `ServerActive=` no `zabbix_agentd.conf`. |
| `zabbix_repo_url` | string | `http://192.168.137.148:8080/zabbix/zabbix-agent-5.0.47-1.el9.x86_64.rpm` | URL completa do RPM do Zabbix Agent. Serve do repositoryvm interno — sem acesso à internet. |

> **Nota:** As variáveis equivalentes na role `monitoring_logs` são `zabbix_server` e `zabbix_agent_rpm_url`. O playbook standalone `zabbix_installation.yml` usa vars inline com nomes ligeiramente diferentes, mas o efeito é idêntico.

### Configuração aplicada em `/etc/zabbix/zabbix_agentd.conf`

```ini
Server=192.168.137.159        # IP do servidor Zabbix (ativo e passivo)
ServerActive=192.168.137.159  # Checks ativos — agente conecta ao servidor
Hostname=postgresvm           # ansible_hostname — identifica o host no Zabbix
```

---

---

## Role db_index_maintenance

### O que faz

Executa manutenção de índices em todos os schemas de usuário do engine configurado. Não tem playbook standalone — deve ser incluído via `include_role` ou chamado por um playbook customizado.

| Engine | Operações executadas |
|---|---|
| MySQL | `ANALYZE TABLE` + `OPTIMIZE TABLE` em todos os schemas de usuário |
| PostgreSQL | `VACUUM ANALYZE` + `REINDEX SCHEMA` em todos os schemas de usuário |
| Oracle | `DBMS_STATS.GATHER_SCHEMA_STATS` + rebuild de índices com `blevel > 3` |
| SQL Server | `ALTER INDEX REBUILD` (fragmentação > threshold) + `UPDATE STATISTICS` |

### Como incluir em um playbook

```yaml
- name: "Manutenção de índices MySQL"
  hosts: mysqlvm
  become: true
  roles:
    - role: db_index_maintenance
      vars:
        db_type: mysql

- name: "Manutenção de índices Oracle — schemas específicos"
  hosts: oraclevm
  become: true
  roles:
    - role: db_index_maintenance
      vars:
        db_type: oracle
        oracle_sid: TSTOR
        db_index_target_schemas: ["APPUSER", "REPORTS"]
```

```bash
# Executar via ansible-playbook ad-hoc com include_role não é suportado diretamente.
# Criar um playbook temporário ou adicionar ao deploy_*.yml e rodar com --tags db_index_maintenance.
ansible-playbook playbooks/deploy_mysql.yml \
  --tags db_index_maintenance -l mysqlvm
```

### Variáveis — `roles/db_index_maintenance/defaults/main.yml`

| Variável | Padrão | Descrição |
|---|---|---|
| `db_type` | `mysql` | Engine alvo. Valores: `mysql`, `postgres`, `oracle`, `sqlserver` |
| `db_index_target_schemas` | `[]` | Lista de schemas alvo. Vazio = todos os schemas de usuário |
| `db_index_frag_threshold` | `30` | SQL Server: rebuilda apenas índices com fragmentação% acima deste valor |
| `oracle_sid` | `TSTOR` | SID Oracle (usado para oracle_home automático) |
| `oracle_home` | `/oracle/{{ oracle_sid }}/19.0.0` | ORACLE_HOME |

---

## Role db_log_rotation

### O que faz

Configura rotação e limpeza de logs de banco para o engine configurado. Não tem playbook standalone — deve ser incluído via `include_role` ou chamado por um playbook customizado.

| Engine | O que gerencia |
|---|---|
| Oracle | `alert_*.log` + `listener.log` logrotate; deleta `.trc`/`.trm` mais antigos que `db_log_retention_days` |
| MySQL | Error log + slow query log logrotate; executa `PURGE BINARY LOGS BEFORE N days` |
| PostgreSQL | Define `log_rotation_age/size/filename` em postgresql.conf; logrotate em `pg_log/` |
| SQL Server | `EXEC sp_cycle_errorlog`; PowerShell deleta arquivos de log mais antigos que N dias |

### Como incluir em um playbook

```yaml
- name: "Rotação de logs Oracle"
  hosts: oraclevm
  become: true
  roles:
    - role: db_log_rotation
      vars:
        db_type: oracle
        oracle_sid: TSTOR
        db_log_retention_days: 30

- name: "Rotação de logs PostgreSQL"
  hosts: postgresvm
  become: true
  roles:
    - role: db_log_rotation
      vars:
        db_type: postgres
        db_log_retention_days: 14
```

### Variáveis — `roles/db_log_rotation/defaults/main.yml`

| Variável | Padrão | Descrição |
|---|---|---|
| `db_type` | `oracle` | Engine alvo. Valores: `oracle`, `mysql`, `postgres`, `sqlserver` |
| `db_log_retention_days` | `30` | Dias de retenção de logs. Arquivos mais antigos são deletados |
| `oracle_sid` | `TSTOR` | SID Oracle |
| `oracle_home` | `/oracle/{{ oracle_sid }}/19.0.0` | ORACLE_HOME |
| `db_log_oracle_diag_path` | `/oracle/{{ oracle_sid }}/diag` | Diretório de diagnóstico Oracle |
| `db_log_mysql_error_log` | `/var/log/mysql/mysqld.log` | Caminho do error log MySQL |
| `db_log_mysql_slow_log` | `/var/log/mysql/slow.log` | Caminho do slow query log MySQL |
| `db_log_postgres_path` | `/var/lib/pgsql/data/log` | Diretório de logs PostgreSQL |
| `db_log_sqlserver_path` | `C:\Program Files\...\MSSQL\Log` | Diretório de logs SQL Server (Windows) |

---

## Ver Também

- [`general_guide.md`](general_guide.md) — Arquitetura geral do projeto
- [`linux_guide.md`](linux_guide.md) — Hardening RHEL e configuração de baseline
- [`offline_requirements.md`](offline_requirements.md) — Como preparar ambiente offline (repositoryvm)
- [`awx_surveys.md`](awx_surveys.md) — Surveys AWX para todos os templates
- [`oracle_security_guide.md`](oracle_security_guide.md) — Auditoria e segurança Oracle
