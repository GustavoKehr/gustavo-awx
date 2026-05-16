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

**`/opt/patches/`** — OPatch e patches:

| Item | Descrição | Tamanho aprox. |
|---|---|---|
| `p6880880/` | Substituto do OPatch (versão mais nova que a do ZIP) | ~200 MB |
| `p37641958/` | Release Update (RU) + one-off — aplicados no runInstaller | ~3 GB |
| `p38291812/` | Patch pós-instalação 1 | varia |
| `p38632161/` | Patch pós-instalação 2 (Oracle 19.30) | varia |
| `p34672698/` | Patch pós-instalação 3 | varia |

**Verificar antes de iniciar:**
```bash
ls -la /opt/oracle/
ls -la /opt/patches/
```

**Hardware mínimo recomendado para Oracle 19c:**
- RAM: 8 GB (2 GB para SGA padrão + SO)
- Disco: 50 GB (software + banco + logs)
- CPU: 2 vCPUs

---

## Playbook — deploy_oracle.yml

7 fases sequenciais. Cada fase depende da anterior.

```
Phase 0: oracle_storage    → oracle_storage    → PV/VG/LV creation, mkfs.xfs, mount
Phase 1: oracle_prereqs    → oracle_prereqs    → RPM, libnsl, hugepages, calc SGA/PGA, sysctl, RHEL9 workaround
Phase 2: oracle_dirs       → oracle_dirs       → diretórios, bash_profile, init.ora, SQL scripts de criação
Phase 3: oracle_transfer   → oracle_transfer   → rsync installer + OPatch + RU + post-patches (~8 GB) para /oracle/<SID>/software
Phase 4: oracle_install_sw → oracle_install_sw → unzip + swap OPatch + runInstaller -applyRU -applyOneOffs + root.sh
Phase 5: oracle_patches    → oracle_patches    → opatch: post1 → post2 → oradism chown → post3 → oradism restore
Phase 6: oracle_dbcreate   → oracle_dbcreate   → orapwd + CreateDB.sql → CreateDBFiles.sql → catalog/catproc → datapatch → SPFILE → utlrp → Users_and_Objects.sql
```

### Comandos de execução

```bash
# Instalação completa (todas as 6 fases — pode levar 2-3 horas)
ansible-playbook playbooks/deploy_oracle.yml

# Fases individuais:
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_prereqs
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_dirs
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_transfer
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_install_sw
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_patches
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_dbcreate

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
| `oracle_data_disk` | `/dev/sdc` | Não | Dispositivo raw para PV/VG. Vazio = skip PV/VG creation. |
| `oracle_vg_name` | `vg_data` | **Sim** | LVM Volume Group para todos os LVs Oracle. |
| `oracle_lv_base_size` | `60G` | **Sim** | `lv_<SID>` — Oracle home + software staging + scripts |
| `oracle_lv_oradata_size` | `10G` | **Sim** | `lv_oradata` — datafiles |
| `oracle_lv_oraarch_size` | `5G` | **Sim** | `lv_oraarch` — archive logs |
| `oracle_lv_undofile_size` | `5G` | **Sim** | `lv_undofile` — undo tablespace |
| `oracle_lv_tempfile_size` | `5G` | **Sim** | `lv_tempfile` — temp tablespace |
| `oracle_lv_mirrlogA_size` | `1G` | **Sim** | `lv_mirrlogA` e `lv_mirrlogB` (mesmo tamanho para ambos) |
| `oracle_lv_origlogA_size` | `1G` | **Sim** | `lv_origlogA` e `lv_origlogB` (mesmo tamanho para ambos) |

### Software e Patches

| Variável | Padrão | Descrição |
|---|---|---|
| `oracle_software_src` | `/opt/oracle` | Source do rsync no awxvm — installer zip, RPM, libnsl_libs. |
| `oracle_patches_src` | `/opt/patches` | Source do rsync no awxvm — OPatch, RU, one-off, post-patches. |
| `oracle_software_dst` | `/oracle/{{ oracle_sid }}/software` | Destino no target — dentro do lv_base. Todos os patches chegam aqui. |
| `oracle_installer_zip` | `LINUX.X64_193000_db_home.zip` | ZIP com binários do Oracle 19c. |
| `oracle_preinstall_rpm` | `oracle-database-preinstall-19c-1.0-1.el9.x86_64.rpm` | RPM de pré-requisitos. Configura grupos, limites, kernel params. |
| `oracle_opatch_dir` | `p6880880` | Diretório do OPatch substituto (versão mais nova que a do ZIP). |
| `oracle_ru_patch_dir` | `p37641958` | **Atualizar a cada trimestre** com o RU mais recente. |
| `oracle_ru_subpath` | `37641958/37642901` | Subpath do patch RU dentro do diretório. |
| `oracle_oneoff_subpath` | `37641958/37643161` | Subpath do patch one-off (aplicado junto ao RU). |
| `oracle_post_patch1_dir` | `p38291812` | Patch pós-instalação 1 (após runInstaller). |
| `oracle_post_patch2_dir` | `p38632161` | Patch pós-instalação 2 (Oracle 19.30). |
| `oracle_post_patch3_dir` | `p34672698` | Patch pós-instalação 3. |

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
| `oracle_nchar_set` | `AL16UTF16` | National character set (para colunas NCHAR/NVARCHAR2). |
| `oracle_nls_language` | `AMERICAN` | Idioma para mensagens de erro e formatos. |
| `oracle_nls_territory` | `AMERICA` | Território para formatos de data/número. |
| `oracle_listener_port` | `1521` | Porta do listener Oracle (padrão do setor). |
| `oracle_undo_tablespace` | `UNDOTBS1` | Nome da tablespace de undo. |

### Senhas (defaults do role — não estão no survey de instalação)

| Variável | Padrão | Descrição |
|---|---|---|
| `oracle_sys_password` | definido em `defaults/main.yml` | Senha do usuário SYS (superusuário). Override via extra vars ou vault em produção. |
| `oracle_system_password` | definido em `defaults/main.yml` | Senha do usuário SYSTEM. Override via extra vars ou vault em produção. |

> **Em produção:** nunca usar os defaults. Setar via AWX extra variables com vault ou credential injection.

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

Aplicar o Release Update (RU) durante a instalação faz o Oracle home já nascer no patch level correto. A alternativa — opatch apply após instalar — exige descompactar o RU separadamente, parar todos os processos Oracle, aplicar, e verificar. Mais complexo e mais propenso a erros. O one-off é aplicado junto via `-applyOneOffs`.

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
| `oracle_patches` | opatch em sequência — RU, one-off, post-install (Phase 5) |
| `oracle_dbcreate` | Criação do banco, catalog, datapatch, SPFILE (Phase 6) |
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
