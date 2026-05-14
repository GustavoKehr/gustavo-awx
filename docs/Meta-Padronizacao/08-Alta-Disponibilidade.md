# 08 — Alta Disponibilidade e Replicacao

## Conceitos Fundamentais

| Conceito | Definicao |
|----------|-----------|
| **HA (High Availability)** | Capacidade do sistema continuar operando com falhas de componentes |
| **Failover** | Troca automatica ou manual para o servidor standby quando o primario falha |
| **Failback** | Retorno ao servidor primario original apos recuperacao |
| **Sincrono** | Transacao confirmada somente apos escrita no standby — RPO = 0, impacto em latencia |
| **Assincrono** | Transacao confirmada no primario; standby recebe dados depois — RPO > 0, sem impacto em latencia |
| **Quorum** | Numero minimo de nos que devem concordar para tomar uma decisao (eleicao de primario) |
| **Split Brain** | Dois nos acreditam ser o primario simultaneamente — cenario critico a evitar |
| **K-Safety** | Numero de nos que podem falhar simultaneamente sem perda de dados (Vertica) |
| **WAL** | Write-Ahead Log — mecanismo de replicacao baseado em log no PostgreSQL |
| **REDO Log** | Log de replicacao no Oracle |

### Disponibilidade por Numero de Noves

| Disponibilidade | Downtime/Ano | Adequado para |
|----------------|-------------|---------------|
| 99.9% (3 noves) | ~8.7 horas | Sistemas de baixa criticidade |
| 99.95% | ~4.4 horas | Sistemas internos importantes |
| 99.99% (4 noves) | ~52 minutos | Sistemas de alta criticidade (ERP, CRM) |
| 99.999% (5 noves) | ~5 minutos | Missao critica (pagamentos, autenticacao) |

---

## PostgreSQL

> **Por que Patroni em vez de replicacao nativa do PostgreSQL sozinha?**
> A replicacao streaming do PostgreSQL e robusta mas nao tem failover automatico nativo. Se o primario morrer as 3h da manha:
> - Replicacao nativa: alguem precisa acordar, checar o estado, executar manualmente `pg_ctl promote` no standby e atualizar o DNS/load balancer
> - Patroni: detecta a falha em `loop_wait` segundos (configuravel; padrao 10s), elege o standby mais atualizado via consenso etcd/Consul, promove automaticamente, e atualiza o endpoint
>
> O downtime cai de "tempo de resposta do DBA de plantao" (tipicamente 15–60min) para 15–30 segundos. Para aplicacoes com SLA de 99.99% (52min downtime/ano), isso e a diferenca entre cumprir ou violar o SLA.
>
> **Por que etcd como DCS (Distributed Configuration Store)?**
> Patroni usa etcd/Consul/ZooKeeper como arbirto para evitar split-brain: dois nos acreditando ser o primario simultaneamente resultaria em divergencia de dados irrecuperavel. O DCS garante que apenas um no seja eleito primario via quorum — sem DCS externo, o Patroni nao pode tomar decisoes seguras de failover.

### Arquitetura de HA Recomendada

```
              ┌─────────────────────────────────────────────┐
              │         HAProxy / Load Balancer / VIP        │
              │    (ex: Keepalived + VIP para primario)      │
              └────────────────────┬────────────────────────┘
                                   │
              ┌────────────────────▼────────────────────────┐
              │          Patroni Cluster Manager             │
              │         (etcd / Consul / ZooKeeper)          │
              └──────┬─────────────────────────┬────────────┘
                     │                         │
          ┌──────────▼──────────┐   ┌──────────▼──────────┐
          │  Primario (R/W)      │   │  Standby (Read-Only) │
          │  PostgreSQL          │◄──│  PostgreSQL          │
          │  Patroni Agent       │   │  Patroni Agent       │
          └─────────────────────┘   └──────────────────────┘
```

### Replicacao com Streaming (nativo)

```sql
-- Criar usuario dedicado para replicacao
CREATE USER replicator
    REPLICATION
    LOGIN
    CONNECTION LIMIT 5
    ENCRYPTED PASSWORD 'ReplicaPass@123!';

-- postgresql.conf no primario
wal_level = replica
max_wal_senders = 10
wal_keep_size = 1GB
hot_standby = on
hot_standby_feedback = on      -- reduz conflitos de vacuum vs queries no standby
wal_receiver_status_interval = 10s

-- pg_hba.conf no primario (permitir replicacao do standby)
host  replication  replicator  10.0.0.11/32  scram-sha-256
host  replication  replicator  10.0.0.12/32  scram-sha-256

-- Criar standby via pg_basebackup (executar no servidor standby)
pg_basebackup \
    -h 10.0.0.10 \
    -U replicator \
    -D /var/lib/postgresql/16/main \
    -P \
    -R \
    --wal-method=stream \
    --slot=replica_01

-- standby.signal e postgresql.auto.conf sao criados automaticamente com -R
# primary_conninfo = 'host=10.0.0.10 port=5432 user=replicator password=ReplicaPass@123! application_name=standby_01'
# primary_slot_name = 'replica_01'

-- Verificar replicacao (no primario)
SELECT
    application_name,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replication_lag,
    sync_state
FROM pg_stat_replication;

-- Verificar do lado do standby
SELECT status, receive_start_lsn, received_lsn, last_msg_receipt_time
FROM pg_stat_wal_receiver;
```

### Replication Slots — Cuidados

```sql
-- Criar slot de replicacao fisico (garante que WAL nao seja removido enquanto standby estiver atrasado)
SELECT pg_create_physical_replication_slot('replica_01');

-- ALERTA: slots inativos acumulam WAL indefinidamente — monitorar retained_bytes
SELECT
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
    restart_lsn
FROM pg_replication_slots;

-- REMOVER slot de standby desativado para evitar enchimento do disco
SELECT pg_drop_replication_slot('replica_01');

-- Configurar limite de WAL retido (segurança)
max_slot_wal_keep_size = 10GB  -- postgresql.conf
```

