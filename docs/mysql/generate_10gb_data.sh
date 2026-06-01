#!/bin/bash
# generate_10gb_data.sh
# Generates ~10GB of data across 4 tables in MySQL 'appdb'
# No stored procedures — uses bash loops + mysql -e (avoids DELIMITER issue)
# Runtime: 20-50 min depending on disk/CPU
# Run as root

set -euo pipefail

DB="appdb"
LOG="/tmp/datagen_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

M() { mysql "$DB" -e "$1"; }

echo "=== Data generation started: $(date) ==="
echo "Log: $LOG"

# ── helper numbers table ──────────────────────────────────────
echo "[setup] Creating _seq100 helper table..."
M "DROP TABLE IF EXISTS _seq100;"
M "CREATE TABLE _seq100 (n TINYINT UNSIGNED NOT NULL PRIMARY KEY);"
M "INSERT INTO _seq100 VALUES
   (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),
   (10),(11),(12),(13),(14),(15),(16),(17),(18),(19),
   (20),(21),(22),(23),(24),(25),(26),(27),(28),(29),
   (30),(31),(32),(33),(34),(35),(36),(37),(38),(39),
   (40),(41),(42),(43),(44),(45),(46),(47),(48),(49),
   (50),(51),(52),(53),(54),(55),(56),(57),(58),(59),
   (60),(61),(62),(63),(64),(65),(66),(67),(68),(69),
   (70),(71),(72),(73),(74),(75),(76),(77),(78),(79),
   (80),(81),(82),(83),(84),(85),(86),(87),(88),(89),
   (90),(91),(92),(93),(94),(95),(96),(97),(98),(99);"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TABLE 1: transactions  — 50 batches x 100K = 5M rows (~3.5GB)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[1/4] Creating transactions table..."
M "DROP TABLE IF EXISTS transactions;"
M "CREATE TABLE transactions (
    id           BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    uuid         CHAR(36)       NOT NULL,
    customer_id  INT UNSIGNED   NOT NULL,
    product_id   INT UNSIGNED   NOT NULL,
    amount       DECIMAL(12,2)  NOT NULL,
    currency     CHAR(3)        NOT NULL DEFAULT 'BRL',
    status       ENUM('pending','processing','completed','failed','refunded') NOT NULL,
    description  VARCHAR(300)   NOT NULL,
    payload      VARCHAR(500)   NOT NULL,
    ip_address   VARCHAR(45)    NOT NULL,
    user_agent   VARCHAR(200)   NOT NULL,
    created_at   DATETIME       NOT NULL,
    updated_at   DATETIME       NOT NULL,
    INDEX idx_customer (customer_id),
    INDEX idx_product  (product_id),
    INDEX idx_status   (status),
    INDEX idx_created  (created_at)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;"

BATCHES=50
for i in $(seq 1 $BATCHES); do
    M "INSERT INTO transactions
           (uuid,customer_id,product_id,amount,currency,status,
            description,payload,ip_address,user_agent,created_at,updated_at)
       SELECT
           UUID(),
           FLOOR(1+RAND()*10000),
           FLOOR(1+RAND()*5000),
           ROUND(10+RAND()*49990,2),
           ELT(1+FLOOR(RAND()*4),'BRL','USD','EUR','ARS'),
           ELT(1+FLOOR(RAND()*5),'pending','processing','completed','failed','refunded'),
           CONCAT('Transaction #',a.n*10000+b.n*100+c.n,' ',REPEAT('data ',20)),
           CONCAT('{\"session\":\"',MD5(RAND()),'\",\"browser\":\"',
                  ELT(1+FLOOR(RAND()*4),'Chrome','Firefox','Safari','Edge'),
                  '\",\"extra\":\"',REPEAT('x',200),'\"}'),
           CONCAT(FLOOR(RAND()*255),'.',FLOOR(RAND()*255),'.',
                  FLOOR(RAND()*255),'.',FLOOR(RAND()*255)),
           CONCAT('Mozilla/5.0 ',REPEAT('agent ',15)),
           DATE_SUB(NOW(),INTERVAL FLOOR(RAND()*730) DAY),
           DATE_SUB(NOW(),INTERVAL FLOOR(RAND()*365) DAY)
       FROM _seq100 a CROSS JOIN _seq100 b CROSS JOIN _seq100 c
       LIMIT 100000;"
    echo "  transactions batch $i/$BATCHES ($(( i * 100000 )) rows inserted)"
