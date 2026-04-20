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
- `ORACLE_BASE` = `/oracle/TSTOR`
- `ORACLE_HOME` = `/oracle/TSTOR/19.0.0`
- `oracle_sid` = `TSTOR` (identificador do banco)

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

**ANTES de executar qualquer fase, os arquivos abaixo devem estar em `/opt/oracle` no AWX VM:**

| Arquivo | Descrição | Tamanho aprox. |
|---|---|---|
| `LINUX.X64_193000_db_home.zip` | Binários Oracle 19c | ~3 GB |
| `oracle-database-preinstall-19c-1.0.2.el9.x86_64.rpm` | RPM de pré-requisitos RHEL | ~25 KB |
| `p6880880/` | Substituição do OPatch (versão mais nova) | ~200 MB |
| `p37641958/` | Release Update (RU) atual | ~3 GB |
| `p38291812/` | Patch pós-instalação 1 | varia |
| `p32249704/` | Patch pós-instalação 2 | varia |
| `p3467298/` | Patch pós-instalação 3 | varia |

**Verificar antes de iniciar:**
```bash
ls -la /opt/oracle/
# Confirmar que todos os arquivos/diretórios estão presentes
```

**Hardware mínimo recomendado para Oracle 19c:**
- RAM: 8 GB (2 GB para SGA padrão + SO)
- Disco: 50 GB (software + banco + logs)
- CPU: 2 vCPUs

---

## Playbook — deploy_oracle.yml

6 fases sequenciais. Cada fase depende da anterior.

