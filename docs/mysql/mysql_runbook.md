# MySQL — Runbook Operacional AWX

Guia prático para executar operações de gestão de usuários MySQL via AWX Job Templates.

> **Para iniciantes:** Este runbook contém os passos exatos para criar, modificar e remover usuários no MySQL usando o AWX. Você não precisará digitar comandos no servidor — basta preencher o formulário (survey) e clicar em "Launch".

---

## Pré-requisitos

Antes de executar qualquer job:

1. **MySQL instalado** em `mysqlvm` (192.168.137.160, porta 13306)
2. **AWX sincronizado** com o repositório GitHub (`gustavo-awx` project)
3. **Credencial Machine** configurada no AWX (usuário `user_aap`)
4. **Job Template** configurado com o survey correto

---

## Job Template AWX — Configuração

Para o playbook `manage_mysql_users.yml`:

| Campo AWX | Valor |
|---|---|
| **Name** | `MYSQL \| Manage Users` |
| **Playbook** | `playbooks/manage_mysql_users.yml` |
| **Inventory** | `LINUX` |
| **Credentials** | `Machine: user_aap` |
| **Limit** | `mysqlvm` |
| **Extra Variables** | `mysql_manage_users_enabled: true` |
| **Survey** | Associar `awx_survey_mysql_manage_users.json` |

---

## Tag Map — O que Cada Tag Faz

| Tag | O que executa | Quando usar |
|---|---|---|
| `mysql` | Todas as tasks MySQL | Raramente — muito abrangente |
| `mysql_install` | Instala e configura o servidor | Primeira instalação |
| `mysql_users` | Todo o ciclo de gestão de usuários | Operação padrão |
| `mysql_users_validate` | Valida variáveis de entrada | Debug de erros |
| `mysql_db` | Cria/remove bancos de dados | Isolado com manage_databases=true |
| `mysql_grants` | Concede privilégios | Adicionar acesso a novo banco |
| `mysql_revoke` | Revoga privilégios | Remover acesso sem deletar usuário |
| `mysql_remove_user` | Remove o usuário | Quando state=absent |
| `db_patches` | Descoberta de patches | Verificação de patches |

---

## Cenários de Uso

### Cenário 1: Criar usuário de leitura para aplicação

**Situação:** Aplicação precisa ler dados do banco `appdb`.

| Campo | Valor |
|---|---|
| MySQL username | `webapp_reader` |
| Host de acesso | `%` |
| Password | `Reader#2024!` |
| User state | `present` |
| Privileges | `SELECT` |
| Target databases | `appdb` |
| Revoke access | `false` |
| Append privileges | `true` |
| Create databases | `false` |

**SQL equivalente:**
```sql
CREATE USER 'webapp_reader'@'%' IDENTIFIED BY '***';
GRANT SELECT ON appdb.* TO 'webapp_reader'@'%';
FLUSH PRIVILEGES;
```

---

### Cenário 2: Criar usuário com escrita completa

**Situação:** Serviço precisa ler e escrever no banco.

| Campo | Valor |
|---|---|
| MySQL username | `webapp` |
| Host de acesso | `192.168.1.50` |
| Password | `App#Secure2024!` |
| User state | `present` |
| Privileges | `SELECT,INSERT,UPDATE,DELETE` |
| Target databases | `appdb` |
| Revoke access | `false` |
| Append privileges | `false` |
| Create databases | `false` |

> **Nota:** `Append privileges: false` substitui todos os grants existentes pelos novos. Use quando quiser garantir exatamente os privilégios definidos.

---

### Cenário 3: Criar banco + usuário ao mesmo tempo

**Situação:** Nova aplicação do zero — banco e usuário ainda não existem.

| Campo | Valor |
|---|---|
| MySQL username | `newapp` |
| Host de acesso | `%` |
| Password | `NewApp#2024` |
| User state | `present` |
| Privileges | `SELECT,INSERT,UPDATE,DELETE` |
| Target databases | `newappdb` |
| Revoke access | `false` |
| Append privileges | `true` |
| **Create databases** | `true` |

**Ordem de execução:**
1. Cria o banco `newappdb`
2. Cria o usuário `newapp`
3. Concede `SELECT,INSERT,UPDATE,DELETE` em `newappdb.*`

---

### Cenário 4: Revogar acesso sem remover usuário

**Situação:** Usuário não deve mais ter acesso ao banco, mas a conta deve continuar existindo.

| Campo | Valor |
|---|---|
| MySQL username | `webapp` |
| Host de acesso | `%` |
| Password | *(deixar vazio)* |
| User state | `present` |
| Privileges | `SELECT,INSERT` |
| Target databases | `appdb` |
| **Revoke access** | `true` |
| Append privileges | `true` |
| Create databases | `false` |

```sql
-- Executado pelo playbook:
REVOKE SELECT, INSERT ON appdb.* FROM 'webapp'@'%';
```

---

### Cenário 5: Remover usuário completamente

**Situação:** Funcionário saiu — remover conta do banco.

