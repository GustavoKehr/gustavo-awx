# 03 — Configuracao por Banco de Dados

## PostgreSQL

### Parametros Criticos (postgresql.conf)

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `shared_buffers` | 25–40% da RAM total | Cache principal de paginas — parametro mais impactante |
| `effective_cache_size` | 50–75% da RAM total | Estimativa para o planner de queries |
| `work_mem` | 4MB–64MB por sort/hash | Muito alto + muitas conexoes = OOM; calcular: RAM_livre / (max_connections * 3) |
| `maintenance_work_mem` | 256MB–2GB | VACUUM, CREATE INDEX, REINDEX |
| `wal_level` | `replica` (minimo) | Habilita replicacao; `logical` para logical replication |
| `wal_buffers` | `64MB` | Buffer WAL antes de flush; `-1` = auto (1/32 de shared_buffers) |
| `max_wal_size` | `4GB`–`16GB` | Frequencia de checkpoints; maior = menos I/O de checkpoint |
| `min_wal_size` | `1GB` | Minimo de WAL mantido para reutilizacao |
| `checkpoint_completion_target` | `0.9` | Distribuir escrita ao longo do intervalo |
| `checkpoint_timeout` | `15min` | Intervalo maximo entre checkpoints |
| `max_connections` | 100–200 (usar PgBouncer) | Cada conexao usa ~5-10MB de RAM; pooler faz o controle real |
| `random_page_cost` | `1.1` (SSD) / `4.0` (HDD) | Orienta o planner sobre custo de I/O aleatório |
| `effective_io_concurrency` | `200` (SSD) / `2` (HDD) | Numero de I/O simultaneos esperados |
| `max_worker_processes` | `= numero de vCPUs` | Pool de workers de background |
| `max_parallel_workers_per_gather` | `= vCPUs / 2` | Paralelismo por query |
| `max_parallel_workers` | `= numero de vCPUs` | Total de workers de paralelismo |
| `log_min_duration_statement` | `1000` (1s) | Loga queries lentas automaticamente |
| `log_statement` | `ddl` (minimo) | Auditoria de DDL; `all` para auditoria completa |
| `log_connections` | `on` | Loga novas conexoes |
| `log_disconnections` | `on` | Loga desconexoes |
| `log_lock_waits` | `on` | Loga esperas por lock acima de `deadlock_timeout` |
| `archive_mode` | `on` (producao) | Habilita arquivamento de WAL |
| `archive_command` | Script de copia | Destino dos WALs arquivados |
| `password_encryption` | `scram-sha-256` | Hash seguro de senha (nao usar `md5`) |
| `ssl` | `on` | TLS obrigatorio em producao |
| `ssl_min_protocol_version` | `TLSv1.2` | Versao minima de TLS |
| `idle_in_transaction_session_timeout` | `300000` (5min) | Encerra sessoes idle-in-transaction |
| `statement_timeout` | `0` (desabilitado globalmente) | Definir por role, nao globalmente |
| `track_io_timing` | `on` | Habilita I/O timing nas views de stats |
| `track_functions` | `all` | Rastrear chamadas de funcoes |
| `autovacuum` | `on` | NUNCA desabilitar em producao |
| `autovacuum_vacuum_scale_factor` | `0.05` | Vacuum apos 5% de mudancas (padrao 20%) |
| `autovacuum_analyze_scale_factor` | `0.02` | Analyze apos 2% de mudancas |

### Autenticacao — pg_hba.conf

```
# Formato: tipo  banco    usuario   endereco             metodo
local   all      postgres                                peer
local   all      all                                     scram-sha-256
host    all      all      127.0.0.1/32                   scram-sha-256
host    all      all      ::1/128                        scram-sha-256
host    all      all      10.0.0.0/8                     scram-sha-256
hostssl all      all      0.0.0.0/0                      scram-sha-256
# Replicacao
host    replication replicator 10.0.0.11/32              scram-sha-256
# NUNCA usar: trust em hosts remotos
# EVITAR: md5 (vulneravel a brute force offline)
```

### Configuracoes de Performance para PGTune

Para gerar configuracao automatica baseada em hardware, usar PGTune:
- https://pgtune.leopard.in.ua/

Parametros de entrada:
- DB Version, OS Type, DB Type (OLTP/DW/Mixed/Desktop)
- Total Memory, CPUs, Connections, Storage Type

### Checklist Pos-Instalacao PostgreSQL
- [ ] `--data-checksums` habilitado na inicializacao
- [ ] Senha do usuario `postgres` alterada
- [ ] Conexao ao `template1` revogada do PUBLIC
- [ ] `REVOKE CREATE ON SCHEMA public FROM PUBLIC;`
- [ ] SSL habilitado com certificado valido
- [ ] `scram-sha-256` em todo o pg_hba.conf
- [ ] Autovacuum configurado e monitorado
- [ ] Logging de slow queries habilitado
- [ ] archive_mode habilitado com archive_command testado
- [ ] `idle_in_transaction_session_timeout` configurado

