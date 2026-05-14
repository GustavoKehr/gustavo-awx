# 02 — Padronizacao de Implementacao

## Database Lifecycle Management (DLM)

Todo banco de dados passa pelas seguintes fases. Cada fase exige documentacao e aprovacao:

```
Design → Develop → Test → Build → Deploy → Maintain → Monitor → Backup → Archive/Destroy
```

### Fase 1: Design
- Definir requisitos funcionais e nao-funcionais (RTO, RPO, SLA, volume)
- Selecionar banco adequado ao tipo de workload (OLTP, OLAP, cache, search)
- Projetar schema com convencoes padronizadas
- Definir estrategia de particionamento e indexacao
- Registrar no CMDB antes de qualquer provisionamento
- Escolher estrategia de HA e DR desde o inicio

### Fase 2: Develop
- Schema via migrations versionadas (Liquibase, Flyway, ou DbUp)
- Scripts idempotentes — podem ser re-executados sem efeito colateral
- Commits de schema somente via Pull Request com revisao obrigatoria

### Fase 3: Test
- Testes em banco isolado de desenvolvimento
- Validar migrations de upgrade E downgrade (rollback)
- Testes de performance com volume de dados representativo
- Verificacao de seguranca (privilegios, acesso anonimo, senhas padrao)

### Fase 4: Build
- Gerar artefatos de migration com versao semantica
- Armazenar no repositorio de artefatos (Nexus, Artifactory, S3)

### Fase 5: Deploy
- Deploy automatizado via pipeline CI/CD
- Sempre aplicar em homologacao antes de producao
- Verificacao pos-deploy: saude, migrations aplicadas, indices criados

### Fase 6: Maintain
- Patches e atualizacoes de versao em janelas de manutencao
- Gerenciar crescimento de tabelas (particionamento, archiving)
- Revisar e otimizar indices periodicamente

### Fase 7: Monitor
- Monitoramento continuo de KPIs (ver documento 07)
- Alertas automatizados para anomalias

### Fase 8: Backup
- Backups automatizados com verificacao de integridade (ver documento 06)
- Testes de restore mensais obrigatorios

### Fase 9: Archive/Destroy
- Arquivar dados historicos conforme politica de retencao
- Destruicao segura (DOD 5220.22-M ou NIST 800-88)
- Remover instancia do CMDB apos descomissionamento

---

## Selecao do Banco de Dados por Tipo de Workload

| Tipo | Caracteristica | Banco Recomendado |
|------|---------------|-------------------|
| OLTP alta concorrencia | Muitas transacoes curtas | PostgreSQL, MySQL, Oracle, SQL Server |
| OLAP / Analytics | Queries longas, grandes volumes | Vertica, Db2 BLU, Oracle |
| Cache / Session store | Latencia sub-milissegundo | Redis |
| Relacional enterprise | Recursos avancados, suporte premium | Oracle, SQL Server, Db2 |
| Open source OLTP | Custo, comunidade, cloud-native | PostgreSQL, MySQL |
| Data Warehouse colunar | Analytics em petabytes | Vertica |
| Fila / Pub-Sub | Mensagens, eventos | Redis Streams |
| Geoespacial | Dados geograficos | PostgreSQL (PostGIS) |

---

## Convencoes de Nomenclatura

Adotar convencoes consistentes elimina ambiguidades e facilita automacao.

### Nomenclatura de Objetos

| Objeto | Convencao | Exemplo |
|--------|-----------|---------|
| Tabelas | `snake_case`, singular | `customer_order` |
| Colunas | `snake_case` | `created_at`, `first_name` |
| Chave Primaria | `<tabela>_id` | `customer_order_id` |
| Chave Estrangeira | `<tabela_referenciada>_id` | `customer_id` |
| Indice | `idx_<tabela>_<coluna(s)>` | `idx_order_customer_id` |
| Indice Unico | `uq_<tabela>_<coluna(s)>` | `uq_customer_email` |
| Constraint CHECK | `chk_<tabela>_<descricao>` | `chk_order_status` |
| View | `vw_<descricao>` | `vw_monthly_sales` |
| Stored Procedure | `sp_<acao>_<objeto>` | `sp_get_customer_orders` |
| Function | `fn_<acao>_<objeto>` | `fn_calculate_tax` |
| Trigger | `trg_<tabela>_<evento>` | `trg_order_before_insert` |
| Sequence | `seq_<tabela>_<coluna>` | `seq_customer_order_id` |

