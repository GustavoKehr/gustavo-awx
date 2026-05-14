# 06 — Backup e Recuperacao de Desastres

## Principios Fundamentais

> **Por que ter uma estrategia formal de backup e nao confiar na replicacao?**
> Replicacao HA (Patroni, HADR, Data Guard) protege contra **falhas de hardware** — se o servidor primario morrer, o standby assume. Mas nao protege contra:
> - `DROP TABLE orders` — o comando e replicado para o standby em milissegundos
> - Corrupcao logica (bug de aplicacao insere dados errados por horas)
> - Ransomware que criptografa dados no primario — o standby recebe os dados criptografados
> - Erro humano em producao
>
> Backup e a unica solucao para esses cenarios. Replicacao + backup = cobertura completa. Replicacao sem backup = falsa sensacao de seguranca.

### Regra 3-2-1
- **3** copias de dados (1 original + 2 backups)
- **2** tipos de midia diferentes (ex: disco local + object storage)
- **1** copia offsite (outra regiao, outro datacenter, cloud)

> Extensao recomendada: **3-2-1-1-0** — 3 copias, 2 midias, 1 offsite, 1 air-gapped (sem conectividade de rede), 0 erros nos testes de restauracao.

### RTO e RPO — Definicoes Obrigatorias por Banco

Antes de definir estrategia de backup, estabelecer com o negocio:

| Metrica | Definicao | Pergunta ao Negocio |
|---------|-----------|---------------------|
| **RTO** (Recovery Time Objective) | Tempo maximo de indisponibilidade aceitavel | "Quanto tempo o sistema pode ficar fora do ar?" |
| **RPO** (Recovery Point Objective) | Perda maxima de dados aceitavel (em tempo) | "Quantos dados podemos perder em um incidente?" |

**Exemplo de classificacao por tier**:

| Tier | Descricao | RTO | RPO | Estrategia de Backup |
|------|-----------|-----|-----|----------------------|
| Tier 1 — Critico | Pagamentos, autenticacao | < 15 min | < 5 min | Full diario + WAL/Binlog continuo + standby ativo |
| Tier 2 — Alto | ERP, CRM principal | < 1h | < 30 min | Full diario + incremental a cada 2h |
| Tier 3 — Normal | Relatorios, analytics | < 4h | < 2h | Full diario + incremental diario |
| Tier 4 — Baixo | Historico, arquivo | < 24h | < 24h | Full semanal |

---

## Tipos de Backup

| Tipo | Descricao | Vantagens | Desvantagens |
|------|-----------|-----------|--------------|
| **Full** | Copia completa do banco | Restore simples, menor RTO | Demora mais, mais espaco |
| **Incremental** | Apenas mudancas desde o ultimo backup (full ou incremental) | Rapido, menor espaco | Restore mais complexo (depende de chain completa) |
| **Diferencial** | Mudancas desde ultimo full | Restore mais simples que incremental | Cresce com o tempo ate o proximo full |
| **Logico** | SQL para recriar estrutura e dados (pg_dump, mysqldump) | Portavel entre versoes, seletivo por objeto | Lento para grandes bancos; nao captura dados em memoria |
| **Fisico** | Copia binaria dos arquivos do banco (pg_basebackup, RMAN, XtraBackup) | Rapido para grandes bancos, PITR possivel | Nao portavel entre versoes/plataformas |
| **Snapshot** | Snapshot do volume de storage (LVM, ZFS, EBS Snapshot) | Muito rapido, consistente (com freeze do banco) | Dependente da plataforma de storage |

**Estrategia recomendada (exemplo Tier 1)**:
- Full fisico semanal (domingo madrugada)
- Incremental fisico diario (segunda a sabado)
- Archive logs / WAL / Binary log: continuo (para PITR com RPO em minutos)
- Retencao minima: 30 dias de backup completo + 7 dias de logs continuos

---

## PostgreSQL

> **Por que pgBackRest em vez de apenas `pg_basebackup` + scripts manuais?**
> `pg_basebackup` e excelente para criar o backup inicial mas nao gerencia:
> - Retencao: precisa de scripts externos para limpar backups antigos
> - Catalogacao: nao rastreia quais backups existem e quando foram feitos
> - Criptografia: nao tem suporte nativo a criptografia
> - Backup incremental: sempre faz full (exceto com `--incremental` no PG 17+)
> - Verificacao: sem checksums automaticos dos arquivos de backup
>
> pgBackRest resolve todos esses pontos com um unico binario que gerencia o ciclo de vida completo de backups. Para bancos pequenos (<50GB) `pg_basebackup` e suficiente. Para producao com volumes maiores, pgBackRest e o padrao da industria (usado por Amazon RDS internamente).

### pg_basebackup — Backup Fisico Nativo

```bash
# Criar usuario dedicado para backup (principio de menor privilegio)
psql -U postgres -c "CREATE USER backup_user REPLICATION LOGIN ENCRYPTED PASSWORD 'Backup@123!';"

# Backup fisico completo com WAL incluido (formato tar comprimido)
pg_basebackup \
    --host=localhost \
    --port=5432 \
    --username=backup_user \
    --pgdata=/backup/pg/base_$(date +%Y%m%d) \
    --format=tar \
    --compress=9 \
    --checkpoint=fast \
    --progress \
    --wal-method=stream \
    --label="full_backup_$(date +%Y%m%d)"

# Verificar integridade do backup
pg_checksums --check -D /backup/pg/base_$(date +%Y%m%d)
```

### pg_dump — Backup Logico Seletivo