**Fontes**:
- https://www.postgresql.org/docs/current/runtime-config.html
- https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server
- https://pgtune.leopard.in.ua/
- https://www.enterprisedb.com/blog/how-to-secure-postgresql-security-hardening-best-practices-checklist-tips-encryption-authentication-vulnerabilities
- https://www.percona.com/blog/postgresql-database-security-best-practices/

---

## MySQL

### Parametros Criticos (my.cnf)

**[mysqld] — InnoDB Storage Engine**

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `innodb_buffer_pool_size` | 70–80% da RAM | Cache InnoDB — parametro mais critico |
| `innodb_buffer_pool_instances` | 8 (ou RAM/1GB) | Reduz contencao no buffer pool |
| `innodb_buffer_pool_chunk_size` | `innodb_buffer_pool_size / instances` | Alinhar com buffer_pool_instances |
| `innodb_log_file_size` | 1GB–4GB | Redo log; maior = menos checkpoints |
| `innodb_log_files_in_group` | `2` | Numero de redo log files |
| `innodb_flush_log_at_trx_commit` | `1` (ACID) / `2` (performance+risco minimo) | 1 = fsync por transacao; 2 = fsync por segundo |
| `innodb_flush_method` | `O_DIRECT` (Linux) | Evita double-buffering com page cache do SO |
| `innodb_file_per_table` | `ON` | Uma tablespace por tabela; facilita gerenciamento |
| `innodb_io_capacity` | `2000` (SSD) / `200` (HDD) | I/O budget para tarefas de background |
| `innodb_io_capacity_max` | `4000` (SSD) / `400` (HDD) | I/O budget maximo em flushes agressivos |
| `innodb_read_io_threads` | `8` | Threads de I/O de leitura |
| `innodb_write_io_threads` | `8` | Threads de I/O de escrita |
| `innodb_thread_concurrency` | `0` (auto) | Controle de concorrencia do InnoDB |
| `innodb_autoinc_lock_mode` | `2` (interleaved) | Melhor performance para bulk inserts |
| `innodb_stats_on_metadata` | `OFF` | Evita recalculo de stats em SHOW TABLE |
| `innodb_adaptive_hash_index` | `ON` | Hash index adaptativo para workloads de ponto |

**[mysqld] — Conexoes e Cache**

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `max_connections` | 500–2000 + ProxySQL | Cada conexao usa ~1MB de RAM |
| `thread_cache_size` | `100` | Reutilizacao de threads |
| `table_open_cache` | `4000` | Cache de tabelas abertas |
| `table_definition_cache` | `2000` | Cache de definicoes de tabelas |
| `open_files_limit` | `65535` | Limite de arquivos abertos |

**[mysqld] — Replicacao e Binlog**

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `log_bin` | `mysql-bin` | Habilita binary log (obrigatorio para replicacao+PITR) |
| `binlog_format` | `ROW` | Replicacao segura em todos os cenarios |
| `binlog_row_image` | `FULL` | Imagem completa da linha no binlog |
| `gtid_mode` | `ON` | GTID-based replication (obrigatorio para HA moderno) |
| `enforce_gtid_consistency` | `ON` | Forcado quando GTID habilitado |
| `log_replica_updates` | `ON` | Replica propaga binlog (para cascading) |
| `relay_log_recovery` | `ON` | Recuperacao automatica de relay log |
| `binlog_expire_logs_seconds` | `604800` (7 dias) | Retencao de binlogs |
| `sync_binlog` | `1` | fsync por transacao (ACID em binlog) |
| `master_info_repository` | `TABLE` | Salvar info em tabela (nao arquivo) |
| `relay_log_info_repository` | `TABLE` | Salvar info de relay log em tabela |

**[mysqld] — Logging e Auditoria**

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `slow_query_log` | `ON` | Log de queries lentas |
| `long_query_time` | `1` | Threshold em segundos |
| `log_queries_not_using_indexes` | `ON` | Loga queries sem indice |
| `slow_query_log_file` | `/var/log/mysql/slow.log` | Destino do slow log |
| `general_log` | `OFF` (producao) | Habilitar temporariamente para troubleshooting |
| `log_error` | `/var/log/mysql/error.log` | Log de erros |

**[mysqld] — Seguranca**

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `sql_mode` | `STRICT_TRANS_TABLES,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION` | Modo estrito |
| `secure_file_priv` | `NULL` | Desabilitar LOAD/SELECT INTO FILE |
| `local_infile` | `0` | Desabilitar LOAD DATA LOCAL INFILE |
| `skip_symbolic_links` | `ON` | Prevenir ataques via symlinks |
| `require_secure_transport` | `ON` | Exigir SSL/TLS para conexoes remotas |
| `default_authentication_plugin` | `caching_sha2_password` | Autenticacao moderna (MySQL 8) |

