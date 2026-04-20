# Guia de Segurança e Configuração Oracle

Referência para os dois playbooks de auditoria e hardening Oracle: verificação de configuração operacional e checklist de segurança.

Parte do conjunto: [`general_guide.md`](general_guide.md) · [`oracle_guide.md`](oracle_guide.md) · [`oracle_runbook.md`](oracle_runbook.md) · [`utility_playbooks_guide.md`](utility_playbooks_guide.md)

---

## Índice

| Playbook | Role | O que faz |
|---|---|---|
| [`oracle_configuration_check.yml`](#oracle_configuration_checkyml) | `oracle_configuration_check` | Verifica e corrige configurações operacionais (conf/error/avail/perf/op) |
| [`oracle_security_check.yml`](#oracle_security_checkyml) | `oracle_security_check` | Auditoria de segurança Oracle (contas, senhas, acesso, serviços, patches) |

---

## oracle_configuration_check.yml

### O que faz

Executa verificações de configuração Oracle cobrindo 5 grupos (27 itens). Cada item pode **checar e corrigir** (`oracle_security_remediate: true`, padrão) ou apenas **reportar** (`oracle_security_remediate: false`).

```
oracle_configuration_check.yml
    └── role: oracle_configuration_check
            ├── Grupo 1 (sec_conf)  — Configuração (sec_1.1 – sec_1.10)
            ├── Grupo 2 (sec_err)   — Defeitos e Erros (sec_2.1 – sec_2.5)
            ├── Grupo 3 (sec_avail) — Disponibilidade (sec_3.1 – sec_3.3)
            ├── Grupo 4 (sec_perf)  — Performance (sec_4.1 – sec_4.4)
            └── Grupo 5 (sec_op)    — Operação (sec_5.1 – sec_5.7)
```

### Grupos e Itens

#### Grupo 1 — Configuração (`sec_conf`)

| Item | Tag | O que verifica / corrige |
|---|---|---|
| sec_1.1 | `sec_1_1` | AUD$ table → move para tablespace dedicado (`oracle_audit_tablespace`) |
| sec_1.2 | `sec_1_2` | DBA role — lista grantees; alerta se não estiver em `oracle_dba_role_approved_users` |
| sec_1.3 | `sec_1_3` | oradism — verifica permissões do binário `/usr/bin/oradism` |
| sec_1.4 | `sec_1_4` | vm.swappiness — verifica e corrige via sysctl |
| sec_1.5 | `sec_1_5` | SELinux — verifica estado (enforcing/permissive/disabled) |
| sec_1.6 | `sec_1_6` | Transparent Huge Pages — verifica e desabilita |
| sec_1.7 | `sec_1_7` | Logon delay — verifica `SEC_CONNECTION_ALLOWED_VERSION_LIST` |
| sec_1.8 | `sec_1_8` | Cleanup rollback — verifica `UNDO_RETENTION` |
| sec_1.9 | `sec_1_9` | Deferred segment creation — verifica `DEFERRED_SEGMENT_CREATION` |
| sec_1.10 | `sec_1_10` | System state dump — verifica `_disable_system_state_dump` |

#### Grupo 2 — Defeitos e Erros (`sec_err`)

| Item | Tag | O que verifica |
|---|---|---|
| sec_2.1 | `sec_2_1` | `_rowsets_enabled` — workaround para bug de rowsets |
| sec_2.2 | `sec_2_2` | Drop segment stats — verifica `_drop_stat_segment_enabled` |
| sec_2.3 | `sec_2_3` | LSLT bug — verifica `_latch_slta_disable_lslt` |
| sec_2.4 | `sec_2_4` | Memória mínima livre — verifica `vm.min_free_kbytes` >= `oracle_min_free_kbytes` |
| sec_2.5 | `sec_2_5` | Listener log — verifica erros no listener.log >= `oracle_listener_error_threshold` |

#### Grupo 3 — Disponibilidade (`sec_avail`)

| Item | Tag | O que verifica |
|---|---|---|
| sec_3.1 | `sec_3_1` | RAC config — verifica `CLUSTER_DATABASE` |
| sec_3.2 | `sec_3_2` | Dual archive dest — verifica `LOG_ARCHIVE_DEST_2` (valor em `oracle_archive_dest_2`) |
| sec_3.3 | `sec_3_3` | Server redundancy — verifica `STANDBY_FILE_MANAGEMENT` |

#### Grupo 4 — Performance (`sec_perf`)

| Item | Tag | O que verifica |
|---|---|---|
| sec_4.1 | `sec_4_1` | Checkpoint — verifica `FAST_START_MTTR_TARGET` |
| sec_4.2 | `sec_4_2` | PGA limit — verifica `PGA_AGGREGATE_LIMIT` >= `oracle_pga_max_size_gb` GB |
| sec_4.3 | `sec_4_3` | Parallel adaptive — verifica `PARALLEL_DEGREE_POLICY` |
| sec_4.4 | `sec_4_4` | Filesystem I/O — verifica `FILESYSTEMIO_OPTIONS` = SETALL |

#### Grupo 5 — Operação (`sec_op`)

| Item | Tag | O que verifica |
|---|---|---|
| sec_5.1 | `sec_5_1` | User account lock — verifica profiles em `oracle_app_profiles` |
| sec_5.2 | `sec_5_2` | DBA registry — verifica `DBA_REGISTRY` (componentes inválidos) |
| sec_5.3 | `sec_5_3` | OS Watcher — verifica se oswtbb está rodando em `oracle_osw_path` |
| sec_5.4 | `sec_5_4` | NOLOGGING — lista objetos criados com NOLOGGING |
| sec_5.5 | `sec_5_5` | Full backup — verifica última execução de backup completo via RMAN |
| sec_5.6 | `sec_5_6` | Controlfile backup — verifica `CONTROL_FILE_RECORD_KEEP_TIME` |
| sec_5.7 | `sec_5_7` | AWR config — verifica `DBMS_WORKLOAD_REPOSITORY` retention e intervalo |

### Como executar

```bash
# Executar todos os itens (remediação ativa por padrão):
ansible-playbook playbooks/oracle_configuration_check.yml -l oraclevm

# Modo somente leitura (sem ALTER/correções):
ansible-playbook playbooks/oracle_configuration_check.yml \
  -e "oracle_security_remediate=false" -l oraclevm

# Executar grupo específico (ex: performance):
ansible-playbook playbooks/oracle_configuration_check.yml \
  --tags sec_perf -l oraclevm

# Executar item específico (ex: sec_1.4 swappiness):
ansible-playbook playbooks/oracle_configuration_check.yml \
  --tags sec_1_4 -l oraclevm

# SID diferente do padrão TSTOR:
ansible-playbook playbooks/oracle_configuration_check.yml \
  -e "oracle_sid=PROD oracle_home=/oracle/PROD/19.0.0" -l oraclevm
```

### Variáveis — `roles/oracle_configuration_check/defaults/main.yml`

| Variável | Padrão | Descrição |
|---|---|---|
| `oracle_sid` | `ORCL` | SID do banco alvo |
| `oracle_home` | `/oracle/{{ oracle_sid }}/19.0.0` | ORACLE_HOME |
| `oracle_base` | `/oracle` | ORACLE_BASE |
| `oracle_os_user` | `oracle` | Usuário OS do Oracle |
| `oracle_security_remediate` | `true` | Se `false`, apenas reporta sem corrigir |
| `oracle_security_allow_restart` | `false` | Permite reiniciar DB se necessário para aplicar parâmetro |
| `oracle_audit_tablespace` | `AUDIT_TS` | Tablespace destino para AUD$ (sec_1.1) |
| `oracle_dba_role_approved_users` | `[]` | Lista de usuários aprovados para ter DBA (sec_1.2) |
| `oracle_min_free_kbytes` | `524288` | Mínimo vm.min_free_kbytes em KB (sec_2.4) |
| `oracle_listener_error_threshold` | `10` | Máximo de erros no listener.log antes de alertar (sec_2.5) |
| `oracle_archive_dest_2` | `""` | LOG_ARCHIVE_DEST_2 esperado (sec_3.2) |
| `oracle_pga_max_size_gb` | `1` | PGA_AGGREGATE_LIMIT mínimo em GB (sec_4.2) |
| `oracle_app_profiles` | `[]` | Profiles de aplicação para verificar lock (sec_5.1) |
| `oracle_osw_path` | `/oracle/{{ oracle_sid }}/OSW/OSWbb` | Caminho do OS Watcher (sec_5.3) |
| `oracle_osw_interval` | `30` | Intervalo OSWbb em segundos |
| `oracle_osw_archive_hours` | `720` | Retenção OSWbb em horas (30 dias) |
| `oracle_awr_retention_days` | `35` | Retenção AWR em dias (sec_5.7) |
| `oracle_awr_interval_min` | `20` | Intervalo AWR em minutos (sec_5.7) |

---

## oracle_security_check.yml

### O que faz

Auditoria de segurança Oracle cobrindo 6 grupos (19 itens, items 1.1–6.1.2). Pode operar em modo **check-only** (sem alterações) ou **remediação** (aplica ALTER, REVOKE onde configurado).

```
oracle_security_check.yml
    └── role: oracle_security_check
            ├── Grupo 1 (oracle_account)  — Gerenciamento de Contas (1.1–1.3)
            ├── Grupo 2 (oracle_password) — Política de Senhas (2.1–2.4b)
            ├── Grupo 3 (oracle_access)   — Controle de Acesso (3.1–3.3)
            ├── Grupo 4 (oracle_service)  — Gerenciamento de Serviços (4.1–4.4)
            ├── Grupo 5 (oracle_audit)    — Auditoria (5.1)
            ├── Grupo 6 (oracle_patches)  — Patches (6.1.1–6.1.2)
            └── Summary (oracle_report)   — Relatório final
```

> **Pré-requisito:** `oracle_home/bin/sqlplus` deve existir no host. O playbook valida antes de executar.

### Grupos e Itens

#### Grupo 1 — Gerenciamento de Contas (`oracle_account`)

| Item | Tag | O que verifica / corrige |
|---|---|---|
| 1.1 | `item_1_1` | Lista todos os usuários Oracle (account_status) |
| 1.2 | `item_1_2` | Enforce `FAILED_LOGIN_ATTEMPTS` <= `oracle_security_failed_login_attempts` (padrão: 5) |
| 1.3 | `item_1_3` | Detecta contas sample/default (SCOTT, DEMO, ADAMS, etc.) |

#### Grupo 2 — Política de Senhas (`oracle_password`)

| Item | Tag | O que verifica / corrige |
|---|---|---|
| 2.1 | `item_2_1` | Deploy e enforce `PASSWORD_VERIFY_FUNCTION` |
| 2.2 | `item_2_2` | Verifica senhas padrão conhecidas (SYS/manager, SCOTT/tiger, etc.) |
| 2.3 | `item_2_3` | Enforce `PASSWORD_LIFE_TIME` <= `oracle_security_password_life_time` (padrão: 90 dias) |
| 2.4A | `item_2_4a` | Enforce `PASSWORD_REUSE_MAX` <= `oracle_security_password_reuse_max` (padrão: 1) |
| 2.4B | `item_2_4b` | Enforce `PASSWORD_REUSE_TIME` >= `oracle_security_password_reuse_time` (padrão: 180 dias) |

#### Grupo 3 — Controle de Acesso (`oracle_access`)

| Item | Tag | O que verifica / corrige |
|---|---|---|
| 3.1 | `item_3_1` | Verifica `sqlnet.ora` TCP.INVITED_NODES; aplica IPs de `oracle_security_allowed_ips` |
| 3.2A | `item_3_2a` | Lista grantees do role DBA |
| 3.2B | `item_3_2b` | Lista grantees de system privileges perigosas (GRANT ANY PRIVILEGE, SYSDBA, etc.) |
| 3.3 | `item_3_3` | Verifica e corrige permissões de arquivos do sistema Oracle |

#### Grupo 4 — Gerenciamento de Serviços (`oracle_service`)

| Item | Tag | O que verifica |
|---|---|---|
| 4.1 | `item_4_1` | Verifica EXECUTE ON UTL_* grants ao PUBLIC; revoga se `oracle_security_revoke_utl_public: true` |
| 4.2 | `item_4_2` | Lista database links existentes |
| 4.3 | `item_4_3` | Verifica porta do listener — alerta se porta padrão 1521 |
| 4.4 | `item_4_4` | Lista tabelas de backup/temporárias |

#### Grupo 5 — Auditoria (`oracle_audit`)

| Item | Tag | O que verifica |
|---|---|---|
| 5.1 | `item_5_1` | Verifica status do listener log |

#### Grupo 6 — Patches (`oracle_patches`)

| Item | Tag | O que verifica |
|---|---|---|
| 6.1.1 | `item_6_1_1` | Executa `opatch lsinventory` — lista patches instalados |
| 6.1.2 | `item_6_1_2` | Verifica versão Oracle contra `oracle_security_known_eos_versions` |

### Como executar

```bash
# Auditoria completa — somente leitura (padrão):
ansible-playbook playbooks/oracle_security_check.yml \
  -e "oracle_security_check_only=true" -l oraclevm

# Auditoria com remediação ativa (altera profiles, revoga se configurado):
ansible-playbook playbooks/oracle_security_check.yml -l oraclevm

# Executar grupo específico (ex: política de senhas):
ansible-playbook playbooks/oracle_security_check.yml \
  --tags oracle_password -l oraclevm

# Item específico (ex: verificar senhas padrão):
ansible-playbook playbooks/oracle_security_check.yml \
  --tags item_2_2 -l oraclevm

# Incluir lista de IPs permitidos no sqlnet.ora (item 3.1):
ansible-playbook playbooks/oracle_security_check.yml \
  -e '{"oracle_security_allowed_ips": ["192.168.137.0/24", "10.0.0.5"]}' \
  -l oraclevm

# Habilitar revogação de UTL_* do PUBLIC (item 4.1):
ansible-playbook playbooks/oracle_security_check.yml \
  --tags item_4_1 \
  -e "oracle_security_revoke_utl_public=true" -l oraclevm

# SID diferente:
ansible-playbook playbooks/oracle_security_check.yml \
  -e "oracle_sid=PROD oracle_home=/oracle/PROD/19.0.0" -l oraclevm
```

### Variáveis — `roles/oracle_security_check/defaults/main.yml`

| Variável | Padrão | Descrição |
|---|---|---|
| `oracle_sid` | `TSTOR` | SID do banco alvo |
| `oracle_home` | `/oracle/{{ oracle_sid }}/19.0.0` | ORACLE_HOME |
| `oracle_sqlnet_ora` | `{{ oracle_home }}/network/admin/sqlnet.ora` | Caminho do sqlnet.ora |
| `oracle_security_check_only` | `false` | Se `true`, nenhum ALTER/REVOKE é executado |
| `oracle_security_failed_login_attempts` | `5` | Limite de tentativas falhas antes de bloquear conta (item 1.2) |
| `oracle_security_password_life_time` | `90` | Expiração de senha em dias (item 2.3) |
| `oracle_security_password_life_time_exclude_profiles` | `[APPLICATION]` | Profiles isentos da expiração de senha |
| `oracle_security_password_reuse_max` | `1` | Máximo de reusos de senha (item 2.4A) |
| `oracle_security_password_reuse_time` | `180` | Intervalo mínimo em dias para reusar senha (item 2.4B) |
| `oracle_security_allowed_ips` | `[]` | IPs para TCP.INVITED_NODES (append-only, item 3.1) |
| `oracle_security_revoke_utl_public` | `false` | Se `true`, revoga EXECUTE ON UTL_* FROM PUBLIC (item 4.1) |
| `oracle_security_known_eos_versions` | `[]` | Versões Oracle conhecidas como EOS para flag (item 6.1.2) |
| `oracle_security_sample_accounts` | `[SCOTT, DEMO, ADAMS, ...]` | Contas sample a detectar (item 1.3) |

> **Credenciais padrão verificadas (item 2.2):** SYS/change_on_install, SYSTEM/manager, SCOTT/tiger, DBSNMP/dbsnmp, MDSYS/mdsys, e outros 6 pares conhecidos.

> **Privileges perigosas verificadas (item 3.2B):** GRANT ANY PRIVILEGE, SYSDBA, SYSOPER, ALTER SYSTEM, CREATE ANY PROCEDURE, SELECT ANY TABLE, EXECUTE ANY PROCEDURE, e outros 17 privilégios.

---

## Diferença entre os dois playbooks

| Aspecto | `oracle_configuration_check.yml` | `oracle_security_check.yml` |
|---|---|---|
| **Foco** | Configuração operacional, performance, disponibilidade | Segurança: contas, senhas, acesso, serviços |
| **Remediação** | `oracle_security_remediate` (padrão `true`) | `oracle_security_check_only` (padrão `false` = remedia) |
| **Grupos** | conf / err / avail / perf / op | account / password / access / service / audit / patches |
| **Qtd itens** | 27 | 19 |
| **Pré-requisito** | Nenhum além de acesso SSH + become | sqlplus acessível em `oracle_home/bin/sqlplus` |

---

## Ver Também

- [`oracle_guide.md`](oracle_guide.md) — Instalação Oracle 19c (6 fases)
- [`oracle_runbook.md`](oracle_runbook.md) — Runbook operacional Oracle
- [`utility_playbooks_guide.md`](utility_playbooks_guide.md) — Outros playbooks utilitários
- [`awx_surveys.md`](awx_surveys.md) — Surveys AWX