### Regras Gerais
- **Sempre lowercase** — evita problemas de case sensitivity entre bancos
- **Sem abreviacoes** — use `customer_address` nao `cust_addr`
- **Sem espacos ou caracteres especiais** — use underscore
- **Evite palavras reservadas** — nao use `order`, `user`, `table`
- **Maximo 30 caracteres** — compativel com Oracle legado
- **Prefixo de dominio** para multi-dominio: `sales_orders`, `hr_employees`

### Nomenclatura de Instancias

```
Formato: <ambiente>-<tipo_banco>-<numero>
Exemplos:
  prod-pg-01       # PostgreSQL producao, instancia 1
  hml-mysql-02     # MySQL homologacao, instancia 2
  dev-oracle-01    # Oracle desenvolvimento
  prod-redis-01    # Redis producao
  prod-vertica-01  # Vertica producao
  prod-db2-01      # Db2 producao
```

---

## Versionamento de Schema (Schema Migration)

### Ferramentas por Banco

| Banco | Ferramenta Principal | Alternativa | Observacao |
|-------|---------------------|-------------|------------|
| PostgreSQL | Flyway | Liquibase | Flyway mais simples, Liquibase mais features |
| MySQL | Flyway | Liquibase | Ambos suportam MySQL nativamente |
| SQL Server | Flyway | DbUp | DbUp muito usado em .NET |
| Oracle | Liquibase | Flyway | Liquibase tem melhor suporte Oracle |
| Db2 | Liquibase | Flyway | Liquibase recomendado pela IBM |
| Vertica | Scripts SQL versionados | — | Vertica nao tem suporte nativo em ferramentas |
| Redis | Redis migrations (custom) | — | Sem ferramentas padrao; usar scripts versionados |

### Principios de Migration
1. **Imutavel** — nunca editar migration ja aplicada em qualquer ambiente
2. **Incremental** — numero de versao sequencial
3. **Idempotente** — `CREATE TABLE IF NOT EXISTS`, `DROP INDEX IF EXISTS`
4. **Rollback documentado** — toda migration com rollback correspondente
5. **DDL separado de DML** — mudancas de estrutura separadas de carga de dados
6. **Testavel** — CI executa migration em banco efemero em cada PR

### Estrutura de Diretorio
```
db/
├── migrations/
│   ├── V1__create_base_schema.sql
│   ├── V2__add_customer_table.sql
│   ├── V3__add_indexes.sql
│   └── V4__add_audit_columns.sql
├── callbacks/
│   ├── beforeMigrate.sql
│   └── afterMigrate.sql
└── seeds/
    └── R__reference_data.sql
```

---

## Implementacao por Banco de Dados

### PostgreSQL — Implementacao

**Prerequisitos minimos**:
- Sistema operacional: RHEL/Rocky/Ubuntu LTS (suporte de longo prazo)
- Filesystem: XFS ou ext4 para dados; NVME/SSD para WAL
- Kernel: `vm.overcommit_memory=2`, `vm.swappiness=1`, `hugepages` configurado
- Separar volumes: dados (`/var/lib/postgresql`), WAL (`/pg_wal`), logs, backups

**Instalacao padrao (RHEL/Rocky 8/9)**:
```bash
# Repositorio oficial PostgreSQL
dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
dnf -qy module disable postgresql
dnf install -y postgresql16-server postgresql16-contrib

# Inicializar com locale e encoding padrao
PGSETUP_INITDB_OPTIONS="--encoding=UTF8 --lc-collate=C --lc-ctype=C --data-checksums" \
    /usr/pgsql-16/bin/postgresql-16-setup initdb

systemctl enable --now postgresql-16
```

