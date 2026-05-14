# 04 — Padronizacao de Migracao de Banco de Dados

## Estrategias de Migracao (Framework Gartner — 5Rs)

| Estrategia | Descricao | Quando Usar | Complexidade |
|------------|-----------|-------------|--------------|
| **Rehost** (Lift & Shift) | Mover banco como esta | Urgencia, restricao de tempo | Baixa |
| **Revise** | Otimizar para nova plataforma | On-premises → cloud, mesma familia de BD | Media |
| **Rearchitect** | Redesenhar para cloud-native | Modernizacao, mudanca de paradigma | Alta |
| **Rebuild** | Reescrever para banco destino | Obsolescencia, mudanca de fornecedor | Muito Alta |
| **Replace** | Substituir por SaaS gerenciado | Sistemas legados sem manutencao ativa | Variavel |

---

## Fases da Migracao

### Fase 1: Planejamento e Escopo
- [ ] Definir estrategia (Rehost/Revise/Rearchitect/Rebuild/Replace)
- [ ] Escopo: banco completo ou schemas/tabelas especificas?
- [ ] Criterios de sucesso mensuráveis
- [ ] RTO e RPO da janela de migracao
- [ ] Stakeholders, aprovadores e times envolvidos
- [ ] Cronograma com marcos (milestones) e datas
- [ ] Orcamento para ferramentas, infraestrutura e horas
- [ ] Plano de comunicacao (quem notificar, quando, por qual canal)
- [ ] Avaliar risco de incompatibilidade antes de comprometer timeline

### Fase 2: Assessment
- **Inventario de objetos**: tabelas, views, procedures, functions, triggers, sequences, packages, jobs
- **Data Profiling**: completude, consistencia, precisao, volume, taxa de crescimento
- **Mapeamento de tipos de dados** entre origem e destino
- **Compatibilidade de SQL dialect**: funcoes nativas, sintaxe, collation, encoding
- **Dependencias de aplicacao**: connection strings, ORM mappings, queries hardcoded
- **Licencas**: impacto de sair do banco atual

### Fase 3: Preparacao
- [ ] Provisionar ambiente de destino com IaC
- [ ] Aplicar baseline de configuracao do banco destino (ver doc 03)
- [ ] Criar planilha de mapeamento de tipos
- [ ] Selecionar e testar ferramentas de migracao
- [ ] Executar migracao de teste com amostra (5–10% dos dados)
- [ ] Treinar equipe nas ferramentas
- [ ] Documentar e testar procedimento de rollback
- [ ] **Criar backup completo do banco origem** e verificar integridade

### Fase 4: Execucao

**Modos**:

| Modo | Downtime | Risco | Ideal Para |
|------|----------|-------|-----------|
| **Big Bang** | Alto | Alto | Bancos < 100GB, janela longa disponivel |
| **Phased** | Medio | Medio | Bancos medios, aplicacoes modulares |
| **Trickle (CDC)** | Minimo | Baixo | Grandes bancos, SLAs rigidos |

**Ordem de migracao recomendada**:
1. DDL (schema, tabelas, sequences, types)
2. Dados de referencia (tabelas de lookup)
3. Dados principais (bulk load com indexes desabilitados)
4. Habilitar indexes e constraints
5. Procedures, functions, packages
6. Triggers
7. Jobs/scheduled tasks
8. Dados delta (via CDC ou re-sync)

### Fase 5: Validacao
- Contagem de linhas por tabela (origem vs destino)
- Checksum de dados criticos
- Validar constraints (FKs, CHECKs, UNIQUE)
- Validar sequences/auto-increment (evitar colisao de IDs)
- Testes de aplicacao: smoke tests, regressao, performance, carga
- Medir performance vs baseline da origem

### Fase 6: Cutover
1. Comunicar janela de manutencao com antecedencia
2. Bloquear novas conexoes no banco origem
3. Aguardar drenagem de transacoes
4. Executar migracao delta (dados do periodo)
5. Validacao final de contagens e integridade
6. Atualizar connection strings das aplicacoes
7. Smoke test em producao
8. Comunicar conclusao e iniciar periodo de observacao (24–48h)

---

## Ferramentas por Par de Bancos

