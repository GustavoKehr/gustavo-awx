# Guia Oracle — Ansible & AWX

Referência completa para instalação e gestão de usuários Oracle 19c via Ansible e AWX.

> **Para iniciantes:** Oracle Database é um banco de dados relacional corporativo de alta performance. A instalação Oracle é complexa — este playbook automatiza ~6 horas de trabalho manual em um único comando. Este guia explica cada variável e o que cada fase faz.

Parte do conjunto: [`general_guide.md`](general_guide.md) · [`mysql_guide.md`](mysql_guide.md) · [`postgres_guide.md`](postgres_guide.md) · [`sqlserver_guide.md`](sqlserver_guide.md) · [`oracle_guide.md`](oracle_guide.md)

---

## Conceitos Oracle Antes de Começar

### O que é SID, ORACLE_BASE e ORACLE_HOME?

```
ORACLE_BASE   → Diretório raiz de todas as instalações Oracle no servidor
  └── oracle_sid (TSTOR)
       └── ORACLE_HOME  → Binários desta versão específica (19.0.0)
            ├── bin/        → executáveis (sqlplus, lsnrctl, dbca...)
            ├── OPatch/     → ferramenta de patches
            └── network/admin/  → listener.ora, sqlnet.ora, tnsnames.ora

/etc/oratab → Arquivo que registra os bancos instalados no SO
/etc/oraInst.loc → Localização do inventory Oracle
```

**Neste projeto:**
- `ORACLE_BASE` = `/oracle/<SID>` (dinâmico — ex: `/oracle/AWOR`)
- `ORACLE_HOME` = `/oracle/<SID>/19.0.0`
- `oracle_sid` = definido no survey (padrão: `AWOR`)

### O que é OPatch?

OPatch é a ferramenta da Oracle para aplicar patches. Cada patch tem um número (ex: `p37641958`). A sequência de aplicação importa: patches dependem de outros patches anteriores.

### O que são HugePages?

HugePages são páginas de memória grandes (2 MB padrão vs 4 KB normal) reservadas para o Oracle. Benefícios:
- Memória SGA não pode ser paginada para disco (sem swap)
- Menos pressão na TLB do processador
- Performance mais estável

O playbook calcula automaticamente: `hugepages = ceil(SGA_MB / 2) × 1.1`

---

## Pré-requisitos de Instalação

**ANTES de executar qualquer fase, os arquivos abaixo devem estar no AWX VM.**

O role usa **dois diretórios source** no host `awxvm`:

**`/opt/oracle/`** — installer e dependências:

| Item | Descrição | Tamanho aprox. |
|---|---|---|
| `LINUX.X64_193000_db_home.zip` | Binários Oracle 19c | ~3 GB |
| `oracle-database-preinstall-19c-1.0-1.el9.x86_64.rpm` | RPM de pré-requisitos RHEL 9 | ~25 KB |
| `libnsl_libs/` | `libnsl.so.1` + `libnsl.so.2` (ausentes em RHEL 9 minimal) | ~200 KB |
| `oswbb840.tar` | OS Watcher (OSWbb) — monitoramento de SO em tempo real | ~2 MB |

**`/opt/patches/`** — OPatch e patches:

| Item | Descrição | Tamanho aprox. |
|---|---|---|
| `p6880880/` | Substituto do OPatch (versão mais nova que a do ZIP) | ~200 MB |
| `p37641958/` | Bundle legado — ainda transferido para o target via rsync, mas **não** usado como `-applyRU` no runInstaller. Manter em `/opt/patches/`. | ~3 GB |
| `p38632161/` | Usado como `-applyRU` no runInstaller (Oracle 19.30 — required for RHEL9/GCC11). Também aplicado standalone via opatch pós-install. | varia |
| `p34672698/` | Patch oradism (post_patch3) — aplicado via opatch pós-install | varia |

**Verificar antes de iniciar:**
```bash
ls -la /opt/oracle/
ls -la /opt/patches/
```

**Hardware mínimo recomendado para Oracle 19c:**
- RAM: 8 GB (2 GB para SGA padrão + SO)
- Disco: 65 GB mínimo (50G base + 5G oradata + 2G×3 arch/undo/temp + 1G×4 logs)
- CPU: 2 vCPUs

---

## Playbook — deploy_oracle.yml

11 fases (0–10). Fases 6c, 8, 9, 10 opcionais; fase 7 automática quando `create_initial_db=true`. Cada fase depende da anterior.

