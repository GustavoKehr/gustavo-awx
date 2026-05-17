# Oracle 19c — Runbook Operacional AWX

Guia prático para instalar Oracle 19c e gerenciar usuários via AWX Job Templates.

> **Para iniciantes:** A instalação do Oracle 19c é uma das mais complexas do mercado de banco de dados. Este runbook automatiza todo o processo — mas exige que os binários estejam preparados antecipadamente.

---

## Pré-requisitos Obrigatórios

**Antes de qualquer job, verificar:**

### 1. Arquivos no AWX VM (awxvm — 192.168.137.153)

O playbook usa **dois diretórios** no AWX VM como source do rsync:

**`/opt/oracle/`** — installer zip, RPM, libnsl, OS Watcher:
```bash
ls -la /opt/oracle/
```

| Item | Tipo | Descrição |
|---|---|---|
| `LINUX.X64_193000_db_home.zip` | Arquivo | Binários Oracle 19c (~3 GB) |
| `oracle-database-preinstall-19c-1.0-1.el9.x86_64.rpm` | Arquivo | RPM de pré-requisitos RHEL 9 |
| `libnsl_libs/` | Diretório | `libnsl.so.1` e `libnsl.so.2` — copiados para `/usr/lib64/` no target se ausentes |
| `oswbb840.tar` | Arquivo | OS Watcher (OSWbb) — obrigatório para Phase 6c (`oracle_oswatcher`) |

**`/opt/patches/`** — OPatch e todos os patches:
```bash
ls -la /opt/patches/
```

| Item | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `p6880880/OPatch/` | Diretório | **Sim** | OPatch substituto (versão mais nova que a do ZIP) |
| `p37641958/` | Diretório | **Sim** (~3 GB) | Bundle legado — ainda transferido para o target via rsync, mas runInstaller **não** o usa mais como `-applyRU`. Manter em `/opt/patches/`. |
| `p38632161/38632161/` | Diretório | **Sim** | Usado como argumento `-applyRU` no runInstaller (Oracle 19.30, RHEL9/GCC11). Também aplicado standalone via opatch (pula se já no inventário). |
| `p34672698/34672698/` | Diretório | **Sim** | Patch oradism (post_patch3) — aplicado via opatch pós-install |

> **Atenção:** O AWX EE acessa estes diretórios diretamente — o rsync é delegado para `awxvm` (não roda dentro do container EE). Os arquivos devem estar no host `awxvm`, não dentro do EE.

### 2. Target VM

- VM ligada e acessível via SSH
- Usuário `user_aap` com sudo NOPASSWD
- Mínimo **6 GB RAM** (SGA 40% = ~2.4 GB em VM 6 GB; menos causa ORA-27072 AIO EINTR)
- Disco adicional em `/dev/sdb` (≥ 65 GB para defaults: 50+5+2+2+2+1+1+1+1 GB)

### 3. AWX Execution Environment

EE precisa montar `/opt/oracle` e `/opt/patches` do host awxvm (configurado via operador patch no k3s). Verificar nos logs do job que ambos os paths existem.

---

## Estrutura de LVs e Diretórios no Target