| Origem | Destino | Ferramenta Principal | Ferramenta Alternativa |
|--------|---------|----------------------|------------------------|
| Oracle | PostgreSQL | `ora2pg` | AWS SCT + DMS |
| Oracle | MySQL | `ora2pg` (modo MySQL) | AWS SCT + DMS |
| Oracle | Oracle | `expdp/impdp` (Data Pump) | RMAN DUPLICATE |
| MySQL | PostgreSQL | `pgLoader` | AWS DMS |
| MySQL | MySQL | `mysqldump` / `mysqlpump` | Percona XtraBackup |
| SQL Server | PostgreSQL | `pgLoader` (limitado) | AWS SCT + DMS |
| SQL Server | SQL Server | Backup/Restore | Detach/Attach |
| PostgreSQL | PostgreSQL | `pg_dump / pg_restore` | `pgcopydb` |
| Qualquer | AWS RDS/Aurora | AWS DMS | AWS SCT (schema) |
| Qualquer | Azure Database | Azure DMS | SSMA (SQL Server Migration Assistant) |
| Qualquer | GCP | Database Migration Service | GCP DMS |
| Redis | Redis | `redis-cli --rdb` / `RESTORE` | `redis-dump` |

---

## Migracao Detalhada por Banco de Dados

### PostgreSQL — Ferramentas e Procedimentos

**pg_dump / pg_restore** (backup/restore logico):
```bash
# Backup de banco completo (custom format — recomendado)
pg_dump \
    --host=origem-server \
    --port=5432 \
    --username=postgres \
    --format=custom \        # -Fc: formato comprimido, permite restore paralelo
    --compress=9 \
    --no-owner \             # nao incluir comandos ALTER OWNER
    --no-acl \               # nao incluir GRANT/REVOKE
    --schema=public \
    --file=/backup/pg/mydb_$(date +%Y%m%d).dump \
    mydb

# Restore paralelo (muito mais rapido para bancos grandes)
pg_restore \
    --host=destino-server \
    --port=5432 \
    --username=postgres \
    --dbname=mydb \
    --jobs=8 \               # -j: numero de threads paralelas
    --clean \                # dropar objetos existentes antes de criar
    --if-exists \
    --no-owner \
    /backup/pg/mydb_20240115.dump

# Listar conteudo do dump antes de restaurar
pg_restore --list /backup/pg/mydb_20240115.dump | head -50
```

**pgcopydb** (copia entre instancias, muito mais rapido):
```bash
# Copia completa com paralelismo
pgcopydb clone \
    --source "postgresql://postgres:senha@origem:5432/mydb" \
    --target "postgresql://postgres:senha@destino:5432/mydb" \
    --jobs 8 \
    --table-jobs 8 \
    --index-jobs 8

# Migrar apenas schema
pgcopydb copy schema \
    --source "postgresql://postgres:senha@origem:5432/mydb" \
    --target "postgresql://postgres:senha@destino:5432/mydb"
```

**pgLoader** (para migracoes de outros bancos para PostgreSQL):
```bash
# MySQL → PostgreSQL
pgloader mysql://root:senha@mysql-host/mydb \
         postgresql://postgres:senha@pg-host/mydb

# Com arquivo de configuracao (mais controle):
cat > migration.load << 'EOF'
LOAD DATABASE
    FROM mysql://root:senha@mysql-host/mydb
    INTO postgresql://postgres:senha@pg-host/mydb

WITH include drop, create tables, create indexes, reset sequences,
     workers = 8, concurrency = 1

SET PostgreSQL PARAMETERS
    maintenance_work_mem to '512MB',
    work_mem to '128MB'

CAST type bigint when (= precision 20) to bigint drop typemod,
     type date drop not null drop default using zero-dates-to-null,
     type tinyint when (= precision 1) to boolean using tinyint-to-boolean,
     type year to integer;
EOF

pgloader migration.load
```

**Validacao pos-migracao PostgreSQL**:
```sql
-- Contar linhas por tabela
SELECT schemaname, tablename, n_live_tup
FROM pg_stat_user_tables
ORDER BY schemaname, tablename;

-- Verificar sequencias
SELECT sequence_name, last_value FROM information_schema.sequences;
-- Ajustar sequencias para maximo do ID atual
SELECT setval('customer_id_seq', (SELECT MAX(customer_id) FROM customers));

-- Verificar constraintss invalidas
SELECT conrelid::regclass, conname, contype
FROM pg_constraint WHERE NOT convalidated;

-- Verificar indices invalidos
SELECT schemaname, tablename, indexname, indexdef
FROM pg_indexes
WHERE indexname IN (
    SELECT indexrelid::regclass::text
    FROM pg_index WHERE NOT indisvalid
);
```