**Data checksums** (`--data-checksums`): obrigatorio em producao — detecta corrupcao silenciosa de dados.

**Configuracao de SO obrigatoria**:
```bash
# /etc/sysctl.d/postgresql.conf
vm.overcommit_memory = 2
vm.overcommit_ratio = 80
vm.swappiness = 1
kernel.shmmax = 17179869184
kernel.shmall = 4194304

# /etc/security/limits.d/postgresql.conf
postgres soft nofile 65536
postgres hard nofile 65536
postgres soft nproc  65536
postgres hard nproc  65536
```

**Estrutura de diretorios**:
```
/var/lib/postgresql/16/main/    # PGDATA — dados principais
/var/lib/postgresql/16/wal/     # WAL (volume separado, SSD NVMe)
/var/log/postgresql/            # Logs
/backup/postgresql/             # Backups
```

**Fontes**:
- https://www.postgresql.org/docs/current/installation.html
- https://www.postgresql.org/docs/current/kernel-resources.html
- https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server
- https://pgtune.leopard.in.ua/ (gerador de configuracao baseado em hardware)

---

### MySQL — Implementacao

**Prerequisitos minimos**:
- SO: RHEL/Rocky 8/9, Ubuntu 22.04 LTS
- Filesystem: XFS com `noatime,nodiratime`
- Separar volumes: dados, binlogs, undologs, tmpdir

**Instalacao padrao (RHEL/Rocky)**:
```bash
# Repositorio oficial MySQL
dnf install -y https://dev.mysql.com/get/mysql84-community-release-el9-1.noarch.rpm
dnf install -y mysql-community-server

# Parametros de inicializacao
systemctl start mysqld

# Pegar senha temporaria
grep 'temporary password' /var/log/mysqld.log

# Seguranca inicial
mysql_secure_installation

systemctl enable mysqld
```

**Configuracao de SO**:
```bash
# /etc/sysctl.d/mysql.conf
vm.swappiness = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# Limites
echo "mysql soft nofile 65535" >> /etc/security/limits.d/mysql.conf
echo "mysql hard nofile 65535" >> /etc/security/limits.d/mysql.conf
```

**Estrutura de diretorios**:
```
/var/lib/mysql/                 # datadir — dados principais
/var/lib/mysql-binlog/          # binlogs (volume separado)
/var/lib/mysql-tmp/             # tmpdir
/backup/mysql/                  # backups
```

**Fontes**:
- https://dev.mysql.com/doc/refman/8.0/en/linux-installation.html
- https://dev.mysql.com/doc/mysql-secure-deployment-guide/8.0/en/
- https://www.percona.com/blog/mysql-server-parameters/
- https://aws.amazon.com/blogs/database/best-practices-for-configuring-parameters-for-amazon-rds-for-mysql-part-1-parameters-related-to-performance/

---

### SQL Server — Implementacao

**Prerequisitos para Linux (RHEL/Rocky)**:
```bash
# Repositorio Microsoft
curl -o /etc/yum.repos.d/mssql-server.repo \
    https://packages.microsoft.com/config/rhel/9/mssql-server-2022.repo

dnf install -y mssql-server

# Configuracao inicial
/opt/mssql/bin/mssql-conf setup
# Escolher edicao, senha de SA, aceitar EULA

systemctl enable --now mssql-server

# SQL Server Agent (opcional)
dnf install -y mssql-server-agent
```

**Configuracao de SO (Linux)**:
```bash
# Memoria hugepages para SQL Server
echo "vm.nr_hugepages = 128" >> /etc/sysctl.d/mssql.conf
sysctl -p /etc/sysctl.d/mssql.conf

# Limites
echo "mssql soft nofile 65535" >> /etc/security/limits.d/mssql.conf
echo "mssql hard nofile 65535" >> /etc/security/limits.d/mssql.conf
```