```
/home/oracle/software/               ← staging dos binários (rsync do AWX — fora do lv_base)

/oracle/<SID>/                       ← lv_<SID> (base: Oracle home, scripts)
├── 19.0.0/                          ← ORACLE_HOME (binários)
├── oraInventory/                    ← inventory Oracle
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
| `oracle_transfer` | 3 | Rsync installer + OPatch + RU + post-patches para `/home/oracle/software` (~8 GB) | 5-20 min |
| `oracle_install_sw` | 4 | unzip + troca OPatch + runInstaller **com `-applyRU p38632161`** (sem -applyOneOffs) + root.sh | 15-30 min |
| `oracle_patches` | 5 | opatch: p38632161(19.30 RU) → oradism chown → p34672698(oradism) → oradism restore | 5-15 min |
| `oracle_dbcreate` | 6 | orapwd + CreateDB.sql → CreateDBFiles.sql → catalog/catproc → datapatch → SPFILE → utlrp → Users_and_Objects.sql | 10-20 min |
| `oracle_netcfg` | 6b | listener.ora / tnsnames.ora / sqlnet.ora + lsnrctl LISTENER_\<SID\> + ALTER SYSTEM REGISTER | < 1 min |
| `oracle_oswatcher` | 6c | Transfer `oswbb840.tar` de awxvm → target + extract + systemd `oswatcher.service` enable+start. Também: check/start via `oracle_configuration_check.yml` | 1-2 min |
| `oracle_configuration_check` | 7 | security/config checks + auto-remediation + SHUTDOWN/STARTUP (quando `create_initial_db=true` e `oracle_configuration_check_enabled=true`) | 2-5 min |
| `oracle_manage_users` | 8 | gestão de usuários Oracle (quando `oracle_manage_users_enabled=true`) | 1-3 min |
| `db_patches` | 9 | patch discovery — sem apply (`db_patches_enabled=false` por padrão) | 1-2 min |
| `oracle_security` | 10 | security audit (oracle_security_check) — requer `oracle_security_check_enabled=true` | 2-5 min |

**Tempo total medido:** ~12 min (Job AWX 428, fresh VM, 2026-05-17)

---

## Cenários de Execução

### Cenário 1: Instalação completa do zero

**Survey a preencher:**

| Campo | Valor de exemplo |
|---|---|
| Oracle SID | `AWOR` |
| SYS Password | `<senha segura>` |
| SYSTEM Password | `<senha segura>` |
| Data Disk | `/dev/sdb` (deixar vazio se VG já existe) |
| VG Name | `vg_data` |
| LV base size | `50G` |
| LV oradata size | `5G` |
| LV oraarch size | `2G` |
| LV undofile size | `2G` |
| LV tempfile size | `2G` |
| LV mirrlog size | `1G` |
| LV origlog size | `1G` |
| SGA % de RAM | `40` |
| PGA % de RAM | `20` |
| Listener Port | `1521` |
| Character Set | `AL32UTF8` |

Não especificar tags — roda todas as fases (storage → prereqs → dirs → transfer → install → patches → dbcreate → configuration_check).

---

### Cenário 2: Re-executar só a criação do banco

**Quando usar:** Software já instalado, banco não criado (CreateDB.sql falhou, sqlplus travou, etc.).

```bash
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_dbcreate -l oraclevm
```

> **Atenção:** Guard em `06_create_database.yml` verifica `control01.ctl`. Se arquivo existir de run parcial, a task pula. Deletar control files antes de re-executar — ver troubleshooting abaixo.

---

### Cenário 3: Atualizar patches (novo RU trimestral)

Os patches estão **hardcoded nos defaults do role** — não são variáveis de survey. Para trocar o RU:

1. Baixar o novo RU do Oracle Support e colocar em `/opt/patches/p<NOVO>/` no awxvm
2. Editar `roles/oracle_install/defaults/main.yml`:
   ```yaml
   oracle_post_patch2_dir: "p<NOVO>"       # era p38632161
   oracle_post_patch2_sub: "<NUM>"         # era 38632161
   ```
3. Se houver novo post_patch3 (oradism):
   ```yaml
   oracle_post_patch3_dir: "p<NOVO3>"
   oracle_post_patch3_sub: "<NUM3>"
   ```
4. Executar apenas Phase 3 (transfer) + Phase 4 (install) para re-aplicar RU via runInstaller:
   ```bash
   ansible-playbook playbooks/deploy_oracle.yml \
     --tags oracle_transfer,oracle_install_sw -l oraclevm
   ```
5. Executar Phase 5 para re-aplicar patches opatch:
   ```bash
   ansible-playbook playbooks/deploy_oracle.yml --tags oracle_patches -l oraclevm
   ```

> **Nota:** `oracle_ru_patch_dir` (p37641958) é variável legada — o diretório ainda é transferido para o target mas o `runInstaller` **não** o usa mais. O RU aplicado via `-applyRU` é `oracle_post_patch2_dir` (p38632161). Manter p37641958 em `/opt/patches/` até confirmar que o role não o referencia mais.

---

### Cenário 3b: Re-criar arquivos de rede do listener

**Quando usar:** listener.ora / tnsnames.ora / sqlnet.ora ausentes ou corrompidos. Listener `LISTENER_<SID>` não iniciando.

```bash
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_netcfg -l oraclevm
```

Idempotente: só para/reinicia o listener se `listener.ora` mudou. Executa `ALTER SYSTEM REGISTER` no final.

---

### Cenário 3c: Re-executar configuration check

**Quando usar:** Banco criado, mas verificações de segurança/config não rodaram ou falharam.

```bash
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_configuration_check -l oraclevm
```

Requer `create_initial_db=true` e `oracle_configuration_check_enabled=true` (default: true quando `create_initial_db=true`).

---

### Cenário 3d: Instalar / verificar OS Watcher

**Quando usar:** OSW não instalado ou não rodando. Instala e registra como systemd service.

**Via AWX (JT "ORACLE | Configuration Check", tag `oracle_oswatcher`):**
- JT 27, limit: host alvo, tag: `oracle_oswatcher`, extra vars: `oracle_sid: <SID>`

**Via CLI:**
```bash
# Instalação standalone (Phase 6c do deploy_oracle.yml):
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_oswatcher \
  -e oracle_sid=AWOR -l oraclevm