**Fontes PostgreSQL**:
- https://www.postgresql.org/docs/current/app-pgdump.html
- https://www.postgresql.org/docs/current/app-pgrestore.html
- https://pgcopydb.readthedocs.io/
- https://pgloader.io/
- https://wiki.postgresql.org/wiki/Converting_from_other_Databases_to_PostgreSQL
- https://www.percona.com/blog/best-practices-for-postgresql-migration/

---

### MySQL — Ferramentas e Procedimentos

**mysqldump** (backup logico — bancos pequenos/medios):
```bash
# Backup completo com todos os metadados
mysqldump \
    --host=origem \
    --user=backup_user \
    --password \
    --all-databases \
    --single-transaction \          # snapshot consistente sem lock (InnoDB)
    --routines \                    # procedures e functions
    --triggers \                    # triggers
    --events \                      # events scheduler
    --master-data=2 \               # comentar posicao do binlog (para replicacao)
    --flush-logs \                  # rotacionar binlog
    --hex-blob \                    # binary data em hex (seguro)
    --compress \
    | gzip > /backup/mysql/all_$(date +%Y%m%d_%H%M).sql.gz

# Restore
gunzip -c /backup/mysql/all_20240115.sql.gz | \
    mysql --host=destino --user=root --password

# Somente schema (sem dados)
mysqldump --no-data --routines --triggers --events \
    --all-databases > schema_only.sql
```

**Percona XtraBackup** (backup fisico — bancos grandes):
```bash
# Backup full fisico (nao bloqueia escritas InnoDB)
xtrabackup \
    --backup \
    --target-dir=/backup/mysql/full_$(date +%Y%m%d) \
    --user=xtrabackup_user \
    --password=SenhaXtra123! \
    --compress \
    --compress-threads=4 \
    --parallel=4

# Prepare (obrigatorio antes de restaurar)
xtrabackup --prepare --target-dir=/backup/mysql/full_20240115

# Restore
systemctl stop mysqld
rm -rf /var/lib/mysql/*
xtrabackup --copy-back --target-dir=/backup/mysql/full_20240115
chown -R mysql:mysql /var/lib/mysql
systemctl start mysqld

# Backup incremental
xtrabackup --backup \
    --target-dir=/backup/mysql/incr_$(date +%Y%m%d) \
    --incremental-basedir=/backup/mysql/full_20240115

# Prepare incremental
xtrabackup --prepare --apply-log-only --target-dir=/backup/mysql/full_20240115
xtrabackup --prepare --apply-log-only --target-dir=/backup/mysql/full_20240115 \
    --incremental-dir=/backup/mysql/incr_20240116
xtrabackup --prepare --target-dir=/backup/mysql/full_20240115  # ultimo prepare
```

**mysqlpump** (alternativa ao mysqldump com paralelismo):
```bash
mysqlpump \
    --add-drop-database \
    --default-parallelism=4 \      # 4 threads paralelas
    --skip-definer \
    --skip-watch-progress \
    --all-databases \
    --exclude-databases=information_schema,performance_schema,sys \
    > /backup/mysql/all_$(date +%Y%m%d).sql
```

**PITR com Binary Logs**:
```bash
# Identificar binlogs disponíveis
mysql -e "SHOW BINARY LOGS;"

# Restore base + aplicar binlogs ate o momento desejado
# 1. Restore do backup base
# 2. Aplicar binlogs
mysqlbinlog \
    --start-datetime="2024-01-15 10:00:00" \
    --stop-datetime="2024-01-15 14:30:00" \
    /var/lib/mysql-binlog/mysql-bin.000123 \
    /var/lib/mysql-binlog/mysql-bin.000124 \
    | mysql --user=root --password
```

**Validacao pos-migracao MySQL**:
```sql
-- Verificar contagem de tabelas
SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROWS
FROM information_schema.TABLES
WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys')
ORDER BY TABLE_SCHEMA, TABLE_NAME;

-- Verificar constraints
SELECT TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, CONSTRAINT_TYPE
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys');

-- Verificar foreign keys com violacoes
SELECT 'CHECK CONSTRAINTS' AS type;
SET FOREIGN_KEY_CHECKS = 0;
-- Verificar integridade antes de re-habilitar
SET FOREIGN_KEY_CHECKS = 1;
```

**Fontes MySQL**:
- https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html
- https://docs.percona.com/percona-xtrabackup/8.0/
- https://dev.mysql.com/doc/refman/8.0/en/mysqlbinlog.html
- https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Source.MySQL.html

