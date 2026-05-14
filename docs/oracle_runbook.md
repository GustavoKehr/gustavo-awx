# Oracle 19c — Runbook Operacional AWX

Guia prático para instalar Oracle 19c e gerenciar usuários via AWX Job Templates.

> **Para iniciantes:** A instalação do Oracle 19c é uma das mais complexas do mercado de banco de dados. Este runbook automatiza todo o processo — mas exige que os binários estejam preparados antecipadamente.

---

## Pré-requisitos Obrigatórios

**Antes de qualquer job, verificar:**

### 1. Arquivos em `/opt/oracle` no AWX VM

```bash
ls -la /opt/oracle/
```

| Item | Tipo | Descrição |
|---|---|---|
| `LINUX.X64_193000_db_home.zip` | Arquivo | Binários Oracle 19c (~3 GB) |
| `oracle-database-preinstall-19c-1.0.2.el9.x86_64.rpm` | Arquivo | RPM de pré-requisitos RHEL |
| `p6880880/` | Diretório | Substituição do OPatch |
| `p37641958/` | Diretório | Release Update (RU) + one-off |
| `p38291812/` | Diretório | Patch pós-instalação 1 |
| `p38632161/` | Diretório | Patch pós-instalação 2 (Oracle 19.30) |
| `p34672698/` | Diretório | Patch pós-instalação 3 (oradism) |

### 2. Target VM

- VM ligada e acessível via SSH
- Usuário `user_aap` com sudo NOPASSWD
- Mínimo **6 GB RAM** (SGA 40% = 1.4 GB; menos causa ORA-27072 AIO EINTR)
- Mínimo **64 GB disco** em `/dev/sdb` (VG `vg_data`); lv_base recomendado ≥ 40 GB

### 3. AWX Execution Environment

O EE deve ter `/opt/oracle` montado (configurado via operador patch no AWX). Verificar nos logs do job que o path existe.

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
| `oracle_prereqs` | 1 | RPM preinstall, sysctl, workaround RHEL 9, hugepages, calc SGA/PGA | 5-10 min |
| `oracle_dirs` | 2 | Estrutura de diretórios, bash_profile, sysctl Oracle | 2-3 min |
| `oracle_transfer` | 3 | Rsync ~8 GB do AWX para `/oracle/<SID>/software` | 15-30 min |
| `oracle_install_sw` | 4 | Descompactar + runInstaller silencioso + root.sh | 10-20 min |
| `oracle_patches` | 5 | opatch: RU → one-off → post1 → post2 → oradism → post3 | 15-30 min |
| `oracle_dbcreate` | 6 | Criação do banco, catalog/catproc, datapatch, SPFILE | 10-20 min |

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

**Quando usar:** Software já instalado, banco não criado (dbca falhou).

```bash
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_dbcreate -l oraclevm
```

---

### Cenário 3: Atualizar patches (novo RU trimestral)

1. Colocar novo patch em `/opt/oracle/p<NOVO>/`
2. Atualizar `oracle_ru_patch_dir` e `oracle_ru_subpath` nos defaults ou via survey
3. Executar só a fase de patches:

```bash
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_patches -l oraclevm
```

> **Atenção:** Aplicar patches requer banco parado. O playbook para e reinicia automaticamente.

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

```bash
# SSH no target (ex: oraclevm 192.168.137.163)
# Substituir <SID> pelo SID usado no survey (ex: AWOR)
ssh user_aap@192.168.137.163

# Verificar banco OPEN:
sudo -u oracle /oracle/<SID>/19.0.0/bin/sqlplus / as sysdba <<EOF
SELECT status FROM v\$instance;
SELECT name, db_unique_name FROM v\$database;
EOF

# Verificar oratab registrado:
grep <SID> /etc/oratab

# Verificar listener:
sudo -u oracle /oracle/<SID>/19.0.0/bin/lsnrctl status

# Verificar patches aplicados:
sudo -u oracle /oracle/<SID>/19.0.0/OPatch/opatch lsinventory | grep "Patch description"

# Verificar LVs montados:
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

## Ver Também

- [`oracle_guide.md`](oracle_guide.md) — Documentação técnica completa
- [`offline_requirements.md`](offline_requirements.md) — Como preparar binários Oracle offline
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
