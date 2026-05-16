# Oracle 19c — Runbook Operacional AWX

Guia prático para instalar Oracle 19c e gerenciar usuários via AWX Job Templates.

> **Para iniciantes:** A instalação do Oracle 19c é uma das mais complexas do mercado de banco de dados. Este runbook automatiza todo o processo — mas exige que os binários estejam preparados antecipadamente.

---

## Pré-requisitos Obrigatórios

**Antes de qualquer job, verificar:**

### 1. Arquivos no AWX VM (awxvm — 192.168.137.153)

O playbook usa **dois diretórios** no AWX VM como source do rsync:

**`/opt/oracle/`** — installer zip, RPM, libnsl:
```bash
ls -la /opt/oracle/
```

| Item | Tipo | Descrição |
|---|---|---|
| `LINUX.X64_193000_db_home.zip` | Arquivo | Binários Oracle 19c (~3 GB) |
| `oracle-database-preinstall-19c-1.0-1.el9.x86_64.rpm` | Arquivo | RPM de pré-requisitos RHEL 9 |
| `libnsl_libs/` | Diretório | `libnsl.so.1` e `libnsl.so.2` — copiados para `/usr/lib64/` no target se ausentes |

**`/opt/patches/`** — OPatch e todos os patches:
```bash
ls -la /opt/patches/
```

| Item | Tipo | Descrição |
|---|---|---|
| `p6880880/` | Diretório | OPatch substituto (versão mais nova que a do ZIP) |
| `p37641958/` | Diretório | Release Update (RU) + one-off — aplicados **dentro do runInstaller** (`-applyRU`) |
| `p38291812/` | Diretório | Patch pós-instalação 1 (post_patch1) |
| `p38632161/` | Diretório | Patch pós-instalação 2 — Oracle 19.30 (post_patch2) |
| `p34672698/` | Diretório | Patch pós-instalação 3 — oradism-related (post_patch3) |

> **Atenção:** O AWX EE acessa estes diretórios diretamente — o rsync é delegado para `awxvm` (não roda dentro do container EE). Os arquivos devem estar no host `awxvm`, não dentro do EE.

### 2. Target VM

- VM ligada e acessível via SSH
- Usuário `user_aap` com sudo NOPASSWD
- Mínimo **6 GB RAM** (SGA 40% = ~2.4 GB em VM 6 GB; menos causa ORA-27072 AIO EINTR)
- Disco adicional em `/dev/sdc` (≥ 85 GB para defaults: 60+10+5+5+5+1+1+1+1 GB)

### 3. AWX Execution Environment

EE precisa montar `/opt/oracle` e `/opt/patches` do host awxvm (configurado via operador patch no k3s). Verificar nos logs do job que ambos os paths existem.

---

## Estrutura de LVs e Diretórios no Target

```
/oracle/<SID>/                       ← lv_<SID> (base: Oracle home, software, scripts)
├── 19.0.0/                          ← ORACLE_HOME (binários)
├── oraInventory/                    ← inventory Oracle
├── software/                        ← staging dos binários (rsync do AWX)
├── admin/
│   ├── adump/                       ← audit dump
│   ├── dpdump/                      ← data pump
│   ├── pfile/                       ← parâmetros
│   └── audit/                       ← auditoria
├── oradata1/                        ← lv_oradata (datafiles + control02)
├── origlogA/                        ← lv_origlogA (redo log grupo 1 membro A + control03)
├── origlogB/                        ← lv_origlogB (redo log grupo 2 membro A)
├── mirrlogA/                        ← lv_mirrlogA (mirror redo grupo 1 + control01)
├── mirrlogB/                        ← lv_mirrlogB (mirror redo grupo 2)
├── oraarch/                         ← lv_oraarch (archive logs)
├── undofile/                        ← lv_undofile (undo tablespace)
├── tempfile/                        ← lv_tempfile (temp tablespace)
└── scripts/db_creation/<SID>/       ← scripts de criação + logs
```

---

## Job Template AWX — Instalação Completa