---

### SQL Server — Ferramentas e Procedimentos

**Backup e Restore nativo**:
```sql
-- Backup full com compressao e checksum
BACKUP DATABASE [MeuBanco]
TO DISK = N'/backup/mssql/MeuBanco_full_20240115.bak'
WITH
    COMPRESSION,
    CHECKSUM,
    STATS = 10,
    FORMAT,
    INIT,
    NAME = N'MeuBanco-Full Backup';

-- Verificar integridade do backup
RESTORE VERIFYONLY
    FROM DISK = N'/backup/mssql/MeuBanco_full_20240115.bak'
    WITH CHECKSUM;

-- Backup diferencial
BACKUP DATABASE [MeuBanco]
TO DISK = N'/backup/mssql/MeuBanco_diff_20240116.bak'
WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, STATS = 10;

-- Backup de log
BACKUP LOG [MeuBanco]
TO DISK = N'/backup/mssql/MeuBanco_log_20240116_1400.bak'
WITH COMPRESSION, CHECKSUM, STATS = 10;

-- Restore com PITR
RESTORE DATABASE MeuBanco
    FROM DISK = N'/backup/mssql/MeuBanco_full_20240115.bak'
    WITH NORECOVERY, REPLACE, STATS = 10;

RESTORE DATABASE MeuBanco
    FROM DISK = N'/backup/mssql/MeuBanco_diff_20240116.bak'
    WITH NORECOVERY, STATS = 10;

RESTORE LOG MeuBanco
    FROM DISK = N'/backup/mssql/MeuBanco_log_20240116_1400.bak'
    WITH NORECOVERY, STOPAT = '2024-01-16 14:25:00';

RESTORE DATABASE MeuBanco WITH RECOVERY;
```

**Migracao de SQL Server para SQL Server**:
```bash
# Detach/Attach (offline — mais rapido para bancos grandes)
# 1. Detach no servidor origem
USE [master];
ALTER DATABASE [MeuBanco] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
EXEC sp_detach_db @dbname = N'MeuBanco';

# 2. Copiar arquivos .mdf, .ldf, .ndf para destino
robocopy \\origem\share \\destino\share MeuBanco*.mdf MeuBanco*.ldf /Z /LOG:copy.log

# 3. Attach no servidor destino
USE [master];
CREATE DATABASE [MeuBanco] ON
    (FILENAME = N'D:\data\MeuBanco.mdf'),
    (FILENAME = N'D:\log\MeuBanco_log.ldf')
FOR ATTACH;
```

**SQL Server Migration Assistant (SSMA)** — migracao de outros bancos para SQL Server:
- SSMA for Oracle: https://learn.microsoft.com/en-us/sql/ssma/oracle/
- SSMA for MySQL: https://learn.microsoft.com/en-us/sql/ssma/mysql/
- SSMA for PostgreSQL: https://learn.microsoft.com/en-us/sql/ssma/postgresql/

**Validacao pos-migracao SQL Server**:
```sql
-- Verificar integridade dos dados apos restore
DBCC CHECKDB ([MeuBanco]) WITH NO_INFOMSGS, ALL_ERRORMSGS;

-- Contar linhas por tabela
SELECT
    s.name AS schema_name,
    t.name AS table_name,
    p.rows AS row_count
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
INNER JOIN sys.partitions p ON t.object_id = p.object_id
WHERE p.index_id IN (0, 1)
ORDER BY s.name, t.name;

-- Verificar fragmentacao de indices
SELECT
    OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name,
    ips.avg_fragmentation_in_percent
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') ips
INNER JOIN sys.indexes i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE ips.avg_fragmentation_in_percent > 10
ORDER BY ips.avg_fragmentation_in_percent DESC;
```

**Fontes SQL Server**:
- https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/backup-overview-sql-server
- https://learn.microsoft.com/en-us/sql/ssma/sql-server-migration-assistant
- https://learn.microsoft.com/en-us/sql/relational-databases/databases/database-detach-and-attach-sql-server
- https://goreplay.org/blog/demystifying-sql-server-migrations-tools-steps-and-best-practices/

---

### Oracle — Ferramentas e Procedimentos

