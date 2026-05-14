# 06 — Backup e Recuperacao de Desastres

## Principios Fundamentais

### Regra 3-2-1
- **3** copias de dados (1 original + 2 backups)
- **2** tipos de midia diferentes (ex: disco + object storage)
- **1** copia offsite (outra regiao, outro datacenter, cloud)

### RTO e RPO — Definicoes Obrigatorias por Banco

Antes de definir estrategia de backup, estabelecer com o negocio:

| Metrica | Definicao | Pergunta ao Negocio |
|---------|-----------|---------------------|
| **RTO** (Recovery Time Objective) | Tempo maximo de indisponibilidade aceitavel | "Quanto tempo o sistema pode ficar fora do ar?" |
| **RPO** (Recovery Point Objective) | Perda maxima de dados aceitavel (em tempo) | "Quantos dados podemos perder em um incidente?" |

**Exemplo de classificacao por tier**:

| Tier | Descricao | RTO | RPO |
|------|-----------|-----|-----|
| Tier 1 — Critico | Banco de pagamentos, autenticacao | < 15 min | < 5 min |
| Tier 2 — Alto | ERP, CRM principal | < 1h | < 30 min |
| Tier 3 — Normal | Relatorios, analytics | < 4h | < 2h |
| Tier 4 — Baixo | Historico, arquivo | < 24h | < 24h |

---

## Tipos de Backup

| Tipo | Descricao | Vantagens | Desvantagens |
|------|-----------|-----------|--------------|
| **Full** | Copia completa do banco | Restore simples | Demora mais, mais espaco |
| **Incremental** | Apenas mudancas desde o ultimo backup | Rapido, menor espaco | Restore mais complexo (depende de chain) |
| **Diferencial** | Mudancas desde ultimo full | Restore mais simples que incremental | Cresce com o tempo ate o proximo full |
| **Logico** | SQL para recriar estrutura e dados | Portavel, seletivo | Lento para grandes bancos |
| **Fisico** | Copia dos arquivos do banco | Rapido para grandes bancos | Nao portavel entre versoes/plataformas |

**Estrategia recomendada**:
- Full semanal (domingo)
- Incremental/Diferencial diario (segunda a sabado)
- Archive logs/WAL/Binary log: continuo (para PITR)

---

## Backup por Banco de Dados

### PostgreSQL

```bash
# Backup fisico com pg_basebackup
pg_basebackup \
    --host=localhost \
    --port=5432 \
    --username=backup_user \
    --pgdata=/backup/pg/base \
    --format=tar \
    --compress=9 \
    --checkpoint=fast \
    --progress \
    --wal-method=stream

# Backup logico seletivo com pg_dump
pg_dump \
    --host=localhost \
    --port=5432 \
    --username=backup_user \
    --format=custom \
    --compress=9 \
    --file=/backup/pg/mydb_$(date +%Y%m%d).dump \
    mydb

# Backup de todos os bancos
pg_dumpall \
    --host=localhost \
    --port=5432 \
    --username=postgres \
    --file=/backup/pg/all_$(date +%Y%m%d).sql

# Configurar archiving de WAL (postgresql.conf)
# archive_mode = on
# archive_command = 'rsync -a %p backup@backup-server:/backup/wal/%f'
```

**PITR (Point-in-Time Recovery)**:
```bash
# Restore para um momento especifico
# 1. Restaurar backup base
pg_restore -d postgres /backup/pg/base.tar

# 2. Configurar recovery.conf (PG < 12) ou postgresql.conf (PG >= 12)
# restore_command = 'cp /backup/wal/%f %p'
# recovery_target_time = '2024-01-15 14:30:00'
```

---

### MySQL

```bash
# Backup logico com mysqldump
mysqldump \
    --host=localhost \
    --user=backup_user \
    --password \
    --all-databases \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --master-data=2 \
    --flush-logs \
    --compress \
    | gzip > /backup/mysql/all_$(date +%Y%m%d).sql.gz

# Backup fisico com Percona XtraBackup (online, sem lock)
xtrabackup \
    --backup \
    --target-dir=/backup/mysql/full_$(date +%Y%m%d) \
    --user=backup_user \
    --password=senha

# Prepare backup antes de restaurar
xtrabackup --prepare --target-dir=/backup/mysql/full_20240115

# Incremental com XtraBackup
xtrabackup \
    --backup \
    --target-dir=/backup/mysql/incr_$(date +%Y%m%d) \
    --incremental-basedir=/backup/mysql/full_domingo
```

