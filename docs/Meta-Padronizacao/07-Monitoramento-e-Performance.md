# 07 — Monitoramento e Performance

## Stack de Monitoramento Recomendada

```
Exporters/Agents  →  Prometheus  →  Grafana (visualizacao)
                                 →  Alertmanager → Slack/PagerDuty/Email/OpsGenie

Logs     →  Filebeat/Fluentd  →  Logstash  →  Elasticsearch  →  Kibana
         →  Loki                            →  Grafana Loki
```

### Exporters por Banco

| Banco | Exporter Prometheus | Dashboard Grafana | Ferramenta Nativa |
|-------|--------------------|--------------------|-------------------|
| PostgreSQL | `postgres_exporter` (prometheuscommunity) | ID: 9628 | pgAdmin, pg_activity |
| MySQL | `mysqld_exporter` (prometheuscommunity) | ID: 7362 | MySQL Workbench, PMM |
| SQL Server | `sql_exporter` (burningalchemist) | ID: 13919 | SSMS, Activity Monitor |
| Oracle | `oracledb_exporter` (iamseth) | ID: 3333 | Enterprise Manager, AWR |
| Db2 | `db2_exporter` (IBM) | Custom | IBM Data Server Manager |
| Vertica | `vertica_exporter` (vertica) | Custom | Vertica MC |
| Redis | `redis_exporter` (oliver006) | ID: 763 | Redis Insight, RedisCommander |

---

## Estabelecimento de Baseline

Antes de configurar alertas, coletar baseline por **2–4 semanas** em producao:

1. Coletar metricas em horarios de pico e fora de pico
2. Identificar padroes: crescimento diario, semanal, sazonalidade
3. Calcular percentis: p50, p95, p99 para latencia e throughput
4. Definir thresholds baseados no baseline (nao valores genericos)
5. Evitar alert fatigue: calibrar para minimizar falsos positivos

---

## KPIs por Categoria

### Disponibilidade
| KPI | Warning | Critico |
|-----|---------|---------|
| Uptime | < 99.5% | < 99% |
| Connection availability | Timeout > 5s | Falha de conexao |
| Replication lag | > 60s | > 300s |

### Performance de Queries
| KPI | Warning | Critico |
|-----|---------|---------|
| Query latency p95 | > 200ms | > 1000ms |
| Query latency p99 | > 500ms | > 5000ms |
| Slow queries/min | > 10 | > 50 |
| Long-running transactions | > 5 min | > 30 min |
| Lock waits | > 10 | > 50 |
| Deadlocks/hour | > 5 | > 20 |

### Recursos
| KPI | Warning | Critico |
|-----|---------|---------|
| CPU processo do banco | > 70% | > 90% |
| Memory usage | > 80% | > 95% |
| Disk IOPS | > 70% max | > 90% max |
| Disk space (dados) | > 70% | > 85% |
| Disk space (logs/WAL) | > 60% | > 80% |

### Conexoes
| KPI | Warning | Critico |
|-----|---------|---------|
| Connection count | > 80% max | > 90% max |
| Pool utilization | > 70% | > 90% |
| Failed connections/min | > 5 | > 20 |
| Idle connections | > 100 | > 300 |

### Cache
| KPI | Warning | Critico |
|-----|---------|---------|
| Buffer cache hit ratio | < 95% | < 90% |
| Redis hit rate | < 90% | < 80% |
| Redis eviction rate | > 100/s | > 1000/s |

---

## PostgreSQL — Monitoramento e Performance