# Ou via oracle_configuration_check.yml (instala + verifica processo):
ansible-playbook playbooks/oracle_configuration_check.yml \
  --tags oracle_oswatcher -e oracle_sid=AWOR -l oraclevm
```

**Verificar:**
```bash
systemctl status oswatcher.service
pgrep -a -f "startOSWbb.sh"
ls /home/oracle/oswbb/startOSWbb.sh
```

---

### Cenário 3e: Executar security audit (Phase 10)

**Quando usar:** Auditoria de segurança pós-instalação ou verificação periódica de compliance.

```bash
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_security \
  -e oracle_security_check_enabled=true -l oraclevm
```

> **Nota:** `oracle_security_check_enabled` default é `false` — deve ser explicitamente ativado.
> Para check combinado (config + security + report HTML), usar `oracle_configuration_check.yml` sem tags.

---

### Cenário 4: Re-transferir binários

**Quando usar:** Arquivos em oraclevm foram corrompidos ou espaço foi liberado.

```bash
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_transfer -l oraclevm
```

O rsync só retransfer o que mudou — se os arquivos estiverem intactos, a task termina rápido.

---

## Fases Pós-Instalação (7–10)

### Phase 7 — oracle_configuration_check

Executa automaticamente após `oracle_dbcreate` quando `create_initial_db=true` e `oracle_configuration_check_enabled=true`:

- Auditorias de configuração/performance/disponibilidade com auto-remediation
- SHUTDOWN + STARTUP para efetivar parâmetros do SPFILE
- Relatório HTML gerado em `/tmp/oracle_config_check_<SID>_<date>.html` + copiado para `reports/`

### Phase 8 — oracle_manage_users

Gestão de usuários Oracle via survey. Só roda quando `oracle_manage_users_enabled: true` (default: `false`).

Usar o Job Template dedicado `ORACLE | Manage Users` com survey `awx_survey_oracle_manage_users.json`.

### Phase 9 — db_patches

Patch discovery: lista patches Oracle disponíveis em `/opt/patches/` sem aplicar. Só roda quando `db_patches_enabled: true` (default: `false`). `db_patch_apply_enabled` é sempre `false` por design — aplicação requer janela de manutenção aprovada.

### Phase 10 — oracle_security (standalone)

Auditoria de segurança via `oracle_security_check` role. Roda automaticamente dentro de `oracle_configuration_check.yml`.

**Recomendado — check combinado (config + security + report):**
```bash
ansible-playbook playbooks/oracle_configuration_check.yml \
  -e oracle_sid=AWOR -e oracle_allow_restart=false -l oraclevm
```

**Somente security audit via deploy_oracle.yml:**
```bash
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_security \
  -e oracle_security_check_enabled=true -l oraclevm
```

Relatório HTML: `reports/oracle_config_check_<SID>_<date>.html`

---

## Job Template AWX — Configuration Check (ID 27)

| Campo AWX | Valor |
|---|---|
| **Name** | `ORACLE \| Configuration Check` |
| **Playbook** | `playbooks/oracle_configuration_check.yml` |
| **Inventory** | `LINUX` |
| **Credentials** | `Machine: user_aap` |
| **Limit** | *(prompt on launch)* |
| **Survey** | `oracle_sid` (text, default: `AWOR`) · `oracle_allow_restart` (multiplechoice, default: `false`) |
| **Tags** | *(vazio = config + security + report)* · `oracle_oswatcher` = só OSW install/check |

**Fases executadas (sem tag):**
- Phase 0: instala OSW se não presente (`oracle_oswatcher`)
- Phase 1: oracle_configuration_check + auto-remediation + report HTML
- Phase 2: oracle_security_check

**Tag `oracle_oswatcher` apenas:**
- Phase 0: transfer + install + systemd service
- Phase 1 / 5.3: verifica processo, inicia via systemd se parado

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
sudo du -sh /home/oracle/software/*
```

**Guard de idempotência do rsync:** A task verifica se o diretório destino existe **e não está vazio**. Se rsync foi interrompido e deixou diretório parcialmente preenchido, a próxima execução **pula o rsync** (vê dir não-vazio). Resultado: conteúdo incompleto → opatch falha com `FileNotFoundException`.