**Estrutura de arquivos**:
```
/var/opt/mssql/data/             # dados e logs de transacao
/var/opt/mssql/log/              # error log, agent log
/var/opt/mssql/backup/           # backups locais
# tempdb: disco SSD local (D: no Azure, nvme no AWS)
```

**Configuracoes iniciais obrigatorias via T-SQL**:
```sql
-- Definir maximos de memoria
EXEC sp_configure 'max server memory (MB)', 51200;  -- 50GB exemplo
EXEC sp_configure 'min server memory (MB)', 4096;
RECONFIGURE;

-- Desabilitar features desnecessarias
EXEC sp_configure 'xp_cmdshell', 0;
EXEC sp_configure 'clr enabled', 0;
EXEC sp_configure 'Ad Hoc Distributed Queries', 0;
RECONFIGURE;

-- Configurar MAXDOP e Cost Threshold
EXEC sp_configure 'max degree of parallelism', 4;
EXEC sp_configure 'cost threshold for parallelism', 50;
EXEC sp_configure 'optimize for ad hoc workloads', 1;
RECONFIGURE;

-- Habilitar Query Store em todos os bancos novos
ALTER DATABASE model SET QUERY_STORE = ON;
ALTER DATABASE model SET QUERY_STORE (OPERATION_MODE = READ_WRITE,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 90),
    MAX_STORAGE_SIZE_MB = 1000);
```

**Fontes**:
- https://learn.microsoft.com/en-us/sql/linux/quickstart-install-connect-red-hat
- https://learn.microsoft.com/en-us/sql/relational-databases/performance/performance-monitoring-and-tuning-tools
- https://docs.aws.amazon.com/whitepapers/latest/best-practices-for-deploying-microsoft-sql-server/
- https://learn.microsoft.com/en-us/azure/azure-sql/virtual-machines/windows/performance-guidelines-best-practices-checklist

---

### Oracle Database — Implementacao

**Prerequisitos de SO (RHEL/Oracle Linux)**:
```bash
# Instalar prerequisitos Oracle
dnf install -y oracle-database-preinstall-19c
# OU para instalacao manual:
dnf install -y bc binutils elfutils-libelf elfutils-libelf-devel \
    fontconfig-devel glibc glibc-devel ksh libaio libaio-devel \
    libXrender libXrender-devel libX11 libXau libXi libXtst \
    libgcc libnsl libstdc++ libstdc++-devel libxcb make net-tools \
    nfs-utils targetcli smartmontools sysstat

# Criar grupos e usuario oracle
groupadd -g 54321 oinstall
groupadd -g 54322 dba
groupadd -g 54323 oper
useradd -u 54321 -g oinstall -G dba,oper oracle
```

**Configuracao de kernel** (`/etc/sysctl.d/97-oracle.conf`):
```bash
fs.aio-max-nr = 1048576
fs.file-max = 6815744
kernel.shmall = 2097152
kernel.shmmax = 4294967295
kernel.shmmni = 4096
kernel.sem = 250 32000 100 128
net.ipv4.ip_local_port_range = 9000 65500
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
vm.dirty_background_ratio = 3
vm.dirty_ratio = 15
```

**Limites de usuario** (`/etc/security/limits.d/oracle.conf`):
```
oracle soft nofile 1024
oracle hard nofile 65536
oracle soft nproc  16384
oracle hard nproc  16384
oracle soft stack  10240
oracle hard stack  32768
oracle soft memlock 134217728
oracle hard memlock 134217728
```

**Estrutura de diretorios**:
```
/u01/app/oracle/                 # ORACLE_BASE
/u01/app/oracle/product/19c/     # ORACLE_HOME
/u02/oradata/                    # dados (volume dedicado)
/u03/fast_recovery_area/         # FRA (volume dedicado)
/u04/archive/                    # archive logs (volume dedicado)
```

