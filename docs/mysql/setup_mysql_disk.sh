#!/bin/bash
# setup_mysql_disk.sh
# Creates LVM on /dev/sdb, mounts /data, moves MySQL datadir, creates test DB with data
# Run as root

set -euo pipefail

DISK="/dev/sdb"
VG_NAME="vg_data"
LV_NAME="lv_mysql"
MOUNT_POINT="/data"
DB_NAME="appdb"
DB_USER="appuser"
DB_PASS="AppPass1!"

echo "=== [1/7] Creating PV on $DISK ==="
pvcreate "$DISK"
pvs "$DISK"

echo ""
echo "=== [2/7] Creating VG: $VG_NAME ==="
vgcreate "$VG_NAME" "$DISK"
vgs "$VG_NAME"

echo ""
echo "=== [3/7] Creating LV: $LV_NAME (100% of VG) ==="
lvcreate -l 100%FREE -n "$LV_NAME" "$VG_NAME"
lvs "/dev/$VG_NAME/$LV_NAME"

echo ""
echo "=== [4/7] Formatting XFS and mounting $MOUNT_POINT ==="
mkfs.xfs "/dev/$VG_NAME/$LV_NAME"
mkdir -p "$MOUNT_POINT"
mount "/dev/$VG_NAME/$LV_NAME" "$MOUNT_POINT"

# Persist in fstab
UUID=$(blkid -s UUID -o value "/dev/$VG_NAME/$LV_NAME")
echo "UUID=$UUID  $MOUNT_POINT  xfs  defaults  0 0" >> /etc/fstab
echo "Mounted $MOUNT_POINT (UUID=$UUID)"
df -h "$MOUNT_POINT"

echo ""
echo "=== [5/7] Moving MySQL datadir to $MOUNT_POINT ==="
systemctl stop mysqld 2>/dev/null || systemctl stop mysql 2>/dev/null || true

# Copy existing datadir
rsync -av /var/lib/mysql/ "$MOUNT_POINT/"
chown -R mysql:mysql "$MOUNT_POINT"
chmod 750 "$MOUNT_POINT"

# Update MySQL config
CONFIG_FILE=""
for f in /etc/my.cnf /etc/mysql/my.cnf /etc/mysql/mysql.conf.d/mysqld.cnf; do
    [ -f "$f" ] && CONFIG_FILE="$f" && break
done

if [ -n "$CONFIG_FILE" ]; then
    # Backup and update datadir
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    if grep -q "^datadir" "$CONFIG_FILE"; then
        sed -i "s|^datadir.*|datadir=$MOUNT_POINT|" "$CONFIG_FILE"
    else
        sed -i "/\[mysqld\]/a datadir=$MOUNT_POINT" "$CONFIG_FILE"
    fi
    echo "Updated datadir in $CONFIG_FILE"
else
    # Create override
    mkdir -p /etc/my.cnf.d/
    echo -e "[mysqld]\ndatadir=$MOUNT_POINT" > /etc/my.cnf.d/datadir.cnf
    echo "Created /etc/my.cnf.d/datadir.cnf"
fi

# SELinux context if applicable
if command -v semanage &>/dev/null; then
    semanage fcontext -a -t mysqld_db_t "$MOUNT_POINT(/.*)?"
    restorecon -Rv "$MOUNT_POINT"
fi

systemctl start mysqld 2>/dev/null || systemctl start mysql 2>/dev/null
sleep 3
echo "MySQL started. Datadir: $(mysql -e 'SELECT @@datadir;' 2>/dev/null || echo 'check manually')"

echo ""
echo "=== [6/7] Creating database and user ==="
mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';
FLUSH PRIVILEGES;
EOF