| Campo | Valor |
|---|---|
| MySQL username | `webapp` |
| Host de acesso | `%` |
| Password | *(qualquer valor)* |
| **User state** | `absent` |
| Privileges | `SELECT` |
| Target databases | `appdb` |
| Revoke access | `false` |
| Append privileges | `true` |
| Create databases | `false` |

```sql
-- Executado pelo playbook:
DROP USER 'webapp'@'%';
```

---

## Checklist de Verificação Pós-Job

```bash
# SSH no servidor MySQL
ssh user_aap@192.168.137.160

# Verificar usuário criado
mysql -u root -p -e "SELECT user, host FROM mysql.user WHERE user='webapp';"

# Verificar privilégios
mysql -u root -p -e "SHOW GRANTS FOR 'webapp'@'%';"

# Testar conexão com o novo usuário
mysql -u webapp -p -h 192.168.137.160 -P 13306 appdb -e "SHOW TABLES;"
```

---

## Troubleshooting de Jobs

### Job falha: `A MySQL module is required`

**Causa:** PyMySQL não instalado.

```bash
# Instalar no servidor:
sudo dnf install python3-PyMySQL     # RHEL
sudo apt install python3-pymysql     # Debian
```

---

### Usuário criado mas não consegue conectar

**Causa comum 1:** Host do usuário não corresponde ao IP de origem.
```sql
-- Verificar como o usuário foi criado:
SELECT user, host FROM mysql.user WHERE user='webapp';
-- Se mostra 'webapp'@'192.168.1.50' mas app conecta de outro IP, é o problema.
```

**Causa comum 2:** Porta errada. MySQL está em `13306`, não em `3306`.
```bash
mysql -u webapp -p -h 192.168.137.160 -P 13306 appdb
#                                              ^ porta não padrão
```

---

### AWX não encontra o host `mysqlvm`

**Causa:** Inventory não sincronizado.

**Solução:**
1. AWX → Inventories → LINUX → Sync
2. Verificar se `mysqlvm` (192.168.137.160) está acessível: `ping 192.168.137.160`

---

## Execução via CLI (fora do AWX)

```bash
ansible-playbook playbooks/manage_mysql_users.yml \
  -l mysqlvm \
  -e "mysql_manage_users_enabled=true" \
  -e "db_username=webapp" \
  -e "db_user_host=%" \
  -e "db_password=App#Secure2024!" \
  -e "db_user_state=present" \
  -e "db_privileges=SELECT,INSERT,UPDATE,DELETE" \
  -e "db_target_databases=appdb" \
  -e "db_revoke_access=false" \
  -e "db_append_privileges=true" \
  -e "db_manage_databases=false"
```

---

---

## MYSQL | Configuration Check

### Visão Geral

Job Template **JT 28 — `MYSQL | Configuration Check`** executa 19 verificações automatizadas divididas em 3 categorias. Auto-corrige tudo que é possível online; itens que exigem restart são aplicados em config + restart único ao final.

**Playbook:** `playbooks/mysql_configuration_check.yml`
**Role:** `roles/mysql_configuration_check/`

---

### AWX Job Template — Configuração

| Campo AWX | Valor |
|---|---|
| **Name** | `MYSQL \| Configuration Check` |
| **Playbook** | `playbooks/mysql_configuration_check.yml` |
| **Inventory** | `LINUX` |
| **Credentials** | `Machine: user_aap` |
| **Limit** | `mysqlvm` (ou host alvo) |
| **Become** | `true` |

**Extra Variables padrão:**
```yaml
mysql_configuration_check_remediate: true      # false = só verifica, não corrige
mysql_configuration_check_allow_restart: true  # false = não reinicia o MySQL
mysql_generate_report: true                    # gera HTML em /tmp/ e fetcha para reports/
mysql_root_password: "Admin#!123"              # senha root (override por ambiente)
```

---

### Mapa de Checks — 19 verificações

| ID | Check | Categoria | Auto-fix? | Restart? |
|---|---|---|---|---|
| 1 | `skip_show_database = ON` | Config | ✅ | ✅ |
| 2 | `validate_password` plugin ativo + params | Config | ✅ | — |
| 3 | Softlink DB SW HOME | Config | ❌ manual | — |
| 4 | `innodb_log_file_size` 512M–1024M | Config | ✅ | ✅ |
| 5 | `innodb_io_capacity >= 1000` | Config | ✅ SET PERSIST | — |
| 6 | `innodb_read/write_io_threads >= 8` | Config | ✅ | ✅ |
| 6b | `tmpdir` separado de `/` | Config | ❌ manual | — |
| 7 | `open_files_limit >= 65536` | Config | ✅ | ✅ |
| 8 | `.mysql_history → /dev/null` | Config | ✅ | — |
| 9 | `vm.swappiness = 1` | Config | ✅ sysctl | — |
| 10 | `local_infile = OFF` | Defect/Error | ✅ SET PERSIST | — |
| 11 | Contas vulneráveis (user/host/pass vazio) | Defect/Error | ❌ manual | — |
| 12 | `max_connect_errors >= 10000` | Defect/Error | ✅ SET PERSIST | — |
| 12b | `skip_name_resolve = ON` | Defect/Error | ✅ | ✅ |
| 13 | Slow log habilitado + `long_query_time` 1–3s | Performance | ✅ SET PERSIST | — |
| 14 | Key Cache Hit Ratio >= 98% (MyISAM) | Performance | ❌ monitor | — |
| 15 | `innodb_buffer_pool_size` 50–70% RAM | Performance | ✅ SET PERSIST | — |
| 16 | `table_open_cache >= max_connections × 5` | Performance | ✅ SET PERSIST | — |
| 17 | `innodb_print_all_deadlocks = ON` | Performance | ✅ SET PERSIST | — |