---

### SQL Server

```sql
-- Backup full com compressao
BACKUP DATABASE [MeuBanco]
TO DISK = N'/backup/mssql/MeuBanco_full_' + CONVERT(VARCHAR, GETDATE(), 112) + '.bak'
WITH COMPRESSION, STATS = 10, CHECKSUM;

-- Backup de log (obrigatorio para PITR com FULL recovery model)
BACKUP LOG [MeuBanco]
TO DISK = N'/backup/mssql/MeuBanco_log_' + CONVERT(VARCHAR, GETDATE(), 112) + '_' +
    REPLACE(CONVERT(VARCHAR, GETDATE(), 108), ':', '') + '.bak'
WITH COMPRESSION, STATS = 10;

-- Verificar integridade do backup
RESTORE VERIFYONLY FROM DISK = N'/backup/mssql/MeuBanco_full.bak';

-- Restore com PITR
RESTORE DATABASE MeuBanco
FROM DISK = '/backup/mssql/MeuBanco_full.bak'
WITH NORECOVERY;

RESTORE LOG MeuBanco
FROM DISK = '/backup/mssql/MeuBanco_log.bak'
WITH NORECOVERY, STOPAT = '2024-01-15 14:30:00';

RESTORE DATABASE MeuBanco WITH RECOVERY;
```

---

### Oracle — RMAN

```bash
# Configurar RMAN
rman target /

# Configuracao inicial
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 30 DAYS;
CONFIGURE BACKUP OPTIMIZATION ON;
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE COMPRESSION ALGORITHM 'MEDIUM';
CONFIGURE ENCRYPTION FOR DATABASE ON;  -- encriptar backups

# Backup full
BACKUP DATABASE PLUS ARCHIVELOG;

# Backup incremental nivel 0 (base)
BACKUP INCREMENTAL LEVEL 0 DATABASE;

# Backup incremental nivel 1 (diario)
BACKUP INCREMENTAL LEVEL 1 DATABASE;

# Validar backup
VALIDATE BACKUPSET <backupset_key>;

# Restore e Recovery
STARTUP MOUNT;
RESTORE DATABASE;
RECOVER DATABASE;
ALTER DATABASE OPEN RESETLOGS;
```

**Exemplo de script de backup automatizado**:
```bash
#!/bin/bash
# /opt/oracle/scripts/rman_backup.sh
export ORACLE_SID=ORCL
export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1

rman target / << EOF
RUN {
    ALLOCATE CHANNEL c1 DEVICE TYPE DISK FORMAT '/backup/oracle/%d_%T_%s_%p.bkp';
    ALLOCATE CHANNEL c2 DEVICE TYPE DISK FORMAT '/backup/oracle/%d_%T_%s_%p.bkp';
    BACKUP INCREMENTAL LEVEL 1 DATABASE;
    BACKUP ARCHIVELOG ALL DELETE INPUT;
    DELETE OBSOLETE;
    RELEASE CHANNEL c1;
    RELEASE CHANNEL c2;
}
EOF
```

---

### IBM Db2

```bash
# Backup online completo
db2 BACKUP DATABASE mydb ONLINE TO /backup/db2 INCLUDE LOGS COMPRESS

# Single System View (SSV) para bancos particionados
db2_all "db2 BACKUP DATABASE mydb ONLINE TO /backup/db2 INCLUDE LOGS"

# Backup incremental
db2 BACKUP DATABASE mydb ONLINE INCREMENTAL DELTA TO /backup/db2 INCLUDE LOGS

# Restore
db2 RESTORE DATABASE mydb FROM /backup/db2 INTO mydb_restored REPLACE EXISTING

# Verificar historico de backup
db2 LIST HISTORY BACKUP ALL FOR DATABASE mydb
```

---

### Vertica

