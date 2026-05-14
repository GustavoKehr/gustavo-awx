# 08 — Alta Disponibilidade e Replicacao

## Conceitos Fundamentais

| Conceito | Definicao |
|----------|-----------|
| **HA (High Availability)** | Capacidade do sistema de continuar operando mesmo com falhas de componentes |
| **Failover** | Troca automatica ou manual para o servidor standby quando o primario falha |
| **Failback** | Retorno ao servidor primario original apos recuperacao |
| **Sincrono** | Transacao confirmada somente apos escrita no standby — RPO = 0, impacto em latencia |
| **Assincrono** | Transacao confirmada no primario; standby recebe dados depois — RPO > 0, sem impacto em latencia |
| **Quorum** | Numero minimo de nos que devem concordar para tomar uma decisao (ex: eleicao de novo primario) |
| **Split Brain** | Dois nos acreditam ser o primario simultaneamente — cenario critico a evitar |

---

## PostgreSQL

### Arquitetura de HA Recomendada

```
              ┌─────────────────────────────────────────────┐
              │              Load Balancer / VIP             │
              └────────────────────┬────────────────────────┘
                                   │
              ┌────────────────────▼────────────────────────┐
              │          Patroni Cluster Manager             │
              │         (etcd / Consul / ZooKeeper)          │
              └──────┬─────────────────────────┬────────────┘
                     │                         │
          ┌──────────▼──────────┐   ┌──────────▼──────────┐
          │  Primario (RW)       │   │  Standby (Read)      │
          │  PostgreSQL          │◄──│  PostgreSQL          │
          │  Patroni Agent       │   │  Patroni Agent       │
          └─────────────────────┘   └──────────────────────┘
```

### Replicacao com Streaming (nativo)

```sql
-- No primario: criar usuario de replicacao
CREATE USER replicator REPLICATION LOGIN CONNECTION LIMIT 5 ENCRYPTED PASSWORD 'SenhaRepl123!';

-- postgresql.conf no primario
wal_level = replica
max_wal_senders = 10
wal_keep_size = 1GB
hot_standby = on

-- pg_hba.conf no primario
host replication replicator 10.0.0.11/32 scram-sha-256

-- Criar standby
pg_basebackup -h 10.0.0.10 -U replicator -D /var/lib/postgresql/data -P -R --wal-method=stream

-- postgresql.conf no standby (PG >= 12)
# primary_conninfo = 'host=10.0.0.10 port=5432 user=replicator password=SenhaRepl123!'
# primary_slot_name = 'replica_01'
# hot_standby = on

-- Verificar replicacao
SELECT * FROM pg_stat_replication;  -- no primario
SELECT * FROM pg_stat_wal_receiver;  -- no standby
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
    maximum_lag_on_failover: 1048576  # 1MB

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.10:5432
  pg_hba:
    - host replication replicator 0.0.0.0/0 scram-sha-256
    - host all all 0.0.0.0/0 scram-sha-256
```

### Replication Slots (cuidado com WAL acumulo)
```sql
-- Criar slot de replicacao
SELECT pg_create_physical_replication_slot('replica_01');

-- Verificar slots (monitorar retained_bytes)
SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;

-- ALERTA: slots inativos acumulam WAL indefinidamente — remover se standby for desativado
```

---

## MySQL

### Topologias de HA

**1. InnoDB Cluster (Group Replication + MySQL Router)**
```
MySQL Router (load balancer)
  → Primary (R/W)
  → Secondary 1 (R) ← Group Replication (sincrona)
  → Secondary 2 (R) ← Group Replication (sincrona)
Minimo 3 nos para quorum
```

**2. Replicacao Tradicional (Source-Replica)**
```sql
-- No primario: habilitar binlog
-- my.cnf: log_bin = mysql-bin, server-id = 1, binlog_format = ROW

-- Criar usuario de replicacao
CREATE USER 'replication'@'10.0.0.%' IDENTIFIED WITH caching_sha2_password BY 'SenhaRepl123!';
GRANT REPLICATION SLAVE ON *.* TO 'replication'@'10.0.0.%';

-- No standby: configurar apontamento
CHANGE REPLICATION SOURCE TO
    SOURCE_HOST = '10.0.0.10',
    SOURCE_PORT = 3306,
    SOURCE_USER = 'replication',
    SOURCE_PASSWORD = 'SenhaRepl123!',
    SOURCE_AUTO_POSITION = 1;  -- GTID-based replication

START REPLICA;
SHOW REPLICA STATUS\G
```