### Views e Queries de Monitoramento
```sql
-- ====================
-- QUERIES ATIVAS E LENTAS
-- ====================

-- Queries lentas ativas agora
SELECT
    pid,
    now() - query_start AS duration,
    state,
    wait_event_type,
    wait_event,
    LEFT(query, 200) AS query_preview,
    application_name,
    client_addr
FROM pg_stat_activity
WHERE state != 'idle'
  AND now() - query_start > interval '5 seconds'
ORDER BY duration DESC;

-- Top 20 queries por tempo total (usando pg_stat_statements)
-- Habilitar: shared_preload_libraries = 'pg_stat_statements'
SELECT
    LEFT(query, 100) AS query_preview,
    calls,
    total_exec_time / 1000 AS total_sec,
    mean_exec_time AS avg_ms,
    max_exec_time AS max_ms,
    rows / calls AS avg_rows,
    100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0) AS hit_pct
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;

-- ====================
-- CACHE E I/O
-- ====================

-- Taxa de cache hit por banco
SELECT
    datname,
    blks_hit,
    blks_read,
    100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0) AS cache_hit_pct
FROM pg_stat_database
WHERE datname NOT IN ('postgres','template0','template1');

-- Taxa de cache hit por tabela
SELECT
    schemaname,
    tablename,
    heap_blks_hit,
    heap_blks_read,
    100.0 * heap_blks_hit / NULLIF(heap_blks_hit + heap_blks_read, 0) AS hit_pct
FROM pg_statio_user_tables
ORDER BY hit_pct ASC NULLS LAST
LIMIT 20;

-- ====================
-- BLOQUEIOS
-- ====================

-- Bloqueios ativos
SELECT
    pid,
    now() - query_start AS duration,
    pg_blocking_pids(pid) AS blocked_by,
    LEFT(query, 150) AS query_preview
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0;

-- Grafico de bloqueios (quem bloqueia quem)
SELECT
    a.pid AS blocked_pid,
    a.usename AS blocked_user,
    b.pid AS blocking_pid,
    b.usename AS blocking_user,
    a.query AS blocked_query,
    b.query AS blocking_query
FROM pg_stat_activity a
JOIN pg_stat_activity b ON b.pid = ANY(pg_blocking_pids(a.pid));

-- ====================
-- REPLICACAO
-- ====================

SELECT
    client_addr,
    application_name,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_lag_size,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;

-- Lag no standby
SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;

-- ====================
-- TAMANHO E CRESCIMENTO
-- ====================

SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) -
        pg_relation_size(schemaname||'.'||tablename)) AS index_size
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;

-- ====================
-- AUTOVACUUM
-- ====================

-- Tabelas precisando de VACUUM urgente (bloat ou age)
SELECT
    schemaname,
    tablename,
    n_dead_tup,
    n_live_tup,
    100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0) AS dead_pct,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY dead_pct DESC;
```

### Configuracoes de Performance PostgreSQL

**Para OLTP** (muitas transacoes curtas):
```ini
shared_buffers = 8GB              # 25% da RAM em servidor de 32GB
effective_cache_size = 24GB       # 75% da RAM
work_mem = 16MB                   # 64MB para conexoes de analitica; 4-16MB para OLTP
maintenance_work_mem = 2GB
wal_level = replica
wal_buffers = 64MB
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_completion_target = 0.9
checkpoint_timeout = 15min
random_page_cost = 1.1            # SSD
effective_io_concurrency = 200    # SSD
max_parallel_workers_per_gather = 4
max_parallel_workers = 16
default_statistics_target = 100
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02
```

**Para Data Warehouse** (queries grandes/paralelas):
```ini
shared_buffers = 8GB
effective_cache_size = 24GB
work_mem = 1GB                    # queries DW usam muito mais work_mem
maintenance_work_mem = 4GB
max_parallel_workers_per_gather = 8
max_parallel_workers = 16
enable_hashjoin = on
enable_mergejoin = on
enable_sort = on
jit = on                          # JIT para queries analíticas
```

**Fontes PostgreSQL Performance**:
- https://www.postgresql.org/docs/current/monitoring-stats.html
- https://www.postgresql.org/docs/current/pgstatstatements.html
- https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server
- https://www.timescale.com/learn/postgresql-performance-tuning
- https://use-the-index-luke.com/sql/explain-plan/postgresql/

---

## MySQL — Monitoramento e Performance