```
Phase 0:  oracle_storage              → PV/VG/LV creation, mkfs.xfs, mount + fstab (noatime,nodiratime,nofail)
Phase 1:  oracle_prereqs              → RPM, libnsl, hugepages, calc SGA/PGA, sysctl, RHEL9 workaround
Phase 2:  oracle_dirs                 → diretórios, bash_profile, init.ora, SQL scripts de criação
Phase 3:  oracle_transfer             → rsync installer + OPatch + RU + post-patches (~8 GB) para /home/oracle/software
Phase 4:  oracle_install_sw           → unzip + swap OPatch + runInstaller -applyRU p38632161 (sem -applyOneOffs) + root.sh
Phase 5:  oracle_patches              → opatch: post2(p38632161/19.30) → oradism chown → post3(p34672698) → oradism restore
Phase 6:  oracle_dbcreate             → orapwd + CreateDB.sql → CreateDBFiles.sql → catalog/catproc → datapatch → SPFILE → utlrp → verify_function_12C → Users_and_Objects.sql
Phase 6b: oracle_netcfg              → listener.ora / tnsnames.ora / sqlnet.ora + lsnrctl LISTENER_<SID> + ALTER SYSTEM REGISTER
Phase 6c: oracle_oswatcher           → transfer oswbb840.tar + instalar OSW em /home/oracle/oswbb + systemd oswatcher.service
Phase 7:  oracle_configuration_check → security/config checks + auto-remediation + SHUTDOWN/STARTUP (auto quando create_initial_db=true)
Phase 8:  oracle_manage_users         → gestão de usuários Oracle (quando oracle_manage_users_enabled=true)
Phase 9:  db_patches                  → patch discovery, sem apply (quando db_patches_enabled=true)
Phase 10: oracle_security             → security audit oracle_security_check (quando oracle_security_check_enabled=true)
```

### Comandos de execução

```bash
# Instalação completa (todas as fases — ~12 min com hardware correto)
ansible-playbook playbooks/deploy_oracle.yml

# Fases individuais:
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_prereqs
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_dirs
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_transfer
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_install_sw
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_patches
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_dbcreate
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_netcfg
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_oswatcher
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_configuration_check
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_manage_users -e oracle_manage_users_enabled=true
ansible-playbook playbooks/deploy_oracle.yml --tags db_patches -e db_patches_enabled=true
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_security -e oracle_security_check_enabled=true

# Limitado a um host
ansible-playbook playbooks/deploy_oracle.yml -l oraclevm

# Gerenciar usuários apenas (day-2)
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_users -l oraclevm
```

---

## Variáveis de Instalação — `roles/oracle_install/defaults/main.yml`

### Identidade e Caminhos

| Variável | Padrão | Survey | Descrição |
|---|---|---|---|
| `oracle_sid` | `AWOR` | **Sim** | Identificador único do banco. Define diretórios, LV name, oratab. |
| `oracle_base` | `/oracle/{{ oracle_sid }}` | Não | Calculado a partir do SID. Raiz de todas as instalações. |
| `oracle_home` | `{{ oracle_base }}/19.0.0` | Não | Calculado a partir do base. Onde ficam os binários. |

### LVM Storage (survey-driven)

| Variável | Padrão | Survey | Descrição |
|---|---|---|---|
| `oracle_data_disk` | `/dev/sdb` | Não | Dispositivo raw para PV/VG. Vazio = skip PV/VG creation. |
| `oracle_vg_name` | `vg_data` | **Sim** | LVM Volume Group para todos os LVs Oracle. |
| `oracle_lv_base_size` | `50G` | **Sim** | `lv_<SID>` — Oracle home + software staging + scripts |
| `oracle_lv_oradata_size` | `5G` | **Sim** | `lv_oradata` — datafiles |
| `oracle_lv_oraarch_size` | `2G` | **Sim** | `lv_oraarch` — archive logs |
| `oracle_lv_undofile_size` | `2G` | **Sim** | `lv_undofile` — undo tablespace |
| `oracle_lv_tempfile_size` | `2G` | **Sim** | `lv_tempfile` — temp tablespace |
| `oracle_lv_mirrlogA_size` | `1G` | **Sim** | `lv_mirrlogA` e `lv_mirrlogB` (mesmo tamanho para ambos) |
| `oracle_lv_origlogA_size` | `1G` | **Sim** | `lv_origlogA` e `lv_origlogB` (mesmo tamanho para ambos) |

### Software e Patches

