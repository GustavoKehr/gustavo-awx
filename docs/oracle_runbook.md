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
| `p3467298/` | Diretório | Patch pós-instalação 3 |

### 2. Target VM (oraclevm — 192.168.137.163)

- VM ligada e acessível via SSH
- Usuário `user_aap` com sudo NOPASSWD
- Mínimo 8 GB RAM, 50 GB disco livre

### 3. AWX Execution Environment

O EE deve ter `/opt/oracle` montado (configurado via operador patch no AWX). Verificar nos logs do job que o path existe.

---

## Estrutura de Diretórios Criada (Fase 2)

```
/oracle/TSTOR/
├── 19.0.0/              ← ORACLE_HOME (binários)
├── oraInventory/        ← inventory Oracle
├── admin/
│   ├── adump/           ← audit dump
│   ├── dpdump/          ← data pump
│   ├── pfile/           ← parâmetros
│   └── audit/           ← auditoria
├── oradata1/            ← datafiles + control02
├── origlogA/            ← redo log grupo 1 membro A + control03
├── origlogB/            ← redo log grupo 2 membro A
├── mirrlogA/            ← mirror redo grupo 1 + control01
├── mirrlogB/            ← mirror redo grupo 2
├── temp/                ← temporary tablespace
├── undo/                ← undo tablespace
├── oraarch/             ← archive logs
└── scripts/db_creation/TSTOR/  ← scripts de criação + logs
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
| `oracle_validate` | Pre | Validação de variáveis (SID, senhas) | < 1 min |
| `oracle_prereqs` | 1 | RPM preinstall, sysctl, workaround RHEL 9, hugepages | 5-10 min |
| `oracle_dirs` | 2 | Estrutura de diretórios, bash_profile, sysctl Oracle | 2-3 min |
| `oracle_transfer` | 3 | Rsync ~8 GB do AWX para oraclevm | 15-30 min |
| `oracle_install_sw` | 4 | Descompactar + runInstaller silencioso + root.sh | 20-40 min |
| `oracle_patches` | 5 | opatch: RU → one-off → post1 → post2 → oradism → post3 | 30-60 min |
| `oracle_dbcreate` | 6 | dbca silencioso + sqlplus check + oratab + datapatch | 20-40 min |

**Tempo total estimado:** 1h30 a 3h (dependendo da velocidade da rede e disco)

---

## Cenários de Execução

### Cenário 1: Instalação completa do zero

**Survey a preencher:**

| Campo | Valor |
|---|---|
| Oracle SID | `TSTOR` |
| SYS password | `Sys#Secure2024!` |
| SYSTEM password | `Sys#Secure2024!` |
| SGA target | `2G` |
| PGA target | `512m` |
| HugePages count | `0` (cálculo automático) |
| Create initial DB | `true` |

Não especificar tags — roda todas as 6 fases.

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
# SSH no oraclevm
ssh user_aap@192.168.137.163

# Verificar banco OPEN:
sudo -u oracle /oracle/TSTOR/19.0.0/bin/sqlplus / as sysdba <<EOF
SELECT status FROM v\$instance;
SELECT name, db_unique_name FROM v\$database;
EOF

# Verificar oratab registrado:
grep TSTOR /etc/oratab

# Verificar listener:
sudo -u oracle /oracle/TSTOR/19.0.0/bin/lsnrctl status

# Verificar patches aplicados:
sudo -u oracle /oracle/TSTOR/19.0.0/OPatch/opatch lsinventory | grep "Patch description"
```

---

## Troubleshooting

### Phase 3 (transfer) é lenta ou trava

**Causa:** Rede lenta ou arquivo sendo transferido pela primeira vez.

**Verificar progresso:**
```bash
# No AWX, acompanhar logs do job em tempo real
# Ou SSH no oraclevm e verificar tamanho dos arquivos:
du -sh /home/oracle/software/
```

---

### Phase 4 (install_sw) falha silenciosamente com rc=6

**rc=6 é sucesso.** O runInstaller retorna 6 quando há warnings — isso é normal. Se falhar com outro rc, verificar:

```bash
# Logs do instalador em oraclevm:
ls -la /oracle/TSTOR/oraInventory/logs/
tail -100 /oracle/TSTOR/oraInventory/logs/installActions*.log
```

---

### Phase 5 (patches) falha com "patch conflict"

**Causa:** Patch já aplicado anteriormente.

**Verificar:**
```bash
sudo -u oracle /oracle/TSTOR/19.0.0/OPatch/opatch lsinventory
```

---

### Banco não fica OPEN após dbca

```bash
# Tentar subir manualmente:
sudo -u oracle /oracle/TSTOR/19.0.0/bin/sqlplus / as sysdba <<EOF
STARTUP;
SELECT status FROM v\$instance;
EOF
```

---

## Ver Também

- [`oracle_guide.md`](oracle_guide.md) — Documentação técnica completa
- [`offline_requirements.md`](offline_requirements.md) — Como preparar binários Oracle offline
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