| Campo AWX | Valor |
|---|---|
| **Name** | `ORACLE \| Deploy` |
| **Playbook** | `playbooks/deploy_oracle.yml` |
| **Inventory** | `LINUX` |
| **Credentials** | `Machine: user_aap` |
| **Limit** | `oraclevm` |
| **Survey** | `awx_survey_oracle_install.json` |

---

## Tag Map — O que Cada Tag Faz

| Tag | Fase | O que executa | Duração aprox. |
|---|---|---|---|
| `oracle_storage` | 0 | PV/VG/LV creation, mkfs.xfs, mount de todos os LVs | 1-2 min |
| `oracle_validate` | — | Assert: oracle_sid, oracle_sys_password e oracle_system_password não-vazios | < 1 min |
| `oracle_prereqs` | 1 | RPM preinstall, libnsl copy, sysctl, hugepages calc, SGA/PGA calc, workaround RHEL 9 | 5-10 min |
| `oracle_dirs` | 2 | Estrutura de diretórios, bash_profile, init.ora, SQL scripts de criação | 1-2 min |
| `oracle_transfer` | 3 | Rsync installer + OPatch + RU + post-patches para `/oracle/<SID>/software` (~8 GB) | 5-20 min |
| `oracle_install_sw` | 4 | unzip + troca OPatch + runInstaller **com `-applyRU` e `-applyOneOffs`** + root.sh | 15-30 min |
| `oracle_patches` | 5 | opatch: post1 → post2 → oradism chown → post3 → oradism restore | 5-15 min |
| `oracle_dbcreate` | 6 | orapwd + CreateDB.sql → CreateDBFiles.sql → catalog/catproc → datapatch → SPFILE → utlrp → Users_and_Objects.sql | 10-20 min |

**Tempo total medido:** ~47 min (Job AWX 271, fresh VM, 2026-04-28)

---

## Cenários de Execução

### Cenário 1: Instalação completa do zero

**Survey a preencher:**

| Campo | Valor de exemplo |
|---|---|
| Oracle SID | `AWOR` |
| Data Disk | `/dev/sdc` (deixar vazio se VG já existe) |
| VG Name | `vg_data` |
| LV base size | `60G` |
| LV oradata size | `10G` |
| LV oraarch size | `5G` |
| LV undofile size | `5G` |
| LV tempfile size | `5G` |
| LV mirrlog size | `1G` |
| LV origlog size | `1G` |
| SGA % de RAM | `40` |
| PGA % de RAM | `20` |
| Character Set | `AL32UTF8` |

Não especificar tags — roda todas as 7 fases (storage → prereqs → dirs → transfer → install → patches → dbcreate).

---

### Cenário 2: Re-executar só a criação do banco

**Quando usar:** Software já instalado, banco não criado (CreateDB.sql falhou, sqlplus travou, etc.).

```bash
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_dbcreate -l oraclevm
```

> **Atenção:** Guard em `06_create_database.yml` verifica `control01.ctl`. Se arquivo existir de run parcial, a task pula. Deletar control files antes de re-executar — ver troubleshooting abaixo.

---

### Cenário 3: Atualizar patches (novo RU trimestral)

1. Colocar novo RU em `/opt/patches/p<NOVO>/` no awxvm
2. Colocar novos post-patches em `/opt/patches/p<NOVO_POST>/` no awxvm
3. Atualizar vars no AWX Job Template (Extra Variables ou defaults):
   ```yaml
   oracle_ru_patch_dir: "p<NOVO>"
   oracle_ru_subpath: "<NOVO>/<RU_SUB>"
   oracle_oneoff_subpath: "<NOVO>/<ONEOFF_SUB>"
   ```
4. Executar apenas Phase 3 (transfer) + Phase 4 (install) para RU:
   ```bash
   ansible-playbook playbooks/deploy_oracle.yml \
     --tags oracle_transfer,oracle_install_sw -l oraclevm
   ```