| Variável | Padrão | Descrição |
|---|---|---|
| `oracle_software_src` | `/opt/oracle` | Source do rsync no awxvm — installer zip, RPM, libnsl_libs. |
| `oracle_patches_src` | `/opt/patches` | Source do rsync no awxvm — OPatch, RU, one-off, post-patches. |
| `oracle_software_dst` | `/home/oracle/software` | Destino no target — diretório de staging. Todos os binários e patches chegam aqui via rsync. |
| `oracle_installer_zip` | `LINUX.X64_193000_db_home.zip` | ZIP com binários do Oracle 19c. |
| `oracle_preinstall_rpm` | `oracle-database-preinstall-19c-1.0-1.el9.x86_64.rpm` | RPM de pré-requisitos. Configura grupos, limites, kernel params. |
| `oracle_opatch_dir` | `p6880880` | Diretório do OPatch substituto (versão mais nova que a do ZIP). |
| `oracle_ru_patch_dir` | `p37641958` | **Legado** — ainda transferido para o target via rsync, mas runInstaller não o usa mais diretamente. Manter em `/opt/patches/`. |
| `oracle_ru_subpath` | `37641958/37642901` | Legado — subpath do patch RU legado. Não usado como argumento de runInstaller. |
| `oracle_oneoff_subpath` | `37641958/37643161` | Legado — removido do runInstaller. Sem `-applyOneOffs` na configuração atual. |
| `oracle_post_patch2_dir` | `p38632161` | **Usado como `-applyRU` no runInstaller** (Oracle 19.30 — necessário para RHEL9/GCC11). Também aplicado standalone via opatch (pula se já no inventário do runInstaller). |
| `oracle_post_patch3_dir` | `p34672698` | Patch oradism (post_patch3) — aplicado via opatch pós-install. |

### HugePages (Memória Grande)

| Variável | Padrão | Descrição |
|---|---|---|
| `oracle_hugepages` | `0` | `0` = calcular automaticamente. Número positivo = forçar valor fixo. |
| `oracle_hugepage_size_mb` | `2` | Tamanho padrão de HugePage em x86_64 (sempre 2 MB). Não alterar. |
| `oracle_hugepages_overhead_pct` | `10` | Margem de segurança adicionada ao cálculo (10% a mais). |
| `oracle_hugetlb_shm_group` | `54321` | GID do grupo `dba`. Configurado pelo RPM de preinstall. |

**Fórmula do cálculo automático:**
```
hugepages = ceil(SGA_em_MB / hugepage_size_MB) × (1 + overhead_pct/100)
```

Exemplo com SGA=2G: `ceil(2048 / 2) × 1.1 = 1024 × 1.1 = 1126 páginas`

### Tuning de Memória (survey-driven)

| Variável | Padrão | Survey | Descrição |
|---|---|---|---|
| `oracle_sga_pct` | `40` | **Sim** | % da RAM da VM para SGA. Ex: VM com 6 GB → 40% = ~2,4 GB SGA. |
| `oracle_pga_pct` | `20` | **Sim** | % da RAM da VM para PGA aggregate. |
| `oracle_sga_target` | `auto` | Não | **Calculado em `01_prereqs.yml`** a partir de `ansible_memtotal_mb × oracle_sga_pct/100`. Não setar manualmente. |
| `oracle_pga_target` | `auto` | Não | **Calculado em `01_prereqs.yml`** a partir de `ansible_memtotal_mb × oracle_pga_pct/100`. Não setar manualmente. |
| `oracle_processes` | `1000` | Não | Máximo de processos Oracle simultâneos. |
| `oracle_open_cursors` | `3000` | Não | Máximo de cursors abertos por sessão. |
| `oracle_db_block_size` | `8192` | Não | Tamanho do bloco de dados (8 KB padrão). Não alterar após criação. |

### Configurações de Banco

| Variável | Padrão | Survey | Descrição |
|---|---|---|---|
| `oracle_character_set` | `AL32UTF8` | Não | Character set do banco. `AL32UTF8` = Unicode completo (recomendado). `WE8MSWIN1252` para legado Windows. |
| `oracle_nchar_set` | `AL16UTF16` | Não | National character set (para colunas NCHAR/NVARCHAR2). |
| `oracle_nls_language` | `AMERICAN` | Não | Idioma para mensagens de erro e formatos. |
| `oracle_nls_territory` | `AMERICA` | Não | Território para formatos de data/número. |
| `oracle_listener_port` | `1521` | **Sim** | Porta do listener Oracle. Survey: integer, range 1024-65535. |
| `oracle_undo_tablespace` | `UNDOTBS1` | Não | Nome da tablespace de undo. |

### Senhas (campos do survey — tipo password)

| Variável | Survey | Padrão | Descrição |
|---|---|---|---|
| `oracle_sys_password` | **Sim** (tipo: password) | *(empty — obrigatório)* | Senha do usuário SYS (superusuário). Coletada via survey, não armazenada em texto claro. |
| `oracle_system_password` | **Sim** (tipo: password) | *(empty — obrigatório)* | Senha do usuário SYSTEM. Coletada via survey. |

> **Importante:** As senhas SYS e SYSTEM estão no survey de instalação (campos tipo `password`). O AWX mascara os valores nos logs. Não é necessário setar via extra vars — o survey já cobre isso.

### OS Watcher

