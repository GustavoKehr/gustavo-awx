# 07 — Monitoramento e Performance

## Stack de Monitoramento Recomendada

```
Exporters/Agents  →  Prometheus  →  Grafana (visualizacao)
                                 →  Alertmanager → Slack/PagerDuty/Email

Logs        →  Filebeat/Fluentd  →  Logstash  →  Elasticsearch  →  Kibana
```

### Exporters por Banco

| Banco | Exporter Prometheus | Exporter Alternativo |
|-------|--------------------|-----------------------|
| PostgreSQL | `postgres_exporter` | `pg_stats_statements` |
| MySQL | `mysqld_exporter` | Percona PMM |
| SQL Server | `sql_exporter` | Telegraf |
| Oracle | `oracledb_exporter` | Oracle Enterprise Manager |
| Db2 | `db2_exporter` | IBM Data Server Manager |
| Vertica | `vertica_exporter` | Vertica Management Console |
| Redis | `redis_exporter` | Redis Insight |

---

## Estabelecimento de Baseline

Antes de configurar alertas, coletar baseline por **minimo 2-4 semanas** em producao:

1. **Coletar metricas** em horarios de pico e fora de pico
2. **Identificar padroes**: crescimento diario, semanal, sazonalidade
3. **Calcular percentis**: p50, p95, p99 para latencia e throughput
4. **Definir thresholds de alerta** baseados no baseline (nao em valores genericos)
5. **Evitar alert fatigue**: calibrar thresholds para minimizar falsos positivos

---

## KPIs Criticos por Categoria

### Disponibilidade
| KPI | Calculo | Warning | Critico |
|-----|---------|---------|---------|
| Uptime | `(uptime_total - downtime) / uptime_total * 100` | < 99.5% | < 99% |
| Connection Availability | Conectividade ao banco | Timeout > 5s | Falha de conexao |
| Replication Lag | Diferenca entre primario e standby | > 60s | > 300s |

### Performance de Queries
| KPI | Descricao | Warning | Critico |
|-----|-----------|---------|---------|
| Query Latency p95 | 95% das queries abaixo deste tempo | > 200ms | > 1000ms |
| Query Latency p99 | 99% das queries abaixo deste tempo | > 500ms | > 5000ms |
| Slow Queries/min | Queries acima do threshold | > 10/min | > 50/min |
| Long Running Transactions | Transacoes ativas > X min | > 5 min | > 30 min |
| Lock Waits | Threads aguardando lock | > 10 | > 50 |
| Deadlocks/hour | Deadlocks detectados | > 5/h | > 20/h |

### Recursos
| KPI | Descricao | Warning | Critico |
|-----|-----------|---------|---------|
| CPU Usage | Uso de CPU do processo do banco | > 70% | > 90% |
| Memory Usage | RAM usada pelo banco | > 80% | > 95% |
| Disk IOPS | Operacoes de I/O por segundo | > 70% do maximo | > 90% |
| Disk Usage (data) | Espaco de dados utilizado | > 70% | > 85% |
| Disk Usage (log) | Espaco de logs/WAL | > 60% | > 80% |
| Network I/O | Bytes enviados/recebidos | Baseline + 3σ | Baseline + 5σ |

### Conexoes
| KPI | Descricao | Warning | Critico |
|-----|-----------|---------|---------|
| Connection Count | Conexoes ativas | > 80% do max | > 90% do max |
| Connection Pool Utilization | Uso do pool (PgBouncer/ProxySQL) | > 70% | > 90% |
| Failed Connections/min | Falhas de autenticacao | > 5/min | > 20/min |
| Idle Connections | Conexoes abertas sem atividade | > 100 | > 300 |

### Cache
| KPI | Descricao | Warning | Critico |
|-----|-----------|---------|---------|
| Buffer Cache Hit Ratio | Paginas servidas do cache vs disco | < 95% | < 90% |
| Redis Cache Hit Rate | Keys encontradas vs misses | < 90% | < 80% |
| Key Eviction Rate (Redis) | Keys forcadas a sair por memoria | > 100/s | > 1000/s |

### Replicacao
| KPI | Descricao | Warning | Critico |
|-----|-----------|---------|---------|
| Replication Lag (segundos) | Atraso do standby em relacao ao primario | > 30s | > 300s |
| Replication Lag (bytes) | Bytes de redo nao aplicados | > 100MB | > 1GB |
| Binary Log Position Diff (MySQL) | Diferenca de posicao no binlog | > 1000 | > 100000 |