### Checklist Pos-Instalacao MySQL
- [ ] `mysql_secure_installation` executado
- [ ] Banco `test` removido
- [ ] Usuarios anonimos removidos
- [ ] `root` nao pode logar remotamente
- [ ] `require_secure_transport=ON`
- [ ] `validate_password` plugin habilitado
- [ ] Slow query log habilitado
- [ ] GTID habilitado
- [ ] `sync_binlog=1` e `innodb_flush_log_at_trx_commit=1`

**Fontes**:
- https://dev.mysql.com/doc/refman/8.0/en/server-system-variables.html
- https://dev.mysql.com/doc/refman/8.0/en/innodb-parameters.html
- https://dev.mysql.com/doc/mysql-secure-deployment-guide/8.0/en/
- https://www.percona.com/blog/mysql-server-parameters/
- https://aws.amazon.com/blogs/database/best-practices-for-configuring-parameters-for-amazon-rds-for-mysql-part-1-parameters-related-to-performance/
- https://www.percona.com/blog/mysql-database-security-best-practices/

---

## SQL Server

### Configuracoes de Instancia (sp_configure)

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `max server memory (MB)` | 80–85% da RAM | Evitar OOM do SO |
| `min server memory (MB)` | 10% da RAM | Evitar trashing de memoria |
| `max degree of parallelism` | vCPUs/2 (max 8) | MAXDOP; 1 por instancia em servidores compartilhados |
| `cost threshold for parallelism` | `50` | Custo minimo para usar paralelismo |
| `optimize for ad hoc workloads` | `1` | Reduz cache de single-use plans |
| `max worker threads` | `0` (auto) | SQL Server calcula baseado em CPUs |
| `remote query timeout (s)` | `600` | Timeout para linked server queries |
| `fill factor (%)` | `80`–`90` | Espaco livre em paginas de indice |
| `index create memory (KB)` | `0` (auto) | Memoria para criacao de indices |
| `min memory per query (KB)` | `1024` | Minimo por query que solicita memoria |
| `lightweight pooling` | `0` | Nao usar fiber mode |

### Configuracoes por Banco de Dados

| Opcao | Valor Producao | Justificativa |
|-------|----------------|---------------|
| Recovery Model | `FULL` | Habilita PITR com log backups |
| Auto-Close | `OFF` | Overhead de abrir/fechar banco |
| Auto-Shrink | `OFF` | Causa fragmentacao severa |
| Auto-Create Statistics | `ON` | Otimizador precisa de stats atualizadas |
| Auto-Update Statistics | `ON` | Atualizacao automatica |
| Auto-Update Statistics Async | `ON` | Nao bloquear queries durante update de stats |
| Query Store | `ON` | Captura historico de planos de execucao |
| Compatibility Level | Versao atual | Usar mais recente suportado pela app |
| Page Verify | `CHECKSUM` | Detectar corrupcao de paginas |
| Delayed Durability | `DISABLED` | ACID completo (habilitar somente em workloads aceitos) |
| Is Read Committed Snapshot | `ON` | RCSI: leituras nao bloqueiam escritas |
| Allow Snapshot Isolation | `ON` | Isolation level sem bloqueio de leitura |

### Configuracao tempdb (CRITICO)
```sql
-- 1 arquivo por nucleo fisico, maximo 8
-- Todos os arquivos com MESMO tamanho e crescimento
-- Disco SSD local (D: no Azure, NVMe no AWS)

USE [master];

-- Remover arquivos extras se existirem
ALTER DATABASE [tempdb] REMOVE FILE [temp2]; -- se necessario

-- Configurar arquivos existentes
ALTER DATABASE [tempdb]
    MODIFY FILE (NAME = N'tempdev', FILENAME = N'D:\tempdb\tempdb.mdf',
                 SIZE = 8192MB, FILEGROWTH = 1024MB);
ALTER DATABASE [tempdb]
    MODIFY FILE (NAME = N'templog', FILENAME = N'D:\tempdb\templog.ldf',
                 SIZE = 2048MB, FILEGROWTH = 512MB);

-- Adicionar arquivos adicionais (1 por nucleo)
ALTER DATABASE [tempdb]
    ADD FILE (NAME = N'tempdev2', FILENAME = N'D:\tempdb\tempdb2.ndf',
              SIZE = 8192MB, FILEGROWTH = 1024MB);
```

### Query Store — Configuracao Recomendada
```sql
ALTER DATABASE [MeuBanco] SET QUERY_STORE = ON;
ALTER DATABASE [MeuBanco] SET QUERY_STORE (
    OPERATION_MODE = READ_WRITE,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 90),
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    INTERVAL_LENGTH_MINUTES = 60,
    MAX_STORAGE_SIZE_MB = 2048,
    QUERY_CAPTURE_MODE = AUTO,
    SIZE_BASED_CLEANUP_MODE = AUTO,
    MAX_PLANS_PER_QUERY = 200
);
```