**GTID — Configuracao Obrigatoria para HA Moderno**
```ini
# my.cnf
gtid_mode = ON
enforce_gtid_consistency = ON
binlog_format = ROW
```

### MySQL Orchestrator — Failover Automatico
- Ferramenta de topologia e failover automatico para MySQL
- Detecta falha do primario, promove o standby mais atualizado
- Integra com Consul/ZooKeeper para quorum
- URL: https://github.com/openark/orchestrator

---

## SQL Server — Always On Availability Groups

### Requisitos
- Windows Server Failover Cluster (WSFC) — obrigatorio
- Minimo 2 nos SQL Server Enterprise Edition
- Quorum configurado (Witness: disco ou file share)

### Configuracao

```sql
-- Criar Availability Group
CREATE AVAILABILITY GROUP [AG_Producao]
WITH (
    AUTOMATED_BACKUP_PREFERENCE = SECONDARY,
    FAILURE_CONDITION_LEVEL = 3,
    HEALTH_CHECK_TIMEOUT = 30000
)
FOR DATABASE [MeuBanco1], [MeuBanco2]
REPLICA ON
    N'SQLSERVER01' WITH (
        ENDPOINT_URL = N'TCP://sqlserver01.domain.com:5022',
        FAILOVER_MODE = AUTOMATIC,
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        BACKUP_PRIORITY = 50,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY)
    ),
    N'SQLSERVER02' WITH (
        ENDPOINT_URL = N'TCP://sqlserver02.domain.com:5022',
        FAILOVER_MODE = AUTOMATIC,
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        BACKUP_PRIORITY = 60,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY)
    );

-- Adicionar listener (VIP para aplicacoes)
ALTER AVAILABILITY GROUP [AG_Producao]
ADD LISTENER N'ag-producao-listener' (
    WITH IP ((N'10.0.0.100', N'255.255.255.0')),
    PORT = 1433
);
```

### Modos de Commit
| Modo | RPO | Impacto | Quando Usar |
|------|-----|---------|-------------|
| SYNCHRONOUS_COMMIT | 0 (zero data loss) | Latencia adicional | HA local, mesma subnet |
| ASYNCHRONOUS_COMMIT | > 0 (aceitavel) | Sem impacto em latencia | DR remoto, outra regiao |

---

## Oracle — Data Guard

### Configuracao via Data Guard Broker

```bash
# dgmgrl — Data Guard Manager CLI
dgmgrl /

# Configurar broker
DGMGRL> CREATE CONFIGURATION 'dg_config' AS
PRIMARY DATABASE IS 'ORCL_PRIMARY'
CONNECT IDENTIFIER IS 'ORCL_PRIMARY';

DGMGRL> ADD DATABASE 'ORCL_STANDBY' AS
CONNECT IDENTIFIER IS 'ORCL_STANDBY'
MAINTAINED AS PHYSICAL;

DGMGRL> ENABLE CONFIGURATION;

# Verificar status
DGMGRL> SHOW CONFIGURATION;
DGMGRL> SHOW DATABASE VERBOSE 'ORCL_STANDBY';

# Switchover (planejado — zero downtime)
DGMGRL> SWITCHOVER TO 'ORCL_STANDBY';

# Failover (emergencia)
DGMGRL> FAILOVER TO 'ORCL_STANDBY';
```

### Modos de Protecao

| Modo | RPO | Impacto | Configuracao |
|------|-----|---------|-------------|
| Maximum Protection | 0 | Alto (primary para se standby offline) | `LOG_ARCHIVE_DEST_2 ... SYNC AFFIRM` |
| Maximum Availability | 0 (se possivel) | Medio (degrada para async se standby offline) | `SYNC NOAFFIRM` |
| Maximum Performance | > 0 | Nenhum | `ASYNC` — padrao |

### Oracle Active Data Guard (licenca adicional)
- Permite leitura no standby enquanto recebe redo
- Offload de queries de relatorio para standby
- Backups no standby (nao impacta o primario)

---

## IBM Db2 — HADR

```bash
# Configurar HADR no primario
db2 UPDATE DB CFG FOR mydb USING
    HADR_LOCAL_HOST  "10.0.0.10"
    HADR_LOCAL_SVC   "51000"
    HADR_REMOTE_HOST "10.0.0.11"
    HADR_REMOTE_SVC  "51000"
    HADR_REMOTE_INST "db2inst1"
    HADR_SYNCMODE    NEARSYNC  -- ou SYNC ou ASYNC

# Configurar HADR no standby (mesma configuracao com hosts invertidos)

# Iniciar HADR
db2 START HADR ON DATABASE mydb AS PRIMARY
db2 START HADR ON DATABASE mydb AS STANDBY

# Verificar status
db2 GET SNAPSHOT FOR DATABASE ON mydb | grep -i hadr

# Takeover (failover manual)
db2 TAKEOVER HADR ON DATABASE mydb
```