### Queries de Monitoramento
```sql
-- ====================
-- PROCESSLIST E QUERIES LENTAS
-- ====================

-- Queries ativas agora
SELECT
    id, user, host, db, command, time, state,
    LEFT(info, 200) AS query_preview
FROM information_schema.PROCESSLIST
WHERE COMMAND != 'Sleep'
  AND TIME > 1
ORDER BY TIME DESC;

-- Performance Schema: top queries por latencia
SELECT
    DIGEST_TEXT,
    COUNT_STAR AS calls,
    AVG_TIMER_WAIT / 1e9 AS avg_ms,
    MAX_TIMER_WAIT / 1e9 AS max_ms,
    SUM_TIMER_WAIT / 1e9 AS total_s
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;

-- ====================
-- INNODB STATUS
-- ====================

SHOW ENGINE INNODB STATUS\G
-- Analisar: TRANSACTIONS (transactions waiting), SEMAPHORES (mutex waits),
-- BUFFER POOL AND MEMORY (hit rate), ROW OPERATIONS (rows read/inserted/updated)

-- Buffer pool hit rate
SELECT
    VARIABLE_NAME,
    VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN (
    'Innodb_buffer_pool_reads',
    'Innodb_buffer_pool_read_requests',
    'Innodb_buffer_pool_pages_data',
    'Innodb_buffer_pool_pages_free',
    'Innodb_buffer_pool_pages_dirty'
);

-- Calcular hit rate
SELECT
    ROUND(100 - (100 * (SELECT VARIABLE_VALUE FROM performance_schema.global_status
        WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') /
        (SELECT VARIABLE_VALUE FROM performance_schema.global_status
        WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests')), 2) AS hit_pct;

-- ====================
-- REPLICACAO
-- ====================

-- No primario
SHOW BINARY LOG STATUS\G          -- MySQL 8.0.22+
SHOW MASTER STATUS\G              -- versoes anteriores

-- Na replica
SHOW REPLICA STATUS\G             -- MySQL 8.0.22+
SHOW SLAVE STATUS\G               -- versoes anteriores
-- Monitorar: Seconds_Behind_Source (lag), IO_Running, SQL_Running

-- Replica lag em segundos
SELECT
    CHANNEL_NAME,
    SERVICE_STATE,
    LAST_QUEUED_TRANSACTION_START_QUEUE_TIMESTAMP,
    LAST_APPLIED_TRANSACTION_END_APPLY_TIMESTAMP
FROM performance_schema.replication_applier_status_by_coordinator;

-- ====================
-- INDICES INUTILIZADOS
-- ====================

-- Tabelas sem indices (table scans)
SELECT
    object_schema AS db_name,
    object_name AS table_name,
    count_read,
    count_fetch
FROM performance_schema.table_io_waits_summary_by_table
WHERE count_read > 0 AND object_schema NOT IN ('performance_schema','information_schema','mysql','sys')
ORDER BY count_read DESC;
```

### Configuracoes de Performance MySQL

```ini
[mysqld]
# Buffer pool (mais critico)
innodb_buffer_pool_size = 24G        # 75% da RAM em 32GB
innodb_buffer_pool_instances = 8
innodb_buffer_pool_chunk_size = 3G   # = pool_size / instances

# Redo log
innodb_log_file_size = 2G
innodb_log_files_in_group = 2

# I/O
innodb_flush_method = O_DIRECT
innodb_io_capacity = 2000
innodb_io_capacity_max = 4000
innodb_read_io_threads = 8
innodb_write_io_threads = 8

# Conexoes
max_connections = 1000
thread_cache_size = 100
table_open_cache = 8000

# Sort e join
sort_buffer_size = 4M
join_buffer_size = 4M
read_rnd_buffer_size = 4M

# Temp tables
tmp_table_size = 256M
max_heap_table_size = 256M
```

**Fontes MySQL Performance**:
- https://dev.mysql.com/doc/refman/8.0/en/performance-schema.html
- https://dev.mysql.com/doc/refman/8.0/en/innodb-monitors.html
- https://www.percona.com/blog/tuning-innodb-primary-keys/
- https://aws.amazon.com/blogs/database/best-practices-for-configuring-parameters-for-amazon-rds-for-mysql-part-1-parameters-related-to-performance/

---

## SQL Server — Monitoramento e Performance