**Inicializacao do banco (DBCA)**:
```bash
# Criar banco com DBCA (Database Configuration Assistant)
dbca -silent -createDatabase \
    -templateName General_Purpose.dbc \
    -gdbName ORCL \
    -sid ORCL \
    -responseFile NO_VALUE \
    -characterSet AL32UTF8 \
    -nationalCharacterSet AL16UTF16 \
    -sysPassword SysSenha123! \
    -systemPassword SystemSenha123! \
    -createAsContainerDatabase false \
    -databaseType MULTIPURPOSE \
    -automaticMemoryManagement false \
    -totalMemory 8192 \
    -datafileDestination /u02/oradata \
    -recoveryAreaDestination /u03/fast_recovery_area \
    -recoveryAreaSize 10240 \
    -storageType FS \
    -emConfiguration NONE
```

**Configuracoes pos-criacao obrigatorias**:
```sql
-- Habilitar archivelog e force logging
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE FORCE LOGGING;
ALTER DATABASE OPEN;

-- Configurar FRA
ALTER SYSTEM SET DB_RECOVERY_FILE_DEST = '/u03/fast_recovery_area' SCOPE=BOTH;
ALTER SYSTEM SET DB_RECOVERY_FILE_DEST_SIZE = 50G SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_1 = 'LOCATION=USE_DB_RECOVERY_FILE_DEST' SCOPE=BOTH;

-- Adicionar redo logs adequados (minimo 3 grupos, 2 membros cada)
ALTER DATABASE ADD LOGFILE GROUP 4 ('/u02/oradata/orcl/redo04a.rdo',
    '/u03/fast_recovery_area/orcl/redo04b.rdo') SIZE 500M;
```

**Fontes**:
- https://docs.oracle.com/en/database/oracle/oracle-database/19/ladbi/
- https://docs.oracle.com/en/database/oracle/oracle-database/19/admin/
- https://docs.oracle.com/en/database/oracle/oracle-database/19/haovw/
- https://docs.oracle.com/cd/E11882_01/install.112/e24321/pre_install.htm

---

### IBM Db2 — Implementacao

**Prerequisitos de SO**:
```bash
# RHEL/Rocky
dnf install -y libaio numactl libstdc++ pam libpam

# Criar grupo e usuario
groupadd -g 999 db2iadm1
groupadd -g 998 db2fadm1
useradd -u 1001 -g db2iadm1 db2inst1
useradd -u 1002 -g db2fadm1 db2fenc1

# Configurar kernel
echo "kernel.msgmax = 65536" >> /etc/sysctl.d/db2.conf
echo "kernel.msgmnb = 65536" >> /etc/sysctl.d/db2.conf
echo "kernel.shmmax = 68719476736" >> /etc/sysctl.d/db2.conf
sysctl -p /etc/sysctl.d/db2.conf
```

**Instalacao**:
```bash
# Extrair e instalar
tar -xvf v11.5.x_linuxx64_server.tar.gz
cd server_dec
./db2_install -b /opt/ibm/db2/V11.5

# Criar instancia
/opt/ibm/db2/V11.5/instance/db2icrt -u db2fenc1 db2inst1

# Criar banco
su - db2inst1
db2 CREATE DATABASE mydb AUTOMATIC STORAGE YES ON /data DBPATH ON /dbpath \
    USING CODESET UTF-8 TERRITORY US COLLATE USING IDENTITY PAGESIZE 32768

db2 UPDATE DBM CFG USING SVCENAME 50000 IMMEDIATE
db2 SET DBMCFG USING AGENT_STACK_SZ 1000 AUTOMATIC
```

**Configuracoes obrigatorias pos-criacao**:
```bash
db2 CONNECT TO mydb

# Habilitar archive logging (obrigatorio para backup online)
db2 UPDATE DB CFG FOR mydb USING LOGARCHMETH1 'DISK:/archive/db2/mydb'
db2 UPDATE DB CFG FOR mydb USING LOGARCHOPT1 ''
db2 UPDATE DB CFG FOR mydb USING FAILARCHPATH '/archive/db2/mydb_failsafe'

# Configurar buffers
db2 UPDATE DB CFG FOR mydb USING BUFFPAGE 65536  # 512MB com pagina 8K
db2 UPDATE DBM CFG USING SHEAPTHRES_SHR AUTOMATIC

# Configurar backup automatico
db2 ACTIVATE DATABASE mydb
```