**Oracle Data Pump (expdp/impdp)** — ferramenta oficial Oracle para migracao:
```bash
# Exportar banco completo
expdp system/SysSenha@ORCL \
    FULL=Y \
    DUMPFILE=full_export_%U.dmp \
    LOGFILE=export_full.log \
    DIRECTORY=EXPORT_DIR \
    PARALLEL=4 \
    COMPRESSION=ALL \
    EXCLUDE=STATISTICS

# Exportar apenas schemas especificos
expdp system/SysSenha@ORCL \
    SCHEMAS=MYAPP,MYAPP_CONFIG \
    DUMPFILE=schema_export_%U.dmp \
    LOGFILE=export_schema.log \
    DIRECTORY=EXPORT_DIR \
    PARALLEL=4 \
    COMPRESSION=ALL

# Importar em banco destino
impdp system/SysSenha@NEWORCL \
    FULL=Y \
    DUMPFILE=full_export_%U.dmp \
    LOGFILE=import_full.log \
    DIRECTORY=IMPORT_DIR \
    PARALLEL=4 \
    TABLE_EXISTS_ACTION=REPLACE \
    TRANSFORM=OID:N     # nao importar OIDs (evitar conflitos)

# Importar remap de schema (mover schema A para schema B)
impdp system/SysSenha@NEWORCL \
    SCHEMAS=MYAPP \
    REMAP_SCHEMA=MYAPP:MYAPP_NEW \
    REMAP_TABLESPACE=USERS:NEW_USERS \
    DUMPFILE=schema_export_%U.dmp \
    DIRECTORY=IMPORT_DIR
```

**ora2pg** — migracao Oracle → PostgreSQL:
```bash
# Instalar ora2pg
cpan install DBD::Oracle DBI Compress::Zlib

# Configuracao basica (ora2pg.conf)
cat > /etc/ora2pg/ora2pg.conf << 'EOF'
ORACLE_DSN  dbi:Oracle:host=oracle-host;port=1521;sid=ORCL
ORACLE_USER system
ORACLE_PWD  SysSenha123!
SCHEMA      MYAPP
PG_DSN      dbi:Pg:dbname=mydb;host=pg-host;port=5432
PG_USER     postgres
PG_PWD      PgSenha123!
TYPE        TABLE   # TABLE, VIEW, PROCEDURE, FUNCTION, SEQUENCE, ...
OUTPUT      myapp_migration.sql
CASE_SENSITIVE  0
NLS_LANG    AMERICAN_AMERICA.AL32UTF8
EOF

# Exportar schema completo
ora2pg -c /etc/ora2pg/ora2pg.conf -t TABLE -o tables.sql
ora2pg -c /etc/ora2pg/ora2pg.conf -t VIEW -o views.sql
ora2pg -c /etc/ora2pg/ora2pg.conf -t PROCEDURE -o procedures.sql
ora2pg -c /etc/ora2pg/ora2pg.conf -t FUNCTION -o functions.sql
ora2pg -c /etc/ora2pg/ora2pg.conf -t TRIGGER -o triggers.sql
ora2pg -c /etc/ora2pg/ora2pg.conf -t SEQUENCE -o sequences.sql
ora2pg -c /etc/ora2pg/ora2pg.conf -t INDEX -o indexes.sql
ora2pg -c /etc/ora2pg/ora2pg.conf -t FKEY -o fkeys.sql

# Exportar dados
ora2pg -c /etc/ora2pg/ora2pg.conf -t COPY -o data.sql  # formato COPY (rapido)

# Gerar relatorio de compatibilidade
ora2pg -c /etc/ora2pg/ora2pg.conf --estimate_cost -t SHOW_REPORT \
    > migration_report.html 2>&1
```

**RMAN Duplicate** (Oracle para Oracle, mesma versao):
```bash
# No servidor destino (auxiliar)
rman auxiliary /

# Duplicate via network (sem backup fisico)
RUN {
    ALLOCATE AUXILIARY CHANNEL c1 DEVICE TYPE DISK;
    DUPLICATE TARGET DATABASE TO newdb
        FROM ACTIVE DATABASE
        DORECOVER
        SPFILE
            SET DB_UNIQUE_NAME='NEWDB'
            SET CONTROL_FILES='/u02/newdb/control01.ctl'
            SET LOG_FILE_NAME_CONVERT='/u02/orcl','/u02/newdb'
            SET DB_FILE_NAME_CONVERT='/u02/orcl','/u02/newdb'
        NOFILENAMECHECK;
}
```