### Queries de Monitoramento
```sql
-- ====================
-- TOP QUERIES CONSUMO DE RECURSOS
-- ====================

-- Top queries por CPU
SELECT TOP 20
    qs.total_worker_time / 1000000 AS total_cpu_sec,
    qs.total_worker_time / qs.execution_count / 1000 AS avg_cpu_ms,
    qs.execution_count,
    qs.total_logical_reads / qs.execution_count AS avg_logical_reads,
    SUBSTRING(st.text, (qs.statement_start_offset/2) + 1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
         ELSE qs.statement_end_offset END - qs.statement_start_offset)/2) + 1) AS query_text,
    DB_NAME(st.dbid) AS database_name
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY total_worker_time DESC;

-- ====================
-- WAITS
-- ====================

-- Wait stats (excluindo waits normais de idle)
SELECT TOP 20
    wait_type,
    waiting_tasks_count,
    wait_time_ms / 1000.0 AS wait_s,
    max_wait_time_ms / 1000.0 AS max_wait_s,
    signal_wait_time_ms / 1000.0 AS signal_wait_s,
    CAST(100.0 * wait_time_ms / SUM(wait_time_ms) OVER() AS DECIMAL(5,2)) AS pct
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'SLEEP_TASK', 'WAITFOR', 'LAZYWRITER_SLEEP', 'SQLTRACE_BUFFER_FLUSH',
    'CLR_AUTO_EVENT', 'DISPATCHER_QUEUE_SEMAPHORE', 'ONDEMAND_TASK_QUEUE',
    'REQUEST_FOR_DEADLOCK_SEARCH', 'RESOURCE_QUEUE', 'SERVER_IDLE_CHECK',
    'SLEEP_DBSTARTUP', 'SLEEP_DBRECOVER', 'SLEEP_MASTERDBREADY',
    'SLEEP_MASTERMDREADY', 'SLEEP_MASTERUPGRADED', 'SLEEP_MSDBSTARTUP',
    'SLEEP_SYSTEMTASK', 'SLEEP_TEMPDBSTARTUP', 'SNI_HTTP_ACCEPT',
    'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', 'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
    'XE_DISPATCHER_WAIT', 'XE_TIMER_EVENT', 'BROKER_TO_FLUSH',
    'CHECKPOINT_QUEUE', 'DBMIRROR_EVENTS_QUEUE', 'SQLTRACE_WAIT_ENTRIES',
    'WAIT_HADR_WORK_QUEUE', 'HADR_WORK_QUEUE'
)
ORDER BY wait_time_ms DESC;

-- ====================
-- SESSOES BLOQUEADAS
-- ====================

-- Sessoes bloqueadas e bloqueadoras
SELECT
    blocking.session_id AS blocking_spid,
    blocking.text AS blocking_text,
    blocked.session_id AS blocked_spid,
    blocked.text AS blocked_text,
    r.wait_time / 1000 AS wait_sec,
    r.wait_type
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) blocked
INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
CROSS APPLY sys.dm_exec_sql_text(
    (SELECT sql_handle FROM sys.dm_exec_requests
     WHERE session_id = r.blocking_session_id)) blocking
WHERE r.blocking_session_id > 0;

-- ====================
-- TEMPDB
-- ====================

-- Uso de espaco no tempdb
SELECT
    SUM(unallocated_extent_page_count) * 8.0 / 1024 AS free_mb,
    SUM(version_store_reserved_page_count) * 8.0 / 1024 AS version_store_mb,
    SUM(internal_object_reserved_page_count) * 8.0 / 1024 AS internal_objects_mb,
    SUM(user_object_reserved_page_count) * 8.0 / 1024 AS user_objects_mb
FROM sys.dm_db_file_space_usage;

-- ====================
-- ALWAYS ON / HA
-- ====================

SELECT
    ag.name AS ag_name,
    ars.role_desc,
    adc.database_name,
    drs.synchronization_state_desc,
    drs.secondary_lag_seconds
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states ars ON ag.group_id = ars.group_id
JOIN sys.availability_databases_cluster adc ON ag.group_id = adc.group_id
JOIN sys.dm_hadr_database_replica_states drs
    ON adc.group_id = drs.group_id AND adc.group_database_id = drs.group_database_id
WHERE ars.is_local = 1;
```

**Fontes SQL Server Performance**:
- https://learn.microsoft.com/en-us/sql/relational-databases/performance/performance-monitoring-and-tuning-tools
- https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-stats-transact-sql
- https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-wait-stats-transact-sql
- https://www.brentozar.com/blitz/  (Brent Ozar's sp_Blitz toolset)