---

## Monitoramento Especifico por Banco

### PostgreSQL
```sql
-- Queries lentas ativas
SELECT pid, now() - query_start AS duration, query
FROM pg_stat_activity
WHERE state = 'active' AND now() - query_start > interval '1 second'
ORDER BY duration DESC;

-- Hits de cache por tabela
SELECT schemaname, tablename,
    heap_blks_hit::float / NULLIF(heap_blks_hit + heap_blks_read, 0) * 100 AS cache_hit_pct
FROM pg_statio_user_tables
ORDER BY cache_hit_pct ASC LIMIT 20;

-- Bloqueios ativos
SELECT pid, wait_event_type, wait_event, query
FROM pg_stat_activity
WHERE wait_event IS NOT NULL AND state = 'active';

-- Tamanho das tabelas
SELECT schemaname, tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- Replicacao
SELECT client_addr, state, sent_lsn - write_lsn AS write_lag,
    write_lsn - flush_lsn AS flush_lag,
    flush_lsn - replay_lsn AS replay_lag
FROM pg_stat_replication;
```

### MySQL
```sql
-- Queries lentas ativas
SHOW PROCESSLIST;
SELECT * FROM information_schema.PROCESSLIST
WHERE TIME > 1 ORDER BY TIME DESC;

-- Status do InnoDB
SHOW ENGINE INNODB STATUS\G

-- Buffer pool hit rate
SELECT (1 - (SELECT VARIABLE_VALUE FROM performance_schema.global_status
    WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') /
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status
    WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests')) * 100 AS hit_rate;

-- Status de replicacao
SHOW SLAVE STATUS\G  -- ou SHOW REPLICA STATUS\G no MySQL 8.0.22+
```

### SQL Server
```sql
-- Top queries por CPU
SELECT TOP 20
    qs.total_worker_time/qs.execution_count AS avg_cpu_time,
    qs.execution_count,
    SUBSTRING(st.text, (qs.statement_start_offset/2)+1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
          ELSE qs.statement_end_offset END - qs.statement_start_offset)/2)+1) AS query_text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY avg_cpu_time DESC;

-- Waits mais comuns
SELECT TOP 20 wait_type,
    waiting_tasks_count,
    wait_time_ms / 1000.0 AS wait_time_s,
    max_wait_time_ms / 1000.0 AS max_wait_s
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN ('SLEEP_TASK','WAITFOR','BROKER_TO_FLUSH',...)
ORDER BY wait_time_ms DESC;

-- Espaco em disco por banco
SELECT name,
    SUM(size * 8.0 / 1024) AS size_MB
FROM sys.master_files
GROUP BY name;

-- AlwaysOn lag
SELECT ag.name, ars.role_desc, adc.database_name,
    drs.secondary_lag_seconds
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states ars ON ag.group_id = ars.group_id
JOIN sys.availability_databases_cluster adc ON ag.group_id = adc.group_id
JOIN sys.dm_hadr_database_replica_states drs ON adc.group_id = drs.group_id;
```

### Oracle
```sql
-- Top SQL por elapsed time
SELECT sql_id, executions, elapsed_time/1000000 AS elapsed_s,
    elapsed_time/NULLIF(executions,0)/1000000 AS avg_elapsed_s,
    SUBSTR(sql_text, 1, 100) AS sql_preview
FROM v$sql
ORDER BY elapsed_time DESC
FETCH FIRST 20 ROWS ONLY;

-- Sessions aguardando
SELECT sid, wait_class, event, seconds_in_wait
FROM v$session
WHERE status = 'ACTIVE' AND wait_class != 'Idle'
ORDER BY seconds_in_wait DESC;

-- Data Guard status
SELECT name, value FROM v$dataguard_stats;
SELECT dest_name, status, archived_seq#, applied_seq# FROM v$archive_dest_status WHERE status != 'INACTIVE';

-- Espaco no tablespace
SELECT tablespace_name,
    ROUND(used_space * 8192 / 1024/1024, 2) AS used_mb,
    ROUND(tablespace_size * 8192 / 1024/1024, 2) AS total_mb,
    ROUND(used_percent, 2) AS used_pct
FROM dba_tablespace_usage_metrics
ORDER BY used_percent DESC;
```

