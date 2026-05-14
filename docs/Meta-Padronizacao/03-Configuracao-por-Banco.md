# 03 — Configuracao por Banco de Dados

## PostgreSQL

### Parametros Criticos (postgresql.conf)

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `shared_buffers` | 25–40% da RAM total | Cache principal de paginas do banco |
| `effective_cache_size` | 50–75% da RAM total | Estimativa de memoria disponivel para cache do SO |
| `work_mem` | 4MB–64MB (ajustar por workload) | Memoria por operacao de sort/hash — cuidado com alto `max_connections` |
| `maintenance_work_mem` | 256MB–1GB | Operacoes de VACUUM, CREATE INDEX, REINDEX |
| `wal_level` | `replica` (minimo) ou `logical` | Habilita replicacao; `logical` para logical replication |
| `wal_buffers` | `64MB` ou `-1` (automatico) | Buffer de WAL antes de flush para disco |
| `max_wal_size` | `1GB`–`10GB` | Controla frequencia de checkpoints |
| `checkpoint_completion_target` | `0.9` | Distribui escrita do checkpoint ao longo do tempo |
| `max_connections` | Ajustar + usar PgBouncer | Conexoes diretas ao banco (pool faz o controle) |
| `log_min_duration_statement` | `1000` (1s) | Loga queries lentas automaticamente |
| `log_statement` | `ddl` (minimo) ou `all` (auditoria) | Auditoria de mudancas de schema |
| `archive_mode` | `on` (producao) | Habilita arquivamento de WAL para PITR |
| `archive_command` | Script de copia para storage | Destino dos WAL arquivados |

### Autenticacao (pg_hba.conf)

```
# Formato: tipo  banco    usuario   endereco       metodo
local   all      postgres              peer
local   all      all                   scram-sha-256
host    all      all      127.0.0.1/32 scram-sha-256
host    all      all      10.0.0.0/8   scram-sha-256
# Nunca usar: trust (sem senha) em hosts remotos
```

### Checklist Pos-Instalacao
- [ ] Alterar senha do usuario `postgres`
- [ ] Revogar conexoes publicas em `template1`
- [ ] Criar usuario dedicado por aplicacao (nao usar `postgres`)
- [ ] Habilitar `ssl = on` e configurar certificados
- [ ] Configurar `log_connections` e `log_disconnections`
- [ ] Definir `search_path` nas roles para evitar confusion de schema

---

## MySQL

### Parametros Criticos (my.cnf / my.ini)

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `innodb_buffer_pool_size` | 70–80% da RAM | Cache InnoDB — parametro mais impactante de performance |
| `innodb_buffer_pool_instances` | 8 (ou 1 por GB de buffer pool) | Reduz contencao no buffer pool |
| `innodb_log_file_size` | 1GB–4GB | Redo log; maior = menos checkpoints, mais crash recovery |
| `innodb_flush_log_at_trx_commit` | `1` (durabilidade total) | `2` para performance com risco minimo de perda de dados |
| `innodb_flush_method` | `O_DIRECT` (Linux) | Evita double buffering com cache do SO |
| `binlog_format` | `ROW` | Replicacao segura em todos os cenarios |
| `log_bin` | `mysql-bin` | Habilita binary log (obrigatorio para replicacao e PITR) |
| `expire_logs_days` | `7` (minimo) | Retencao de binary logs |
| `max_connections` | Ajustar por workload | Use ProxySQL para pooling |
| `thread_cache_size` | `16`–`64` | Reutilizacao de threads |
| `query_cache_type` | `0` (desabilitar no MySQL 8) | Query cache removido no MySQL 8 |
| `slow_query_log` | `1` | Habilita log de queries lentas |
| `long_query_time` | `1` | Threshold em segundos para slow query log |
| `sql_mode` | `STRICT_TRANS_TABLES,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO` | Modo estrito evita insercoes silenciosas de dados invalidos |