---

## Oracle — Monitoramento e Performance

### Queries de Monitoramento (AWR e V$ views)
```sql
-- ====================
-- QUERIES LENTAS ATIVAS
-- ====================

-- Sessoes ativas com SQL em execucao
SELECT
    s.sid,
    s.serial#,
    s.username,
    s.status,
    s.wait_class,
    s.event,
    s.seconds_in_wait,
    SUBSTR(sq.sql_text, 1, 200) AS sql_preview,
    sq.executions,
    sq.buffer_gets / NULLIF(sq.executions, 0) AS avg_gets_per_exec
FROM v$session s
LEFT JOIN v$sql sq ON s.sql_id = sq.sql_id
WHERE s.status = 'ACTIVE'
  AND s.username IS NOT NULL
  AND s.wait_class != 'Idle'
ORDER BY s.seconds_in_wait DESC;

-- Top SQL por Elapsed Time (AWR)
SELECT
    sql_id,
    executions_delta AS execs,
    ROUND(elapsed_time_delta / 1e6 / NULLIF(executions_delta, 0), 2) AS avg_elapsed_s,
    ROUND(buffer_gets_delta / NULLIF(executions_delta, 0)) AS avg_gets,
    ROUND(disk_reads_delta / NULLIF(executions_delta, 0)) AS avg_reads,
    parsing_schema_name
FROM dba_hist_sqlstat s
JOIN dba_hist_snapshot sn ON s.snap_id = sn.snap_id
WHERE sn.begin_interval_time > SYSDATE - 1
ORDER BY elapsed_time_delta DESC
FETCH FIRST 20 ROWS ONLY;

-- ====================
-- WAITS E GARGALOS
-- ====================

-- Top 10 eventos de wait (instancia)
SELECT
    event,
    total_waits,
    ROUND(time_waited_micro / 1e6, 2) AS total_wait_s,
    ROUND(time_waited_micro / total_waits / 1000, 2) AS avg_wait_ms,
    wait_class
FROM v$system_event
WHERE wait_class != 'Idle'
ORDER BY time_waited_micro DESC
FETCH FIRST 10 ROWS ONLY;

-- ====================
-- DATA GUARD STATUS
-- ====================

-- Status do Data Guard
SELECT name, value, datum_time FROM v$dataguard_stats;

-- Archive logs aplicados
SELECT
    dest_name,
    status,
    archived_seq#,
    applied_seq#,
    archived_seq# - applied_seq# AS gap
FROM v$archive_dest_status
WHERE status != 'INACTIVE';

-- ====================
-- TABLESPACE E ESPACO
-- ====================

SELECT
    ts.tablespace_name,
    ROUND(df.total_mb, 0) AS total_mb,
    ROUND(fs.free_mb, 0) AS free_mb,
    ROUND(df.total_mb - fs.free_mb, 0) AS used_mb,
    ROUND((df.total_mb - fs.free_mb) / df.total_mb * 100, 1) AS used_pct,
    ts.status,
    df.autoextensible
FROM dba_tablespaces ts
JOIN (SELECT tablespace_name, SUM(bytes)/1048576 AS total_mb, MAX(autoextensible) AS autoextensible
      FROM dba_data_files GROUP BY tablespace_name) df
    ON ts.tablespace_name = df.tablespace_name
LEFT JOIN (SELECT tablespace_name, SUM(bytes)/1048576 AS free_mb
           FROM dba_free_space GROUP BY tablespace_name) fs
    ON ts.tablespace_name = fs.tablespace_name
ORDER BY used_pct DESC;

-- ====================
-- AWR REPORT (automatico)
-- ====================
-- Para gerar HTML AWR report:
@$ORACLE_HOME/rdbms/admin/awrrpt.sql
-- Escolher: HTML, begin_snap, end_snap, report_name

-- Para gerar via SQL:
SELECT * FROM TABLE(dbms_workload_repository.awr_report_html(
    l_dbid    => (SELECT dbid FROM v$database),
    l_inst_num => 1,
    l_bid     => :begin_snap_id,
    l_eid     => :end_snap_id));
```