echo ""
echo "=== [7/7] Creating tables and inserting sample data ==="
mysql "$DB_NAME" <<'EOF'
-- Customers table
CREATE TABLE IF NOT EXISTS customers (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    email       VARCHAR(150) UNIQUE NOT NULL,
    country     VARCHAR(50),
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Products table
CREATE TABLE IF NOT EXISTS products (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    sku         VARCHAR(50) UNIQUE NOT NULL,
    name        VARCHAR(200) NOT NULL,
    price       DECIMAL(10,2) NOT NULL,
    stock       INT DEFAULT 0,
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Orders table
CREATE TABLE IF NOT EXISTS orders (
    id           INT AUTO_INCREMENT PRIMARY KEY,
    customer_id  INT NOT NULL,
    product_id   INT NOT NULL,
    quantity     INT NOT NULL DEFAULT 1,
    total        DECIMAL(10,2) NOT NULL,
    status       ENUM('pending','processing','shipped','delivered','cancelled') DEFAULT 'pending',
    ordered_at   DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    FOREIGN KEY (product_id)  REFERENCES products(id)
);

-- Sample customers
INSERT INTO customers (name, email, country) VALUES
  ('Alice Silva',    'alice@example.com',   'Brazil'),
  ('Bob Santos',     'bob@example.com',     'Brazil'),
  ('Carol Oliveira', 'carol@example.com',   'Portugal'),
  ('David Lima',     'david@example.com',   'Brazil'),
  ('Eva Costa',      'eva@example.com',     'Argentina'),
  ('Frank Rocha',    'frank@example.com',   'Brazil'),
  ('Gabi Melo',      'gabi@example.com',    'Brazil'),
  ('Hugo Neves',     'hugo@example.com',    'Uruguay'),
  ('Iris Campos',    'iris@example.com',    'Brazil'),
  ('Jorge Dias',     'jorge@example.com',   'Portugal');

-- Sample products
INSERT INTO products (sku, name, price, stock) VALUES
  ('SKU-001', 'Notebook Pro 15',        4999.99,  50),
  ('SKU-002', 'Mouse Wireless',           89.90,  200),
  ('SKU-003', 'Teclado Mecânico',        349.00,  80),
  ('SKU-004', 'Monitor 27" 4K',         2199.00,  30),
  ('SKU-005', 'SSD 1TB NVMe',            599.00, 120),
  ('SKU-006', 'Headset USB',             249.90,  60),
  ('SKU-007', 'Webcam Full HD',          189.90,  90),
  ('SKU-008', 'Hub USB-C 7-in-1',        129.00, 150),
  ('SKU-009', 'Cadeira Gamer',          1499.00,  25),
  ('SKU-010', 'Mesa para Escritório',    899.00,  15);

-- Sample orders
INSERT INTO orders (customer_id, product_id, quantity, total, status) VALUES
  (1, 1, 1, 4999.99, 'delivered'),
  (1, 2, 2,  179.80, 'delivered'),
  (2, 3, 1,  349.00, 'shipped'),
  (3, 4, 1, 2199.00, 'processing'),
  (4, 5, 2, 1198.00, 'delivered'),
  (5, 6, 1,  249.90, 'pending'),
  (6, 7, 1,  189.90, 'shipped'),
  (7, 8, 3,  387.00, 'delivered'),
  (8, 9, 1, 1499.00, 'processing'),
  (9, 10,1,  899.00, 'pending'),
  (10,1, 1, 4999.99, 'delivered'),
  (2, 5, 1,  599.00, 'shipped'),
  (3, 2, 4,  359.60, 'delivered'),
  (4, 6, 2,  499.80, 'pending'),
  (5, 3, 1,  349.00, 'delivered');

SELECT 'customers' AS tbl, COUNT(*) AS total FROM customers
UNION ALL
SELECT 'products',          COUNT(*)          FROM products
UNION ALL
SELECT 'orders',            COUNT(*)          FROM orders;
EOF

echo ""
echo "=== DONE ==="
echo "  Disk:       $DISK -> /dev/$VG_NAME/$LV_NAME"
echo "  Mount:      $MOUNT_POINT"
echo "  MySQL DB:   $DB_NAME"
echo "  DB User:    $DB_USER / $DB_PASS"
df -h "$MOUNT_POINT"
