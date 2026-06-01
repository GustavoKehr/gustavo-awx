#!/bin/bash
# ============================================================
# create_and_fill_db.sh
# Creates appdb and fills ~2-3GB of data on /data/mysql
# Uses bash loops + mysql -e (no stored procedures)
# ============================================================
MYSQL="mysql -u root -pAdmin123!"
DB="appdb"
TARGET_GB=2

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $*"; }
info() { echo -e "${YELLOW}[..] ${NC}$*"; }

echo "=============================================="
echo " Creating $DB + filling ~${TARGET_GB}GB data"
echo "=============================================="

# ── Create DB + tables ────────────────────────────────────────
$MYSQL << 'EOF'
DROP DATABASE IF EXISTS appdb;
CREATE DATABASE appdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE appdb;

-- Helper sequence table (0-999)
CREATE TABLE _seq (n INT PRIMARY KEY);

-- Main tables
CREATE TABLE customers (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    name       VARCHAR(100),
    email      VARCHAR(150),
    country    VARCHAR(60),
    phone      VARCHAR(30),
    address    TEXT,
    created_at DATETIME DEFAULT NOW(),
    updated_at DATETIME DEFAULT NOW(),
    status     TINYINT DEFAULT 1,
    score      DECIMAL(5,2),
    notes      TEXT
) ENGINE=InnoDB;

CREATE TABLE products (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    sku         VARCHAR(50) UNIQUE,
    name        VARCHAR(200),
    description TEXT,
    category    VARCHAR(100),
    price       DECIMAL(10,2),
    cost        DECIMAL(10,2),
    stock       INT DEFAULT 0,
    weight_kg   DECIMAL(6,3),
    created_at  DATETIME DEFAULT NOW(),
    active      TINYINT DEFAULT 1
) ENGINE=InnoDB;

CREATE TABLE orders (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    customer_id INT,
    product_id  INT,
    quantity    INT,
    unit_price  DECIMAL(10,2),
    total       DECIMAL(12,2),
    status      VARCHAR(30),
    notes       TEXT,
    created_at  DATETIME DEFAULT NOW(),
    shipped_at  DATETIME,
    INDEX (customer_id),
    INDEX (product_id),
    INDEX (created_at)
) ENGINE=InnoDB;

CREATE TABLE events_log (
    id         BIGINT AUTO_INCREMENT PRIMARY KEY,
    event_type VARCHAR(80),
    source     VARCHAR(100),
    message    TEXT,
    payload    JSON,
    severity   TINYINT,
    created_at DATETIME(3) DEFAULT NOW(3),
    INDEX (event_type),
    INDEX (created_at)
) ENGINE=InnoDB;

CREATE TABLE sensor_data (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    sensor_id   VARCHAR(40),
    metric      VARCHAR(60),
    value       DOUBLE,
    unit        VARCHAR(20),
    recorded_at DATETIME(3) DEFAULT NOW(3),
    INDEX (sensor_id),
    INDEX (recorded_at)
) ENGINE=InnoDB;

-- Fill sequence table
INSERT INTO _seq (n)
WITH RECURSIVE r(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM r WHERE n < 999)
SELECT n FROM r;

EOF
log "Database and tables created"

# ── Customers (~50MB) ─────────────────────────────────────────
info "Inserting customers..."
for i in $(seq 1 20); do
    $MYSQL $DB -e "
    INSERT INTO customers (name,email,country,phone,address,score,notes)
    SELECT
        CONCAT('Customer ',a.n*1000+b.n),
        CONCAT('user',a.n*1000+b.n,'@example',MOD(b.n,50),'.com'),
        ELT(1+MOD(a.n+b.n,8),'Brazil','USA','Germany','France','Japan','Argentina','Canada','UK'),
        CONCAT('+55 11 9',LPAD(FLOOR(RAND()*99999999),8,'0')),
        CONCAT(FLOOR(RAND()*9999)+1,' ',ELT(1+MOD(b.n,5),'Main St','Oak Ave','Pine Rd','Elm Blvd','Cedar Ln')),
        ROUND(RAND()*100,2),
        REPEAT(CONCAT('Note for customer ',a.n*1000+b.n,' '),8)
    FROM _seq a JOIN _seq b ON b.n < 50
    LIMIT 5000;" 2>/dev/null
    echo -n "."
done
echo ""
log "Customers: $(echo "SELECT COUNT(*) FROM customers" | $MYSQL -sN $DB)"

# ── Products (~20MB) ──────────────────────────────────────────
info "Inserting products..."
$MYSQL $DB -e "
INSERT INTO products (sku,name,description,category,price,cost,stock,weight_kg)
SELECT
    CONCAT('SKU-',LPAD(a.n*1000+b.n,8,'0')),
    CONCAT(ELT(1+MOD(a.n,10),'Widget','Gadget','Device','Module','Unit','System','Tool','Part','Component','Assembly'),
           ' Model ',CHAR(65+MOD(b.n,26)),'-',a.n*1000+b.n),
    REPEAT(CONCAT('High quality product number ',a.n*1000+b.n,' with advanced features. '),5),
    ELT(1+MOD(a.n+b.n,12),'Electronics','Mechanical','Software','Hardware','Networking','Storage','Power','Cooling','Display','Audio','Accessories','Industrial'),
    ROUND(10+RAND()*990,2),
    ROUND(5+RAND()*400,2),
    FLOOR(RAND()*1000),
    ROUND(0.1+RAND()*20,3)