| Variável | Padrão | Descrição |
|---|---|---|
| `oracle_oswatcher_tar` | `oswbb840.tar` | Nome do tar do OSWbb em `/opt/oracle/` no awxvm. |
| `oracle_osw_path` | `/home/oracle/oswbb` | Diretório de instalação no target. |
| `oracle_osw_interval` | `30` | Intervalo de coleta em segundos. |
| `oracle_osw_archive_hours` | `720` | Horas de retenção dos arquivos coletados (30 dias). |

O serviço systemd `oswatcher.service` é criado na Phase 6c (`oracle_oswatcher`) e gerenciado via `systemctl`. Idempotente: skip se `startOSWbb.sh` já presente.

```bash
# Verificar status no target:
systemctl status oswatcher.service
```

---

### Controle de Fase e Tablespace Datafiles

| Variável | Padrão | Survey | Descrição |
|---|---|---|---|
| `create_initial_db` | `true` | Não | Se `false`, instala só o software sem criar banco (útil para preparar nó de standby). |
| `ts_audit_datafiles` | `1` | Não | Nº de datafiles para `TS_AUDIT_DAT01`. Arquivos nomeados `TS_AUDIT_DAT01_01.DBF`, `_02.DBF`, etc. |
| `ts_perfstat_datafiles` | `1` | Não | Nº de datafiles para `TS_PERFSTAT_DAT01`. |
| `ts_sid_dat_datafiles` | `1` | Não | Nº de datafiles para `TS_<SID>_DAT01` (tablespace de dados). |
| `ts_sid_idx_datafiles` | `1` | Não | Nº de datafiles para `TS_<SID>_IDX01` (tablespace de índices). |

---

## Variáveis de Gestão de Usuários — `roles/oracle_manage_users/defaults/main.yml`

| Variável do Schema | Tipo | Padrão | Obrigatório | Descrição |
|---|---|---|---|---|
| `username` | string | — | **Sim** | Nome do usuário Oracle (convenção: MAIÚSCULAS). |
| `password` | string | `""` | Sim (quando present) | Senha. Nunca em logs. |
| `state` | string | `present` | Não | `present` = criar/atualizar. `absent` = `DROP USER ... CASCADE`. |
| `privileges` | string | `""` | Não | System privileges (ex: `CONNECT,RESOURCE`). |
| `roles` | list | `[]` | Não | Oracle roles a conceder (ex: `["DBA"]`). |
| `revoke` | bool | `false` | Não | Se `true`, revoga os privileges listados. |
| `default_tablespace` | string | `USERS` | Não | Tablespace padrão do usuário. |
| `temp_tablespace` | string | `TEMP` | Não | Tablespace temporária do usuário. |
| `allowed_ips` | list | `[]` | Não | IPs a adicionar em `sqlnet.ora TCP.INVITED_NODES`. |

---

## Conceitos de Usuários Oracle

### System Privileges vs Roles Oracle

**System Privileges** — permissões a nível do banco:

| Privilege | O que permite |
|---|---|
| `CONNECT` | Conectar ao banco (login) |
| `RESOURCE` | Criar tabelas, triggers, sequences no próprio schema |
| `CREATE SESSION` | Equivalente a CONNECT (mais específico) |
| `CREATE TABLE` | Criar tabelas no próprio schema |
| `UNLIMITED TABLESPACE` | Usar espaço ilimitado em qualquer tablespace |
| `CREATE ANY TABLE` | Criar tabelas em qualquer schema |
| `CREATE PUBLIC SYNONYM` | Criar sinônimos públicos |

**Roles Oracle** — conjuntos de privilégios pré-definidos:

| Role | O que contém |
|---|---|
| `DBA` | Todos os privilégios administrativos |
| `CONNECT` | `CREATE SESSION` + privileges básicos |
| `RESOURCE` | Criar objetos no próprio schema |
| `SELECT_CATALOG_ROLE` | Ler views do dicionário de dados |
| `DATAPUMP_EXP_FULL_DATABASE` | Export completo via Data Pump |
| `DATAPUMP_IMP_FULL_DATABASE` | Import completo via Data Pump |

### Controle de Acesso por IP — sqlnet.ora

O arquivo `sqlnet.ora` controla quais IPs podem se conectar via `TCP.INVITED_NODES`:

```
# sqlnet.ora
TCP.INVITED_NODES = (192.168.1.10, 192.168.1.20, 10.0.0.0/24)
```

O playbook **adiciona** IPs à lista via `manage_ip.yml` — nunca remove existentes.

---

## Variáveis do Survey AWX — `oracle_manage_users`