**Fix:**
```bash
# Forçar re-rsync deletando o dir no target:
sudo rm -rf /home/oracle/software/<patch_dir>
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
sudo du -sh /home/oracle/software/*
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
| **Project** | (projeto apontando para a raiz do repositório `gustavo-awx`) |
| **Execution Environment** | `oracle-ee` (EE com `/opt/oracle` e `/opt/patches` montados) |
| **Playbook** | `playbooks/deploy_oracle.yml` |
| **Credentials** | `Machine: user_aap` |
| **Limit** | `oraclevm-fresh` *(ou marcar "Prompt on launch")* |
| **Verbosity** | Normal (0) |
| **Enable Privilege Escalation** | ✅ (become: true no playbook) |

---

### Passo 2 — Extra Variables

Na aba **Variables** do Job Template, setar:

As senhas SYS e SYSTEM são coletadas pelo **survey** (campos tipo `password`) — não precisam ficar em Extra Variables. Se quiser forçar um valor diferente do survey via extra vars:

```yaml
oracle_sys_password: "SuaSenhaSegura123!"
oracle_system_password: "SuaSenhaSegura123!"
```

Variáveis opcionais (só setar se precisar mudar o default):

```yaml
# Controle de patches — omitir usa os defaults de defaults/main.yml
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
   - **Nota:** AWX project configurado para branch `main` do repositório `GustavoKehr/gustavo-awx`

| # | Question Name | Variable | Type | Default | Required | Min | Max |
|---|---|---|---|---|---|---|---|
| 1 | Oracle SID | `oracle_sid` | Text | `AWOR` | Sim | 1 | 8 |
| 2 | SYS Password | `oracle_sys_password` | Password | *(empty)* | Sim | — | — |
| 3 | SYSTEM Password | `oracle_system_password` | Password | *(empty)* | Sim | — | — |
| 4 | Data Disk (PV source) | `oracle_data_disk` | Text | `/dev/sdb` | Não | 0 | 20 |
| 5 | VG Name | `oracle_vg_name` | Text | `vg_data` | Sim | 1 | 32 |
| 6 | LV: lv_\<SID\> size (base) | `oracle_lv_base_size` | Text | `50G` | Sim | 2 | 10 |
| 7 | LV: lv_oradata size | `oracle_lv_oradata_size` | Text | `5G` | Sim | 2 | 10 |
| 8 | LV: lv_oraarch size | `oracle_lv_oraarch_size` | Text | `2G` | Sim | 2 | 10 |
| 9 | LV: lv_undofile size | `oracle_lv_undofile_size` | Text | `2G` | Sim | 2 | 10 |
| 10 | LV: lv_tempfile size | `oracle_lv_tempfile_size` | Text | `2G` | Sim | 2 | 10 |
| 11 | LV: lv_mirrlogA/B size | `oracle_lv_mirrlogA_size` | Text | `1G` | Sim | 2 | 10 |
| 12 | LV: lv_origlogA/B size | `oracle_lv_origlogA_size` | Text | `1G` | Sim | 2 | 10 |
| 13 | SGA % of VM RAM | `oracle_sga_pct` | Integer | `40` | Sim | 10 | 80 |
| 14 | PGA % of VM RAM | `oracle_pga_pct` | Integer | `20` | Sim | 5 | 50 |
| 15 | Listener Port | `oracle_listener_port` | Integer | `1521` | Sim | 1024 | 65535 |
| 16 | Character Set | `oracle_character_set` | Text | `AL32UTF8` | Não | 5 | 30 |
| 17 | TS_AUDIT_DAT01 datafiles | `ts_audit_datafiles` | Integer | `1` | Não | 1 | 10 |
| 18 | TS_PERFSTAT_DAT01 datafiles | `ts_perfstat_datafiles` | Integer | `1` | Não | 1 | 10 |
| 19 | TS_\<SID\>_DAT01 datafiles | `ts_sid_dat_datafiles` | Integer | `1` | Não | 1 | 10 |
| 20 | TS_\<SID\>_IDX01 datafiles | `ts_sid_idx_datafiles` | Integer | `1` | Não | 1 | 10 |

> **Alternativa:** importar o JSON completo via curl (AWX usa HTTP, porta 31911):
> ```bash
> # Na awxvm — substitua <JT_ID> pelo ID do Job Template criado
> curl -u admin:suasenha \
>   -X POST http://192.168.137.153:31911/api/v2/job_templates/<JT_ID>/survey_spec/ \
>   -H "Content-Type: application/json" \
>   -d @/home/user_aap/gustavo-awx/playbooks/awx_survey_oracle_install.json
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
ls -la /opt/patches/p38632161/
ls -la /opt/patches/p34672698/
ls -la /opt/oracle/oswbb840.tar

# SSH no target (ex: oraclevm-fresh 192.168.137.165):
ssh user_aap@192.168.137.165
df -h           # confirmar disco livre
free -m         # confirmar RAM
lsblk           # confirmar /dev/sdb disponível
```

---

## Ver Também

- [`oracle_guide.md`](oracle_guide.md) — Documentação técnica completa
- [`offline_requirements.md`](offline_requirements.md) — Como preparar binários Oracle offline
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