### Checklist Pos-Instalacao
- [ ] Executar `mysql_secure_installation`
- [ ] Remover banco `test` e usuarios anonimos
- [ ] Alterar porta padrao 3306 se possivel (seguranca por obscuridade)
- [ ] Desabilitar `LOAD DATA INFILE` se nao utilizado
- [ ] Configurar `--skip-symbolic-links`
- [ ] Habilitar SSL/TLS para conexoes remotas
- [ ] Criar usuarios com `REQUIRE SSL`

---

## SQL Server

### Configuracoes de Instancia

| Configuracao | Valor Recomendado | Como Configurar |
|-------------|-------------------|-----------------|
| Max Server Memory | 80–85% da RAM | `sp_configure 'max server memory'` |
| Min Server Memory | 10% da RAM | `sp_configure 'min server memory'` |
| Max Degree of Parallelism (MAXDOP) | `= numero de cores fisicos / 2` (maximo 8) | `sp_configure 'max degree of parallelism'` |
| Cost Threshold for Parallelism | `50` | `sp_configure 'cost threshold for parallelism'` |
| Optimize for Ad Hoc Workloads | `1` | Reduz cache de single-use plans |

### Configuracoes por Banco de Dados

| Opcao | Valor Producao | Justificativa |
|-------|----------------|---------------|
| Recovery Model | `FULL` | Habilita PITR com log backups |
| Auto-Close | `OFF` | Evita overhead de abrir/fechar banco |
| Auto-Shrink | `OFF` | Causa fragmentacao severa se habilitado |
| Auto-Create Statistics | `ON` | Mantém estatisticas atualizadas para o optimizer |
| Auto-Update Statistics | `ON` | Atualiza automaticamente |
| Query Store | `ON` | Obrigatorio — captura historico de planos de execucao |
| Compatibility Level | Versao atual do SQL Server | Use o mais recente suportado pela aplicacao |

### Configuracao tempdb
```sql
-- Criar multiplos arquivos para tempdb (1 por nucleo, maximo 8)
-- Todos os arquivos com mesmo tamanho inicial e crescimento igual
-- Armazenar em disco SSD local (D: no Azure, NVMe no AWS)

ALTER DATABASE tempdb MODIFY FILE (NAME = 'tempdev', SIZE = 4096MB, FILEGROWTH = 512MB);
```

### Checklist Pos-Instalacao
- [ ] Desabilitar `xp_cmdshell`
- [ ] Desabilitar `xp_dirtree`
- [ ] Desabilitar CLR se nao necessario
- [ ] Desabilitar SQL Server Browser service
- [ ] Habilitar Encrypted Connections (Force Encryption = Yes)
- [ ] Configurar auditoria de login (sucesso e falha)
- [ ] Remover `sa` do login ou renomear
- [ ] Usar Windows Authentication ao inves de SQL Authentication

---

## Oracle Database

### Parametros Criticos (SPFILE)

| Parametro | Valor / Recomendacao | Justificativa |
|-----------|---------------------|---------------|
| `DB_UNIQUE_NAME` | Nome unico da instancia | Obrigatorio para Data Guard e GoldenGate |
| `ARCHIVELOG mode` | `ALTER DATABASE ARCHIVELOG` | Obrigatorio para backups online e PITR |
| `FORCE LOGGING` | `ALTER DATABASE FORCE LOGGING` | Garante que tudo vai para o redo log |
| `LOG_MODE` | `ARCHIVELOG` | Verificar com `SELECT LOG_MODE FROM V$DATABASE` |
| `DB_RECOVERY_FILE_DEST` | Path no ASM ou filesystem | Destino dos archive logs e FRA |
| `DB_RECOVERY_FILE_DEST_SIZE` | Minimo 3x tamanho diario de redo | Espaco para Flash Recovery Area |
| `SGA_TARGET` | 40–70% da RAM (com AMM) | Gerenciamento automatico de memoria do SGA |
| `PGA_AGGREGATE_TARGET` | 20% da RAM | Pool de memoria para processos PGA |
| `DG_BROKER_START` | `TRUE` | Habilita Data Guard Broker para HA |
| `FAL_SERVER` | Nome do standby | Fast-Start Failover: servidor de archive log |
| `LOG_ARCHIVE_DEST_2` | Destino standby com `LGWR SYNC AFFIRM` | Replicacao sincrona com zero data loss |