### Checklist Pos-Instalacao SQL Server
- [ ] `xp_cmdshell` desabilitado
- [ ] CLR desabilitado (se nao usado)
- [ ] SQL Browser service desabilitado (se nao necessario)
- [ ] Conexoes criptografadas forcadas (`Force Encryption = Yes`)
- [ ] Auditoria de login habilitada (sucesso e falha)
- [ ] `sa` desabilitado ou renomeado
- [ ] Windows Authentication preferida ao inves de SQL auth
- [ ] TDE habilitado em bancos com dados sensiveis
- [ ] RCSI habilitado para reducao de bloqueios
- [ ] tempdb em SSD local com arquivos multiplos

**Fontes**:
- https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/server-configuration-options-sql-server
- https://learn.microsoft.com/en-us/sql/relational-databases/databases/database-properties-options-page
- https://learn.microsoft.com/en-us/sql/relational-databases/performance/query-store-best-practices
- https://docs.aws.amazon.com/whitepapers/latest/best-practices-for-deploying-microsoft-sql-server/
- https://learn.microsoft.com/en-us/azure/azure-sql/virtual-machines/windows/performance-guidelines-best-practices-checklist
- https://cloud.google.com/compute/docs/instances/sql-server/best-practices

---

## Oracle Database

### Parametros de Inicializacao (SPFILE) Criticos

| Parametro | Valor / Recomendacao | Justificativa |
|-----------|---------------------|---------------|
| `DB_UNIQUE_NAME` | Nome unico da instancia | Obrigatorio para Data Guard e GoldenGate |
| `ARCHIVELOG mode` | `ALTER DATABASE ARCHIVELOG` | Obrigatorio para backup online e PITR |
| `FORCE LOGGING` | `ALTER DATABASE FORCE LOGGING` | Garante todos os dados no redo |
| `SGA_TARGET` | 40–70% da RAM (com AMM) | Gerenciamento automatico do SGA |
| `PGA_AGGREGATE_TARGET` | 20% da RAM | Pool de memoria PGA |
| `SGA_MAX_SIZE` | Igual ou maior que SGA_TARGET | Maximo do SGA |
| `MEMORY_MAX_TARGET` | 0 (desabilitar AMM em Linux) | AMM causa problemas com hugepages no Linux |
| `DB_BLOCK_SIZE` | `8192` (8K) — padrao | Tamanho de bloco; definir na criacao (nao mudavel) |
| `DB_RECOVERY_FILE_DEST` | Path ASM ou filesystem | Flash Recovery Area |
| `DB_RECOVERY_FILE_DEST_SIZE` | Minimo 3x tamanho diario de redo | Espaco para FRA |
| `LOG_BUFFER` | `32M`–`128M` | Buffer de redo em memoria |
| `LOG_ARCHIVE_DEST_1` | `LOCATION=USE_DB_RECOVERY_FILE_DEST` | Archive destino local |
| `LOG_ARCHIVE_DEST_2` | Destino standby (Data Guard) | Replicacao sincrona/assincrona |
| `LOG_ARCHIVE_FORMAT` | `%t_%s_%r.arc` | Formato do nome do archive log |
| `DG_BROKER_START` | `TRUE` | Habilita Data Guard Broker |
| `FAL_SERVER` | Nome/TNS do standby | Fast Archive Log server (gap resolution) |
| `FAL_CLIENT` | Nome/TNS do primario | Fast Archive Log client |
| `AUDIT_TRAIL` | `DB,EXTENDED` | Auditoria completa em tabela |
| `AUDIT_SYS_OPERATIONS` | `TRUE` | Auditar operacoes de SYSDBA |
| `ENABLE_PLUGGABLE_DATABASE` | `FALSE` (non-CDB) / `TRUE` (CDB) | Para bancos standalone nao-container |
| `UNDO_TABLESPACE` | `UNDOTBS1` | Tablespace de UNDO dedicada |
| `UNDO_RETENTION` | `900` (15 min minimo) | Retencao de UNDO para flashback/erros |
| `PROCESSES` | `500`–`2000` | Maximo de processos OS (inclui connections + background) |
| `SESSIONS` | `PROCESSES * 1.5` | Maximo de sessoes |
| `OPEN_CURSORS` | `300`–`1000` | Cursores abertos por sessao |
| `CURSOR_SHARING` | `EXACT` | `FORCE` apenas se muitas SQL com literais |
| `STATISTICS_LEVEL` | `TYPICAL` | Coleta de estatisticas de performance |
| `AWR_SNAPSHOT_RETENTION` | `30 dias` | Retencao de snapshots AWR |