> **Nota:** RU é aplicado dentro do `runInstaller` com `-applyRU`. Para re-aplicar RU o instalador precisa ser re-executado. Phase 5 (`oracle_patches`) aplica apenas post-install patches (p38291812, p38632161, p34672698).

---

### Cenário 4: Re-transferir binários

**Quando usar:** Arquivos em oraclevm foram corrompidos ou espaço foi liberado.

```bash
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_transfer -l oraclevm
```

O rsync só retransfer o que mudou — se os arquivos estiverem intactos, a task termina rápido.

---

## Job Template AWX — Gestão de Usuários

| Campo AWX | Valor |
|---|---|
| **Name** | `ORACLE \| Manage Users` |
| **Playbook** | `playbooks/manage_oracle_users.yml` |
| **Inventory** | `LINUX` |
| **Credentials** | `Machine: user_aap` |
| **Limit** | `oraclevm` |
| **Extra Variables** | `oracle_manage_users_enabled: true` |
| **Survey** | `awx_survey_oracle_manage_users.json` |

---

## Cenários de Gestão de Usuários

### Criar usuário de aplicação

| Campo | Valor |
|---|---|
| Oracle username | `WEBAPP` |
| Oracle password | `App#Secure2024!` |
| User state | `present` |
| Privileges | `CONNECT,RESOURCE` |
| Roles | *(vazio)* |
| Revoke access | `false` |
| Default tablespace | `USERS` |
| Temp tablespace | `TEMP` |
| Allowed IPs | `192.168.1.50` |

---

### Criar DBA

| Campo | Valor |
|---|---|
| Oracle username | `DBADMIN` |
| Oracle password | `DBA#Admin2024!` |
| User state | `present` |
| Privileges | `CONNECT` |
| **Roles** | `DBA` |
| Revoke access | `false` |
| Default tablespace | `USERS` |
| Temp tablespace | `TEMP` |
| Allowed IPs | `192.168.137.1` |

---

### Remover usuário

| Campo | Valor |
|---|---|
| Oracle username | `OLDUSER` |
| Oracle password | *(qualquer)* |
| **User state** | `absent` |
| Allowed IPs | *(vazio)* |

> `DROP USER OLDUSER CASCADE` — remove o usuário e todos os objetos que ele possui.

---

## Checklist de Verificação Pós-Instalação

> **A maioria dos checks já roda automaticamente no job.** Ao final do Phase 6 (`oracle_dbcreate`), o playbook executa:
>
> - `lsnrctl start` + verify listener (falha o job se TNS-12541)
> - `SELECT status FROM v$instance` → assert `OPEN`
> - `SELECT VALUE FROM v$parameter WHERE name='spfile'` → assert SPFILE ativo
> - Summary block com DB_NAME, DB_VERSION, CHARSET, SGA_TARGET, PGA_TARGET, SPFILE, OPEN_MODE, oratab, listener status, LVs montados
>
> Patches verificados ao final do Phase 5 (`oracle_patches`) via `opatch lsinventory`.

Se precisar verificar manualmente após o job:

```bash
# SSH no target (substituir IP e <SID>)
ssh user_aap@192.168.137.165

# DB status
sudo -u oracle /oracle/<SID>/19.0.0/bin/sqlplus -s / as sysdba <<EOF
SELECT status FROM v\$instance;
EXIT;
EOF

# Listener
sudo -u oracle /oracle/<SID>/19.0.0/bin/lsnrctl status

# Patches
sudo -u oracle /oracle/<SID>/19.0.0/OPatch/opatch lsinventory | grep "Patch "

# LVs
df -h | grep oracle
```

---

## Troubleshooting

### AWX job marcado como failed com "Task was marked as running at system start up"

**Causa:** AWX task pod (`awx-server-task`) foi morto pelo OOMKiller enquanto job rodava. k3s reinicia o pod e marca o job em execução como zombie.

**Verificar:**
```bash
kubectl get pods -n awx
kubectl describe pod awx-server-task-<id> -n awx | grep -i oom
```