### Estrutura de Redo Logs Recomendada
```sql
-- Minimo 3 grupos, cada grupo com 2 membros (em discos diferentes)
-- Tamanho: 500MB–2GB dependendo do volume de mudancas
ALTER DATABASE ADD LOGFILE GROUP 1 (
    '+DATA/orcl/redo01a.log',
    '+FRA/orcl/redo01b.log'
) SIZE 1G;
```

### Standby Redo Logs (obrigatorio para Data Guard)
```sql
-- N+1 grupos onde N = numero de grupos de redo do primario
-- Mesmo tamanho dos redo logs do primario
ALTER DATABASE ADD STANDBY LOGFILE GROUP 11 (
    '+DATA/standby/srl01a.log',
    '+FRA/standby/srl01b.log'
) SIZE 1G;
```

### Checklist Pos-Instalacao
- [ ] Configurar ARCHIVELOG mode
- [ ] Configurar FORCE LOGGING
- [ ] Criar standby redo logs
- [ ] Configurar RMAN para backups automaticos
- [ ] Aplicar Oracle CPU (Critical Patch Update) atual
- [ ] Habilitar Auditing (AUDIT_TRAIL = DB, EXTENDED)
- [ ] Configurar Password Policy (30/60/90 dias + complexidade)
- [ ] Revogar privilegios desnecessarios de `PUBLIC`
- [ ] Configurar Oracle Wallet para autenticacao sem senha em scripts

---

## IBM Db2

### Parametros Criticos

| Parametro | Valor Recomendado | Tipo |
|-----------|-------------------|------|
| `LOCKLIST` | `AUTOMATIC` | DBM Config |
| `MAXLOCKS` | `80` | DB Config |
| `LOGFILSIZ` | `65536` (pages) | DB Config |
| `LOGPRIMARY` | `13` | DB Config |
| `LOGSECOND` | `12` | DB Config |
| `LOGARCHMETH1` | `DISK:/path` ou `TSM` | DB Config — archive logging |
| `NUM_IOSERVERS` | `8` (I/O async) | DB Config |
| `NUM_IOCLEANERS` | `8` | DB Config |
| `STMTHEAP` | `AUTOMATIC` | DB Config |
| `SHEAPTHRES_SHR` | `AUTOMATIC` | DBM Config |

### Configuracao de Reader/Writer Threads
- Ratio recomendado: **5–8 threads de leitura para cada 1 thread de escrita**
- Ajustar `NUM_IOSERVERS` e `NUM_IOCLEANERS` com base no numero de CPUs e tipo de workload

### Archive Logging
```bash
# Configurar archive logging (obrigatorio para backup online)
db2 UPDATE DB CFG FOR mydb USING LOGARCHMETH1 DISK:/db2logs/archive
db2 UPDATE DB CFG FOR mydb USING LOGARCHOPT1 ''

# Frequencia de archive: a cada 10-30 minutos recomendado
# Monitorar: db2 GET DB CFG FOR mydb | grep LOG
```

### Checklist Pos-Instalacao
- [ ] Habilitar archive logging
- [ ] Configurar backup automatico com `db2 BACKUP DB`
- [ ] Configurar HADR se HA for requisito
- [ ] Definir retencao de backup (minimo 3 copias em disco)
- [ ] Configurar auditoria com `db2audit`
- [ ] Usar autenticacao do SO (nao autenticacao interna do Db2)
- [ ] Aplicar fix packs atuais

---

## Vertica

### Parametros e Sizing

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| Nucleos por no | 32–48 cores fisicos | Optimal para processamento colunar |
| RAM por no | Minimo 256GB | Cache de dados e operacoes analíticas |
| RAM por core | 8–12 GB/core fisico | Ratio para balancear workload |
| K-Safety | `1` (minimo producao) | Tolera falha de 1 no sem perda de dados |
| Backup hosts | 1 por no Vertica | Performance otima de backup |
| Backup directories | 1 por no | Facilita backup e restore granular |