done
M "SELECT COUNT(*) AS transactions_total FROM transactions;"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TABLE 2: events_log — 40 batches x 100K = 4M rows (~2.4GB)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[2/4] Creating events_log table..."
M "DROP TABLE IF EXISTS events_log;"
M "CREATE TABLE events_log (
    id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    event_type  VARCHAR(50)   NOT NULL,
    severity    ENUM('DEBUG','INFO','WARNING','ERROR','CRITICAL') NOT NULL,
    source      VARCHAR(100)  NOT NULL,
    host        VARCHAR(100)  NOT NULL,
    message     VARCHAR(500)  NOT NULL,
    stack_trace VARCHAR(500)  NOT NULL,
    metadata    JSON,
    session_id  CHAR(32)      NOT NULL,
    request_id  CHAR(36)      NOT NULL,
    duration_ms INT UNSIGNED  NOT NULL,
    created_at  DATETIME      NOT NULL,
    INDEX idx_type     (event_type),
    INDEX idx_severity (severity),
    INDEX idx_host     (host),
    INDEX idx_created  (created_at)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;"

BATCHES=40
for i in $(seq 1 $BATCHES); do
    M "INSERT INTO events_log
           (event_type,severity,source,host,message,
            stack_trace,metadata,session_id,request_id,duration_ms,created_at)
       SELECT
           ELT(1+FLOOR(RAND()*8),
               'http.request','db.query','cache.miss','auth.login',
               'auth.logout','worker.job','scheduler.task','api.call'),
           ELT(1+FLOOR(RAND()*5),'DEBUG','INFO','WARNING','ERROR','CRITICAL'),
           CONCAT(ELT(1+FLOOR(RAND()*4),'web-','app-','api-','worker-'),FLOOR(RAND()*20)+1),
           CONCAT(ELT(1+FLOOR(RAND()*3),'srv-','node-','host-'),
                  LPAD(FLOOR(RAND()*100),3,'0'),'.internal'),
           CONCAT('Event at ',DATE_SUB(NOW(),INTERVAL FLOOR(RAND()*1000) HOUR),
                  ' — ',REPEAT(ELT(1+FLOOR(RAND()*3),'info ','warn ','err '),30)),
           CONCAT('at Module.',MD5(RAND()),' line ',FLOOR(RAND()*500),
                  ' ',REPEAT('at trace() ',15)),
           JSON_OBJECT('user_id',FLOOR(RAND()*100000),
                       'tenant',FLOOR(RAND()*1000),
                       'region',ELT(1+FLOOR(RAND()*4),'us-east','eu-west','sa-east','ap'),
                       'flags',FLOOR(RAND()*255)),
           MD5(RAND()),
           UUID(),
           FLOOR(RAND()*5000),
           DATE_SUB(NOW(),INTERVAL FLOOR(RAND()*1095) DAY)
       FROM _seq100 a CROSS JOIN _seq100 b CROSS JOIN _seq100 c
       LIMIT 100000;"
    echo "  events_log batch $i/$BATCHES ($(( i * 100000 )) rows inserted)"
done
M "SELECT COUNT(*) AS events_log_total FROM events_log;"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TABLE 3: sensor_data — 100 batches x 100K = 10M rows (~2.5GB)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[3/4] Creating sensor_data table..."
M "DROP TABLE IF EXISTS sensor_data;"
M "CREATE TABLE sensor_data (
    id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    sensor_id   INT UNSIGNED  NOT NULL,
    site_id     INT UNSIGNED  NOT NULL,
    metric      VARCHAR(60)   NOT NULL,
    value       DOUBLE        NOT NULL,
    unit        VARCHAR(20)   NOT NULL,
    quality     TINYINT       NOT NULL,
    tags        VARCHAR(200)  NOT NULL,
    recorded_at DATETIME(3)   NOT NULL,
    INDEX idx_sensor (sensor_id,recorded_at),
    INDEX idx_site   (site_id),
    INDEX idx_metric (metric),
    INDEX idx_ts     (recorded_at)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;"

BATCHES=100
for i in $(seq 1 $BATCHES); do
    M "INSERT INTO sensor_data
           (sensor_id,site_id,metric,value,unit,quality,tags,recorded_at)
       SELECT
           FLOOR(1+RAND()*2000),
           FLOOR(1+RAND()*500),
           ELT(1+FLOOR(RAND()*10),
               'cpu.usage','mem.used','disk.iops','net.rx_bytes','net.tx_bytes',
               'temp.celsius','humidity.pct','pressure.hpa','voltage.v','current.a'),
           ROUND(RAND()*1000,4),
           ELT(1+FLOOR(RAND()*6),'%','bytes','ms','C','V','A'),
           FLOOR(RAND()*3),
           CONCAT('site=',FLOOR(RAND()*500),',rack=',FLOOR(RAND()*50),
                  ',env=',ELT(1+FLOOR(RAND()*3),'prod','staging','dev'),
                  ',dc=',ELT(1+FLOOR(RAND()*4),'us-east','eu-west','sa-east','ap')),
           DATE_SUB(NOW(),INTERVAL FLOOR(RAND()*525600) MINUTE)
       FROM _seq100 a CROSS JOIN _seq100 b CROSS JOIN _seq100 c
       LIMIT 100000;"
    echo "  sensor_data batch $i/$BATCHES ($(( i * 100000 )) rows inserted)"