| Variável AWX | Tipo | Padrão | Obrigatório | Descrição | Exemplo |
|---|---|---|---|---|---|
| `oracle_username` | text | — | **Sim** | Nome do usuário Oracle. Convenção: maiúsculas. | `APPUSER` |
| `oracle_password` | password | — | Sim (quando present) | Senha. | `App#Secure2024!` |
| `oracle_user_state` | multiplechoice | `present` | **Sim** | `present` ou `absent`. | `present` |
| `oracle_privileges` | text | `CONNECT,RESOURCE` | Não | System privileges separados por vírgula. | `CONNECT,RESOURCE` |
| `oracle_roles` | text | — | Não | Oracle roles separadas por vírgula. | `DBA` |
| `oracle_revoke_access` | multiplechoice | `false` | **Sim** | `true` = revoga privileges. | `false` |
| `oracle_default_tablespace` | text | `USERS` | Não | Tablespace padrão. | `USERS` |
| `oracle_temp_tablespace` | text | `TEMP` | Não | Tablespace temporária. | `TEMP` |
| `oracle_allowed_ips` | textarea | — | Não | IPs para sqlnet.ora (separados por vírgula). | `192.168.1.50` |

---

## Exemplos Práticos

### Exemplo 1: Usuário de aplicação básico

```yaml
oracle_username: "WEBAPP"
oracle_password: "App#Secure2024!"
oracle_user_state: "present"
oracle_privileges: "CONNECT,RESOURCE"
oracle_roles: ""
oracle_revoke_access: "false"
oracle_default_tablespace: "USERS"
oracle_temp_tablespace: "TEMP"
oracle_allowed_ips: "192.168.1.50"
```

**SQL executado:**
```sql
CREATE USER WEBAPP IDENTIFIED BY '***'
  DEFAULT TABLESPACE USERS
  TEMPORARY TABLESPACE TEMP;
GRANT CONNECT TO WEBAPP;
GRANT RESOURCE TO WEBAPP;
```

---

### Exemplo 2: DBA completo

```yaml
oracle_username: "DBADMIN"
oracle_password: "DBA#Admin2024!"
oracle_user_state: "present"
oracle_privileges: "CONNECT"
oracle_roles: "DBA"
oracle_revoke_access: "false"
oracle_default_tablespace: "USERS"
oracle_temp_tablespace: "TEMP"
oracle_allowed_ips: "192.168.137.1"
```

```sql
CREATE USER DBADMIN IDENTIFIED BY '***'
  DEFAULT TABLESPACE USERS
  TEMPORARY TABLESPACE TEMP;
GRANT CONNECT TO DBADMIN;
GRANT DBA TO DBADMIN;
```

---

### Exemplo 3: Remover usuário e todos seus objetos

```yaml
oracle_username: "OLDUSER"
oracle_password: ""
oracle_user_state: "absent"
oracle_privileges: ""
oracle_roles: ""
oracle_revoke_access: "false"
oracle_default_tablespace: "USERS"
oracle_temp_tablespace: "TEMP"
oracle_allowed_ips: ""
```

```sql
DROP USER OLDUSER CASCADE;
-- CASCADE remove todos os objetos do usuário (tabelas, procedures, etc.)
```

---

## Checks do oracle_configuration_check — Referência Completa

O role `oracle_configuration_check` executa 29 verificações agrupadas em 5 categorias. Cada check produz `PASS`, `FAIL`, `FIXED` ou `N/A` no relatório HTML.

> **oracle_configuration_check_remediate: true** (default) — FIX tasks rodam automaticamente. Setar `false` para modo auditoria apenas (nenhuma alteração no banco/SO).
> **oracle_security_allow_restart: true** — DB reinicia ao final para efetivar parâmetros SPFILE. Setar `false` para aplicar sem reinício (parâmetros ficam pendentes até próximo restart manual).

### Categoria 1 — Configuração Geral

| ID | Check | O que verifica | Auto-fix | O que o FIX faz |
|---|---|---|---|---|
| 1.1 | AUD$ Table | Tabela de auditoria não está em SYSTEM/SYSAUX — deve estar em `TS_AUDIT_DAT01` | **Sim** | Move AUD$ para tablespace correta |
| 1.2 | DB User DBA Role | Nenhum usuário não-padrão com role DBA (exceto lista `oracle_dba_role_approved_users`) | Não | Só reporte — requer revisão manual |
| 1.3 | oradism File Permission | `oradism` com owner=root, mode=4750 no ORACLE_HOME | **Sim** | Corrige permissões via `chmod/chown` |
| 1.4 | Linux swappiness | `vm.swappiness=1` (kernel >2.6.18) | **Sim** | `sysctl vm.swappiness=1` + persiste em `/etc/sysctl.conf` |
| 1.5 | Linux SELinux | SELinux desabilitado (`SELINUX=disabled`) | **Sim** | `setenforce 0` + atualiza `/etc/selinux/config` + grub |
| 1.6 | Page Table Size | `PageTables` ≤ 2% da RAM total | Não | Requer HugePages corretamente configurado (fase 1) |
| 1.7 | DB Logon Delay | `_sys_logon_delay=0` (Oracle 12+) | **Sim** | `ALTER SYSTEM SET _sys_logon_delay=0 SCOPE=SPFILE` |
| 1.8 | _cleanup_rollback_entries | Parâmetro ≥ 2000 | **Sim** | `ALTER SYSTEM SET _cleanup_rollback_entries=2000 SCOPE=SPFILE` |
| 1.9 | deferred_segment_creation | Parâmetro = `false` | **Sim** | `ALTER SYSTEM SET deferred_segment_creation=FALSE SCOPE=SPFILE` |
| 1.10 | _disable_system_state | Parâmetro = `10` | **Sim** | `ALTER SYSTEM SET _disable_system_state=10 SCOPE=SPFILE` |