### K-Safety e Tolerancia a Falhas
```sql
-- Verificar K-Safety configurado
SELECT GET_COMPLIANCE_STATUS();

-- K=1: tolera falha de 1 no (minimo para producao)
-- K=2: tolera falha de 2 nos simultaneos

-- Verificar saude do cluster
SELECT * FROM SYSTEM;
SELECT * FROM NODES;
```

### Projections — Otimizacao
```sql
-- Verificar projections existentes
SELECT * FROM PROJECTIONS WHERE IS_UP_TO_DATE = FALSE;

-- Rebalancear apos adicionar nos
SELECT REBALANCE_CLUSTER();

-- Usar Database Designer para otimizar projections por workload
SELECT DESIGNER_CREATE_PROJECTION(...);
```

### Checklist Pos-Instalacao
- [ ] Verificar K-Safety com `SELECT GET_COMPLIANCE_STATUS()`
- [ ] Configurar backup com `vbr.py`
- [ ] Testar restore antes de ir para producao
- [ ] Configurar TLS para conexoes de cliente
- [ ] Criar usuarios com roles especificas (nao usar dbadmin em aplicacoes)
- [ ] Configurar retenção de dados com partition pruning
- [ ] Monitorar via `SYSTEM_TABLES` e tabelas de sistema

---

## Redis

### Configuracao Critica (redis.conf)

| Parametro | Valor Recomendado | Justificativa |
|-----------|-------------------|---------------|
| `maxmemory` | 80% da RAM disponivel | Limite de memoria — obrigatorio em producao |
| `maxmemory-policy` | `allkeys-lru` (cache puro) ou `volatile-lru` (misto) | Politica de eviction quando atinge limite |
| `save` | Configurar RDB ou desabilitar | Persistencia: `save 900 1 300 10 60 10000` |
| `appendonly` | `yes` (durabilidade critica) | AOF log para zero data loss |
| `appendfsync` | `everysec` | Balance entre performance e durabilidade |
| `requirepass` | Senha forte (32+ chars) | Autenticacao — obrigatorio em producao |
| `protected-mode` | `yes` | Rejeita conexoes externas sem senha |
| `bind` | `127.0.0.1 <IP_privado>` | Nunca bind em 0.0.0.0 sem firewall |
| `tls-port` | `6380` (ou porta customizada) | TLS — obrigatorio em producao |
| `tls-cert-file` | Path do certificado | Certificado TLS valido |
| `tls-key-file` | Path da chave privada | Chave do certificado |
| `rename-command CONFIG ""` | Desabilitar comando | Previne alteracao de configuracao por clientes |
| `rename-command DEBUG ""` | Desabilitar comando | Previne uso malicioso |

### ACLs — Redis 6+ (substitui requirepass)
```
# redis.conf
user default off nopass nocommands nokeys
user appuser on >SenhaForte123! ~* &* +@read +@write
user adminuser on >SenhaAdmin456! ~* &* +@all
```

### Topologia de Producao — Sentinel
```
# 3 servidores Sentinel em hosts fisicos separados
# sentinel.conf em cada servidor Sentinel
sentinel monitor mymaster 10.0.0.10 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 10000
sentinel parallel-syncs mymaster 1
```

### Persistencia — Escolha
| Cenario | Configuracao |
|---------|-------------|
| Cache puro (perda de dados aceitavel) | `save ""` (desabilitar RDB), `appendonly no` |
| Cache com recuperacao basica | RDB snapshots: `save 900 1 300 10 60 10000` |
| Dados criticos sem replicacao | AOF: `appendonly yes` + `appendfsync everysec` |
| Maior durabilidade | RDB + AOF combinados |

### Checklist Pos-Instalacao
- [ ] Configurar `maxmemory` e `maxmemory-policy`
- [ ] Habilitar autenticacao (ACLs Redis 6+ ou `requirepass`)
- [ ] Desabilitar comandos perigosos (`CONFIG`, `DEBUG`, `FLUSHALL`, `FLUSHDB`)
- [ ] Restringir `bind` a IPs especificos
- [ ] Configurar TLS
- [ ] Nunca expor Redis diretamente na internet
- [ ] Configurar Sentinel ou Cluster para HA
- [ ] Restringir permissoes do diretorio de dados ao usuario `redis`