### Redis
```bash
# Info completo
redis-cli INFO all

# Latencia em tempo real
redis-cli --latency

# Monitoramento de memoria
redis-cli INFO memory

# Comandos mais usados
redis-cli INFO commandstats | sort -t= -k2 -rn | head -20

# Clientes conectados
redis-cli CLIENT LIST

# Slow log
redis-cli SLOWLOG GET 20
redis-cli CONFIG SET slowlog-log-slower-than 10000  # 10ms em microsegundos
```

---

## Ciclo de Performance Tuning

```
1. MONITOR: coletar metricas e baselines
       ↓
2. ANALYZE: identificar gargalos (queries lentas, I/O, memoria, bloqueios)
       ↓
3. TUNE: implementar mudanca (indice, parametro, query rewrite)
       ↓
4. VALIDATE: medir melhora obtida vs esperada
       ↓
5. DOCUMENT: registrar mudanca e resultado no runbook
       ↓
   REPEAT (continuo)
```

### Causas Comuns de Performance Degradada

| Sintoma | Causa Mais Provavel | Acao |
|---------|--------------------|----- |
| CPU alto | Queries sem indice, sorting em memoria | Analisar EXPLAIN, adicionar indices |
| I/O alto | Buffer pool pequeno, full table scans | Aumentar buffer pool, verificar indices |
| Memoria alta | Conexoes demais, work_mem alto | Reduzir max_connections, usar pooling |
| Lock waits | Transacoes longas, hot spots | Otimizar transacoes, particionamento |
| Crescimento de log | Transacoes sem commit, long-running | Monitorar idle-in-transaction |

---

## Benchmarks de Referencia (TPC)

Para capacity planning e avaliacao de hardware:

| Benchmark | Tipo de Workload | O que Mede | Uso |
|-----------|------------------|------------|-----|
| **TPC-C** | OLTP transacional | Transacoes por minuto (tpmC) | Bancos transacionais (ERP, e-commerce) |
| **TPC-H** | Decision Support (DSS) | Queries por hora (QphH) | Data warehouses, analytics |
| **TPC-E** | OLTP financeiro | Transacoes por segundo | Sistemas financeiros |
| **TPC-DS** | Data warehouse complexo | Queries por hora | BI, Vertica, analytics |

**Usar TPC-C para**: PostgreSQL, MySQL, SQL Server, Oracle, Db2 em workloads OLTP.
**Usar TPC-H/TPC-DS para**: Vertica, Db2 BLU, SQL Server columnstore.

---

## Alertas Recomendados (Prometheus + Alertmanager)

```yaml
# Exemplo de rules para PostgreSQL
groups:
  - name: postgresql
    rules:
      - alert: PostgreSQLHighConnections
        expr: pg_stat_activity_count > (pg_settings_max_connections * 0.8)
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "PostgreSQL connections above 80% of max"

      - alert: PostgreSQLReplicationLag
        expr: pg_replication_lag > 300
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL replication lag > 5 minutes"

      - alert: PostgreSQLCacheHitRatioLow
        expr: >
          (sum(pg_stat_database_blks_hit) /
          (sum(pg_stat_database_blks_hit) + sum(pg_stat_database_blks_read))) < 0.95
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "PostgreSQL cache hit ratio below 95%"

      - alert: DiskSpaceWarning
        expr: (node_filesystem_avail_bytes{mountpoint="/var/lib/postgresql"} /
               node_filesystem_size_bytes{mountpoint="/var/lib/postgresql"}) < 0.30
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Database disk space below 30% free"
```

---

## Planejamento de Capacidade

### Dados a Coletar (ultimos 12 meses minimo)
- Taxa de crescimento de dados (GB/mes por banco e tabela)
- Crescimento de usuarios e transacoes
- Tendencias de CPU, memoria e I/O
- Picos de carga (horario, diario, mensal, anual)

### Projecao Simples
```
Capacidade atual + (taxa de crescimento mensal × 18 meses) = capacidade necessaria em 18 meses
```

Alertas de capacidade:
- **70%** de uso: planejar expansao
- **80%** de uso: aprovar e iniciar expansao
- **90%** de uso: critico — escalar imediatamente