done
M "SELECT COUNT(*) AS sensor_data_total FROM sensor_data;"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TABLE 4: documents — 60 batches x 10K = 600K rows (~1.5GB)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[4/4] Creating documents table..."
M "DROP TABLE IF EXISTS documents;"
M "CREATE TABLE documents (
    id           BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    doc_uuid     CHAR(36)        NOT NULL,
    title        VARCHAR(200)    NOT NULL,
    category     VARCHAR(50)     NOT NULL,
    author       VARCHAR(100)    NOT NULL,
    department   VARCHAR(80)     NOT NULL,
    body         TEXT            NOT NULL,
    summary      VARCHAR(500)    NOT NULL,
    keywords     VARCHAR(300)    NOT NULL,
    language     CHAR(5)         NOT NULL DEFAULT 'pt-BR',
    revision     SMALLINT        NOT NULL DEFAULT 1,
    word_count   INT UNSIGNED    NOT NULL,
    is_published TINYINT(1)      NOT NULL DEFAULT 1,
    created_at   DATETIME        NOT NULL,
    updated_at   DATETIME        NOT NULL,
    INDEX idx_category  (category),
    INDEX idx_author    (author),
    INDEX idx_published (is_published,created_at)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;"

BATCHES=60
for i in $(seq 1 $BATCHES); do
    M "INSERT INTO documents
           (doc_uuid,title,category,author,department,
            body,summary,keywords,language,revision,
            word_count,is_published,created_at,updated_at)
       SELECT
           UUID(),
           CONCAT(ELT(1+FLOOR(RAND()*6),
               'Relatorio','Analise','Guia','Manual','Politica','Procedimento'),
               ' ',MD5(RAND())),
           ELT(1+FLOOR(RAND()*8),
               'financeiro','juridico','ti','rh','operacoes',
               'marketing','compliance','auditoria'),
           CONCAT(ELT(1+FLOOR(RAND()*5),'Joao','Maria','Pedro','Ana','Carlos'),
                  ' ',
                  ELT(1+FLOOR(RAND()*5),'Silva','Santos','Oliveira','Souza','Lima')),
           CONCAT(ELT(1+FLOOR(RAND()*4),'Departamento de ','Setor de ','Gerencia de ','Nucleo de '),
                  ELT(1+FLOOR(RAND()*5),'TI','Financas','RH','Operacoes','Compliance')),
           CONCAT(REPEAT('Lorem ipsum dolor sit amet consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam quis nostrud exercitation ullamco laboris. ',12),MD5(RAND())),
           CONCAT('Resumo do documento ',UUID(),' ',REPEAT('resumo executivo ',20)),
           CONCAT(MD5(RAND()),' compliance risco auditoria ',
                  ELT(1+FLOOR(RAND()*4),'fiscal','legal','operacional','estrategico')),
           ELT(1+FLOOR(RAND()*3),'pt-BR','en-US','es-AR'),
           FLOOR(1+RAND()*10),
           FLOOR(500+RAND()*4500),
           IF(RAND()>0.1,1,0),
           DATE_SUB(NOW(),INTERVAL FLOOR(RAND()*730) DAY),
           DATE_SUB(NOW(),INTERVAL FLOOR(RAND()*365) DAY)
       FROM _seq100 a CROSS JOIN _seq100 b
       LIMIT 10000;"
    echo "  documents batch $i/$BATCHES ($(( i * 10000 )) rows inserted)"
done
M "SELECT COUNT(*) AS documents_total FROM documents;"

# ── cleanup ───────────────────────────────────────────────────
M "DROP TABLE _seq100;"

# ── final summary ─────────────────────────────────────────────
echo ""
echo "=== FINAL SUMMARY ==="
M "SELECT
    table_name,
    FORMAT(table_rows,0)                                              AS est_rows,
    CONCAT(ROUND((data_length+index_length)/1024/1024/1024,2),' GB') AS size
   FROM information_schema.tables
   WHERE table_schema='$DB'
     AND table_name IN ('transactions','events_log','sensor_data','documents')
   ORDER BY (data_length+index_length) DESC;"

M "SELECT CONCAT(ROUND(SUM(data_length+index_length)/1024/1024/1024,2),' GB') AS total_size
   FROM information_schema.tables
   WHERE table_schema='$DB';"

echo ""
echo "=== DONE: $(date) ==="
echo "Log: $LOG"