```bash
# Backup de banco especifico em formato custom (permite restore seletivo)
pg_dump \
    --host=localhost \
    --port=5432 \
    --username=backup_user \
    --format=custom \
    --compress=9 \
    --blobs \
    --verbose \
    --file=/backup/pg/mydb_$(date +%Y%m%d_%H%M%S).dump \
    mydb

# Backup em formato diretorio (paralelizado, mais rapido para bancos grandes)
pg_dump \
    --host=localhost \
    --port=5432 \
    --username=backup_user \
    --format=directory \
    --compress=9 \
    --jobs=4 \
    --file=/backup/pg/mydb_dir_$(date +%Y%m%d) \
    mydb

# Backup de todos os bancos (inclui roles e tablespaces)
pg_dumpall \
    --host=localhost \
    --port=5432 \
    --username=postgres \
    --globals-only \
    --file=/backup/pg/globals_$(date +%Y%m%d).sql

# Restore seletivo (apenas uma tabela)
pg_restore \
    --host=localhost \
    --port=5432 \
    --username=postgres \
    --dbname=mydb \
    --table=orders \
    --verbose \
    /backup/pg/mydb_20240115.dump
```

### Continuous Archiving (WAL) — PITR

```bash
# postgresql.conf — habilitar archive
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /backup/wal/%f && cp %p /backup/wal/%f'
# Alternativa com rsync para servidor remoto:
# archive_command = 'rsync -a %p backup@backup-server:/backup/wal/%f'

# Para PITR com pgBackRest (ferramenta enterprise-grade):
# /etc/pgbackrest.conf
[global]
repo1-path=/backup/pgbackrest
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=SenhaCifragem!
log-level-console=info

[mydb]
pg1-path=/var/lib/postgresql/16/main

# Backup full com pgBackRest
pgbackrest --stanza=mydb backup --type=full

# Backup diferencial
pgbackrest --stanza=mydb backup --type=diff

# Backup incremental
pgbackrest --stanza=mydb backup --type=incr

# Listar backups disponiveis
pgbackrest --stanza=mydb info

# Restore PITR para momento especifico
pgbackrest --stanza=mydb restore \
    --target="2024-01-15 14:30:00" \
    --target-action=promote
```

### Checklist PostgreSQL

- [ ] `pg_basebackup` configurado com `--wal-method=stream` (WAL incluso no backup)
- [ ] `archive_mode = on` com `archive_command` testado e monitorado
- [ ] Slot de replicacao monitorado (evitar acumulo de WAL ilimitado)
- [ ] `pg_checksums` habilitado no data directory (detecta corrupção silenciosa)
- [ ] Restauracao testada mensalmente em servidor separado
- [ ] Backups criptografados (pgBackRest ou GPG pos-dump)
- [ ] Retencao de WAL suficiente para cobrir o RPO (minimo 2x o intervalo de backup full)