**Fontes**:
- https://www.ibm.com/docs/en/db2/11.5?topic=installing-db2-linux
- https://www.ibm.com/docs/en/db2/11.5?topic=tuning-db2-performance
- https://www.ibm.com/docs/en/db2/11.5?topic=configuring-database-manager-configuration-parameters
- https://community.ibm.com/community/user/blogs/youssef-sbai-idrissi1/2023/07/27/how-to-set-up-security-for-ibm-db2-best-practices

---

### Vertica — Implementacao

**Prerequisitos de Hardware**:
- CPU: 32–48 cores fisicos por no (nao usar hyperthreading para Vertica)
- RAM: minimo 256GB por no; ratio 8–12GB RAM por core fisico
- Disco dados: NVMe SSD ou SAS 10K RPM em RAID 10
- Rede: minimo 10Gbps entre nos (25/100Gbps recomendado)
- SO: RHEL 7/8, Debian, Ubuntu

**Prerequisitos de SO**:
```bash
# Desabilitar THP (Transparent Huge Pages) — obrigatorio para Vertica
echo "never" > /sys/kernel/mm/transparent_hugepage/enabled
echo "never" > /sys/kernel/mm/transparent_hugepage/defrag

# Adicionar ao rc.local para persistir
cat >> /etc/rc.local << 'EOF'
echo "never" > /sys/kernel/mm/transparent_hugepage/enabled
echo "never" > /sys/kernel/mm/transparent_hugepage/defrag
EOF

# Configurar I/O scheduler
for dev in $(ls /sys/block/ | grep -v loop); do
    echo "noop" > /sys/block/$dev/queue/scheduler
done

# Limites
cat >> /etc/security/limits.conf << 'EOF'
dbadmin  -  nofile  65536
dbadmin  -  nproc   65536
EOF
```

**Instalacao**:
```bash
# Como root
rpm -Uvh vertica-11.x.x-0.x86_64.RHEL6.rpm

# Criar usuario dbadmin
/opt/vertica/sbin/install_vertica \
    --hosts 10.0.0.10,10.0.0.11,10.0.0.12 \
    --rpm vertica-11.x.x.rpm \
    --dba-user dbadmin \
    --dba-group verticadba \
    --data-dir /vertica/data \
    --ssh-identity /root/.ssh/id_rsa

# Criar banco de dados
su - dbadmin
/opt/vertica/bin/admintools -t create_db \
    --database VMart \
    --catalog_path /vertica/catalog \
    --data_path /vertica/data \
    --hosts 10.0.0.10,10.0.0.11,10.0.0.12 \
    --shard-count 6 \
    --password AdminSenha123!
```

**Configuracoes obrigatorias**:
```sql
-- Verificar K-Safety (deve ser 1 em producao)
SELECT GET_COMPLIANCE_STATUS();

-- Configurar autenticacao
ALTER DATABASE VMart SET EnableSSL = 1;
ALTER DATABASE VMart SET MaxClientSessions = 500;

-- Configurar recursos
CREATE RESOURCE POOL analytics MEMORYSIZE '60%' MAXMEMORYSIZE '80%';
CREATE RESOURCE POOL etl MEMORYSIZE '20%' MAXMEMORYSIZE '40%';
```

**Fontes**:
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/InstallationGuide/
- https://www.vertica.com/kb/Recommendations-for-Sizing-Vertica-Nodes-and-Clusters/
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/AdministratorsGuide/ConfiguringTheDB/
- https://support.microfocus.com/kb/kmdoc.php?id=KM00624599

---

### Redis — Implementacao