**Fontes Oracle Performance**:
- https://docs.oracle.com/en/database/oracle/oracle-database/19/tgdba/
- https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/dynamic-performance-views.html
- https://docs.oracle.com/en/database/oracle/oracle-database/19/arpls/DBMS_WORKLOAD_REPOSITORY.html
- https://www.oracle.com/technical-resources/articles/database-performance/

---

## IBM Db2 — Monitoramento e Performance

### Queries de Monitoramento
```sql
-- ====================
-- SNAPSHOTS DE PERFORMANCE
-- ====================

-- Ativar monitoramento
UPDATE DBM CFG USING DFT_MON_STMT ON;
UPDATE DBM CFG USING DFT_MON_LOCK ON;
UPDATE DBM CFG USING DFT_MON_SORT ON;
UPDATE DBM CFG USING DFT_MON_BUFPOOL ON;

-- Status geral do banco
SELECT * FROM TABLE(SNAP_GET_DB_V95('MYDB', -1)) AS SNAPSHOT;

-- ====================
-- QUERIES LENTAS (Event Monitor)
-- ====================

-- Criar event monitor para statements
CREATE EVENT MONITOR stmt_mon FOR STATEMENTS WRITE TO TABLE EVMON.STMTMON
    (IN TBSP_NAME PAGESIZE 32768);
SET EVENT MONITOR stmt_mon STATE = 1;

-- Ler resultados
SELECT
    SUBSTR(STMT_TEXT, 1, 200),
    TOTAL_CPU_TIME / 1000 AS cpu_ms,
    TOTAL_ACT_TIME / 1000 AS elapsed_ms,
    ROWS_RETURNED,
    NUM_EXECUTIONS
FROM EVMON.STMTMON
ORDER BY TOTAL_ACT_TIME DESC
FETCH FIRST 20 ROWS ONLY;

-- ====================
-- BUFFER POOL HIT RATE
-- ====================

SELECT
    BP_NAME,
    POOL_DATA_L_READS,
    POOL_DATA_P_READS,
    ROUND(CASE WHEN POOL_DATA_L_READS > 0
        THEN 100 - (POOL_DATA_P_READS * 100.0 / POOL_DATA_L_READS) ELSE 100 END, 2) AS hit_pct
FROM TABLE(SNAP_GET_BP_V95('MYDB', -1))
ORDER BY hit_pct;

-- ====================
-- LOCKS E DEADLOCKS
-- ====================

SELECT
    AGENT_ID,
    LOCK_OBJECT_NAME,
    LOCK_MODE,
    LOCK_STATUS,
    AGENT_ID_HOLDING_LK
FROM TABLE(SNAP_GET_LOCK('MYDB', -1))
ORDER BY LOCK_STATUS;

-- ====================
-- REPLICACAO HADR
-- ====================
```bash
db2pd -db mydb -hadr
```

**Fontes Db2 Performance**:
- https://www.ibm.com/docs/en/db2/11.5?topic=monitoring-database-activities
- https://www.ibm.com/docs/en/db2/11.5?topic=management-performance-tuning-guidelines
- https://www.ibm.com/docs/en/db2/11.5?topic=functions-snap-get-db-v95

---

## Vertica — Monitoramento e Performance

### System Tables e Queries
```sql
-- ====================
-- QUERIES LENTAS E EXECUCAO
-- ====================

-- Queries em execucao agora
SELECT
    start_timestamp,
    now() - start_timestamp AS duration,
    user_name,
    LEFT(request, 200) AS query_preview,
    is_executing,
    request_type
FROM v_monitor.current_session
WHERE is_executing = TRUE
ORDER BY start_timestamp;

-- Top queries por tempo (historico)
SELECT
    user_name,
    LEFT(request, 200) AS query_preview,
    request_duration_ms / 1000 AS elapsed_s,
    memory_acquired_mb,
    rows_read,
    rows_returned
FROM v_monitor.query_requests
WHERE start_timestamp > now() - '1 hour'::interval
ORDER BY request_duration_ms DESC
LIMIT 20;

-- Resource pool usage
SELECT
    pool_name,
    running_query_count,
    waiting_query_count,
    memory_inuse_kb / 1024 AS memory_used_mb,
    memory_size_kb / 1024 AS memory_total_mb,
    ROUND(100.0 * memory_inuse_kb / NULLIF(memory_size_kb, 0), 1) AS memory_pct