### Patroni — HA Automatico

```yaml
# /etc/patroni/patroni.yml
scope: postgres-cluster
namespace: /service/
name: pg-node-01

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.10:8008

etcd:
  hosts: 10.0.0.20:2379,10.0.0.21:2379,10.0.0.22:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 10485760  # 10MB — nao promover standby muito atrasado
    synchronous_mode: false            # true = sincrono (RPO=0, mas lentidade se standby cair)
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_connections: 200
        max_wal_senders: 10
        max_replication_slots: 10

  initdb:
    - encoding: UTF8
    - data-checksums

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.10:5432
  data_dir: /var/lib/postgresql/16/main
  bin_dir: /usr/lib/postgresql/16/bin
  config_dir: /etc/postgresql/16/main

  authentication:
    replication:
      username: replicator
      password: ReplicaPass@123!
    superuser:
      username: postgres
      password: PGAdminPass@123!

  pg_hba:
    - host replication replicator 0.0.0.0/0 scram-sha-256
    - host all all 0.0.0.0/0 scram-sha-256

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
```

```bash
# Comandos Patronictl
patronictl -c /etc/patroni/patroni.yml list           # status do cluster
patronictl -c /etc/patroni/patroni.yml switchover     # failover planejado
patronictl -c /etc/patroni/patroni.yml failover pg-node-01  # failover de emergencia
patronictl -c /etc/patroni/patroni.yml reinit pg-node-02    # reiniciar standby
```

### repmgr — Alternativa ao Patroni

```bash
# repmgr.conf (no primario)
node_id=1
node_name=pg-node-01
conninfo='host=10.0.0.10 user=repmgr dbname=repmgr connect_timeout=2'
data_directory='/var/lib/postgresql/16/main'
failover=automatic
promote_command='/usr/bin/repmgr standby promote -f /etc/repmgr.conf --log-to-file'
follow_command='/usr/bin/repmgr standby follow -f /etc/repmgr.conf --log-to-file --upstream-node-id=%n'

# Registrar primario
repmgr -f /etc/repmgr.conf primary register

# Clonar e registrar standby
repmgr -h 10.0.0.10 -U repmgr -d repmgr -f /etc/repmgr.conf standby clone
repmgr -f /etc/repmgr.conf standby register

# Status do cluster
repmgr -f /etc/repmgr.conf cluster show
```