```bash
# Configurar e executar backup com vbr.py
# vbr.ini:
[Misc]
snapshotName = full_backup
restorePointLimit = 7

[Transmission]
port = 50023

[Database]
dbName = VMart
dbUser = dbadmin

[Nodes]
v_vmartdb_node0001 = backup_host_01:/backup/vertica
v_vmartdb_node0002 = backup_host_02:/backup/vertica

# Executar backup
/opt/vertica/bin/vbr.py --task backup --config /opt/vertica/config/vbr.ini

# Restore completo
/opt/vertica/bin/vbr.py --task restore --config /opt/vertica/config/vbr.ini
```

---

### Redis

```bash
# RDB Snapshot manual
redis-cli BGSAVE

# Aguardar conclusao
redis-cli LASTSAVE

# Configuracao RDB em redis.conf
save 900 1      # se 1 chave mudou em 900s, faz snapshot
save 300 10     # se 10 chaves mudaram em 300s
save 60 10000   # se 10000 chaves mudaram em 60s
dir /var/lib/redis
dbfilename dump.rdb

# AOF - Append Only File
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec  # a cada segundo (balance performance/durabilidade)
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# Backup manual do arquivo RDB
cp /var/lib/redis/dump.rdb /backup/redis/dump_$(date +%Y%m%d_%H%M%S).rdb
```

---

## Plano de Recuperacao de Desastres (DR)

### Componentes Obrigatorios do Plano

1. **Identificacao de Ativos Criticos**
   - Lista de todos os bancos de dados classificados por tier
   - Dependencias entre bancos e aplicacoes

2. **Responsaveis e Contatos**
   - DBA responsavel por cada banco
   - Contato de emergencia (plantao 24x7)
   - Contato do vendor para suporte critico
   - Aprovadores para declaracao de desastre

3. **Procedimentos de Resposta por Cenario**
   - Falha de hardware (disco, servidor)
   - Corrupção de dados
   - Ransomware/ataque
   - Falha de datacenter completo
   - Erro humano (DROP TABLE acidental)

4. **Procedimento Padrao de Restore**
   1. Declarar incidente e ativar time de DR
   2. Avaliar escopo do dano
   3. Isolar sistema afetado (evitar propagacao)
   4. Identificar ultimo backup bom conhecido
   5. Provisionar ambiente de restore (se necessario novo servidor)
   6. Executar restore + recovery
   7. Validar integridade dos dados
   8. Testes de fumaça nas aplicacoes
   9. Redirecionar trafego
   10. Comunicar conclusao e registrar incidente

5. **Comunicacao**
   - Template de comunicacao de incidente
   - Canais de comunicacao (Slack, email, SMS)
   - Frequencia de atualizacoes durante incidente

### Testes de DR — Cadencia Obrigatoria

| Teste | Frequencia | O que Validar |
|-------|------------|---------------|
| Restore de backup | Mensal | Backup integro e restauravel |
| Failover de replicacao | Trimestral | HA funciona conforme esperado |
| DR Completo (tabletop) | Semestral | Equipe sabe o procedimento |
| DR Simulado (real) | Anual | Processo end-to-end funciona dentro do RTO/RPO |

### Documentacao de Restore por Banco

Para cada banco em producao, documentar:
- Localizacao dos backups (path, bucket S3, etc.)
- Credenciais para acesso aos backups (no vault de secrets)
- Comando exato de restore com os parametros usados em producao
- Tempo estimado de restore (medir no ultimo teste)
- Checklist de validacao pos-restore

---

## Encriptacao de Backups

Todos os backups devem ser criptografados:

| Banco | Mecanismo |
|-------|-----------|
| PostgreSQL | `pg_dump` + `openssl enc -aes-256-cbc` ou gpg |
| MySQL | `mysqldump` + `openssl` ou Percona XtraBackup com encryption |
| SQL Server | `BACKUP DATABASE WITH ENCRYPTION` (nativo) |
| Oracle | `CONFIGURE ENCRYPTION FOR DATABASE ON` no RMAN |
| Db2 | Encryption nativa do backup |
| Vertica | `vbr.py` com configuracao de criptografia |
| Redis | Criptografar arquivos RDB/AOF no nivel do SO ou com rclone crypt |

**Gerenciamento de chaves de backup**: nunca armazenar chave no mesmo local que o backup. Usar KMS externo.