### Categoria 2 — Defeitos e Erros Conhecidos

| ID | Check | O que verifica | Auto-fix | O que o FIX faz |
|---|---|---|---|---|
| 2.1 | _rowsets_enabled | Parâmetro = `false` (evita bug de corrupção em batch) | **Sim** | `ALTER SYSTEM SET _rowsets_enabled=FALSE SCOPE=SPFILE` |
| 2.2 | _drop_stat_segment | Parâmetro = `1` OR patch `23125826` aplicado | **Sim** | `ALTER SYSTEM SET _drop_stat_segment=1 SCOPE=SPFILE` se patch ausente |
| 2.3 | LSLT Bug | Patch `33121934` aplicado AND `_disable_last_successful_login_time=true` | **Sim** | `ALTER SYSTEM SET` (só se patch presente; restart necessário) |
| 2.4 | Min OS Free Memory | `vm.min_free_kbytes ≥ 524288` AND MTU loopback=16436 | **Sim** | Atualiza sysctl + `nmcli` para MTU do loopback |
| 2.5 | Listener.log Errors | Nenhum erro repetido > threshold nos últimos 30 dias | Não | Só reporte — verificar log manualmente |

### Categoria 3 — Disponibilidade

| ID | Check | O que verifica | Auto-fix | Observação |
|---|---|---|---|---|
| 3.1 | RAC Configuration | Banco em modo RAC (`parallel=YES`) | Não | **Sempre FAIL em single-instance** — esperado em lab |
| 3.3 | DB Server Redundancy | Daemon de cluster rodando (crsd/corosync/pacemaker) | Não | **Sempre FAIL em servidor único** — esperado em lab |

> **Nota:** Checks 3.1 e 3.3 são FAIL em qualquer instalação single-instance — isso é **normal** em ambientes de lab e desenvolvimento. Não requerem ação.

### Categoria 4 — Performance e Capacidade

| ID | Check | O que verifica | Auto-fix | O que o FIX faz |
|---|---|---|---|---|
| 4.1 | Checkpoint Not Complete | Sem mensagem "checkpoint not complete" no alert.log | Não | Requer aumento dos redo logs — manual |
| 4.2 | PGA Limit | `pga_aggregate_limit=0` AND `_pga_max_size ≥ oracle_pga_max_size_gb` (default: 2 GB) | **Sim** | `ALTER SYSTEM SET` ambos os parâmetros SCOPE=SPFILE |
| 4.3 | _parallel_adaptive_max_users | Parâmetro = `2` | **Sim** | `ALTER SYSTEM SET _parallel_adaptive_max_users=2 SCOPE=SPFILE` |
| 4.4 | filesystemio_options | Parâmetro = `setall` (obrigatório para LVM/XFS) | **Sim** | `ALTER SYSTEM SET filesystemio_options=setall SCOPE=SPFILE` |
| 4.5 | SGA/PGA Memory Sizing | SGA entre `oracle_sga_pct_min` (20%) e `oracle_sga_pct_max` (50%) da RAM; PGA entre 10%-40% | **Sim** | `ALTER SYSTEM SET sga_target / pga_aggregate_target` baseado em % da RAM |

### Categoria 5 — Operação

| ID | Check | O que verifica | Auto-fix | O que o FIX faz |
|---|---|---|---|---|
| 5.1 | User Account Lock | Perfis de aplicação com `FAILED_LOGIN_ATTEMPTS` limitado | **Sim** | `ALTER PROFILE ... LIMIT FAILED_LOGIN_ATTEMPTS 3` (sem restart) |
| 5.2 | DBA_REGISTRY Components | Todos os componentes do dicionário com status `VALID` | Não | Específico por versão — requer intervenção manual |
| 5.3 | OS Watcher | `startOSWbb.sh` instalado + processo em execução | **Sim** | Inicia `systemctl start oswatcher` |
| 5.4 | Nologging | Sem LOBs ou datafiles marcados como `NOLOGGING` | Não | Requer `ALTER ... LOGGING` manual por objeto |
| 5.5 | DB Full Backup | Backup completo (RMAN ou export) executado | Não | Requer política de backup configurada |
| 5.6 | Control File Backup | Backup do control file nos últimos 8 dias | Não | Requer `BACKUP CURRENT CONTROLFILE` agendado |
| 5.7 | AWR Configuration | Retenção ≥ 35 dias AND intervalo ≤ 20 min | **Sim** | `DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS` (sem restart) |