FROM _seq a JOIN _seq b ON b.n < 10
LIMIT 10000;"
log "Products: $(echo "SELECT COUNT(*) FROM products" | $MYSQL -sN $DB)"

# ── Orders (~500MB) ───────────────────────────────────────────
info "Inserting orders (this takes a few minutes)..."
CUST_MAX=$($MYSQL -sN $DB -e "SELECT MAX(id) FROM customers")
PROD_MAX=$($MYSQL -sN $DB -e "SELECT MAX(id) FROM products")
for i in $(seq 1 50); do
    $MYSQL $DB -e "
    INSERT INTO orders (customer_id,product_id,quantity,unit_price,total,status,notes,created_at,shipped_at)
    SELECT
        1+MOD(a.n*1000+b.n,$CUST_MAX),
        1+MOD(a.n*37+b.n*13,$PROD_MAX),
        1+MOD(a.n+b.n,20),
        ROUND(5+RAND()*500,2),
        ROUND((1+MOD(a.n+b.n,20))*(5+RAND()*500),2),
        ELT(1+MOD(a.n*3+b.n,5),'pending','processing','shipped','delivered','cancelled'),
        REPEAT(CONCAT('Order note batch $i item ',b.n,' '),4),
        DATE_SUB(NOW(), INTERVAL MOD(a.n*7+b.n,365) DAY),
        IF(MOD(a.n+b.n,3)=0, DATE_SUB(NOW(), INTERVAL MOD(a.n+b.n,30) DAY), NULL)
    FROM _seq a JOIN _seq b ON 1=1
    LIMIT 100000;" 2>/dev/null
    echo -n "."
done
echo ""
log "Orders: $(echo "SELECT COUNT(*) FROM orders" | $MYSQL -sN $DB)"

# ── Events log (~800MB) ───────────────────────────────────────
info "Inserting events_log (bulk batches)..."
for i in $(seq 1 40); do
    $MYSQL $DB -e "
    INSERT INTO events_log (event_type,source,message,payload,severity)
    SELECT
        ELT(1+MOD(a.n+b.n,8),'login','logout','error','warning','info','purchase','api_call','system'),
        CONCAT('service-',MOD(a.n,20)),
        CONCAT('Event message number ',a.n*1000+b.n,' from source service-',MOD(a.n,20),' at batch $i'),
        JSON_OBJECT('batch','$i','seq',a.n*1000+b.n,'host',CONCAT('host-',MOD(b.n,10)),'code',MOD(a.n+b.n,500)),
        1+MOD(a.n+b.n,5)
    FROM _seq a JOIN _seq b ON 1=1
    LIMIT 100000;" 2>/dev/null
    echo -n "."
done
echo ""
log "Events: $(echo "SELECT COUNT(*) FROM events_log" | $MYSQL -sN $DB)"

# ── Sensor data (~1GB) ────────────────────────────────────────
info "Inserting sensor_data (largest table)..."
for i in $(seq 1 60); do
    $MYSQL $DB -e "
    INSERT INTO sensor_data (sensor_id,metric,value,unit)
    SELECT
        CONCAT('sensor-',LPAD(MOD(a.n*7+b.n,200),4,'0')),
        ELT(1+MOD(a.n+b.n,6),'temperature','humidity','pressure','voltage','current','rpm'),
        ROUND(-50+RAND()*150,4),
        ELT(1+MOD(a.n+b.n,6),'C','%','hPa','V','A','rpm')
    FROM _seq a JOIN _seq b ON 1=1
    LIMIT 100000;" 2>/dev/null
    echo -n "."
done
echo ""
log "Sensors: $(echo "SELECT COUNT(*) FROM sensor_data" | $MYSQL -sN $DB)"

# ── Final report ──────────────────────────────────────────────
echo ""
echo "=== RESULTS ==="
$MYSQL $DB -e "
SELECT
    table_name,
    FORMAT(table_rows,0) AS rows_est,
    ROUND((data_length+index_length)/1024/1024,1) AS size_mb
FROM information_schema.tables
WHERE table_schema='appdb' AND table_name != '_seq'
ORDER BY data_length+index_length DESC;"

$MYSQL $DB -e "
SELECT ROUND(SUM(data_length+index_length)/1024/1024/1024,2) AS total_gb
FROM information_schema.tables WHERE table_schema='appdb';"

echo ""
log "Done! Data on: $(mysql -u root -pAdmin123! -sN -e 'SELECT @@datadir;' 2>/dev/null)"
echo "=============================================="