**Validacao Oracle pos-migracao**:
```sql
-- Contar objetos
SELECT object_type, COUNT(*) FROM dba_objects
WHERE owner = 'MYAPP' AND status = 'VALID'
GROUP BY object_type ORDER BY 1;

-- Verificar objetos invalidos
SELECT object_name, object_type, status FROM dba_objects
WHERE owner = 'MYAPP' AND status != 'VALID';

-- Recompilar todos os invalidos
EXEC UTL_RECOMP.RECOMP_SERIAL('MYAPP');

-- Contar linhas por tabela
SELECT table_name, num_rows FROM dba_tables WHERE owner = 'MYAPP' ORDER BY 1;
-- NOTA: num_rows e estimativa; usar COUNT(*) para verificacao exata em tabelas criticas
```

**Fontes Oracle**:
- https://docs.oracle.com/en/database/oracle/oracle-database/19/sutil/oracle-data-pump-overview.html
- https://docs.oracle.com/en/database/oracle/oracle-database/19/bradv/oracle-database-backup-and-recovery-reference.html
- https://ora2pg.darold.net/documentation.html
- https://docs.oracle.com/en/database/oracle/oracle-database/19/bradv/duplicating-a-database.html

---

### IBM Db2 — Ferramentas e Procedimentos

**db2move + db2look** (exportar/importar schema e dados):
```bash
# Exportar schema completo
db2look -d mydb -e -o schema.ddl -i db2inst1 -w senha

# Exportar dados com db2move (IXF format — nativo Db2)
mkdir /export/db2
cd /export/db2
db2move mydb EXPORT -u db2inst1 -p senha

# No servidor destino, criar banco e importar
db2 CREATE DATABASE newdb USING CODESET UTF-8 TERRITORY US
db2 CONNECT TO newdb
db2 -tvf schema.ddl

db2move newdb LOAD -u db2inst1 -p senha \
    -lo INSERT  # INSERT ou REPLACE

# Verificar erros de load
db2move newdb LOAD -l /export/db2 -u db2inst1 -p senha 2>&1 | grep -i error
```

**Backup e Restore Db2** (backup fisico — recomendado para bancos grandes):
```bash
# Backup online completo
db2 BACKUP DATABASE mydb ONLINE
    TO /backup/db2
    INCLUDE LOGS
    COMPRESS
    PARALLELISM 4

# Single System View (bancos particionados — DPF)
db2_all "<<+0< db2 BACKUP DATABASE mydb ONLINE TO /backup/db2 INCLUDE LOGS"

# Backup incremental
db2 BACKUP DATABASE mydb ONLINE INCREMENTAL DELTA
    TO /backup/db2
    INCLUDE LOGS
    COMPRESS

# Restore
db2 RESTORE DATABASE mydb
    FROM /backup/db2
    TAKEN AT 20240115140000
    INTO newdb
    REPLACE EXISTING
    WITHOUT PROMPTING

# Rollforward (aplicar logs para PITR)
db2 ROLLFORWARD DATABASE newdb
    TO '2024-01-15-14.30.00'
    AND STOP
    OVERFLOW LOG PATH /archive/db2/mydb

db2 ROLLFORWARD DATABASE newdb QUERY STATUS
```

**Migracao entre versoes Db2**:
```bash
# Verificar pre-requisitos de upgrade
db2prereqcheck -v 11.5

# Fazer upgrade in-place (requer downtime)
db2 DEACTIVATE DATABASE mydb
/opt/ibm/db2/V11.5/instance/db2iupdt db2inst1
db2 START DBM
db2 UPGRADE DATABASE mydb
db2 ACTIVATE DATABASE mydb
```

**Validacao Db2**:
```bash
# Contar linhas por tabela
db2 "SELECT TABSCHEMA, TABNAME, CARD FROM SYSCAT.TABLES WHERE TABSCHEMA='MYAPP' ORDER BY TABNAME"

# Verificar tabelas com card = -1 (estatisticas nao coletadas)
db2 "RUNSTATS ON TABLE myapp.customers WITH DISTRIBUTION AND DETAILED INDEXES ALL"

# Verificar integridade referencial
db2 "SET INTEGRITY FOR myapp.orders IMMEDIATE CHECKED"
```

**Fontes Db2**:
- https://www.ibm.com/docs/en/db2/11.5?topic=tools-db2move-database-movement-tool
- https://www.ibm.com/docs/en/db2/11.5?topic=commands-backup-database
- https://www.ibm.com/docs/en/db2/11.5?topic=commands-restore-database
- https://aws.amazon.com/blogs/architecture/field-notes-building-on-demand-disaster-recovery-for-ibm-db2-on-aws/