### Resumo: Auto-fix vs Reporte

**Auto-fix (17 checks):** 1.1, 1.3, 1.4, 1.5, 1.7, 1.8, 1.9, 1.10, 2.1, 2.2, 2.3, 2.4, 4.2, 4.3, 4.4, 4.5, 5.1, 5.3, 5.7

**Reporte apenas (10 checks):** 1.2, 1.6, 2.5, 3.1, 3.3, 4.1, 5.2, 5.4, 5.5, 5.6

---

## Política de Senhas — Profiles Oracle

Criados/atualizados na Phase 6 (`oracle_dbcreate`) via `Users_and_Objects.sql`.

### Profile APPLICATION

Atribuído aos usuários de aplicação criados pelo playbook. Política mais permissiva em relação à expiração (UNLIMITED), mas com verificação de complexidade obrigatória.

| Parâmetro | Valor | Descrição |
|---|---|---|
| `FAILED_LOGIN_ATTEMPTS` | `3` | Conta bloqueada após 3 falhas consecutivas |
| `PASSWORD_LIFE_TIME` | `UNLIMITED` | Senha não expira (aplicações não podem receber prompt de troca) |
| `PASSWORD_REUSE_TIME` | `180` | Não pode reutilizar senha usada nos últimos 180 dias |
| `PASSWORD_REUSE_MAX` | `1` | Deve trocar senha ao menos 1 vez antes de reutilizar |
| `PASSWORD_VERIFY_FUNCTION` | `verify_function_12C` | Verifica complexidade: mínimo 8 chars, maiúsc + minúsc + número + especial |
| `PASSWORD_LOCK_TIME` | `1` | Conta bloqueada por 1 dia após exceder FAILED_LOGIN_ATTEMPTS |
| `PASSWORD_GRACE_TIME` | `7` | 7 dias de aviso antes da expiração |

### Profile DEFAULT

Aplicado a todos os usuários Oracle sem profile explícito (incluindo contas de DBA).

| Parâmetro | Valor | Descrição |
|---|---|---|
| `FAILED_LOGIN_ATTEMPTS` | `3` | Conta bloqueada após 3 falhas |
| `PASSWORD_LIFE_TIME` | `5` | Senha expira em 5 dias — força troca periódica para contas administrativas |
| `PASSWORD_REUSE_TIME` | `180` | Não pode reutilizar nos últimos 180 dias |
| `PASSWORD_REUSE_MAX` | `1` | Mínimo 1 troca antes de reutilizar |
| `PASSWORD_VERIFY_FUNCTION` | `verify_function_12C` | Mesmo verificador de complexidade |
| `PASSWORD_LOCK_TIME` | `1` | Bloqueio por 1 dia |
| `PASSWORD_GRACE_TIME` | `7` | 7 dias de aviso |

### verify_function_12C

Função de verificação de complexidade criada em `roles/oracle_install/files/verify_function_12c.sql` e executada na Phase 6 **antes** do `Users_and_Objects.sql`.

Regras verificadas:
- Mínimo 8 caracteres
- Pelo menos 1 letra maiúscula
- Pelo menos 1 letra minúscula
- Pelo menos 1 dígito numérico
- Pelo menos 1 caractere especial
- Senha não pode conter o nome do usuário
- Senha não pode ser igual à senha anterior

```bash
# Verificar manualmente se a função existe:
sudo -u oracle /oracle/<SID>/19.0.0/bin/sqlplus / as sysdba <<EOF
SELECT object_name, status FROM dba_objects
WHERE object_name = 'VERIFY_FUNCTION_12C' AND owner = 'SYS';
EOF
```

---

## Decisões de Design

### Por que `CV_ASSUME_DISTID=RHEL8`?

Oracle 19c não foi certificado para RHEL 9. Sem essa variável, o instalador detecta RHEL 9 e rejeita a instalação. A variável faz o instalador acreditar que está em RHEL 8, contornando a verificação de plataforma. Oracle 19c funciona perfeitamente em RHEL 9 na prática.

### Por que `rc not in [0, 6]` no runInstaller?

O `runInstaller` retorna `rc=6` quando conclui com avisos (warnings) — isso é **normal** em instalações silenciosas. Tratar `rc=6` como falha bloquearia toda a automação. O playbook aceita rc=0 e rc=6 como sucesso.

### Por que `opatch apply -silent`?

`opatch apply -silent` elimina as perguntas interativas do opatch. Sem o flag, o processo fica travado aguardando input do terminal — inviável em automação.

### Por que rsync delegado ao awxvm, não ao EE container?