### Modos HADR
| Modo | Latencia | RPO |
|------|----------|-----|
| SYNC | Alta | 0 |
| NEARSYNC | Media | ~1 log page |
| ASYNC | Nenhuma | Variavel |
| SUPERASYNC | Nenhuma | Variavel (sem confirmacao do standby) |

---

## Vertica — Tolerancia a Falhas

### K-Safety
```sql
-- Verificar K-Safety atual
SELECT GET_COMPLIANCE_STATUS();
SELECT * FROM SYSTEM WHERE KEY = 'KSafe';

-- K=1: cluster sobrevive a perda de 1 no
-- K=2: cluster sobrevive a perda de 2 nos simultaneos

-- Minimo de nos por K-Safety:
-- K=0: 1 no (sem tolerancia, apenas desenvolvimento)
-- K=1: 3 nos (minimo para producao)
-- K=2: 5 nos

-- Verificar saude do cluster
SELECT * FROM V_MONITOR.NODES;
SELECT * FROM V_MONITOR.DISK_STORAGE;
```

### Eon Mode vs Enterprise Mode
| Aspecto | Enterprise Mode | Eon Mode |
|---------|----------------|----------|
| Storage | Local nos nos | Compartilhado (S3, Pure Storage) |
| Scaling | Mais complexo | Facil (adicionar/remover nos) |
| Disponibilidade durante escala | Downtime possivel | Online scaling |
| Custo | Hardware dedicado | Paga pelo storage usado |

---

## Redis — Sentinel e Cluster

### Redis Sentinel (HA para instancias standalone)

```
Minimo: 3 Sentinels em hosts fisicos SEPARADOS (evitar split-brain)

Topologia:
  Sentinel 1 (10.0.0.20)  ─┐
  Sentinel 2 (10.0.0.21)  ─┼─ monitoram ─► Master (10.0.0.10)
  Sentinel 3 (10.0.0.22)  ─┘                    ↑
                                        Replica 1 (10.0.0.11)
                                        Replica 2 (10.0.0.12)
```

```
# sentinel.conf
sentinel monitor mymaster 10.0.0.10 6379 2  # quorum = 2
sentinel auth-pass mymaster SenhaMaster123!
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
sentinel parallel-syncs mymaster 1

# TLS para Sentinel
sentinel tls-port 26379
sentinel tls-cert-file /etc/redis/tls/sentinel.crt
sentinel tls-key-file /etc/redis/tls/sentinel.key
```

### Redis Cluster (HA + sharding)

```
Minimo: 6 nos (3 masters + 3 replicas)
16384 hash slots distribuidos entre masters

Master 1 (slots 0-5460)     ← Replica 4
Master 2 (slots 5461-10922) ← Replica 5
Master 3 (slots 10923-16383) ← Replica 6
```

```bash
# Criar cluster Redis
redis-cli --cluster create \
    10.0.0.10:6379 10.0.0.11:6379 10.0.0.12:6379 \
    10.0.0.13:6379 10.0.0.14:6379 10.0.0.15:6379 \
    --cluster-replicas 1

# Verificar status do cluster
redis-cli cluster info
redis-cli cluster nodes

# Failover manual
redis-cli -h 10.0.0.13 CLUSTER FAILOVER
```

### Criterios de Escolha: Sentinel vs Cluster

| Criterio | Sentinel | Cluster |
|----------|----------|---------|
| Volume de dados | < 25GB | > 25GB |
| Comandos multi-key | Sim | Limitado (mesma slot) |
| Complexidade operacional | Baixa | Media |
| Sharding automatico | Nao | Sim |
| Minimo de nos | 3 + 1 master | 6 (3+3) |

---

## Checklist de Validacao de HA

Executar apos configuracao e trimestralmente:

- [ ] Failover testado (desligar primario, confirmar que standby assumiu)
- [ ] Aplicacao reconecta automaticamente apos failover
- [ ] Connection string usa listener/VIP (nao IP direto do primario)
- [ ] RPO medido durante ultimo failover (lag antes do failover)
- [ ] RTO medido (tempo ate aplicacao voltar a funcionar)
- [ ] Alertas dispararam corretamente durante o failover
- [ ] Failback testado (primario original recuperado e voltou como standby)
- [ ] Documentacao atualizada com resultado do teste