```
Phase 1: oracle_prereqs    → tags: oracle_prereqs    → RPM, hugepages, workaround RHEL 9
Phase 2: oracle_dirs       → tags: oracle_dirs       → estrutura de diretórios, bash_profile
Phase 3: oracle_transfer   → tags: oracle_transfer   → rsync ~5 GB do AWX para oraclevm
Phase 4: oracle_install_sw → tags: oracle_install_sw → descompactar + runInstaller + root.sh
Phase 5: oracle_patches    → tags: oracle_patches    → opatch em sequência (RU → one-off → post)
Phase 6: oracle_dbcreate   → tags: oracle_dbcreate   → dbca silencioso + verificação + oratab
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

| Variável | Padrão | Obrigatório | Descrição |
|---|---|---|---|
| `oracle_sid` | `TSTOR` | **Sim** | Identificador único do banco. Define o nome dos diretórios e o oratab. |
| `oracle_base` | `/oracle/{{ oracle_sid }}` | Não | Calculado a partir do SID. Raiz de todas as instalações. |
| `oracle_home` | `{{ oracle_base }}/19.0.0` | Não | Calculado a partir do base. Onde ficam os binários. |

### Software e Patches

| Variável | Padrão | Descrição |
|---|---|---|
| `oracle_software_src` | `/opt/oracle` | Onde os binários estão no AWX VM (source do rsync). |
| `oracle_software_dst` | `/home/oracle/software` | Onde os binários chegam no oraclevm (destino do rsync). |
| `oracle_installer_zip` | `LINUX.X64_193000_db_home.zip` | Nome do arquivo ZIP com os binários do Oracle 19c. |
| `oracle_preinstall_rpm` | `oracle-database-preinstall-19c-1.0.2.el9.x86_64.rpm` | RPM de pré-requisitos. Configura grupos, limites, kernel params. |
| `oracle_opatch_dir` | `p6880880` | Diretório do OPatch substituto (versão mais nova que a do ZIP). |
| `oracle_ru_patch_dir` | `p37641958` | **Atualizar a cada trimestre** com o RU mais recente. |
| `oracle_ru_subpath` | `37641958/37642901` | Subpath do patch RU dentro do diretório. |
| `oracle_oneoff_subpath` | `37641958/37643161` | Subpath do patch one-off (aplicado junto ao RU). |
| `oracle_post_patch1_dir` | `p38291812` | Patch pós-instalação 1 (aplicado após runInstaller). |
| `oracle_post_patch2_dir` | `p32249704` | Patch pós-instalação 2. |
| `oracle_post_patch3_dir` | `p3467298` | Patch pós-instalação 3. |

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

### Tuning de Memória

| Variável | Padrão | Descrição |
|---|---|---|
| `oracle_sga_target` | `2G` | System Global Area — cache principal (buffers, shared pool, redo log). Impacta hugepages. |
| `oracle_pga_target` | `512m` | Program Global Area — memória por sessão (sorts, hash joins). |
| `oracle_processes` | `1000` | Máximo de processos Oracle simultâneos. |
| `oracle_open_cursors` | `3000` | Máximo de cursors abertos por sessão. |
| `oracle_db_block_size` | `8192` | Tamanho do bloco de dados (8 KB padrão). Não alterar após criação. |

### Configurações de Banco

| Variável | Padrão | Descrição |
|---|---|---|
| `oracle_character_set` | `WE8MSWIN1252` | Character set do banco. Define como textos são armazenados. Western Windows. |
| `oracle_nchar_set` | `AL16UTF16` | National character set (para colunas NCHAR/NVARCHAR2). |
| `oracle_nls_language` | `AMERICAN` | Idioma para mensagens de erro e formatos. |
| `oracle_nls_territory` | `AMERICA` | Território para formatos de data/número. |
| `oracle_listener_port` | `1521` | Porta do listener Oracle (padrão do setor). |
| `oracle_undo_tablespace` | `UNDOTBS1` | Nome da tablespace de undo. |

### Senhas (Obrigatório via Survey)

| Variável | Padrão | Descrição |
|---|---|---|
| `oracle_sys_password` | `""` | **Obrigatório via AWX survey.** Senha do usuário SYS (superusuário). Vazio = instalação falha intencionalmente. |
| `oracle_system_password` | `""` | **Obrigatório via AWX survey.** Senha do usuário SYSTEM. |

> **Nunca deixe senhas nos defaults.** O valor vazio é intencional — força o operador a sempre informar via survey.

### Controle de Fase

| Variável | Padrão | Descrição |
|---|---|---|
| `create_initial_db` | `true` | Se `false`, instala só o software sem criar banco (útil para preparar nó de standby). |

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

Oracle 19c não foi certificado para RHEL 9. Sem essa variável de ambiente, o instalador detecta RHEL 9 e rejeita a instalação. A variável faz o instalador acreditar que está em RHEL 8, contornando a verificação de plataforma. Oracle 19c funciona perfeitamente em RHEL 9 na prática.

### Por que `rc not in [0, 6]` no runInstaller?

O `runInstaller` retorna `rc=6` quando conclui com avisos (warnings) — isso é **normal** em instalações silenciosas. Tratar `rc=6` como falha bloquearia toda a automação. O playbook aceita rc=0 e rc=6 como sucesso.

### Por que `echo -e "y\ny" | opatch apply`?

O `opatch` em modo não-silencioso faz perguntas interativas durante a aplicação. Em automação não há terminal para responder. O pipe com `echo` injeta as respostas `y` automaticamente para cada pergunta.

### Por que rsync para os binários?

Oracle software + patches somam ~8 GB. O módulo `copy` do Ansible carrega o arquivo inteiro na memória do control node. O `synchronize` (rsync) transfere em streaming, suporta retomada de transferência interrompida, e só retransfer o que mudou se rodar novamente.

### Por que `-applyRU` durante o runInstaller?

Aplicar o Release Update (RU) durante a instalação faz o banco já nascer no patch level correto. A alternativa — aplicar após instalar — exige: parar o banco → opatch → reiniciar → verificar. Mais passos e mais risco de erro.

---

## Tags Disponíveis

| Tag | O que executa |
|---|---|
| `oracle` | Todas as tasks Oracle |
| `oracle_validate` | Validação de suporte de SO |
| `oracle_prereqs` | Pré-requisitos Phase 1 |
| `oracle_dirs` | Criação de diretórios Phase 2 |
| `oracle_transfer` | Transferência de binários Phase 3 |
| `oracle_install_sw` | Instalação do software Phase 4 |
| `oracle_patches` | Aplicação de patches Phase 5 |
| `oracle_dbcreate` | Criação do banco Phase 6 |
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

**Verificar no servidor:**
```bash
sudo -u oracle /oracle/TSTOR/19.0.0/bin/sqlplus / as sysdba <<EOF
SELECT status FROM v\$instance;
SELECT * FROM v\$database;
EOF
```

---

### Listener não iniciando

```bash
sudo -u oracle /oracle/TSTOR/19.0.0/bin/lsnrctl status
sudo -u oracle /oracle/TSTOR/19.0.0/bin/lsnrctl start
```

---

## Ver Também

- [`oracle_runbook.md`](oracle_runbook.md) — Guia operacional
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
- [`offline_requirements.md`](offline_requirements.md) — Preparar binários Oracle offline