Oracle software + patches somam ~8 GB. O rsync roda delegado ao `awxvm` (o host, não o container EE) via `delegate_to: awxvm`. O EE não tem acesso direto ao filesystem do host. O rsync usa `--rsync-path="sudo rsync"` para escrever diretamente nos diretórios do usuário oracle sem staging intermediário.

### Por que não usa dbca para criar o banco?

O banco é criado via sequência de scripts SQL (`CreateDB.sql`, `CreateDBFiles.sql`, `CreateDBCatalog.sql`, `lockAccount.sql`, `postDBCreation.sql`) executados pelo `sqlplus /nolog`, dentro do shell script `{{ oracle_sid }}.sh`. Esse método replica exatamente o processo manual documentado no `oracle_install_guide.txt` e dá controle granular sobre cada passo. `postDBCreation.sql` executa: `datapatch`, `CREATE SPFILE`, `utlrp.sql` (compilação de inválidos), shutdown e startup.

### Por que `-applyRU` durante o runInstaller?

Aplicar o Release Update (RU) durante a instalação faz o Oracle home já nascer no patch level correto. A alternativa — opatch apply após instalar — exige descompactar o RU separadamente, parar todos os processos Oracle, aplicar, e verificar. Mais complexo e mais propenso a erros.

O RU aplicado é sempre `p38632161/38632161` (Oracle 19.30). Não há `-applyOneOffs` na configuração atual — foi removido. O Phase 5 (`oracle_patches`) complementa com patches adicionais via opatch standalone.

---

## Tags Disponíveis

| Tag | O que executa |
|---|---|
| `oracle` | Todas as tasks Oracle |
| `oracle_storage` | PV/VG/LV creation, mkfs.xfs, mount (Phase 0) |
| `oracle_prereqs` | RPM preinstall, sysctl, hugepages, cálculo SGA/PGA (Phase 1) |
| `oracle_dirs` | Criação de diretórios, bash_profile (Phase 2) |
| `oracle_transfer` | Rsync binários AWX → target (Phase 3) |
| `oracle_install_sw` | Descompactar + runInstaller + root.sh (Phase 4) |
| `oracle_patches` | opatch: p38632161 (19.30 RU) → oradism chown → p34672698 (oradism) → oradism restore (Phase 5) |
| `oracle_dbcreate` | Criação do banco, catalog, datapatch, SPFILE (Phase 6) |
| `oracle_netcfg` | listener.ora / tnsnames.ora / sqlnet.ora + lsnrctl LISTENER_\<SID\> (Phase 6b) |
| `oracle_oswatcher` | Instalar OS Watcher: transfer tar + extract + systemd oswatcher.service (Phase 6c). Também: check/start via oracle_configuration_check.yml |
| `oracle_security` | Security audit via oracle_security_check role (Phase 10 — requer `oracle_security_check_enabled=true`) |
| `oracle_users` | Ciclo de gestão de usuários |
| `oracle_users_validate` | Validação de variáveis de usuário |
| `oracle_user_create` | Criação do usuário via sqlplus |
| `oracle_grants` | Concessão de system privileges |
| `oracle_role_grants` | Concessão de Oracle roles |
| `oracle_revoke` | Revogação de privileges |
| `oracle_sqlnet` | Atualização do sqlnet.ora |
| `oracle_user_drop` | Remoção de usuário (DROP CASCADE) |

---

## Troubleshooting

### runInstaller falha com "OS not certified"

**Causa:** Oracle 19c não suporta RHEL 9 sem o workaround.

**Verificar:** A variável `CV_ASSUME_DISTID=RHEL8` deve estar no ambiente antes do runInstaller. O playbook faz isso automaticamente via `environment:` no task.

---

### Phase 1 falha: `/etc/init.d` já foi renomeado

```
fatal: mv /etc/init.d /etc/initd.back — directory already exists
```

**Não é erro real** — o workaround já foi aplicado anteriormente. O task usa `creates: /etc/initd.back` para ser idempotente. Verificar se o arquivo `creates:` está correto.

---

### Phase 6 falha: banco não ficou OPEN

```
FATAL: "OPEN" not in db_status.stdout
```

**Verificar no servidor (substituir `<SID>`):**
```bash
sudo -u oracle /oracle/<SID>/19.0.0/bin/sqlplus / as sysdba <<EOF
SELECT status FROM v\$instance;
SELECT * FROM v\$database;
EOF
```

---

### Listener não iniciando

```bash
sudo -u oracle /oracle/<SID>/19.0.0/bin/lsnrctl status
sudo -u oracle /oracle/<SID>/19.0.0/bin/lsnrctl start
```

---

## Ver Também

- [`oracle_runbook.md`](oracle_runbook.md) — Guia operacional
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
- [`offline_requirements.md`](offline_requirements.md) — Preparar binários Oracle offline