**Fontes**:
- [PostgreSQL — Backup and Restore](https://www.postgresql.org/docs/current/backup.html)
- [pgBackRest User Guide](https://pgbackrest.org/user-guide.html)
- [PostgreSQL — Continuous Archiving and PITR](https://www.postgresql.org/docs/current/continuous-archiving.html)
- [CIS PostgreSQL Benchmark — Section 6 (Audit)](https://www.cisecurity.org/benchmark/postgresql)

---

## MySQL

> **Por que XtraBackup em vez de apenas `mysqldump` para producao?**
> `mysqldump` e uma ferramenta logica — le cada linha e gera SQL. Para um banco de 500GB:
> - Backup demora 4–8 horas com carga adicional no servidor
> - Restore re-executa todos os INSERTs — pode demorar 10–20h
> - `--single-transaction` nao bloqueia InnoDB mas nao captura DDL ocorrendo durante o backup
> - Sem suporte a incremental nativo
>
> Percona XtraBackup faz backup fisico (copia binaria dos arquivos InnoDB enquanto o MySQL roda):
> - Backup de 500GB em 20–40 minutos
> - Restore em 20–40 minutos (copia de arquivos, nao re-execucao de SQL)
> - Suporte real a incremental via Log Sequence Number (LSN)
> - Zero lock de tabelas InnoDB
>
> **Regra pratica**: `mysqldump` para bancos < 10GB ou exports logicos pontuais; XtraBackup para tudo maior em producao.

### mysqldump — Backup Logico

```bash
# Backup completo de todas as bases (consistent snapshot via --single-transaction)
mysqldump \
    --host=localhost \
    --user=backup_user \
    --password='Backup@123!' \
    --all-databases \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --source-data=2 \
    --flush-logs \
    --set-gtid-purged=ON \
    --compress \
    | gzip > /backup/mysql/all_$(date +%Y%m%d_%H%M%S).sql.gz

# Backup de banco especifico
mysqldump \
    --host=localhost \
    --user=backup_user \
    --password='Backup@123!' \
    --single-transaction \
    --routines \
    --triggers \
    mydb | gzip > /backup/mysql/mydb_$(date +%Y%m%d).sql.gz

# Restore
gunzip < /backup/mysql/mydb_20240115.sql.gz | mysql -u root -p mydb
```

### Percona XtraBackup — Backup Fisico Online (sem lock)

```bash
# Instalar XtraBackup (RHEL/CentOS)
dnf install percona-xtrabackup-84

# Backup full (nao bloqueia o banco)
xtrabackup \
    --backup \
    --target-dir=/backup/mysql/full_$(date +%Y%m%d) \
    --user=backup_user \
    --password='Backup@123!' \
    --host=localhost \
    --datadir=/var/lib/mysql \
    --parallel=4 \
    --compress \
    --compress-threads=4

# Backup incremental (baseado no LSN do ultimo full)
xtrabackup \
    --backup \
    --target-dir=/backup/mysql/incr_$(date +%Y%m%d) \
    --incremental-basedir=/backup/mysql/full_domingo \
    --user=backup_user \
    --password='Backup@123!' \
    --parallel=4

# Prepare — OBRIGATORIO antes de restaurar
# Full backup:
xtrabackup --prepare --target-dir=/backup/mysql/full_20240114

# Incremental — aplicar sobre o full (em ordem):
xtrabackup --prepare --apply-log-only --target-dir=/backup/mysql/full_20240114
xtrabackup --prepare --apply-log-only \
    --target-dir=/backup/mysql/full_20240114 \
    --incremental-dir=/backup/mysql/incr_20240115
xtrabackup --prepare --target-dir=/backup/mysql/full_20240114

# Restore (MySQL deve estar parado)
systemctl stop mysqld
rm -rf /var/lib/mysql/*
xtrabackup --copy-back --target-dir=/backup/mysql/full_20240114
chown -R mysql:mysql /var/lib/mysql
systemctl start mysqld
```

### PITR com Binary Logs

```bash
# Habilitar binary log (my.cnf)
[mysqld]
log_bin = /var/log/mysql/mysql-bin.log
binlog_format = ROW
expire_logs_days = 14
max_binlog_size = 512M
gtid_mode = ON
enforce_gtid_consistency = ON

# Encontrar posicao do binlog no momento do desastre
mysqlbinlog \
    --start-datetime="2024-01-15 14:00:00" \
    --stop-datetime="2024-01-15 14:30:00" \
    /var/log/mysql/mysql-bin.000123 > /tmp/recovery.sql

# Aplicar (apos restaurar o backup base)
mysql -u root -p < /tmp/recovery.sql

# PITR via GTID — restaurar ate um GTID especifico
mysqlbinlog \
    --include-gtids="3E11FA47-71CA-11E1-9E33-C80AA9429562:1-100" \
    /var/log/mysql/mysql-bin.* | mysql -u root -p
```

### mysqlcheck — Verificacao de Integridade

```bash
# Verificar e reparar todas as tabelas
mysqlcheck --all-databases --check --auto-repair -u root -p

# Verificar tabelas com problemas de checksum
mysqlcheck --all-databases --checksum -u root -p
```

### Checklist MySQL

- [ ] `--single-transaction` sempre usado no mysqldump (evita lock de tabelas)
- [ ] `binlog_format = ROW` habilitado (necessario para PITR preciso)
- [ ] Binary logs retidos por minimo 14 dias
- [ ] XtraBackup configurado para backup fisico (producao com grandes volumes)
- [ ] GTID habilitado (`gtid_mode=ON`)
- [ ] Backup criptografado (XtraBackup `--encrypt=AES256` ou GPG)
- [ ] Restauracao testada mensalmente
- [ ] `mysqlcheck` executado semanal para detectar corrupcao

**Fontes**:
- [MySQL — Backup and Recovery](https://dev.mysql.com/doc/refman/8.4/en/backup-and-recovery.html)
- [Percona XtraBackup Documentation](https://docs.percona.com/percona-xtrabackup/latest/)
- [MySQL — mysqlbinlog for PITR](https://dev.mysql.com/doc/refman/8.4/en/point-in-time-recovery.html)
- [CIS MySQL Benchmark](https://www.cisecurity.org/benchmark/mysql)

---

## SQL Server

### Estrategia de Backup com T-SQL

```sql
-- Backup full com compressao e checksum (deteccao de corrupcao)
BACKUP DATABASE [MeuBanco]
TO DISK = N'/backup/mssql/MeuBanco_full_' + FORMAT(GETDATE(), 'yyyyMMdd_HHmmss') + '.bak'
WITH
    COMPRESSION,
    CHECKSUM,
    STATS = 10,
    DESCRIPTION = 'Full backup - ' + CONVERT(VARCHAR, GETDATE());

-- Backup diferencial (desde o ultimo full)
BACKUP DATABASE [MeuBanco]
TO DISK = N'/backup/mssql/MeuBanco_diff_' + FORMAT(GETDATE(), 'yyyyMMdd_HHmmss') + '.bak'
WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, STATS = 10;

-- Backup de log de transacoes (OBRIGATORIO para PITR com modelo FULL)
BACKUP LOG [MeuBanco]
TO DISK = N'/backup/mssql/MeuBanco_log_' + FORMAT(GETDATE(), 'yyyyMMdd_HHmmss') + '.trn'
WITH COMPRESSION, CHECKSUM, STATS = 10;

-- Backup para multiplos arquivos (striped — mais rapido para bancos grandes)
BACKUP DATABASE [MeuBanco]
TO
    DISK = N'/backup/mssql/MeuBanco_full_1.bak',
    DISK = N'/backup/mssql/MeuBanco_full_2.bak',
    DISK = N'/backup/mssql/MeuBanco_full_3.bak'
WITH COMPRESSION, CHECKSUM, STATS = 10;

-- Verificar integridade do backup (sem restaurar)
RESTORE VERIFYONLY
FROM DISK = N'/backup/mssql/MeuBanco_full_20240115.bak'
WITH CHECKSUM;
```

### Restore com PITR

```sql
-- Sequencia de restore com PITR:
-- 1. Restaurar backup full (NORECOVERY = mais logs/diferenciais serao aplicados)
RESTORE DATABASE [MeuBanco]
FROM DISK = N'/backup/mssql/MeuBanco_full_20240115.bak'
WITH NORECOVERY, STATS = 10;

-- 2. Aplicar diferencial (se houver)
RESTORE DATABASE [MeuBanco]
FROM DISK = N'/backup/mssql/MeuBanco_diff_20240115.bak'
WITH NORECOVERY, STATS = 10;

-- 3. Aplicar logs de transacao ate o momento desejado
RESTORE LOG [MeuBanco]
FROM DISK = N'/backup/mssql/MeuBanco_log_20240115_1400.trn'
WITH NORECOVERY, STOPAT = '2024-01-15 14:25:00';

-- 4. Ultimo restore coloca o banco online
RESTORE DATABASE [MeuBanco] WITH RECOVERY;

-- Verificar status de todos os backups registrados
SELECT
    database_name,
    backup_start_date,
    backup_finish_date,
    type,
    backup_size / 1024.0 / 1024.0 AS size_mb,
    physical_device_name
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
WHERE database_name = 'MeuBanco'
ORDER BY backup_start_date DESC;
```

### Backup via Ola Hallengren Solution (best practice da industria)

```sql
-- Solucao open-source amplamente adotada para automatizar backups no SQL Server
-- Download: https://ola.hallengren.com/

-- Backup full de todas as bases do usuario
EXECUTE dbo.DatabaseBackup
    @Databases = 'USER_DATABASES',
    @Directory = '/backup/mssql',
    @BackupType = 'FULL',
    @Compress = 'Y',
    @CheckSum = 'Y',
    @CleanupTime = 168,     -- remover backups com mais de 7 dias (horas)
    @Verify = 'Y';

-- Backup diferencial
EXECUTE dbo.DatabaseBackup
    @Databases = 'USER_DATABASES',
    @Directory = '/backup/mssql',
    @BackupType = 'DIFF',
    @Compress = 'Y',
    @CheckSum = 'Y';

-- Backup de logs
EXECUTE dbo.DatabaseBackup
    @Databases = 'USER_DATABASES',
    @Directory = '/backup/mssql',
    @BackupType = 'LOG',
    @Compress = 'Y',
    @CheckSum = 'Y',
    @CleanupTime = 48;
```

### Checklist SQL Server

- [ ] Modelo de recuperacao `FULL` configurado em todos os bancos de producao
- [ ] `BACKUP DATABASE WITH CHECKSUM` — sempre incluir checksum
- [ ] `RESTORE VERIFYONLY` executado apos cada backup
- [ ] Backup de logs a cada 15-30 minutos (para RPO < 30 min)
- [ ] Ola Hallengren ou SQL Agent Jobs automatizados
- [ ] Backup off-server (nao apenas no servidor de BD)
- [ ] DBCC CHECKDB semanal para detectar corrupcao
- [ ] Restauracao testada mensalmente em servidor separado

**Fontes**:
- [SQL Server — Backup Overview](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/backup-overview-sql-server)
- [Ola Hallengren — SQL Server Maintenance Solution](https://ola.hallengren.com/)
- [SQL Server — Point-in-Time Recovery](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/restore-a-sql-server-database-to-a-point-in-time)
- [CIS SQL Server Benchmark](https://www.cisecurity.org/benchmark/microsoft_sql_server)
- [DISA STIG for SQL Server](https://public.cyber.mil/stigs/downloads/)

---

## Oracle — RMAN (Recovery Manager)

> **Por que RMAN e a unica opcao aceita para backup em Oracle producao?**
> RMAN e o unico backup que entende a estrutura interna do Oracle:
> - **Backup consistente online**: usa os archive logs para garantir consistencia sem parar o banco
> - **Detecta corrupcao de bloco**: ao fazer backup, o RMAN valida cada bloco Oracle. Um backup com blocos corrompidos e detectado imediatamente — scripts de SO copiando arquivos nao detectam isso ate o restore falhar
> - **Incremental a nivel de bloco**: copia apenas blocos modificados desde o ultimo backup (nao arquivo inteiro)
> - **Gestao automatica de retencao**: sabe quais backups sao necessarios para cumprir a politica de retencao
> - **Integracao com Data Guard**: backups podem ser feitos no standby, sem impacto no primario
>
> Fazer backup copiando os datafiles diretamente no filesystem enquanto o Oracle esta rodando resulta em arquivos inconsistentes — o restore pode parecer funcionar mas os dados serao corrompidos.

### Configuracao Inicial do RMAN

```bash
rman target /

# Politica de retencao: manter backups suficientes para recuperar os ultimos 30 dias
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 30 DAYS;

# Otimizacao: nao fazer backup de arquivos identicos
CONFIGURE BACKUP OPTIMIZATION ON;

# Autobackup do controlfile e SPFILE (critico para recuperacao)
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '/backup/oracle/cf_%F';

# Compressao de backup
CONFIGURE COMPRESSION ALGORITHM 'MEDIUM' AS OF RELEASE 'DEFAULT' OPTIMIZE FOR LOAD TRUE;

# Encriptacao (obrigatoria para dados sensiveis)
CONFIGURE ENCRYPTION FOR DATABASE ON;
CONFIGURE ENCRYPTION ALGORITHM 'AES256';

# Paralelismo (ajustar para numero de discos/canais)
CONFIGURE DEVICE TYPE DISK PARALLELISM 4;

# Verificar configuracao
SHOW ALL;
```

### Scripts de Backup RMAN

```bash
#!/bin/bash
# /opt/oracle/scripts/rman_full_backup.sh
export ORACLE_SID=ORCL
export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1
export PATH=$ORACLE_HOME/bin:$PATH
BACKUP_DIR=/backup/oracle
LOG_DIR=/var/log/oracle/rman

mkdir -p $BACKUP_DIR $LOG_DIR
LOGFILE="$LOG_DIR/rman_full_$(date +%Y%m%d_%H%M%S).log"

rman target / log=$LOGFILE << 'RMAN_EOF'
RUN {
    ALLOCATE CHANNEL c1 DEVICE TYPE DISK
        FORMAT '/backup/oracle/full_%d_%T_%s_%p.bkp'
        MAXPIECESIZE 50G;
    ALLOCATE CHANNEL c2 DEVICE TYPE DISK
        FORMAT '/backup/oracle/full_%d_%T_%s_%p.bkp'
        MAXPIECESIZE 50G;
    ALLOCATE CHANNEL c3 DEVICE TYPE DISK
        FORMAT '/backup/oracle/full_%d_%T_%s_%p.bkp'
        MAXPIECESIZE 50G;
    ALLOCATE CHANNEL c4 DEVICE TYPE DISK
        FORMAT '/backup/oracle/full_%d_%T_%s_%p.bkp'
        MAXPIECESIZE 50G;

    BACKUP AS COMPRESSED BACKUPSET
        INCREMENTAL LEVEL 0
        DATABASE
        PLUS ARCHIVELOG DELETE INPUT
        TAG 'FULL_INCR0';

    BACKUP CURRENT CONTROLFILE TAG 'CONTROLFILE';
    BACKUP SPFILE TAG 'SPFILE';

    DELETE OBSOLETE;
    RELEASE CHANNEL c1;
    RELEASE CHANNEL c2;
    RELEASE CHANNEL c3;
    RELEASE CHANNEL c4;
}
RMAN_EOF

# Verificar resultado
if [ $? -ne 0 ]; then
    echo "RMAN BACKUP FAILED - Check $LOGFILE" | mail -s "ORACLE BACKUP FAILURE - $ORACLE_SID" dba@empresa.com
fi
```

```bash
#!/bin/bash
# /opt/oracle/scripts/rman_incremental_backup.sh
export ORACLE_SID=ORCL
export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1
export PATH=$ORACLE_HOME/bin:$PATH

rman target / << 'RMAN_EOF'
RUN {
    ALLOCATE CHANNEL c1 DEVICE TYPE DISK FORMAT '/backup/oracle/incr_%d_%T_%s_%p.bkp';
    ALLOCATE CHANNEL c2 DEVICE TYPE DISK FORMAT '/backup/oracle/incr_%d_%T_%s_%p.bkp';

    BACKUP AS COMPRESSED BACKUPSET
        INCREMENTAL LEVEL 1
        FOR RECOVER OF COPY WITH TAG 'INCR_DAILY'
        DATABASE;

    BACKUP ARCHIVELOG ALL
        NOT BACKED UP 1 TIMES
        DELETE INPUT;

    RELEASE CHANNEL c1;
    RELEASE CHANNEL c2;
}
RMAN_EOF
```

### Restore e Recovery RMAN

```bash
# Scenario 1: Perda de datafile especifico
rman target /
RMAN> RUN {
    RESTORE DATAFILE '/u01/app/oracle/oradata/ORCL/users01.dbf';
    RECOVER DATAFILE '/u01/app/oracle/oradata/ORCL/users01.dbf';
    SQL 'ALTER DATABASE DATAFILE ''/u01/app/oracle/oradata/ORCL/users01.dbf'' ONLINE';
}

# Scenario 2: Recover completo com PITR
RMAN> SHUTDOWN IMMEDIATE;
RMAN> STARTUP MOUNT;
RMAN> RUN {
    SET UNTIL TIME "TO_DATE('2024-01-15 14:30:00','YYYY-MM-DD HH24:MI:SS')";
    RESTORE DATABASE;
    RECOVER DATABASE;
}
RMAN> ALTER DATABASE OPEN RESETLOGS;

# Scenario 3: Recuperar usando DUPLICATE (para clone/DR)
rman target sys@primary auxiliary sys@standby
RMAN> DUPLICATE TARGET DATABASE TO standby FROM ACTIVE DATABASE
    SPFILE
        SET DB_UNIQUE_NAME 'ORCL_STANDBY'
        SET LOG_ARCHIVE_DEST_2 'SERVICE=primary ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=ORCL'
    NOFILENAMECHECK;

# Validar backups sem restaurar
RMAN> RESTORE DATABASE VALIDATE;
RMAN> RESTORE TABLESPACE users VALIDATE;
RMAN> VALIDATE BACKUPSET 123;

# Crosscheck — verificar backups fisicamente existentes
RMAN> CROSSCHECK BACKUP;
RMAN> DELETE EXPIRED BACKUP;
```

### Checklist Oracle

- [ ] `CONFIGURE CONTROLFILE AUTOBACKUP ON` sempre ativo
- [ ] Encriptacao AES256 habilitada para todos os backups
- [ ] Archive log mode ativo (`SELECT LOG_MODE FROM V$DATABASE`)
- [ ] RMAN catalog configurado (nao confiar apenas no controlfile)
- [ ] `RESTORE DATABASE VALIDATE` executado apos backup full
- [ ] `CROSSCHECK BACKUP` semanal para detectar backups corrompidos/expirados
- [ ] Backups testados em ambiente separado trimestralmente
- [ ] FRA (Fast Recovery Area) monitorada — nao deixar encher

**Fontes**:
- [Oracle — RMAN Backup and Recovery User's Guide 19c](https://docs.oracle.com/en/database/oracle/oracle-database/19/bradv/)
- [Oracle — MAA Best Practices for Backup and Recovery](https://www.oracle.com/database/technologies/high-availability/maa.html)
- [DISA STIG for Oracle Database](https://public.cyber.mil/stigs/downloads/)
- [CIS Oracle Database Benchmark](https://www.cisecurity.org/benchmark/oracle_database)

---

## IBM Db2

### Backup Online com Db2

```bash
# Conectar ao banco
db2 CONNECT TO mydb

# Backup online completo (banco continua disponivel)
db2 BACKUP DATABASE mydb ONLINE \
    TO /backup/db2 \
    INCLUDE LOGS \
    COMPRESS \
    UTIL_IMPACT_PRIORITY 50  # limita impacto em producao

# Verificar historico de backups
db2 LIST HISTORY BACKUP ALL FOR DATABASE mydb

# Backup incremental delta (apenas mudancas desde o ultimo backup de qualquer tipo)
db2 BACKUP DATABASE mydb ONLINE INCREMENTAL DELTA \
    TO /backup/db2 \
    INCLUDE LOGS \
    COMPRESS

# Backup incremental (mudancas desde ultimo full ou backup incremental)
db2 BACKUP DATABASE mydb ONLINE INCREMENTAL \
    TO /backup/db2 \
    INCLUDE LOGS \
    COMPRESS

# Para bancos particionados (MPP) — Single System View
db2_all "<<+0< db2 BACKUP DATABASE mydb ONLINE TO /backup/db2 INCLUDE LOGS"
```

### ROLLFORWARD — PITR no Db2

```bash
# 1. Restaurar backup base
db2 RESTORE DATABASE mydb FROM /backup/db2 \
    TAKEN AT 20240115000000 \
    INTO mydb \
    REPLACE EXISTING \
    WITHOUT ROLLING FORWARD

# 2. Rollforward para ponto no tempo
db2 ROLLFORWARD DATABASE mydb \
    TO 2024-01-15-14.30.00.000000 \
    AND STOP \
    OVERFLOW LOG PATH /backup/db2/logs

# Ou rollforward para o fim dos logs disponiveis
db2 ROLLFORWARD DATABASE mydb TO END OF LOGS AND STOP

# Verificar status do rollforward
db2 ROLLFORWARD DATABASE mydb QUERY STATUS

# Verificar integridade apos restore
db2 CONNECT TO mydb
db2 "SELECT TABSCHEMA, TABNAME, STATUS FROM SYSCAT.TABLES WHERE STATUS != 'N'"
```

### Configurar Arquivo de Logs para PITR

```bash
# Configurar retencao de logs de archive
db2 UPDATE DB CFG FOR mydb USING \
    LOGARCHMETH1 DISK:/backup/db2/logs \
    LOGARCHOPT1 "" \
    FAILARCHPATH /backup/db2/logs_failsafe \
    NUMARCHRETRY 5 \
    ARCHRETRYDELAY 20 \
    MINCOMMIT 1

# Verificar configuracao de log
db2 GET DB CFG FOR mydb | grep -i "log\|arch"
```

### Checklist IBM Db2

- [ ] `LOGARCHMETH1` configurado para path de archive (nao `OFF`)
- [ ] Backup incluindo `INCLUDE LOGS` (necessario para PITR)
- [ ] Historico verificado apos cada backup (`LIST HISTORY`)
- [ ] Rollforward testado em ambiente separado
- [ ] `FAILARCHPATH` definido (fallback para archive de logs)
- [ ] Backup criptografado (Db2 Advanced Enterprise Edition)
- [ ] `db2 RESTORE ... REBUILD` testado trimestralmente

**Fontes**:
- [IBM Db2 — Backup and Recovery Guide](https://www.ibm.com/docs/en/db2/11.5?topic=recovery-backup-overview)
- [IBM Db2 — ROLLFORWARD Command](https://www.ibm.com/docs/en/db2/11.5?topic=commands-rollforward-database)
- [IBM Db2 Best Practices — Backup and Recovery](https://www.ibm.com/support/pages/best-practices-db2-backup-and-recovery)
- [CIS IBM Db2 Benchmark](https://www.cisecurity.org/benchmark/ibm_db2)

---

## Vertica

### vbr.py — Vertica Backup and Restore Utility

```ini
# /opt/vertica/config/vbr_full.ini
[Misc]
snapshotName = vertica_full
restorePointLimit = 7          # manter os 7 ultimos backups
savepoints = 5
hardLinkLocal = False

[Transmission]
port = 50023
encrypt = True

[Database]
dbName = VMart
dbUser = dbadmin
dbPromptForPassword = False

[Nodes]
v_vmartdb_node0001 = backup-host-01:/backup/vertica/node1
v_vmartdb_node0002 = backup-host-02:/backup/vertica/node2
v_vmartdb_node0003 = backup-host-03:/backup/vertica/node3
```

```bash
# Backup completo
/opt/vertica/bin/vbr.py --task backup --config /opt/vertica/config/vbr_full.ini

# Backup de objetos especificos (schemas/tabelas)
/opt/vertica/bin/vbr.py \
    --task backup \
    --config /opt/vertica/config/vbr_full.ini \
    --include-objects "public.sales,public.customers"

# Listar snapshots disponiveis
/opt/vertica/bin/vbr.py --task listbackup --config /opt/vertica/config/vbr_full.ini

# Restore completo (banco deve estar parado ou em modo manutencao)
admintools -t stop_db -d VMart
/opt/vertica/bin/vbr.py --task restore --config /opt/vertica/config/vbr_full.ini
admintools -t start_db -d VMart

# Restore de um snapshot especifico
/opt/vertica/bin/vbr.py \
    --task restore \
    --config /opt/vertica/config/vbr_full.ini \
    --restore-point vertica_full_20240115_020000

# Verificar integridade do backup
/opt/vertica/bin/vbr.py --task checkbackup --config /opt/vertica/config/vbr_full.ini
```

### Backup de Dados via COPY

```sql
-- Exportar tabela para arquivo (para migracoes ou backup logico)
COPY public.sales
TO '/backup/vertica/data/sales_20240115.csv'
DELIMITER ',' ENCLOSED BY '"'
HEADER;

-- Exportar com compressao
COPY public.sales
TO '/backup/vertica/data/sales_20240115.csv.gz'
GZIP
DELIMITER '|';

-- Exportar para S3 (Eon Mode)
COPY public.sales
TO 's3://my-bucket/backup/vertica/sales/'
PARQUET;

-- Restaurar de arquivo
COPY public.sales
FROM '/backup/vertica/data/sales_20240115.csv.gz'
GZIP DELIMITER ',';
```

### Checklist Vertica

- [ ] `vbr.py` configurado com ao menos 1 backup host por no do cluster
- [ ] `restorePointLimit >= 7` (manter 7 snapshots)
- [ ] Backup criptografado (`encrypt = True` na config)
- [ ] Restore testado mensalmente (garantir que o cluster sobe limpo)
- [ ] K-Safety verificado apos restore (`SELECT GET_COMPLIANCE_STATUS()`)
- [ ] Verificar espaco disponivel nos hosts de backup antes de cada job

**Fontes**:
- [Vertica — vbr Backup and Restore Utility](https://www.vertica.com/docs/latest/HTML/Content/Authoring/AdministratorsGuide/BackupRestore/BackingUpAndRestoringTheDatabase.htm)
- [Vertica — Eon Mode Backup](https://www.vertica.com/docs/latest/HTML/Content/Authoring/Eon/EonBackupRestore.htm)
- [Vertica Best Practices — Backup and Recovery](https://www.vertica.com/kb/best-practices-backup-recovery/)

---

## Redis

### RDB Snapshot

```bash
# redis.conf — configuracao de snapshot automatico
save 3600 1      # salvar se ao menos 1 chave mudou em 1 hora
save 300 100     # salvar se ao menos 100 chaves mudaram em 5 min
save 60 10000    # salvar se ao menos 10000 chaves mudaram em 1 min

dir /var/lib/redis
dbfilename dump.rdb
rdbcompression yes
rdbchecksum yes      # checksum CRC64 no arquivo RDB

# Trigger snapshot manual
redis-cli BGSAVE

# Aguardar conclusao do snapshot
redis-cli LASTSAVE   # retorna timestamp Unix do ultimo save bem-sucedido

# Backup do arquivo RDB
REDIS_DIR=/var/lib/redis
BACKUP_DIR=/backup/redis
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

redis-cli BGSAVE
# Aguardar ate LASTSAVE mudar
BEFORE=$(redis-cli LASTSAVE)
while [ $(redis-cli LASTSAVE) -le $BEFORE ]; do sleep 1; done

cp $REDIS_DIR/dump.rdb $BACKUP_DIR/dump_$TIMESTAMP.rdb
gzip $BACKUP_DIR/dump_$TIMESTAMP.rdb
```

### AOF — Append Only File

```bash
# redis.conf — configuracao AOF
appendonly yes
appendfilename "appendonly.aof"
appenddirname "appendonlydir"   # Redis 7+: cada base em subdiretorio separado

# appendfsync: tradeoff durabilidade vs performance
# always   — flush por transacao (mais lento, mais seguro, RPO = 0)
# everysec — flush a cada segundo (balanceado, RPO = 1 segundo) — RECOMENDADO
# no       — deixa o OS decidir (rapido, menos seguro)
appendfsync everysec

# Rewrite automatico para compactar o AOF
auto-aof-rewrite-percentage 100   # rewrite quando AOF dobra de tamanho
auto-aof-rewrite-min-size 64mb    # mas somente se maior que 64MB

# Trigger rewrite manual
redis-cli BGREWRITEAOF

# Backup do AOF
cp /var/lib/redis/appendonly.aof /backup/redis/appendonly_$(date +%Y%m%d).aof
gzip /backup/redis/appendonly_$(date +%Y%m%d).aof
```

### Redis-Shake — Migracao e Backup entre Instancias

```bash
# Instalar redis-shake
wget https://github.com/tair-opensource/RedisShake/releases/latest/download/redis-shake_linux_amd64.tar.gz
tar -xzf redis-shake_linux_amd64.tar.gz

# config de sync entre instancias (backup continuo via replicacao)
# shake.toml
[source]
type = "sync"
address = "10.0.0.10:6379"
password = "SenhaMaster123!"

[target]
type = "standalone"
address = "10.0.0.20:6379"  # servidor de backup/DR
password = "SenhaBackup123!"

# Executar sync
./redis-shake shake.toml

# Exportar para RDB (backup completo)
# shake_rdb.toml
[source]
type = "sync"
address = "10.0.0.10:6379"
password = "SenhaMaster123!"

[target]
type = "rdb"
rdb_file_path = "/backup/redis/export_$(date +%Y%m%d).rdb"

./redis-shake shake_rdb.toml
```

### Restore Redis

```bash
# Restore de RDB
systemctl stop redis
cp /backup/redis/dump_20240115_020000.rdb.gz /tmp/
gunzip /tmp/dump_20240115_020000.rdb.gz
cp /tmp/dump_20240115_020000.rdb /var/lib/redis/dump.rdb
chown redis:redis /var/lib/redis/dump.rdb
systemctl start redis

# Verificar apos restore
redis-cli DBSIZE
redis-cli INFO keyspace
redis-cli INFO persistence

# Restore de AOF
systemctl stop redis
cp /backup/redis/appendonly_20240115.aof.gz /tmp/
gunzip /tmp/appendonly_20240115.aof.gz
cp /tmp/appendonly_20240115.aof /var/lib/redis/appendonly.aof
# Verificar integridade do AOF
redis-check-aof --fix /var/lib/redis/appendonly.aof
systemctl start redis
```

### Checklist Redis

- [ ] RDB e AOF habilitados simultaneamente para melhor durabilidade
- [ ] `rdbchecksum yes` habilitado (deteccao de corrupcao)
- [ ] `appendfsync everysec` como minimo (nao usar `no` em producao)
- [ ] Arquivo RDB/AOF copiado para storage separado regularmente
- [ ] `redis-check-rdb` e `redis-check-aof` executados nos backups
- [ ] Redis Cluster: verificar que todos os masters foram snapshottados
- [ ] Criptografia dos arquivos de backup (GPG ou criptografia do volume)
- [ ] Restauracao testada mensalmente

**Fontes**:
- [Redis — Persistence Documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)
- [Redis — RDB and AOF Backup](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)
- [RedisShake — Migration and Backup Tool](https://github.com/tair-opensource/RedisShake)
- [Redis Enterprise — Backup and Export](https://redis.io/docs/latest/operate/rs/databases/import-export/)

---

## Plano de Recuperacao de Desastres (DR)

### Componentes Obrigatorios do Plano

1. **Inventario de Ativos Criticos**
   - Lista de todos os bancos de dados classificados por tier (ver tabela acima)
   - Dependencias entre bancos e aplicacoes
   - Estimativa de volume de dados por banco (para estimar RTO de restore)

2. **Responsaveis e Contatos**
   - DBA responsavel por cada banco (nome + celular)
   - Contato de emergencia 24x7 (plantao/on-call)
   - Contato do vendor para suporte critico (Oracle Support, IBM PMR, etc.)
   - Aprovadores para declaracao de desastre

3. **Procedimentos de Resposta por Cenario**

   | Cenario | Impacto Tipico | Procedimento |
   |---------|----------------|-------------|
   | Falha de disco | Datafile inacessivel | Restore do datafile especifico + recovery |
   | Corrupcao de dados | Dados inconsistentes em tabelas | PITR para momento anterior a corrupcao |
   | Ransomware | Todo o banco comprometido | Restore de backup air-gapped anterior ao ataque |
   | Falha do servidor | BD totalmente indisponivel | Failover para standby (HA) ou restore em novo servidor |
   | Falha de datacenter | Regiao inteira offline | DR remoto — failover para replica assincrona em outra regiao |
   | Erro humano (DROP TABLE) | Tabela ou dados deletados | PITR ou flashback (Oracle) |

4. **Procedimento Padrao de Restore**
   1. Declarar incidente e ativar time de DR
   2. Avaliar escopo do dano (quais bancos, quais objetos, desde quando)
   3. Isolar sistema afetado (evitar propagacao de corrupcao para replicas)
   4. Identificar ultimo backup bom conhecido (verificar checksum/integridade)
   5. Provisionar ambiente de restore (novo servidor se necessario)
   6. Executar restore + recovery (conforme runbook do banco especifico)
   7. Validar integridade dos dados (checksums, contagem de registros, integridade referencial)
   8. Testes de fumaca nas aplicacoes
   9. Redirecionar trafego (DNS, load balancer, connection strings)
   10. Comunicar conclusao e registrar incidente no ITSM
   11. Analise pos-incidente (post-mortem) e melhorias

5. **Comunicacao durante Incidente**
   - Canal dedicado no Slack/Teams para incidentes de banco
   - Template de comunicacao: "Incidente iniciado em [hora]. Banco [nome] afetado. RTO estimado: [X min/h]. Proximo update em [hora]."
   - Atualizacoes a cada 30 minutos enquanto o incidente estiver ativo

### Testes de DR — Cadencia Obrigatoria

| Teste | Frequencia | O que Validar |
|-------|------------|---------------|
| Restore de backup | **Mensal** | Backup integro e restauravel em tempo dentro do RTO |
| Failover de replicacao | **Trimestral** | HA funciona; aplicacao reconecta; RTO/RPO medidos |
| DR completo (tabletop exercise) | **Semestral** | Equipe conhece o procedimento; lacunas identificadas |
| DR simulado (real) | **Anual** | Processo end-to-end dentro do RTO/RPO declarado |

### Documentacao de Runbook por Banco

Para cada banco em producao, manter runbook com:
- Localizacao dos backups (path, bucket S3, endpoint de storage)
- Credenciais para acesso (no secrets manager — nunca em texto plano)
- Comando exato de restore com os parametros usados em producao
- Tempo estimado de restore por tamanho (medir no ultimo teste)
- Checklist de validacao pos-restore especifica para o banco
- Historico dos ultimos testes (data, RTO atingido, problemas encontrados)

---

## Encriptacao de Backups

**Todos os backups devem ser criptografados em repouso e em transito.**

| Banco | Mecanismo Nativo | Alternativa |
|-------|-----------------|-------------|
| PostgreSQL | `pg_dump \| openssl enc -aes-256-cbc` ou pgBackRest com `cipher-type=aes-256-cbc` | GPG com chave assimetrica |
| MySQL | XtraBackup `--encrypt=AES256 --encrypt-key-file=/etc/xtrabackup.key` | GPG |
| SQL Server | `BACKUP DATABASE WITH ENCRYPTION (ALGORITHM = AES_256, ...)` — nativo | — |
| Oracle | `CONFIGURE ENCRYPTION FOR DATABASE ON; CONFIGURE ENCRYPTION ALGORITHM 'AES256'` — RMAN | — |
| Db2 | `BACKUP ... ENCRYPT INCLUDE LOGS` (licenca Advanced) | GPG |
| Vertica | `encrypt = True` no vbr.ini | Criptografia do volume de backup |
| Redis | Criptografar arquivos RDB/AOF no nivel do SO (dm-crypt/LUKS) ou com rclone crypt | GPG |

**Gerenciamento de chaves de backup**:
- Nunca armazenar a chave de criptografia no mesmo local que o backup
- Usar KMS externo (AWS KMS, Azure Key Vault, GCP KMS, HashiCorp Vault)
- Rotacionar chaves de backup anualmente
- Documentar procedimento de recuperacao de chave (e se a chave sumir, o backup e inutilizavel)

---

## Monitoramento de Backup

### Alertas Obrigatorios

| Alerta | Condicao | Severidade |
|--------|----------|------------|
| Backup nao executou | Job nao rodou no horario esperado | CRITICO |
| Backup falhou | Job executou mas retornou erro | CRITICO |
| Backup demorou mais que o esperado | Duracao > 2x a media historica | AVISO |
| Espaco de backup < 20% livre | Volume/bucket de backup quase cheio | AVISO |
| Backup mais antigo que SLA | Backup mais recente mais antigo que o RPO | CRITICO |
| Falha de teste de restauracao | Restauracao mensal retornou erro | CRITICO |

### Queries de Monitoramento

```sql
-- PostgreSQL: verificar ultimo WAL arquivado
SELECT last_archived_wal, last_archived_time,
       last_failed_wal, last_failed_time
FROM pg_stat_archiver;

-- SQL Server: ultimo backup bem-sucedido por banco
SELECT d.name, MAX(b.backup_finish_date) AS last_backup
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset b ON b.database_name = d.name
WHERE d.database_id > 4  -- excluir system databases
GROUP BY d.name
ORDER BY last_backup ASC;  -- bancos sem backup aparecem primeiro (NULL)

-- Oracle: status do ultimo job de backup RMAN
SELECT start_time, end_time, status, output_device_type
FROM v$rman_backup_job_details
ORDER BY start_time DESC
FETCH FIRST 10 ROWS ONLY;
```

**Fontes Gerais**:
- [Veeam — 3-2-1-1-0 Rule Explained](https://www.veeam.com/blog/3-2-1-1-0-data-protection-rule.html)
- [NIST SP 800-209 — Security Guidelines for Storage Infrastructure](https://csrc.nist.gov/publications/detail/sp/800-209/final)
- [ISO/IEC 27040 — Storage Security](https://www.iso.org/standard/44404.html)
- [ITIL 4 — Service Continuity Management](https://www.axelos.com/certifications/itil-service-management/itil-4-foundation)