**Prerequisitos de SO**:
```bash
# RHEL/Rocky
dnf install -y epel-release
dnf install -y redis

# Configuracoes obrigatorias de SO para Redis
echo "vm.overcommit_memory = 1" >> /etc/sysctl.d/redis.conf
echo "net.core.somaxconn = 65535" >> /etc/sysctl.d/redis.conf
sysctl -p /etc/sysctl.d/redis.conf

# Desabilitar THP
echo "never" > /sys/kernel/mm/transparent_hugepage/enabled
# Adicionar ao /etc/rc.local para persistir

# Limites
cat >> /etc/security/limits.d/redis.conf << 'EOF'
redis  soft  nofile  65535
redis  hard  nofile  65535
EOF
```

**Estrutura de diretorios**:
```bash
mkdir -p /var/lib/redis        # dados (RDB/AOF)
mkdir -p /var/log/redis        # logs
mkdir -p /etc/redis/tls        # certificados TLS
chown -R redis:redis /var/lib/redis /var/log/redis /etc/redis
chmod 750 /etc/redis/tls
```

**Gerar certificados TLS**:
```bash
# Gerar CA e certificados para Redis
cd /etc/redis/tls

# CA
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
    -subj "/CN=Redis-CA/O=MyOrg/C=BR"

# Certificado do servidor
openssl genrsa -out redis.key 2048
openssl req -new -key redis.key -out redis.csr \
    -subj "/CN=redis-prod-01/O=MyOrg/C=BR"
openssl x509 -req -days 365 -in redis.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out redis.crt

chown redis:redis /etc/redis/tls/*.{key,crt}
chmod 640 /etc/redis/tls/*.key
```

**Instalacao via codigo fonte (producao de alta performance)**:
```bash
# Versao LTS atual
wget https://download.redis.io/redis-stable.tar.gz
tar xzf redis-stable.tar.gz && cd redis-stable

# Compilar com TLS
make BUILD_TLS=yes USE_SYSTEMD=yes
make install

# Criar usuario de sistema
useradd --system --shell /bin/false --home /var/lib/redis redis
```

**Fontes**:
- https://redis.io/docs/latest/operate/oss_and_stack/install/install-redis/
- https://redis.io/docs/latest/operate/oss_and_stack/management/config/
- https://redis.io/docs/latest/operate/oss_and_stack/management/security/
- https://redis.io/docs/latest/operate/rs/security/recommended-security-practices/

---

## Connection Pooling

Obrigatorio em todo ambiente com multiplos clientes conectados.

### Padrao por Banco

| Banco | Ferramenta Principal | Alternativa | Observacao |
|-------|---------------------|-------------|------------|
| PostgreSQL | **PgBouncer** | pgpool-II | PgBouncer mais leve; pgpool-II com HA |
| MySQL | **ProxySQL** | MySQL Router | ProxySQL mais features; Router mais simples |
| SQL Server | Pool nativo JDBC/ADO | **RDS Proxy** (AWS) | Usar pool do driver; RDS Proxy para lambda |
| Oracle | Pool nativo (UCP/JDBC) | **DRCP** | DRCP para conexoes de aplicacao web |
| Db2 | Pool nativo (CPDS) | — | Usar connection pool do driver |
| Redis | Pool nativo do cliente | — | redis-py, Jedis, ioredis tem pool nativo |
| Vertica | Pool nativo do driver | — | Vertica JDBC/ODBC com pooling |

### PgBouncer — Configuracao Completa (PostgreSQL)
```ini
[databases]
mydb = host=127.0.0.1 port=5432 dbname=mydb pool_size=25
mydb_readonly = host=10.0.0.11 port=5432 dbname=mydb pool_size=50 pool_mode=session

[pgbouncer]
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /run/pgbouncer/pgbouncer.pid

listen_addr = 0.0.0.0
listen_port = 6432

# TLS
client_tls_sslmode = require
client_tls_cert_file = /etc/pgbouncer/tls/pgbouncer.crt
client_tls_key_file = /etc/pgbouncer/tls/pgbouncer.key

auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt

# Pool mode: session | transaction | statement
pool_mode = transaction

# Limites
max_client_conn = 2000
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 10
reserve_pool_timeout = 5.0

# Timeouts
server_idle_timeout = 600
client_idle_timeout = 0
server_connect_timeout = 15
query_timeout = 0

# Monitoramento
stats_period = 60

# Limpeza de conexoes com statements pendentes
server_reset_query = DISCARD ALL
server_reset_query_always = 0
```