### Configuracao de Redo Logs
```sql
-- Minimo 3 grupos, 2 membros por grupo, em discos diferentes
-- Tamanho baseado no volume de redo: objetivo de switch a cada 20-30 min

-- Verificar tamanho atual dos redo logs
SELECT GROUP#, BYTES/1024/1024 AS MB, STATUS FROM V$LOG;

-- Adicionar grupos maiores
ALTER DATABASE ADD LOGFILE GROUP 4
    ('/u02/oradata/orcl/redo04a.rdo', '/u03/fra/orcl/redo04b.rdo') SIZE 1G;

-- Apos verificar que grupo antigo esta INACTIVE, remover
ALTER DATABASE DROP LOGFILE GROUP 1;

-- Standby Redo Logs (N+1 onde N = numero de grupos de redo)
ALTER DATABASE ADD STANDBY LOGFILE GROUP 11
    ('/u02/oradata/orcl/srl11a.rdo', '/u03/fra/orcl/srl11b.rdo') SIZE 1G;
```

### Password Profile Oracle
```sql
-- Criar profile de senha forte
CREATE PROFILE prod_profile LIMIT
    PASSWORD_LIFE_TIME        60          -- expira em 60 dias
    PASSWORD_REUSE_TIME       365         -- nao reusar por 1 ano
    PASSWORD_REUSE_MAX        5           -- nao reusar 5 ultimas senhas
    PASSWORD_VERIFY_FUNCTION  ora12c_strong_verify_function
    FAILED_LOGIN_ATTEMPTS     5           -- lock apos 5 falhas
    PASSWORD_LOCK_TIME        1/24        -- lock por 1 hora
    PASSWORD_GRACE_TIME       7           -- 7 dias de graca
    SESSIONS_PER_USER         UNLIMITED
    CPU_PER_SESSION           UNLIMITED
    IDLE_TIME                 60;         -- desconecta apos 60 min idle

-- Aplicar a todos os usuarios nao-SYS
ALTER USER appuser PROFILE prod_profile;
```

### Checklist Pos-Instalacao Oracle
- [ ] ARCHIVELOG mode habilitado
- [ ] FORCE LOGGING habilitado
- [ ] FRA configurada com espaco suficiente
- [ ] Redo logs com tamanho adequado (3+ grupos, 2+ membros)
- [ ] Standby redo logs criados
- [ ] Audit trail habilitado (DB,EXTENDED)
- [ ] Profile de senha forte aplicado a todos os usuarios
- [ ] `DBA_USERS_WITH_DEFPWD` = vazio
- [ ] Oracle Critical Patch Update (CPU) aplicado
- [ ] Oracle Wallet configurado para autenticacao externa em scripts

**Fontes**:
- https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/initialization-parameters.html
- https://docs.oracle.com/en/database/oracle/oracle-database/19/admin/managing-the-redo-log.html
- https://docs.oracle.com/en/database/oracle/oracle-database/19/dbseg/keeping-your-oracle-database-secure.html
- https://docs.oracle.com/en/database/oracle/oracle-database/19/haovw/high-availability-overview-and-best-practices.pdf
- https://docs.oracle.com/cd/F19136_01/haovw/high-availability-overview-and-best-practices.pdf

---

## IBM Db2

### Parametros de Gerenciador de Banco (DBM CFG)

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `SVCENAME` | `50000` | Porta TCP do servico Db2 |
| `SHEAPTHRES_SHR` | `AUTOMATIC` | Memoria de sort compartilhada |
| `INTRA_PARALLEL` | `YES` | Habilitar paralelismo intra-query |
| `NUM_POOLAGENTS` | `100`–`500` | Pool de agentes |
| `MAXAGENTS` | `AUTOMATIC` | Maximo de agentes |
| `JAVA_HEAP_SZ` | `2048` | Heap Java (se usar procedures Java) |
| `DIAGLEVEL` | `2` | Nivel de diagnostico (3 em troubleshooting) |
| `NOTIFYLEVEL` | `3` | Nivel de notificacao de alertas |
| `AUTHENTICATION` | `SERVER_ENCRYPT` | Criptografar senhas na rede |
| `SYSADM_GROUP` | `db2iadm1` | Grupo sysadm — privilegio mais alto |
| `SYSCTRL_GROUP` | `db2ctladm1` | Grupo sysctrl |
| `SYSMAINT_GROUP` | `db2maint1` | Grupo sysmaint |