**Fix:** Aumentar RAM da awxvm no Proxmox:
```bash
# No Proxmox host:
qm set <VM_ID> -memory 8192
# Reiniciar awxvm para efetivar
```

---

### Phase 3 (transfer) é lenta ou trava

**Causa:** Rede lenta ou arquivo sendo transferido pela primeira vez.

**Verificar progresso:**
```bash
# SSH no target e verificar tamanho dos arquivos em staging:
sudo du -sh /oracle/<SID>/software/*
```

**Guard de idempotência do rsync:** A task verifica se o diretório destino existe **e não está vazio**. Se rsync foi interrompido e deixou diretório parcialmente preenchido, a próxima execução **pula o rsync** (vê dir não-vazio). Resultado: conteúdo incompleto → opatch falha com `FileNotFoundException`.

**Fix:**
```bash
# Forçar re-rsync deletando o dir no target:
sudo rm -rf /oracle/<SID>/software/<patch_dir>
# Relaunch do job — rsync vai re-transferir completo
```

---

### Phase 4 (install_sw) falha silenciosamente com rc=6

**rc=6 é sucesso.** O runInstaller retorna 6 quando há warnings — isso é normal. Se falhar com outro rc, verificar:

```bash
# Logs do instalador (substituir <SID>):
ls -la /oracle/<SID>/oraInventory/logs/
tail -100 /oracle/<SID>/oraInventory/logs/installActions*.log
```

---

### Phase 5 (patches) — `CheckSystemSpace` failed

**Causa:** opatch exige espaço livre no ORACLE_HOME LV para descompactar patch.

**Verificar:**
```bash
df -h /oracle/<SID>
sudo du -sh /oracle/<SID>/software/*
```

**Fix:** Estender lv_base:
```bash
# No target (como root):
lvextend -L +10G /dev/vg_data/lv_<SID>
xfs_growfs /oracle/<SID>
```

---

### Phase 5 (patches) — `OPatch failed — FileNotFoundException: perl.zip`

**Causa:** Diretório do patch existe mas está incompleto (rsync interrompido anteriormente).

**Fix:** Ver seção "Phase 3 — guard de idempotência" acima. Deletar dir e relaunch.

---

### Phase 5 (patches) — falha com "patch conflict"

**Causa:** Patch já aplicado anteriormente.

**Verificar:**
```bash
sudo -u oracle /oracle/<SID>/19.0.0/OPatch/opatch lsinventory
```

---

### Phase 6 (dbcreate) — banco não fica OPEN — ORA-19502 / ORA-27072

**Sintoma:** `ORA-27072: File I/O error, Additional info: 4 (EINTR), block XXXXXX` ao criar redo logs.

**Causa:** Pressão de memória no target VM. SGA muito grande para RAM disponível → kernel interrompe operações AIO (errno EINTR) durante write do redo log.

**Diagnóstico:**
```bash
# Verificar RAM disponível no target:
free -m
# Verificar alert log Oracle:
tail -50 /oracle/<SID>/admin/diag/rdbms/<sid>/<SID>/trace/alert_<SID>.log
```

**Fix:**
1. Aumentar RAM do VM target (mínimo 6 GB para SGA 40%)
2. Reduzir `oracle_sga_pct` no survey (ex: 40 → 25)
3. Variável `oracle_redo_log_size` em `CreateDB.sql.j2` — default `100M` (era `500M`)
4. Verificar LVs `lv_origlogA` e `lv_mirrlogA` ≥ 1G (tamanho do redo log + overhead XFS)

---

### Phase 6 (dbcreate) — CREATE DATABASE pulado (task retorna `ok` sem executar)

**Causa:** Guard em `06_create_database.yml`: `test -f mirrlogA/cntrl/control01.ctl && exit 0`. Control file de run com falha anterior ainda existe.

**Verificar:**
```bash
sudo ls /oracle/<SID>/mirrlogA/cntrl/
```