FROM v_monitor.resource_pool_status
ORDER BY memory_used_mb DESC;

-- ====================
-- STORAGE E PROJECTIONS
-- ====================

-- Espaco por storage container
SELECT
    node_name,
    storage_path,
    SUM(disk_block_size_bytes) / 1e9 AS total_gb,
    SUM(disk_space_used_bytes) / 1e9 AS used_gb,
    SUM(disk_space_free_bytes) / 1e9 AS free_gb,
    ROUND(100.0 * SUM(disk_space_used_bytes) / SUM(disk_block_size_bytes), 1) AS used_pct
FROM v_monitor.disk_storage
GROUP BY node_name, storage_path
ORDER BY used_pct DESC;

-- Rosette Optimizer Storage (ROS)
SELECT
    projection_name,
    SUM(ros_count) AS ros_containers,
    SUM(ros_row_count) AS row_count,
    SUM(used_bytes) / 1e9 AS used_gb
FROM v_monitor.projection_storage
GROUP BY projection_name
ORDER BY used_gb DESC
LIMIT 20;

-- ====================
-- CLUSTER HEALTH
-- ====================

SELECT
    node_name,
    node_state,
    is_primary,
    catalog_path,
    data_path
FROM v_catalog.nodes;

SELECT GET_COMPLIANCE_STATUS();  -- K-Safety status
```

**Fontes Vertica Performance**:
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/AdministratorsGuide/Monitoring/
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/SQLReferenceManual/SystemTables/MONITOR/
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/AdministratorsGuide/ResourceManagement/

---

## Redis — Monitoramento e Performance

### Comandos e Metricas
```bash
# ====================
# INFO — visao geral completa
# ====================
redis-cli INFO all

# Secoes especificas:
redis-cli INFO server        # versao, PID, memoria do processo
redis-cli INFO clients       # conexoes, clientes
redis-cli INFO memory        # uso de memoria detalhado
redis-cli INFO persistence   # RDB e AOF status
redis-cli INFO stats         # hits, misses, expired keys
redis-cli INFO replication   # master/replica status
redis-cli INFO cpu           # uso de CPU
redis-cli INFO keyspace      # keys por banco/DB

# ====================
# PERFORMANCE CRITICA
# ====================

# Latencia em tempo real
redis-cli --latency           # minimo/maximo/media
redis-cli --latency-history   # historico por intervalo
redis-cli --latency-dist      # distribuicao percentil

# Hit/miss rate
redis-cli INFO stats | grep -E "keyspace_hits|keyspace_misses"
# Calcular: hit_rate = hits / (hits + misses) * 100

# Evictions
redis-cli INFO stats | grep evicted_keys
# Se > 0 e crescendo: maxmemory muito apertado

# Expired keys
redis-cli INFO stats | grep expired_keys

# Slow log
redis-cli SLOWLOG GET 20
redis-cli SLOWLOG LEN           # quantidade no slow log
redis-cli SLOWLOG RESET         # limpar slow log

# ====================
# MEMORIA
# ====================

redis-cli INFO memory | grep -E "used_memory_human|used_memory_peak_human|mem_fragmentation_ratio|maxmemory_human"
# mem_fragmentation_ratio > 1.5: fragmentacao alta (considerar restart)
# mem_fragmentation_ratio < 1.0: swap sendo usado (critico!)

# Analisar distribuicao de tipos/tamanhos de keys
redis-cli --memkeys --memkeys-samples 100 | head -20

# Memoria por tipo de dado
redis-cli OBJECT ENCODING key_name
redis-cli OBJECT IDLETIME key_name    # tempo sem acesso (segundos)

# ====================
# CLIENTES E CONEXOES
# ====================

redis-cli CLIENT LIST                  # lista todos os clientes
redis-cli CLIENT INFO                  # info do cliente atual
redis-cli INFO clients | grep connected_clients

# Matar cliente especifico
redis-cli CLIENT KILL ID <client-id>

# ====================
# REPLICACAO
# ====================