---

### Resultado do Lab — mysqlvm (2026-06-03, MySQL 8.0.45)

| # | Status | Valor anterior | Valor corrigido |
|---|---|---|---|
| 1 | FAIL → config+restart | OFF | ON |
| 2 | ✅ PASS | — | — |
| 3 | ✅ PASS | — | — |
| 4 | FAIL → config+restart | 48 MB | 512 MB |
| 5 | ✅ PASS | 1000 | — |
| 6 | FAIL → config+restart | read=4 write=4 | 8/8 |
| 6b | FAIL — manual | `/var/tmp` em `/` | — |
| 7 | FAIL → config+restart | 10000 | 65536 |
| 8 | ✅ PASS | — | — |
| 9 | FAIL → FIXED | 30 | 1 |
| 10 | ✅ PASS | — | — |
| 11 | ✅ PASS | 0 contas | — |
| 12 | FAIL → FIXED | 100 | 10000 |
| 12b | FAIL → FIXED+restart | OFF | ON |
| 13 | FAIL → FIXED | desabilitado, 10s | habilitado, 3s |
| 14 | ✅ PASS | 100% | — |
| 15 | FAIL → FIXED | 128 MB | 2 GB (60% de 3.6 GB RAM) |
| 16 | ✅ PASS | 4000 ≥ 755 | — |
| 17 | FAIL → FIXED | OFF | ON |

**Totais:** 19 checks — 8 PASS / 6 auto-fixed / 5 manual (restart ativou os demais)

---

### Itens Manuais — Ação Necessária

#### 6b — tmpdir separado de `/`
MySQL usa `/var/tmp` por padrão que está na raiz. Em produção provisionar volume dedicado:
```ini
# /etc/my.cnf — após criar e montar /data/mysql_tmp
tmpdir = /data/mysql_tmp
```
Depois reiniciar MySQL.

#### 3 — Softlink DB SW HOME
Configurar MYSQL_HOME via `alternatives` para facilitar upgrade de versão:
```bash
alternatives --set mysql /usr/bin/mysql-8.0
```
(Verificar nomes exatos com `alternatives --list`)

#### 11 — Contas vulneráveis
Verificar periodicamente:
```sql
SELECT user, host,
       IF(authentication_string = '' OR authentication_string IS NULL, 'EMPTY', 'SET') AS auth
FROM mysql.user
WHERE user = '' OR host = '' OR authentication_string = '' OR authentication_string IS NULL;
```
Deletar ou corrigir qualquer resultado.

#### 14 — Key Cache Hit Ratio (MyISAM)
Se tabelas MyISAM em uso e ratio < 98%, aumentar `key_buffer_size`:
```ini
# /etc/my.cnf — para servidor com 64 GB RAM:
key_buffer_size = 12G
```

---

### Execução via CLI

```bash
# Check-only (sem corrigir nada):
ansible-playbook playbooks/mysql_configuration_check.yml \
  -l mysqlvm \
  -e "mysql_configuration_check_remediate=false" \
  -e "mysql_root_password=Admin#!123"

# Check + fix, sem restart automático:
ansible-playbook playbooks/mysql_configuration_check.yml \
  -l mysqlvm \
  -e "mysql_configuration_check_remediate=true" \
  -e "mysql_configuration_check_allow_restart=false" \
  -e "mysql_root_password=Admin#!123"

# Tag específica (só verificar buffer pool):
ansible-playbook playbooks/mysql_configuration_check.yml \
  -l mysqlvm --tags perf_15 \
  -e "mysql_root_password=Admin#!123"
```

---

### Variáveis Defaults (override por ambiente)

Arquivo: `roles/mysql_configuration_check/defaults/main.yml`

| Variável | Default | Quando alterar |
|---|---|---|
| `mysql_root_password` | `""` | Sempre em produção |
| `mysql_configuration_check_remediate` | `true` | `false` para auditoria sem mudanças |
| `mysql_configuration_check_allow_restart` | `true` | `false` em janela sem restart permitida |
| `mysql_innodb_log_file_size_target` | `512M` | Aumentar para `1G` em servidores com + RAM |
| `mysql_buffer_pool_pct_target` | `60` | Ajustar 50–70 conforme workload |
| `mysql_long_query_time_target` | `3` | Reduzir para `1` em apps de baixa latência |
| `mysql_no_history_users` | `[root, mysql]` | Adicionar outros DBAs |
| `mysql_open_files_limit_target` | `65536` | Manter para produção |

---

## Ver Também

- [`mysql_guide.md`](mysql_guide.md) — Documentação técnica completa
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
- [`general_guide.md`](general_guide.md) — Arquitetura geral do projeto