**Fix:**
```bash
# Shutdown Oracle primeiro:
export ORACLE_HOME=/oracle/<SID>/19.0.0 ORACLE_SID=<SID>
sudo -u oracle $ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
shutdown abort;
exit;
EOF

# Deletar control files de todas as cópias:
sudo rm -rf /oracle/<SID>/mirrlogA/cntrl \
            /oracle/<SID>/origlogA/cntrl \
            /oracle/<SID>/oradata1/cntrl
# Relaunch do job
```

---

### Banco não fica OPEN após dbcreate

```bash
# Verificar alert log para causa:
sudo tail -50 /oracle/<SID>/admin/diag/rdbms/<sid>/<SID>/trace/alert_<SID>.log

# Tentar subir manualmente:
sudo -u oracle /oracle/<SID>/19.0.0/bin/sqlplus / as sysdba <<EOF
STARTUP;
SELECT status FROM v\$instance;
EOF
```

---

## Configuração Manual do Job Template no AWX (sem API)

> Esta seção cobre o setup completo pela UI do AWX — campo a campo — para quem não tem acesso à API.

### Passo 1 — Criar o Job Template

AWX → **Templates** → **Add** → **Add job template**

| Campo | Valor |
|---|---|
| **Name** | `ORACLE \| Deploy` |
| **Job Type** | Run |
| **Inventory** | `LINUX` |
| **Project** | (projeto apontando para `deploy_oracle_with_vars`) |
| **Execution Environment** | `oracle-ee` (EE com `/opt/oracle` e `/opt/patches` montados) |
| **Playbook** | `playbooks/deploy_oracle.yml` |
| **Credentials** | `Machine: user_aap` |
| **Limit** | `oraclevm-fresh` *(ou marcar "Prompt on launch")* |
| **Verbosity** | Normal (0) |
| **Enable Privilege Escalation** | ✅ (become: true no playbook) |

---

### Passo 2 — Extra Variables

Na aba **Variables** do Job Template, setar:

```yaml
# Senhas obrigatórias — os defaults do role têm valor hardcoded F9toqfd(
# Em ambiente de lab pode deixar vazio (usa o default); em produção SEMPRE override aqui.
oracle_sys_password: "SuaSenhaSegura123!"
oracle_system_password: "SuaSenhaSegura123!"
```

Variáveis opcionais (só setar se precisar mudar o default):

```yaml
# Controle de patches — omitir usa os defaults de defaults/main.yml
oracle_post_patch1_enabled: true   # false se p38291812 não estiver em /opt/patches

# Controle de fases
create_initial_db: true            # false = instala só software (standby prep)

# Tuning avançado (raramente necessário)
oracle_hugepages: 0                # 0 = cálculo automático a partir de oracle_sga_pct
oracle_listener_port: 1521
oracle_processes: 1000
oracle_open_cursors: 3000
```

---

### Passo 3 — Importar o Survey

1. Na aba **Survey** do Job Template → **Enable Survey** (toggle ON)
2. Ao invés de criar campo por campo, usar a API de import:
   - Ir em **Templates** → selecionar o JT → **...** (kebab menu) → **Survey** não tem import direto na UI
   - **Alternativa via UI:** criar cada campo manualmente conforme tabela abaixo