redis-cli INFO replication
# Verificar: master_link_status, master_last_io_seconds_ago, master_sync_in_progress
# Lag de replicacao:
redis-cli INFO replication | grep master_repl_offset  # no master
redis-cli INFO replication | grep slave_repl_offset   # na replica
```

### Otimizacoes de Performance Redis

**Tipos de dados eficientes**:
```bash
# Usar estruturas compactas para dados pequenos
# Hashes para objetos (mais eficiente que keys separadas)
redis-cli HSET user:1000 name "Gustavo" email "gustavo@email.com" role "admin"
# vs (ineficiente):
redis-cli SET user:1000:name "Gustavo"
redis-cli SET user:1000:email "gustavo@email.com"

# Verificar encoding (ziplist mais eficiente para hashes pequenos)
redis-cli OBJECT ENCODING user:1000

# Configurar limites de ziplist
# hash-max-listpack-entries 128
# hash-max-listpack-value 64
```

**Pipelining e MULTI/EXEC**:
```bash
# Pipeline: enviar multiplos comandos sem aguardar resposta individual
redis-cli --pipe << 'EOF'
SET key1 value1
SET key2 value2
SET key3 value3
EOF

# Transacoes MULTI/EXEC
redis-cli << 'EOF'
MULTI
INCR counter
SET status "active"
EXPIRE session:123 3600
EXEC
EOF
```

**Fontes Redis Performance**:
- https://redis.io/docs/latest/commands/info/
- https://redis.io/docs/latest/commands/slowlog/
- https://redis.io/docs/latest/commands/latency/
- https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/

---

## Ciclo de Performance Tuning

```
1. MONITOR: coletar metricas e baselines
       ↓
2. ANALYZE: identificar gargalos (slow queries, I/O, memoria, locks)
       ↓
3. TUNE: implementar mudanca (indice, parametro, rewrite de query)
       ↓
4. VALIDATE: medir melhora vs esperada
       ↓
5. DOCUMENT: registrar no runbook com antes/depois
       ↓
   REPEAT (processo continuo)
```

### Gargalos Comuns e Solucoes

| Sintoma | Causa Mais Provavel | Acao |
|---------|--------------------|----- |
| CPU alto | Queries sem indice, sorting | EXPLAIN ANALYZE, adicionar indices, rewrite |
| I/O alto | Buffer pool pequeno, full scans | Aumentar shared_buffers/buffer_pool, verificar indices |
| Memoria alta | Muitas conexoes, work_mem alto | Pooling, reduzir work_mem, verificar leaks |
| Lock waits | Transacoes longas, hot rows | Otimizar transacoes, MVCC, particionamento |
| Log/WAL crescendo | Transacoes nao commitadas, archive lento | Monitorar idle-in-transaction, verificar archive |
| Replication lag alto | I/O no standby, queries longas | I/O no standby, verificar replica_conflict |

---

## Benchmarks de Referencia (TPC)

| Benchmark | Tipo | O que Mede | Banco |
|-----------|------|------------|-------|
| **TPC-C** | OLTP | tpmC (transacoes/min) | PostgreSQL, MySQL, Oracle, SQL Server |
| **TPC-H** | DSS/Analytics | QphH (queries/hora) | Vertica, Db2, Oracle |
| **TPC-DS** | Data Warehouse | TotalQI (query complexity) | Vertica, Db2 BLU |
| **TPC-E** | OLTP financeiro | Transacoes/segundo | SQL Server, Oracle |
| **YCSB** | NoSQL/Cache | Throughput + latencia | Redis, MongoDB |

**Fontes benchmarks**:
- https://www.tpc.org/tpcc/
- https://www.tpc.org/tpch/
- https://github.com/brianfrankcooper/YCSB

---

## Planejamento de Capacidade

```
Capacidade atual + (taxa de crescimento mensal × 18 meses) = necessidade em 18 meses
```

**Alertas de capacidade**:
- **70%** uso de disco: planejar expansao
- **80%** uso de disco: aprovar e iniciar expansao
- **90%** uso de disco: critico — escalar imediatamente

**Fontes**:
- https://www.solarwinds.com/database-performance-analyzer/use-cases/database-performance-tuning
- https://www.splunk.com/en_us/blog/learn/database-monitoring.html