**Fontes PostgreSQL HA**:
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [PostgreSQL — Streaming Replication](https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION)
- [repmgr Documentation](https://repmgr.org/docs/current/)
- [PostgreSQL High Availability Cookbook](https://www.packtpub.com/product/postgresql-high-availability-cookbook)

---

## MySQL

> **Por que GTID e obrigatorio para HA moderno no MySQL?**
> Replicacao tradicional (sem GTID) usa `binlog_file + position` para rastrear onde a replica parou. Apos um failover, o novo primario tem um arquivo de binlog diferente do antigo — as replicas precisam ser reconfiguradas manualmente para apontar para a posicao correta no novo primario. Esse processo e propenso a erros e exige downtime de manutencao.
>
> Com GTID, cada transacao recebe um ID global unico (UUID:numero). Apos um failover, as replicas simplesmente conectam ao novo primario e ele fornece automaticamente as transacoes que a replica ainda nao tem — sem reconfigurar posicoes de binlog. O failover passa de "procedimento manual de 30 minutos" para "automatico em segundos".
>
> **Por que InnoDB Cluster em vez de replicacao tradicional?**
> InnoDB Cluster (Group Replication + MySQL Router) adiciona:
> - **Quorum automatico**: sem quorum (menos de `n/2 + 1` nos respondendo), o cluster recusa escritas em vez de provocar split-brain
> - **MySQL Router**: as aplicacoes conectam ao Router que redireciona automaticamente para o primario atual — sem precisar atualizar DNS
> - **Monitoramento nativo**: `cluster.status()` mostra o estado de todos os nos

### Topologias de HA

**1. InnoDB Cluster (MySQL Group Replication + MySQL Router)**

```
MySQL Router (load balancer automatico)
  → Primary (R/W)     ─┐
  → Secondary 1 (R)  ─┤ Group Replication (quorum-based, sincrona com Paxos)
  → Secondary 2 (R)  ─┘
Minimo 3 nos para quorum (tolerancia a falha de 1 no)
```

```bash
# Configurar InnoDB Cluster via MySQL Shell
mysqlsh

JS> var cluster = dba.createCluster('producao_cluster');
JS> cluster.addInstance('replication@10.0.0.11:3306', {recoveryMethod: 'clone'});
JS> cluster.addInstance('replication@10.0.0.12:3306', {recoveryMethod: 'clone'});
JS> cluster.status();

# Verificar status
JS> cluster.describe();
JS> cluster.status({extended: 1});

# Instalar MySQL Router (proxy para o cluster)
mysqlrouter --bootstrap root@10.0.0.10:3306 --user=mysqlrouter
systemctl start mysqlrouter
# Conexoes R/W: 6446; Conexoes Read-Only: 6447
```

**2. GTID-Based Replication Tradicional**

```ini
# my.cnf — primario e standbys
[mysqld]
server_id = 1          # ID unico por servidor
gtid_mode = ON
enforce_gtid_consistency = ON
log_bin = mysql-bin
binlog_format = ROW
sync_binlog = 1        # flush por transacao (durabilidade maxima)
binlog_row_image = FULL
log_replica_updates = ON  # permite chain de replicacao
relay_log_info_repository = TABLE
master_info_repository = TABLE
```

```sql
-- Criar usuario de replicacao
CREATE USER 'replication'@'10.0.0.%'
    IDENTIFIED WITH caching_sha2_password
    BY 'ReplPass@123!'
    REQUIRE SSL;
GRANT REPLICATION SLAVE ON *.* TO 'replication'@'10.0.0.%';

-- Configurar replicacao no standby
CHANGE REPLICATION SOURCE TO
    SOURCE_HOST = '10.0.0.10',
    SOURCE_PORT = 3306,
    SOURCE_USER = 'replication',
    SOURCE_PASSWORD = 'ReplPass@123!',
    SOURCE_SSL = 1,
    SOURCE_SSL_CA = '/etc/mysql/tls/ca.pem',
    SOURCE_AUTO_POSITION = 1;  -- GTID-based (mais robusto que binlog position)

START REPLICA;

-- Verificar status da replicacao
SHOW REPLICA STATUS\G

-- Queries de monitoramento
SELECT * FROM performance_schema.replication_connection_status\G
SELECT * FROM performance_schema.replication_applier_status_by_worker\G

-- Verificar lag
SELECT
    CHANNEL_NAME,
    SERVICE_STATE,
    LAST_ERROR_MESSAGE,
    TIME_SINCE_LAST_MESSAGE
FROM performance_schema.replication_connection_status;
```

**3. MySQL Group Replication (sem MySQL Shell)**

```sql
-- my.cnf — todos os nos do grupo
[mysqld]
plugin_load_add = 'group_replication.so'
group_replication_group_name = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"  -- UUID unico
group_replication_start_on_boot = OFF
group_replication_local_address = "10.0.0.10:33061"
group_replication_group_seeds = "10.0.0.10:33061,10.0.0.11:33061,10.0.0.12:33061"
group_replication_bootstrap_group = OFF

-- Iniciar o grupo (apenas no primeiro no, apenas uma vez)
SET GLOBAL group_replication_bootstrap_group=ON;
START GROUP_REPLICATION;
SET GLOBAL group_replication_bootstrap_group=OFF;

-- Adicionar demais nos
START GROUP_REPLICATION;

-- Verificar membros do grupo
SELECT * FROM performance_schema.replication_group_members;
```

### MySQL Orchestrator — Failover Automatico

```bash
# Orchestrator detecta topologia e gerencia failovers
# Instalar e configurar
wget https://github.com/openark/orchestrator/releases/latest/download/orchestrator-linux-amd64.tar.gz
tar -xzf orchestrator-linux-amd64.tar.gz -C /usr/local/bin/

# orchestrator.conf.json (trecho principal)
{
  "MySQLTopologyUser": "orchestrator",
  "MySQLTopologyPassword": "OrchestratorPass@123!",
  "MySQLOrchestratorHost": "localhost",
  "MySQLOrchestratorPort": 3306,
  "MySQLOrchestratorDatabase": "orchestrator",
  "RecoverMasterClusterFilters": ["*"],     -- auto-failover para todos os clusters
  "PromotionIgnoreHostnameFilters": [],
  "FailMasterPromotionIfSQLThreadNotUpToDate": true,
  "PreventCrossDataCenterMasterFailover": true
}

# Descobrir topologia
orchestrator-client -c discover -i 10.0.0.10:3306

# Verificar status
orchestrator-client -c clusters
orchestrator-client -c topology -i MeuCluster

# Failover manual
orchestrator-client -c graceful-master-takeover-auto -i 10.0.0.10:3306
```

**Fontes MySQL HA**:
- [MySQL — InnoDB Cluster](https://dev.mysql.com/doc/mysql-shell/8.4/en/mysql-innodb-cluster.html)
- [MySQL — Group Replication](https://dev.mysql.com/doc/refman/8.4/en/group-replication.html)
- [Orchestrator GitHub](https://github.com/openark/orchestrator)
- [Percona — MySQL High Availability Best Practices](https://www.percona.com/resources/technical-presentations/mysql-high-availability-best-practices)

---

## SQL Server — Always On Availability Groups

> **Por que Always On AG em vez de Database Mirroring ou Log Shipping?**
> - **Database Mirroring**: descontinuado desde SQL Server 2012. Limitado a 1 mirror, sem leitura no secondary, sem suporte a backup no secondary.
> - **Log Shipping**: backup/restore manual de transaction logs. RPO depende da frequencia do job (tipicamente 15–60 min). Sem failover automatico — requer intervencao manual.
> - **Always On AG**: suporta ate 8 replicas (SQL Server 2022), todas com failover automatico ou manual configuravel. Replicas secundarias podem receber leitura (read scale), backups e DBCC — descarregando o primario. Listener garante que a aplicacao sempre conecta ao primario atual sem reconfigurar strings de conexao.
>
> **Por que WSFC (Windows Server Failover Cluster) e obrigatorio para AOAG?**
> O WSFC fornece o mecanismo de quorum e o health monitoring do cluster Windows. O SQL Server usa o WSFC para decidir qual no e o primario e quando fazer failover automatico — sem WSFC, o SQL Server nao tem como coordenar a eleicao de forma segura.

### Requisitos

- Windows Server Failover Cluster (WSFC) — obrigatorio para AOAG
- Minimo 2 replicas SQL Server Enterprise Edition
- Quorum configurado (Cloud Witness, Disk Witness ou File Share Witness)
- Todas as replicas no mesmo dominio AD (ou usando certificados para workgroups)

### Configuracao Completa

```sql
-- Passo 1: Habilitar Always On em cada instancia SQL Server
-- (via SQL Server Configuration Manager ou PowerShell)

-- Passo 2: Criar endpoint de mirroring de banco de dados
CREATE ENDPOINT [Hadr_Endpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022)
    FOR DATA_MIRRORING (
        ROLE = ALL,
        AUTHENTICATION = WINDOWS NEGOTIATE,
        ENCRYPTION = REQUIRED ALGORITHM AES
    );

-- Passo 3: Criar Availability Group
CREATE AVAILABILITY GROUP [AG_Producao]
WITH (
    AUTOMATED_BACKUP_PREFERENCE = SECONDARY,
    FAILURE_CONDITION_LEVEL = 3,        -- failover automatico em condicoes criticas
    HEALTH_CHECK_TIMEOUT = 30000,       -- 30 segundos
    DB_FAILOVER = ON,                   -- failover se qualquer banco ficar offline
    DTC_SUPPORT = NONE,
    REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0
)
FOR DATABASE [MeuBanco1], [MeuBanco2]
REPLICA ON
    N'SQLSERVER01' WITH (
        ENDPOINT_URL = N'TCP://sqlserver01.domain.com:5022',
        FAILOVER_MODE = AUTOMATIC,
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        SESSION_TIMEOUT = 10,
        BACKUP_PRIORITY = 50,
        SECONDARY_ROLE (
            ALLOW_CONNECTIONS = READ_ONLY,
            READ_ONLY_ROUTING_URL = N'TCP://sqlserver01.domain.com:1433'
        ),
        PRIMARY_ROLE (
            ALLOW_CONNECTIONS = ALL,
            READ_ONLY_ROUTING_LIST = (N'SQLSERVER02', N'SQLSERVER03')
        )
    ),
    N'SQLSERVER02' WITH (
        ENDPOINT_URL = N'TCP://sqlserver02.domain.com:5022',
        FAILOVER_MODE = AUTOMATIC,
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        SESSION_TIMEOUT = 10,
        BACKUP_PRIORITY = 60,
        SECONDARY_ROLE (
            ALLOW_CONNECTIONS = READ_ONLY,
            READ_ONLY_ROUTING_URL = N'TCP://sqlserver02.domain.com:1433'
        )
    ),
    N'SQLSERVER03' WITH (
        ENDPOINT_URL = N'TCP://sqlserver03.domain.com:5022',
        FAILOVER_MODE = MANUAL,
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,  -- replica DR em outra regiao
        SESSION_TIMEOUT = 10,
        BACKUP_PRIORITY = 70,
        SECONDARY_ROLE (
            ALLOW_CONNECTIONS = NO
        )
    );

-- Passo 4: Adicionar listener (VIP para aplicacoes — sempre conectar no listener!)
ALTER AVAILABILITY GROUP [AG_Producao]
    ADD LISTENER N'ag-producao' (
        WITH IP ((N'10.0.0.100', N'255.255.255.0')),
        PORT = 1433
    );

-- Adicionar banco ao AG na replica secundaria
ALTER DATABASE [MeuBanco1] SET HADR AVAILABILITY GROUP = [AG_Producao];
```

### Monitoramento e Failover

```sql
-- Status geral do AG
SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    ar.availability_mode_desc,
    ar.failover_mode_desc,
    ars.role_desc,
    ars.operational_state_desc,
    ars.synchronization_health_desc,
    ars.connected_state_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id;

-- Lag de replicacao por banco
SELECT
    ag.name,
    drs.database_id,
    DB_NAME(drs.database_id) AS db_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.log_send_queue_size / 1024.0 AS log_send_queue_mb,
    drs.redo_queue_size / 1024.0 AS redo_queue_mb
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id;

-- Failover manual planejado
ALTER AVAILABILITY GROUP [AG_Producao] FAILOVER;

-- Failover forcado (emergencia — risco de perda de dados com async)
ALTER AVAILABILITY GROUP [AG_Producao] FORCE_FAILOVER_ALLOW_DATA_LOSS;
```

### Modos de Commit

| Modo | RPO | Impacto | Quando Usar |
|------|-----|---------|-------------|
| SYNCHRONOUS_COMMIT | 0 (zero data loss) | Latencia adicional (~1ms na LAN) | HA local, mesma subnet |
| ASYNCHRONOUS_COMMIT | > 0 (variavel) | Sem impacto em latencia | DR remoto, outra regiao/datacenter |

**Fontes SQL Server HA**:
- [SQL Server — Always On Availability Groups](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/overview-of-always-on-availability-groups-sql-server)
- [SQL Server — WSFC for HADR](https://learn.microsoft.com/en-us/sql/sql-server/failover-clusters/windows/windows-server-failover-clustering-wsfc-with-sql-server)
- [DISA STIG for SQL Server](https://public.cyber.mil/stigs/downloads/)
- [SQL Server 2022 HA Best Practices](https://learn.microsoft.com/en-us/sql/sql-server/sql-server-2022-release-notes)

---

## Oracle — Data Guard

> **Por que Data Guard e nao apenas RMAN com streaming para um standby manual?**
> Data Guard e a arquitetura de HA certificada e suportada pela Oracle para zero data loss e failover automatico. Diferencas criticas:
> - **Gerenciamento de redo streams**: Data Guard gerencia automaticamente gaps de archive log, re-sincronizacao apos queda do standby e validacao de consistencia
> - **Data Guard Broker (DGMGRL)**: interface unificada para monitorar, switchover e failover — operacoes que seriam procedimentos manuais complexos tornam-se um comando
> - **Active Data Guard**: permite leitura no standby enquanto recebe redo — offload de queries de relatorio sem custo adicional de hardware
> - **Fast-Start Failover (FSFO)**: com um observer externo, o Data Guard pode fazer failover automatico sem intervencao humana em <30 segundos
>
> **Por que FORCE LOGGING e obrigatorio?**
> Sem FORCE LOGGING, operacoes com NOLOGGING (bulk loads, DDL com `NOLOGGING` hint) nao geram redo e nao sao replicadas para o standby. Apos um failover, o standby abre com blocos inconsistentes nesses segmentos — o banco "funciona" mas os dados estao corrompidos. FORCE LOGGING garante que todo dado seja incluido no redo e chegue ao standby, sem excecoes.

### Prerequisitos

```sql
-- No primario: habilitar ARCHIVELOG e FORCE LOGGING
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE FORCE LOGGING;
ALTER DATABASE OPEN;

-- Configurar parametros necessarios para Data Guard
ALTER SYSTEM SET LOG_ARCHIVE_DEST_1 =
    'LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=ORCL_PRIMARY'
    SCOPE=BOTH;

ALTER SYSTEM SET LOG_ARCHIVE_DEST_2 =
    'SERVICE=ORCL_STANDBY ASYNC
     VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE)
     DB_UNIQUE_NAME=ORCL_STANDBY
     COMPRESSION=ENABLE'
    SCOPE=BOTH;

ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2 = ENABLE SCOPE=BOTH;
ALTER SYSTEM SET FAL_SERVER = ORCL_STANDBY SCOPE=BOTH;
ALTER SYSTEM SET FAL_CLIENT = ORCL_PRIMARY SCOPE=BOTH;
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT = AUTO SCOPE=BOTH;

-- Criar standby redo logs (minimo mesmo numero que os online redo logs + 1)
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 4
    ('/u01/app/oracle/oradata/ORCL/standby_redo04.log') SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 5
    ('/u01/app/oracle/oradata/ORCL/standby_redo05.log') SIZE 200M;

-- Criar parametros para o standby no SPFILE
ALTER SYSTEM SET DB_UNIQUE_NAME = 'ORCL_PRIMARY' SCOPE=SPFILE;
```

### Criacao do Standby via RMAN DUPLICATE

```bash
# No standby: criar PFILE minimo
# /tmp/init_standby.ora
DB_NAME=ORCL
DB_UNIQUE_NAME=ORCL_STANDBY
LOG_ARCHIVE_DEST_1=LOCATION=/u01/arch
CONTROL_FILES=/u01/app/oracle/oradata/ORCL_STANDBY/control01.ctl
DB_FILE_NAME_CONVERT='/oradata/ORCL/','/oradata/ORCL_STANDBY/'
LOG_FILE_NAME_CONVERT='/oradata/ORCL/','/oradata/ORCL_STANDBY/'

# Criar standby via RMAN DUPLICATE (primario online)
rman target sys@ORCL_PRIMARY auxiliary sys@ORCL_STANDBY

RMAN> DUPLICATE TARGET DATABASE FOR STANDBY
    FROM ACTIVE DATABASE
    DORECOVER
    SPFILE
        SET DB_UNIQUE_NAME 'ORCL_STANDBY'
        SET LOG_ARCHIVE_DEST_1 'LOCATION=/u01/arch'
        SET FAL_SERVER 'ORCL_PRIMARY'
        SET LOG_ARCHIVE_DEST_2 'SERVICE=ORCL_PRIMARY ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=ORCL_PRIMARY'
    NOFILENAMECHECK;
```

### Configuracao via Data Guard Broker

```bash
# dgmgrl — Data Guard Manager CLI
dgmgrl /

DGMGRL> CREATE CONFIGURATION 'dg_config' AS
    PRIMARY DATABASE IS 'ORCL_PRIMARY'
    CONNECT IDENTIFIER IS 'ORCL_PRIMARY';

DGMGRL> ADD DATABASE 'ORCL_STANDBY' AS
    CONNECT IDENTIFIER IS 'ORCL_STANDBY'
    MAINTAINED AS PHYSICAL;

DGMGRL> ENABLE CONFIGURATION;

# Alterar modo de protecao
DGMGRL> EDIT CONFIGURATION SET PROTECTION MODE AS MaxAvailability;
# MaxProtection: RPO=0, para o primario se standby offline
# MaxAvailability: RPO=0 se possivel, degrada para async se standby offline
# MaxPerformance: async, sem impacto no primario (padrao)

# Verificar status
DGMGRL> SHOW CONFIGURATION;
DGMGRL> SHOW DATABASE VERBOSE 'ORCL_STANDBY';
DGMGRL> SHOW DATABASE VERBOSE 'ORCL_PRIMARY';

# Switchover planejado (zero downtime se banco e aplicacao suportam)
DGMGRL> SWITCHOVER TO 'ORCL_STANDBY';

# Failover de emergencia
DGMGRL> FAILOVER TO 'ORCL_STANDBY';

# Validar configuracao
DGMGRL> VALIDATE DATABASE 'ORCL_STANDBY';
DGMGRL> VALIDATE DATABASE VERBOSE 'ORCL_STANDBY';
```

### Oracle Active Data Guard (ADG)

```sql
-- ADG permite leitura no standby enquanto recebe redo (licenca adicional)
-- Abrir standby em modo leitura com redo apply ativo
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
ALTER DATABASE OPEN READ ONLY;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT;

-- Verificar que o standby esta aplicando redo com banco aberto
SELECT OPEN_MODE, DATABASE_ROLE FROM V$DATABASE;
-- Esperado: OPEN_MODE=READ ONLY WITH APPLY, DATABASE_ROLE=PHYSICAL STANDBY

-- Monitorar apply lag
SELECT INST_ID, APPLY_LAG, APPLY_RATE FROM V$DATAGUARD_STATS
WHERE NAME = 'apply lag';

-- Far Sync (intermediario para reducao de latencia em DR longa distancia)
-- Primary → Far Sync (LGWR SYNC, perto) → Standby (ASYNC, longe)
```

**Fontes Oracle HA**:
- [Oracle Data Guard Concepts and Administration 19c](https://docs.oracle.com/en/database/oracle/oracle-database/19/sbydb/)
- [Oracle MAA (Maximum Availability Architecture)](https://www.oracle.com/database/technologies/high-availability/maa.html)
- [Oracle Active Data Guard](https://www.oracle.com/database/technologies/high-availability/active-dataguard.html)
- [DISA STIG for Oracle Database](https://public.cyber.mil/stigs/downloads/)

---

## IBM Db2 — HADR

### Configuracao HADR

```bash
# 1. Preparar banco para HADR (deve estar em modo ARCHIVE LOG)
db2 UPDATE DB CFG FOR mydb USING LOGARCHMETH1 DISK:/db2/arch

# 2. Fazer backup do banco (necessario para inicializar o standby)
db2 BACKUP DATABASE mydb TO /backup/db2 INCLUDE LOGS

# 3. Configurar HADR no primario
db2 UPDATE DB CFG FOR mydb USING \
    HADR_LOCAL_HOST  "10.0.0.10" \
    HADR_LOCAL_SVC   "51000" \
    HADR_REMOTE_HOST "10.0.0.11" \
    HADR_REMOTE_SVC  "51000" \
    HADR_REMOTE_INST "db2inst1" \
    HADR_SYNCMODE    NEARSYNC \     # SYNC | NEARSYNC | ASYNC | SUPERASYNC
    HADR_TIMEOUT     120 \
    HADR_PEER_WINDOW 120            # janela de sincronia (segundos)

# 4. Restaurar backup no standby e configurar HADR (mesmos parametros com hosts invertidos)
db2 RESTORE DATABASE mydb FROM /backup/db2 TAKEN AT <timestamp>
db2 UPDATE DB CFG FOR mydb USING \
    HADR_LOCAL_HOST  "10.0.0.11" \
    HADR_LOCAL_SVC   "51000" \
    HADR_REMOTE_HOST "10.0.0.10" \
    HADR_REMOTE_SVC  "51000" \
    HADR_REMOTE_INST "db2inst1" \
    HADR_SYNCMODE    NEARSYNC

# 5. Iniciar HADR (primeiro o standby, depois o primario)
db2 START HADR ON DATABASE mydb AS STANDBY
db2 START HADR ON DATABASE mydb AS PRIMARY

# Verificar status
db2 GET SNAPSHOT FOR DATABASE ON mydb | grep -iE "hadr|standby|primary"
# Ou mais detalhado:
db2pd -hadr -db mydb
```

### Monitoramento e Failover HADR

```sql
-- Via SQL (catalog node)
SELECT
    HADR_ROLE,
    HADR_STATE,
    HADR_SYNCMODE,
    HADR_CONNECT_STATUS,
    HADR_CONNECT_STATUS_TIME,
    LOG_HADR_WAIT_TIME,
    BYTES_SENT,
    BYTES_RECEIVED
FROM SYSIBMADM.SNAPHADR;

-- Lag de replicacao
SELECT
    LOG_HADR_WAIT_TIME AS lag_ms,
    PRIMARY_LOG_TIME,
    STANDBY_LOG_TIME
FROM TABLE(MON_GET_HADR(NULL, -2)) AS T;
```

```bash
# Takeover (failover manual)
db2 TAKEOVER HADR ON DATABASE mydb

# Takeover by force (se primario nao responde)
db2 TAKEOVER HADR ON DATABASE mydb BY FORCE

# Apos failover: conectar nova primaria
db2 CONNECT TO mydb
db2 "SELECT MEMBER, STANDBY_ID, STATE FROM SYSIBMADM.SNAPHADR"

# Reintegrar o primario antigo como standby
# 1. Restaurar ultimo backup
# 2. Configurar HADR no sentido inverso
# 3. START HADR AS STANDBY
```

### HADR com Automatic Client Reroute (ACR)

```bash
# Configurar ACR para que aplicacoes reconectem apos failover
db2 UPDATE ALTERNATE SERVER FOR DATABASE mydb
    USING HOSTNAME 10.0.0.11 PORT 50000

# Verificar configuracao ACR
db2 GET ALTERNATE SERVER FOR DATABASE mydb
```

### Modos HADR

| Modo | Latencia | RPO | Quando Usar |
|------|----------|-----|-------------|
| SYNC | Alta (espera ACK do standby) | 0 | Datacenter local, rede de baixa latencia |
| NEARSYNC | Media | ~1 log page | Recomendado para producao (bom equilibrio) |
| ASYNC | Baixa | Variavel | DR remoto em WAN |
| SUPERASYNC | Nenhuma | Variavel (sem ACK) | DR muito distante; nao recomendado para dados criticos |

**Fontes IBM Db2 HA**:
- [IBM Db2 — HADR Configuration and Administration](https://www.ibm.com/docs/en/db2/11.5?topic=availability-high-disaster-recovery-hadr)
- [IBM Db2 — Automatic Client Reroute](https://www.ibm.com/docs/en/db2/11.5?topic=connections-automatic-client-reroute)
- [IBM Db2 Best Practices — High Availability](https://www.ibm.com/support/pages/best-practices-db2-hadr)

---

## Vertica — Tolerancia a Falhas

### K-Safety

```sql
-- Verificar K-Safety e compliance do cluster
SELECT * FROM V_CATALOG.SYSTEM WHERE KEY = 'KSafe';
SELECT GET_COMPLIANCE_STATUS();

-- Detalhes de compliance por segmento
SELECT * FROM V_MONITOR.STORAGE_CONTAINERS WHERE FAULTS > 0;

-- Minimo de nos por nivel de K-Safety:
-- K=0: 1 no (desenvolvimento apenas — sem tolerancia)
-- K=1: 3 nos (minimo para producao — tolera falha de 1 no)
-- K=2: 5 nos (alta disponibilidade — tolera falha de 2 nos simultaneos)
-- K=3: 7 nos (missao critica)

-- Verificar status de todos os nos
SELECT NODE_NAME, NODE_STATE, NODE_ADDRESS, CATALOG_PATH
FROM V_CATALOG.NODES
ORDER BY NODE_NAME;

-- Verificar nos com dados ausentes (non-compliant)
SELECT * FROM V_MONITOR.DISK_STORAGE
WHERE STORAGE_USAGE = 'DATA, TEMP' AND USED_BYTES = 0;
```

### Eon Mode vs Enterprise Mode

| Aspecto | Enterprise Mode | Eon Mode |
|---------|----------------|----------|
| Storage | Local em cada no | Compartilhado (S3/MinIO/Pure Storage) |
| Scaling | Rebalanceamento de dados (downtime possivel) | Online — adicionar/remover nos sem rebalancear |
| Disponibilidade durante escala | Possivel degradacao | Transparente |
| Custo | Hardware dedicado | Pay-as-you-go para storage |
| Cold storage | Nao nativo | Suporte nativo a subcluster de computacao por demanda |

```sql
-- Configurar Eon Mode (configurado no bootstrap — nao pode mudar apos criacao)
-- bootstrap.json
{
  "communal_storage_location": "s3://meu-bucket/vertica-eon",
  "s3_enable_virtual_addressing": true,
  "aws_access_key_id": "AKIAIOSFODNN7EXAMPLE",
  "aws_secret_access_key": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "ksafety": 1,
  "num_shards": 6
}

-- Criar subcluster (Eon Mode — scale-out separado por carga de trabalho)
SELECT START_SUBCLUSTER('analytics_subcluster');
SELECT ADD_NODES_TO_SUBCLUSTER('analytics_subcluster', ARRAY['v_vmart_node0004', 'v_vmart_node0005']);

-- Listar subclusters
SELECT SUBCLUSTER_NAME, IS_PRIMARY, CONTROL_NODE
FROM V_CATALOG.SUBCLUSTERS;

-- Monitorar depot (cache local dos dados do communal storage)
SELECT NODE_NAME, PINNED_BYTES, CACHED_BYTES, DEPOT_SIZE
FROM V_CATALOG.DEPOT_PINS;
```

### Failover e Recuperacao no Vertica

```bash
# Se um no falhar (K=1, cluster continua operando com os nos restantes)
# Verificar nos indisponiveis
vsql -U dbadmin -c "SELECT NODE_NAME, NODE_STATE FROM NODES WHERE NODE_STATE != 'UP';"

# Remover no permanentemente falho e redistribuir dados
/opt/vertica/bin/admintools -t remove_node -d VMart -s 10.0.0.14

# Re-adicionar no apos recuperacao
/opt/vertica/bin/admintools -t add_node -d VMart -s 10.0.0.14
/opt/vertica/bin/admintools -t rebalance_data -d VMart -k 1

# Para Eon Mode: rebalanceamento e automatico
```

**Fontes Vertica HA**:
- [Vertica — K-Safety and Fault Tolerance](https://www.vertica.com/docs/latest/HTML/Content/Authoring/ConceptsGuide/Other/KSafety.htm)
- [Vertica — Eon Mode Overview](https://www.vertica.com/docs/latest/HTML/Content/Authoring/Eon/EonOverview.htm)
- [Vertica — High Availability Best Practices](https://www.vertica.com/kb/high-availability-best-practices/)
- [Vertica — Subclusters in Eon Mode](https://www.vertica.com/docs/latest/HTML/Content/Authoring/Eon/Subclusters/SubclustersOverview.htm)

---

## Redis — Sentinel e Cluster

> **Por que Sentinel precisa de 3 nos em hosts SEPARADOS?**
> Sentinel usa quorum para decidir se o master caiu e se deve promover uma replica. Com 2 sentinels: se a rede entre os 2 cair, cada um pensa que o outro morreu — quorum de 1/2 = impossivel de decidir sem split-brain. Com 3 sentinels em hosts separados: mesmo se a rede entre 2 deles cair, 2 de 3 ainda se enxergam e tomam a decisao de failover corretamente. Este e o numero minimo para quorum seguro.
>
> Se os 3 sentinels estiverem no mesmo servidor do master, uma falha do servidor derruba o master E todos os sentinels simultaneamente — sem quorum para failover.
>
> **Por que Redis Cluster tem minimo de 6 nos (3 master + 3 replica)?**
> No Redis Cluster, cada master precisa de pelo menos 1 replica para HA. Com 3 masters e 0 replicas: a perda de 1 master torna 1/3 dos slots indisponiveis e o cluster para de aceitar escritas. Com 3 replicas, a perda de qualquer master resulta na promocao automatica da sua replica — cluster permanece operacional.
>
> **Por que usar `cluster-require-full-coverage no`?**
> Com o valor padrao `yes`, se qualquer faixa de slots perder tanto o master quanto a replica, o cluster inteiro para de responder — para proteger consistencia. Para a maioria dos casos de uso, `no` e preferivel: o cluster continua servindo os slots que tem cobertura, degradando parcialmente em vez de parar completamente.

### Redis Sentinel (HA para instancias standalone)

```
Topologia recomendada (Sentinel em hosts SEPARADOS para evitar split-brain):
  Sentinel 1 (10.0.0.20:26379) ─┐
  Sentinel 2 (10.0.0.21:26379) ─┼─ monitoram ─► Master (10.0.0.10:6379)
  Sentinel 3 (10.0.0.22:26379) ─┘                    ↑ replicacao
                                              Replica 1 (10.0.0.11:6379)
                                              Replica 2 (10.0.0.12:6379)
```

```bash
# sentinel.conf (mesmo em todos os 3 sentinels, ajustar apenas o hostname)
port 26379
bind 0.0.0.0
protected-mode no

# Monitorar master (quorum = 2: 2 de 3 sentinels devem concordar no failover)
sentinel monitor mymaster 10.0.0.10 6379 2
sentinel auth-pass mymaster MasterPass@123!
sentinel auth-user mymaster default          # Redis 6+ ACL

# Timeouts
sentinel down-after-milliseconds mymaster 5000     # 5s sem resposta = down
sentinel failover-timeout mymaster 60000           # 60s para completar failover
sentinel parallel-syncs mymaster 1                 # sincronizar 1 replica por vez

# TLS para Sentinel (Redis 6+)
tls-port 26379
port 0                                             # desabilitar porta sem TLS
tls-cert-file /etc/redis/tls/sentinel.crt
tls-key-file /etc/redis/tls/sentinel.key
tls-ca-cert-file /etc/redis/tls/ca.crt
tls-auth-clients yes

sentinel tls-replication yes
sentinel tls-no-auth yes                           # para conexoes entre sentinels
```

```bash
# Verificar status do Sentinel
redis-cli -p 26379 sentinel masters
redis-cli -p 26379 sentinel slaves mymaster
redis-cli -p 26379 sentinel ckquorum mymaster      # verificar quorum

# Failover manual via Sentinel
redis-cli -p 26379 sentinel failover mymaster

# Verificar qual e o master atual (para aplicacoes)
redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
```

### Redis Cluster (HA + Sharding Automatico)

```
Topologia minima (6 nos: 3 masters + 3 replicas):
  Master 1 (10.0.0.10:6379) — slots 0-5460      ← Replica 4 (10.0.0.13:6379)
  Master 2 (10.0.0.11:6379) — slots 5461-10922  ← Replica 5 (10.0.0.14:6379)
  Master 3 (10.0.0.12:6379) — slots 10923-16383 ← Replica 6 (10.0.0.15:6379)
16384 hash slots distribuidos entre masters
```

```bash
# redis.conf — configuracao de cluster (todos os nos)
port 6379
cluster-enabled yes
cluster-config-file /var/lib/redis/nodes.conf
cluster-node-timeout 5000              # 5s para detectar no offline
cluster-announce-ip 10.0.0.10         # IP que o no anuncia para o cluster
cluster-announce-port 6379
cluster-announce-bus-port 16379       # porta de gossip entre nos
cluster-require-full-coverage no      # continuar operando com slots sem cobertura

# Criar cluster (apenas uma vez no primeiro setup)
redis-cli --cluster create \
    10.0.0.10:6379 10.0.0.11:6379 10.0.0.12:6379 \
    10.0.0.13:6379 10.0.0.14:6379 10.0.0.15:6379 \
    --cluster-replicas 1 \
    --cluster-yes

# Verificar status
redis-cli -c cluster info
redis-cli -c cluster nodes | column -t

# Adicionar novo master ao cluster
redis-cli --cluster add-node 10.0.0.16:6379 10.0.0.10:6379

# Adicionar replica para master especifico
redis-cli --cluster add-node 10.0.0.17:6379 10.0.0.10:6379 \
    --cluster-slave \
    --cluster-master-id <master-node-id>

# Rebalancear slots apos adicionar nos
redis-cli --cluster rebalance 10.0.0.10:6379 --cluster-use-empty-masters

# Remover no do cluster
redis-cli --cluster del-node 10.0.0.10:6379 <node-id>

# Verificar distribuicao de slots
redis-cli -c cluster slots | python3 -c "
import sys, ast
for item in ast.literal_eval(sys.stdin.read()):
    print(f'Slots {item[0]}-{item[1]}: {item[2][0].decode()}')"
```

### Criterios de Escolha: Sentinel vs Cluster

| Criterio | Sentinel | Redis Cluster |
|----------|----------|---------------|
| Volume de dados | < 25GB por instancia | > 25GB ou necessidade de escala horizontal |
| Comandos multi-key (MSET, pipelines) | Sim, sem restricao | Limitado (chaves devem estar no mesmo slot) |
| Comandos Lua scripts | Sim | Limitado |
| Complexidade operacional | Baixa | Media-alta |
| Sharding automatico | Nao | Sim (hash slots) |
| Minimo de nos | 3 sentinels + 1 master | 6 (3 masters + 3 replicas) |
| Failover time | ~5-15 segundos | ~1-5 segundos |
| Modelo de programacao | Identico ao standalone | Requer cliente ciente de cluster |

**Fontes Redis HA**:
- [Redis — Sentinel Documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/)
- [Redis — Cluster Tutorial](https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/)
- [Redis — Cluster Specification](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/)
- [Redis — High Availability with Sentinel](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/#sentinel-as-a-means-of-automatic-failover)

---

## Checklist de Validacao de HA

### Validacao Inicial (apos configuracao)

- [ ] Failover testado: desligar primario, confirmar que standby assumiu em RTO esperado
- [ ] Aplicacao reconecta automaticamente apos failover (sem intervencao manual)
- [ ] Connection string usa listener/VIP/proxy (nao IP direto do primario)
- [ ] RPO medido durante failover (lag antes da promocao)
- [ ] RTO medido (tempo entre queda do primario e aplicacao operacional no standby)
- [ ] Alertas dispararam corretamente durante o failover
- [ ] Failback testado (primario original recuperado e voltou como standby)

### Validacao Periodica (trimestral)

- [ ] Failover simulado planejado em horario de baixo uso
- [ ] Verificar que todas as replicas estao sincronizadas
- [ ] Verificar espaco disponivel para WAL/redo log acumulo durante failover
- [ ] Testar reconexao de todas as aplicacoes apos failover
- [ ] Documentar RTO/RPO atingidos e comparar com SLA
- [ ] Atualizar runbook com qualquer mudanca no procedimento

### Decisao: Sincrono vs Assincrono

| Cenario | Recomendacao |
|---------|-------------|
| HA local (mesmo datacenter) | Sincrono (RPO=0, latencia de LAN e aceitavel) |
| DR regional (< 100km) | Sincrono pode ser viavel dependendo da latencia |
| DR geografico (> 100km ou WAN) | Assincrono (evitar degradacao do primario) |
| Missao critica sem tolerancia a perda de dados | Sincrono com replica em outro rack no mesmo DC |