| # | Question Name | Variable | Type | Default | Required | Min | Max |
|---|---|---|---|---|---|---|---|
| 1 | Oracle SID | `oracle_sid` | Text | `AWOR` | Sim | 1 | 8 |
| 2 | Data Disk (PV source) | `oracle_data_disk` | Text | `/dev/sdc` | Não | 0 | 20 |
| 3 | VG Name | `oracle_vg_name` | Text | `vg_data` | Sim | 1 | 32 |
| 4 | LV: lv_\<SID\> size (base) | `oracle_lv_base_size` | Text | `60G` | Sim | 2 | 10 |
| 5 | LV: lv_oradata size | `oracle_lv_oradata_size` | Text | `10G` | Sim | 2 | 10 |
| 6 | LV: lv_oraarch size | `oracle_lv_oraarch_size` | Text | `5G` | Sim | 2 | 10 |
| 7 | LV: lv_undofile size | `oracle_lv_undofile_size` | Text | `5G` | Sim | 2 | 10 |
| 8 | LV: lv_tempfile size | `oracle_lv_tempfile_size` | Text | `5G` | Sim | 2 | 10 |
| 9 | LV: lv_mirrlogA/B size | `oracle_lv_mirrlogA_size` | Text | `1G` | Sim | 2 | 10 |
| 10 | LV: lv_origlogA/B size | `oracle_lv_origlogA_size` | Text | `1G` | Sim | 2 | 10 |
| 11 | SGA % of VM RAM | `oracle_sga_pct` | Integer | `40` | Sim | 10 | 80 |
| 12 | PGA % of VM RAM | `oracle_pga_pct` | Integer | `20` | Sim | 5 | 50 |
| 13 | Character Set | `oracle_character_set` | Text | `AL32UTF8` | Não | 5 | 30 |
| 14 | TS_AUDIT_DAT01 datafiles | `ts_audit_datafiles` | Integer | `1` | Não | 1 | 10 |
| 15 | TS_PERFSTAT_DAT01 datafiles | `ts_perfstat_datafiles` | Integer | `1` | Não | 1 | 10 |
| 16 | TS_\<SID\>_DAT01 datafiles | `ts_sid_dat_datafiles` | Integer | `1` | Não | 1 | 10 |
| 17 | TS_\<SID\>_IDX01 datafiles | `ts_sid_idx_datafiles` | Integer | `1` | Não | 1 | 10 |

> **Alternativa:** importar o JSON completo via curl (uma linha, sem API browser):
> ```bash
> # Na awxvm — substitua <JT_ID> pelo ID do Job Template criado
> curl -sk -u admin:suasenha \
>   -X POST https://localhost/api/v2/job_templates/<JT_ID>/survey_spec/ \
>   -H "Content-Type: application/json" \
>   -d @/home/user_aap/deploy_oracle_with_vars/playbooks/awx_survey_oracle_install.json
> ```

---

### Passo 4 — Variáveis que o Role Compute Automaticamente

> Estas variáveis **nunca devem ser setadas** pelo operador — são calculadas internamente:

| Variável | Calculada em | Fórmula |
|---|---|---|
| `oracle_base` | defaults/main.yml | `/oracle/{{ oracle_sid }}` |
| `oracle_home` | defaults/main.yml | `{{ oracle_base }}/19.0.0` |
| `oracle_scripts_dir` | defaults/main.yml | `{{ oracle_base }}/scripts/db_creation/{{ oracle_sid }}` |
| `oracle_sga_target` | 01_prereqs.yml | `ansible_memtotal_mb × oracle_sga_pct / 100` (em MB) |
| `oracle_pga_target` | 01_prereqs.yml | `ansible_memtotal_mb × oracle_pga_pct / 100` (em MB) |
| `_oracle_hugepages_final` | 01_prereqs.yml | `ceil(SGA_MB / 2MB) × 1.10` (quando oracle_hugepages=0) |

---

### Passo 5 — Verificar antes de lançar

```bash
# Na awxvm — confirmar que source dirs existem e têm conteúdo:
ls -la /opt/oracle/LINUX.X64_193000_db_home.zip
ls -la /opt/oracle/oracle-database-preinstall-19c-1.0-1.el9.x86_64.rpm
ls -la /opt/oracle/libnsl_libs/
ls -la /opt/patches/p6880880/OPatch/
ls -la /opt/patches/p37641958/
ls -la /opt/patches/p38291812/
ls -la /opt/patches/p38632161/
ls -la /opt/patches/p34672698/

# SSH no target (ex: oraclevm-fresh 192.168.137.165):
ssh user_aap@192.168.137.165
df -h           # confirmar disco livre
free -m         # confirmar RAM
lsblk           # confirmar /dev/sdc disponível
```

---

## Ver Também

- [`oracle_guide.md`](oracle_guide.md) — Documentação técnica completa
- [`offline_requirements.md`](offline_requirements.md) — Como preparar binários Oracle offline
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