### Parametros de Banco de Dados (DB CFG)

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `BUFFPAGE` | `AUTOMATIC` | Buffer pool automatico (ou definir buffer pools separados) |
| `LOGFILSIZ` | `65536` (512MB pages de 8K) | Tamanho de cada redo log file |
| `LOGPRIMARY` | `20` | Numero de redo log files primarios |
| `LOGSECOND` | `20` | Redo log files secundarios (overflow) |
| `LOGARCHMETH1` | `DISK:/archive/db2/<dbname>` | Metodo de archive logging |
| `LOGARCHOPT1` | `` (vazio) | Opcoes de archive |
| `FAILARCHPATH` | `/archive/db2/<dbname>_fail` | Path alternativo de archive em falha |
| `NUMARCHRETRY` | `5` | Tentativas de archive antes de fail |
| `ARCHRETRYDELAY` | `20` | Delay entre tentativas (segundos) |
| `LOGRETAIN` | `RECOVERY` | Reter logs para recuperacao |
| `USEREXIT` | `NO` (usar LOGARCHMETH1) | Metodo legado |
| `SOFTMAX` | `300` | Intervalo de soft checkpoint (100 = default) |
| `NUM_IOSERVERS` | `8` | I/O servers asincronos |
| `NUM_IOCLEANERS` | `8` | Page cleaners |
| `LOCKLIST` | `AUTOMATIC` | Lista de locks |
| `MAXLOCKS` | `80` | Porcentagem maxima de locklist por aplicacao |
| `STMTHEAP` | `AUTOMATIC` | Memoria por statement |
| `APPLHEAPSZ` | `AUTOMATIC` | Heap por aplicacao |
| `SORTHEAP` | `AUTOMATIC` | Memoria de sort |
| `DBHEAP` | `AUTOMATIC` | Heap do banco de dados |
| `CATALOGCACHE_SZ` | `AUTOMATIC` | Cache do catalogo |
| `PCKCACHESZ` | `AUTOMATIC` | Cache de packages compilados |
| `AUTO_REORG` | `ON` | Reorganizacao automatica de tabelas |
| `AUTO_RUNSTATS` | `ON` | Estatisticas automaticas |
| `AUTO_STATS_VIEWS` | `ON` | Estatisticas de views automaticas |
| `AUTO_SAMPLING` | `ON` | Amostragem automatica para stats |
| `HADR_LOCAL_HOST` | IP do servidor local | HADR: host local |
| `HADR_REMOTE_HOST` | IP do servidor standby | HADR: host remoto |
| `HADR_SYNCMODE` | `NEARSYNC` | Modo HADR (SYNC/NEARSYNC/ASYNC) |

### Buffer Pools — Configuracao Manual (alternativa ao AUTOMATIC)
```sql
-- Criar buffer pools separados por tipo de workload
CREATE BUFFERPOOL OLTPBP IMMEDIATE SIZE 131072 AUTOMATIC PAGESIZE 8K;
-- 131072 pages * 8K = 1GB

CREATE BUFFERPOOL DWHBP IMMEDIATE SIZE 524288 AUTOMATIC PAGESIZE 32K;
-- Para tabelas com pagesize 32K (analytics)

-- Associar tablespaces ao buffer pool
CREATE LARGE TABLESPACE OLTPDATA
    PAGESIZE 8K MANAGED BY AUTOMATIC STORAGE
    BUFFERPOOL OLTPBP;
```

### Checklist Pos-Instalacao Db2
- [ ] Archive logging habilitado (`LOGARCHMETH1`)
- [ ] `AUTO_RUNSTATS`, `AUTO_REORG` habilitados
- [ ] Buffer pools dimensionados adequadamente
- [ ] `AUTHENTICATION SERVER_ENCRYPT`
- [ ] Grupos de privilegio (SYSADM, SYSCTRL, SYSMAINT) configurados
- [ ] Auditoria habilitada com `db2audit`
- [ ] Fix packs atuais aplicados
- [ ] HADR configurado (se HA for requisito)

**Fontes**:
- https://www.ibm.com/docs/en/db2/11.5?topic=reference-database-manager-configuration-parameters
- https://www.ibm.com/docs/en/db2/11.5?topic=reference-database-configuration-parameters
- https://www.ibm.com/docs/en/db2/11.5?topic=tuning-performance-guidelines
- https://www.ibm.com/support/pages/db2-backup-and-restore-basics
- https://community.ibm.com/community/user/blogs/youssef-sbai-idrissi1/2023/07/27/how-to-set-up-security-for-ibm-db2-best-practices

---

## Vertica

### Parametros de Configuracao do Banco

| Parametro | Valor Recomendado | Como Configurar |
|-----------|-------------------|----------------|
| `MaxClientSessions` | `500`–`2000` | `ALTER DATABASE ... SET MaxClientSessions` |
| `EnableSSL` | `1` | `ALTER DATABASE ... SET EnableSSL = 1` |
| `EnableTLSClientAuth` | `1` | Autenticacao mutua TLS |
| `RequireSSL` | `1` | Exigir SSL/TLS |
| `KSafety` | `1` (3 nos) ou `2` (5+ nos) | Definido na criacao do banco |
| `ResourcePoolMode` | Configurar pools por workload | `CREATE RESOURCE POOL` |
| `MaxMemorySize` | % da RAM | Por resource pool |
| `MaxConcurrency` | Numero de queries simultâneas | Por resource pool |
| `QueryTimeout` | `3600` (1 hora) para analytics | Por session/resource pool |

### Resource Pools
```sql
-- Pool para OLAP (analytics)
CREATE RESOURCE POOL analytics_pool
    MEMORYSIZE '60%'
    MAXMEMORYSIZE '75%'
    MAXCONCURRENCY 20
    QUEUETIMEOUT 300
    EXECUTIONPARALLELISM AUTO;

-- Pool para ETL
CREATE RESOURCE POOL etl_pool
    MEMORYSIZE '25%'
    MAXMEMORYSIZE '35%'
    MAXCONCURRENCY 5
    QUEUETIMEOUT 0;

-- Pool para usuarios normais
CREATE RESOURCE POOL user_pool
    MEMORYSIZE '10%'
    MAXMEMORYSIZE '20%'
    MAXCONCURRENCY 50
    RUNTIMEPRIORITY 50;

-- Associar usuario ao pool
ALTER USER analytics_user RESOURCE POOL analytics_pool;
```