---

### Vertica — Ferramentas e Procedimentos

**vbr.py — Vertica Backup/Restore**:
```ini
# /opt/vertica/config/vbr.ini
[Misc]
snapshotName = prod_backup
restorePointLimit = 7
objectRestoreMode = coexist

[Transmission]
port = 50023
checksum = sha256
encrypt = true
privateKey = /etc/vertica/tls/backup.key
publicKey = /etc/vertica/tls/backup.crt

[Database]
dbName = VMart
dbUser = dbadmin
dbPromptForPassword = False
dbPassword = AdminSenha123!
dbPort = 5433

[Nodes]
v_vmart_node0001 = backup_host_01:/backup/vertica/node01
v_vmart_node0002 = backup_host_02:/backup/vertica/node02
v_vmart_node0003 = backup_host_03:/backup/vertica/node03
```

```bash
# Executar backup
/opt/vertica/bin/vbr.py --task backup --config /opt/vertica/config/vbr.ini

# Listar backups disponíveis
/opt/vertica/bin/vbr.py --task listbackup --config /opt/vertica/config/vbr.ini

# Restore completo
/opt/vertica/bin/vbr.py --task restore --config /opt/vertica/config/vbr.ini

# Restore de objeto especifico (tabela/schema)
/opt/vertica/bin/vbr.py --task objectrestore \
    --config /opt/vertica/config/vbr.ini \
    --table myschema.fact_sales
```

**Exportacao via COPY para migracao de dados**:
```sql
-- Exportar dados para S3/filesystem
COPY myschema.fact_sales
TO 's3://my-bucket/exports/fact_sales/'
PARQUET;  -- ou ORC, CSV

-- Exportar com filtro
COPY (SELECT * FROM fact_sales WHERE sale_date > '2023-01-01')
TO '/tmp/fact_sales_2023.csv'
DELIMITER ',' ENCLOSED BY '"';

-- Importar de outra instancia Vertica
CONNECT TO VERTICA sourcedb USER dbadmin
    PASSWORD 'AdminSenha123!'
    ON 'source-vertica-host', 5433;

COPY myschema.fact_sales
    SOURCE VERTICA sourcedb.myschema.fact_sales;

DISCONNECT sourcedb;
```

**Fontes Vertica**:
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/AdministratorsGuide/BackingUpAndRestoring/
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/SQLReferenceManual/Statements/COPY/
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/AdministratorsGuide/ManagingActiveConnections/

---

### Redis — Ferramentas e Procedimentos

**Backup e Restore via RDB**:
```bash
# Forcar snapshot RDB imediato
redis-cli -h redis-host -p 6380 --tls \
    --cert /etc/redis/tls/client.crt \
    --key /etc/redis/tls/client.key \
    --cacert /etc/redis/tls/ca.crt \
    BGSAVE

# Aguardar conclusao
redis-cli LASTSAVE  # retorna timestamp do ultimo save

# Copiar arquivo RDB
cp /var/lib/redis/dump.rdb /backup/redis/dump_$(date +%Y%m%d_%H%M%S).rdb

# Restore: parar Redis, substituir arquivo, iniciar
systemctl stop redis
cp /backup/redis/dump_20240115.rdb /var/lib/redis/dump.rdb
chown redis:redis /var/lib/redis/dump.rdb
systemctl start redis
```

**Migracao com redis-cli (DUMP/RESTORE)**:
```bash
#!/bin/bash
# Migrar keys de um Redis para outro
SOURCE="redis-source:6380"
TARGET="redis-target:6380"

redis-cli -h redis-source KEYS '*' | while read key; do
    redis-cli -h redis-source DUMP "$key" | \
    redis-cli -h redis-target --pipe-mode << EOF
RESTORE "$key" 0 "$(<stdin)"
EOF
done
```

**redis-shake** — ferramenta de migracao entre instancias Redis:
```bash
# Instalar redis-shake
wget https://github.com/tair-opensource/RedisShake/releases/latest/download/redis-shake.tar.gz
tar xzf redis-shake.tar.gz

# Configuracao de migracao
cat > sync.toml << 'EOF'
[source]
address = "redis-source:6380"
password = "SenhaSource123!"
tls = true

[target]
address = "redis-target:6380"
password = "SenhaTarget123!"
tls = true

[advanced]
parallel = 32
pipeline_count_limit = 1024
EOF

# Executar migracao
./redis-shake sync.toml
```