### ProxySQL — Configuracao (MySQL)
```sql
-- Adicionar backends MySQL
INSERT INTO mysql_servers (hostgroup_id, hostname, port, weight)
VALUES (10, '10.0.0.10', 3306, 1000),   -- primario (R/W)
       (20, '10.0.0.11', 3306, 1000),   -- replica (R)
       (20, '10.0.0.12', 3306, 1000);   -- replica (R)

-- Regras de roteamento
INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, apply)
VALUES (1, 1, '^SELECT.*FOR UPDATE', 10, 1),  -- SELECT FOR UPDATE vai para primario
       (2, 1, '^SELECT', 20, 1),              -- SELECT vai para replicas
       (3, 1, '.*', 10, 1);                   -- todo o resto vai para primario

-- Usuarios
INSERT INTO mysql_users (username, password, default_hostgroup, max_connections)
VALUES ('appuser', 'SenhaApp123!', 10, 500);

-- Configuracoes globais
UPDATE global_variables SET variable_value = '500' WHERE variable_name = 'mysql-max_connections';
UPDATE global_variables SET variable_value = '600000' WHERE variable_name = 'mysql-wait_timeout';
UPDATE global_variables SET variable_value = '1' WHERE variable_name = 'mysql-log_mysql_warnings_enabled';

LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;
LOAD MYSQL RULES TO RUNTIME; SAVE MYSQL RULES TO DISK;
LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;
LOAD MYSQL VARIABLES TO RUNTIME; SAVE MYSQL VARIABLES TO DISK;
```

---

## Documentacao Operacional Minima (Runbook)

Todo banco em producao deve ter documentado:

- [ ] Endpoint de conexao (host:porta ou listener)
- [ ] Versao do banco e data da ultima atualizacao
- [ ] DBA responsavel e contato de emergencia 24x7
- [ ] Janela de manutencao aprovada
- [ ] SLA de disponibilidade (uptime %)
- [ ] Procedimento de restart manual
- [ ] Procedimento de failover manual e automatico
- [ ] Localizacao dos logs e como interpreta-los
- [ ] Localizacao dos backups e comando de restore
- [ ] URL do dashboard de monitoramento
- [ ] Canal de alertas (Slack, PagerDuty, email)
- [ ] Aplicacoes dependentes (impacto de indisponibilidade)
- [ ] Topologia de replicacao (diagrama)
- [ ] Procedimento de escalacao de incidentes (P1/P2/P3/P4)

---

## Fontes e Referencias

| Banco | Fonte |
|-------|-------|
| PostgreSQL | https://www.postgresql.org/docs/current/ |
| PostgreSQL tuning | https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server |
| MySQL | https://dev.mysql.com/doc/refman/8.0/en/ |
| MySQL production | https://dev.mysql.com/doc/mysql-secure-deployment-guide/8.0/en/ |
| SQL Server Linux | https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-overview |
| SQL Server perf | https://learn.microsoft.com/en-us/sql/relational-databases/performance/ |
| Oracle install | https://docs.oracle.com/en/database/oracle/oracle-database/19/ladbi/ |
| Oracle admin | https://docs.oracle.com/en/database/oracle/oracle-database/19/admin/ |
| IBM Db2 | https://www.ibm.com/docs/en/db2/11.5 |
| Vertica | https://www.vertica.com/docs/latest/HTML/ |
| Redis | https://redis.io/docs/latest/ |
| DLM (Microsoft) | https://learn.microsoft.com/en-us/sql/relational-databases/database-lifecycle-management |
| Red Gate DLM | https://www.red-gate.com/blog/what-is-database-lifecycle-management/ |
| Flyway | https://documentation.red-gate.com/fd |
| Liquibase | https://docs.liquibase.com/ |
| PgBouncer | https://www.pgbouncer.org/config.html |
| ProxySQL | https://proxysql.com/documentation/ |