### Configuracao de Storage (Vertica Eon Mode vs Enterprise)

**Enterprise Mode** (armazenamento local):
```bash
# admintools
/opt/vertica/bin/admintools -t create_db \
    --database MyDB \
    --catalog_path /vertica/catalog \
    --data_path /vertica/data \
    --hosts 10.0.0.10,10.0.0.11,10.0.0.12 \
    --shard-count 6
```

**Eon Mode** (armazenamento S3):
```bash
/opt/vertica/bin/admintools -t create_db \
    --database MyDB \
    --communal-storage-location s3://my-vertica-bucket/mydb \
    --depot-path /vertica/depot \
    --hosts 10.0.0.10,10.0.0.11,10.0.0.12 \
    --shard-count 6
```

### Projections — Design e Otimizacao
```sql
-- Verificar projections existentes
SELECT projection_name, anchor_table_name, is_up_to_date, is_segmented
FROM PROJECTIONS ORDER BY anchor_table_name;

-- Verificar projections desatualizadas
SELECT projection_name, anchor_table_name
FROM PROJECTIONS WHERE IS_UP_TO_DATE = FALSE;

-- Usar Database Designer para otimizar projections
SELECT DESIGNER_CREATE_PROJECTION(
    'myschema.fact_sales',
    'USING CLUSTERING KEY (sale_date) SEGMENTED BY HASH(customer_id) ALL NODES'
);

-- Verificar uso de projections
SELECT projection_name, ros_count, ros_row_count, wos_row_count
FROM PROJECTION_STORAGE ORDER BY ros_row_count DESC;
```

### Checklist Pos-Instalacao Vertica
- [ ] K-Safety verificado: `SELECT GET_COMPLIANCE_STATUS()`
- [ ] TLS habilitado e configurado
- [ ] Roles criadas (nao usar dbadmin em aplicacoes)
- [ ] Resource pools configurados por tipo de workload
- [ ] Backup configurado com `vbr.py`
- [ ] Monitoramento via MC (Management Console) ou Prometheus exporter
- [ ] Indices de projecao validados com Database Designer
- [ ] `AUTO_PROJECTION` avaliado (pode criar projections automaticamente)

**Fontes**:
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/AdministratorsGuide/ConfiguringTheDB/
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/AdministratorsGuide/ResourceManagement/
- https://www.vertica.com/kb/Best-Practices-for-Creating-Access-Policies-on-Vertica/
- https://www.vertica.com/kb/Recommendations-for-Sizing-Vertica-Nodes-and-Clusters/
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/AdministratorsGuide/BackingUpAndRestoring/

---

## Redis

### Parametros Criticos (redis.conf)

**Memoria**

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `maxmemory` | 80% da RAM disponivel | Limite de memoria — obrigatorio em producao |
| `maxmemory-policy` | `allkeys-lru` (cache puro) / `volatile-lru` (misto) / `noeviction` (persistencia) | Politica de eviction |
| `maxmemory-samples` | `10` (LRU aproximado, mais preciso) | Amostras para algoritmo LRU |
| `active-expire-enabled` | `yes` | Expirar keys ativamente em background |
| `lazyfree-lazy-eviction` | `yes` | Evictions assincronas (nao bloqueia) |
| `lazyfree-lazy-expire` | `yes` | Expiracoes assincronas |

**Persistencia**

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `save` | `900 1 300 10 60 10000` (cache) / `""` (cache puro) | Configuracao RDB snapshot |
| `stop-writes-on-bgsave-error` | `yes` | Parar escritas se snapshot falhar |
| `rdbcompression` | `yes` | Comprimir arquivo RDB |
| `rdbchecksum` | `yes` | Checksum no arquivo RDB |
| `appendonly` | `yes` (durabilidade) / `no` (cache) | AOF: log de operacoes |
| `appendfilename` | `appendonly.aof` | Nome do arquivo AOF |
| `appendfsync` | `everysec` | fsync a cada segundo (balance) |
| `no-appendfsync-on-rewrite` | `no` | Fazer fsync durante rewrite do AOF |
| `auto-aof-rewrite-percentage` | `100` | Reescrever AOF quando dobrar de tamanho |
| `auto-aof-rewrite-min-size` | `64mb` | Tamanho minimo antes de rewrite |
| `aof-use-rdb-preamble` | `yes` | Hibrido RDB+AOF: mais rapido no load |