**Migracao com replicacao temporaria**:
```bash
# 1. Configurar novo Redis como replica do antigo (temporariamente)
redis-cli -h redis-novo REPLICAOF redis-antigo 6380

# 2. Aguardar sincronizacao completa
redis-cli -h redis-novo INFO replication | grep master_sync_in_progress
# Aguardar "master_sync_in_progress:0" e "master_link_status:up"

# 3. Promover novo Redis a standalone
redis-cli -h redis-novo REPLICAOF NO ONE

# 4. Atualizar connection strings das aplicacoes
# 5. Descomissionar Redis antigo
```

**Validacao Redis**:
```bash
# Contar keys
redis-cli DBSIZE

# Verificar keys por padrao
redis-cli --scan --pattern 'session:*' | wc -l
redis-cli --scan --pattern 'cache:*' | wc -l

# Verificar memoria
redis-cli INFO memory | grep used_memory_human

# Verificar replicacao
redis-cli INFO replication
```

**Fontes Redis**:
- https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/
- https://redis.io/docs/latest/commands/restore/
- https://github.com/tair-opensource/RedisShake
- https://redis.io/docs/latest/operate/oss_and_stack/management/replication/

---

## Checklist Completo de Migracao

### Pre-Migracao
- [ ] Estrategia definida e aprovada (Rehost/Revise/Rearchitect/Rebuild/Replace)
- [ ] Inventario completo de objetos do banco origem
- [ ] Data profiling realizado (completude, consistencia, volume)
- [ ] Mapeamento de tipos de dados documentado
- [ ] Ferramenta de migracao selecionada e testada
- [ ] Ambiente de destino provisionado com IaC
- [ ] Baseline de performance coletado na origem
- [ ] Backup completo do banco origem verificado e testado
- [ ] Procedimento de rollback documentado e testado em ambiente de teste
- [ ] Comunicacao enviada para stakeholders
- [ ] Janela de manutencao aprovada e calendário bloqueado
- [ ] Migracao de teste realizada com 10% dos dados

### Durante a Migracao
- [ ] Monitoramento ativo durante toda a execucao
- [ ] Log detalhado de cada etapa com timestamps
- [ ] Backups intermediarios antes de cada fase critica
- [ ] Nao alterar dados na origem durante Big Bang migration

### Pos-Migracao
- [ ] Contagem de linhas validada para todas as tabelas
- [ ] Constraints e indices verificados
- [ ] Objetos invalidos recompilados
- [ ] Sequences ajustadas para o ultimo ID
- [ ] Performance baseline comparado (< 20% de degradacao)
- [ ] Testes de aplicacao aprovados (smoke, regressao, carga)
- [ ] Backups configurados e testados no novo banco
- [ ] Monitoramento configurado e alertas validados
- [ ] Runbook do novo banco documentado
- [ ] Licencas do banco origem avaliadas para cancelamento
- [ ] Licoes aprendidas documentadas

---

## Migracao para Cloud — Consideracoes Especiais

### AWS
- **Schema Conversion**: AWS SCT (gratuito) identifica incompatibilidades automaticamente
- **Dados**: AWS DMS para migracao online com CDC (zero downtime)
- **Servicos gerenciados**: RDS, Aurora (PostgreSQL/MySQL/Oracle compativel), DocumentDB

### Azure
- **Schema**: Azure Database Migration Service, SSMA (SQL Server Migration Assistant)
- **Dados**: Azure DMS com online migration
- **Servicos**: Azure Database for PostgreSQL, MySQL, MariaDB; Azure SQL

### GCP
- **Schema + Dados**: Database Migration Service (DMS) com minimal downtime
- **Servicos**: Cloud SQL (PostgreSQL/MySQL/SQL Server), AlloyDB (PostgreSQL-compatible)

### Sizing para Cloud
- Nao fazer lift-and-shift de sizing on-prem para cloud sem analise de workload
- Cloud permite resize facil — comece conservative e ajuste com dados reais
- Usar ferramentas de rightsizing: AWS Compute Optimizer, Azure Advisor, GCP Recommender

**Fontes Cloud**:
- https://aws.amazon.com/dms/
- https://aws.amazon.com/blogs/database/schema-conversion-tool-amazon-aurora/
- https://learn.microsoft.com/en-us/azure/dms/
- https://cloud.google.com/database-migration
- https://www.gartner.com/en/documents/4261799 (Gartner Enterprise DB Migration)