**Rede e Seguranca**

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `bind` | `127.0.0.1 10.0.0.10` | Nunca bind em `0.0.0.0` sem firewall |
| `protected-mode` | `yes` | Rejeitar conexoes externas sem auth |
| `port` | `6379` (ou customizado) | Porta sem TLS (desabilitar se usar TLS) |
| `tls-port` | `6380` | Porta TLS |
| `tls-cert-file` | `/etc/redis/tls/redis.crt` | Certificado do servidor |
| `tls-key-file` | `/etc/redis/tls/redis.key` | Chave privada |
| `tls-ca-cert-file` | `/etc/redis/tls/ca.crt` | CA para verificar clientes |
| `tls-auth-clients` | `yes` | Exigir certificado de cliente |
| `tls-protocols` | `TLSv1.2 TLSv1.3` | Versoes TLS permitidas |
| `timeout` | `300` | Desconectar cliente idle apos 300s |
| `tcp-keepalive` | `300` | TCP keepalive para detectar conexoes mortas |
| `maxclients` | `1000`–`10000` | Maximos de clientes conectados |

**Replicacao**

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `replicaof` | `<master_ip> <port>` | Configurar replica |
| `replica-serve-stale-data` | `yes` | Servir dados desatualizados enquanto sincroniza |
| `replica-read-only` | `yes` | Replicas somente leitura |
| `repl-diskless-sync` | `yes` | Sync sem criar arquivo RDB em disco |
| `repl-diskless-sync-delay` | `5` | Aguardar 5s para mais replicas conectarem |
| `repl-backlog-size` | `100mb` | Buffer de replicacao (permite reconexao parcial) |
| `repl-backlog-ttl` | `3600` | Tempo de retencao do backlog |
| `min-replicas-to-write` | `1` | Minimo de replicas para aceitar escrita |
| `min-replicas-max-lag` | `10` | Lag maximo das replicas |

**Performance**

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `hz` | `20` (padrao 10) | Frequencia de tarefas de background |
| `dynamic-hz` | `yes` | Ajustar hz dinamicamente com carga |
| `aof-rewrite-incremental-fsync` | `yes` | fsync incremental durante rewrite |
| `rdb-save-incremental-fsync` | `yes` | fsync incremental durante save |
| `latency-monitor-threshold` | `100` | Monitorar operacoes lentas (ms) |
| `slowlog-log-slower-than` | `10000` | Slow log: operacoes acima de 10ms (microsegundos) |
| `slowlog-max-len` | `1000` | Tamanho maximo do slow log |

### ACLs — Redis 6+
```
# redis.conf
# Desabilitar usuario default
user default off nopass nokeys nocommands

# Usuario de aplicacao
user appuser on >SenhaApp123! ~cache:* ~session:* +GET +SET +DEL +EXPIRE +TTL +KEYS +MGET

# Usuario somente leitura
user readonly on >SenhaRO456! ~* +@read

# Usuario de backup
user backup on >SenhaBkp789! ~* +BGSAVE +DEBUG +BGREWRITEAOF +LASTSAVE

# Administrador
user admin on >SenhaAdmin000! ~* &* +@all
```

### Topologia de Sentinel — redis.conf + sentinel.conf
```
# Cada servidor Sentinel: sentinel.conf
sentinel monitor mymaster 10.0.0.10 6380 2
sentinel auth-pass mymaster SenhaMaster123!
sentinel sentinel-user sentinel_user
sentinel sentinel-pass SentinelPass456!
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
sentinel parallel-syncs mymaster 1
sentinel announce-ip 10.0.0.20   # IP deste sentinel
sentinel announce-port 26380
sentinel tls-port 26380
sentinel port 0
sentinel tls-cert-file /etc/redis/tls/sentinel.crt
sentinel tls-key-file /etc/redis/tls/sentinel.key
sentinel tls-ca-cert-file /etc/redis/tls/ca.crt
```

### Checklist Pos-Instalacao Redis
- [ ] `vm.overcommit_memory = 1` no SO
- [ ] THP desabilitado no SO
- [ ] `maxmemory` configurado
- [ ] `maxmemory-policy` definida adequadamente
- [ ] Autenticacao habilitada (ACLs Redis 6+ ou `requirepass`)
- [ ] Comandos perigosos desabilitados/renomeados
- [ ] `bind` restrito a IPs especificos
- [ ] TLS habilitado com certificado valido
- [ ] `protected-mode yes`
- [ ] Sentinel (3+ nos) ou Cluster (6+ nos) para HA
- [ ] RDB + AOF para durabilidade (se necessario)
- [ ] Permissoes de diretorio `/var/lib/redis` restritas ao usuario redis

**Fontes**:
- https://redis.io/docs/latest/operate/oss_and_stack/management/config/
- https://redis.io/docs/latest/operate/oss_and_stack/management/security/
- https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/
- https://redis.io/docs/latest/operate/rs/security/recommended-security-practices/
- https://redis.io/blog/5-basic-steps-to-secure-redis-deployments/
- https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/
- https://redis.io/docs/latest/operate/oss_and_stack/management/replication/
