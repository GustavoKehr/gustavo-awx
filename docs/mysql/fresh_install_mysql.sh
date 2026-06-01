#!/bin/bash
# ============================================================
# fresh_install_mysql.sh
# Full wipe + fresh MySQL install with datadir on /data
# Creates zbx_odbc user for Zabbix ODBC monitoring
# Run as root on mysqlvm
# ============================================================
set -euo pipefail

DISK="/dev/sdb"
VG="vg_data"
LV="datalv"
MOUNT="/data"
NEW_DATADIR="/data/mysql"
MYSQL_ROOT_PASS="Admin123!"      # change if desired
ZBX_USER="zbx_odbc"
ZBX_PASS="password"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo "=============================================="
echo " MySQL Fresh Install -> datadir: $NEW_DATADIR"
echo "=============================================="

# ── 1. Wipe MySQL completely ──────────────────────────────────
echo ""
echo "=== [1/8] Removing existing MySQL ==="
systemctl stop mysqld 2>/dev/null || true
systemctl stop mysql  2>/dev/null || true

dnf remove -y mysql-server mysql mysql-common mysql-community-server \
    mysql-community-client mysql-community-common \
    mariadb mariadb-server 2>/dev/null || true

# Remove all data and configs
rm -rf /var/lib/mysql
rm -rf /etc/my.cnf /etc/my.cnf.d/
rm -rf /var/log/mysql* /var/log/mysqld.log
rm -f  /var/run/mysqld/mysqld.pid
log "MySQL wiped"

# ── 2. Setup LVM + /data ──────────────────────────────────────
echo ""
echo "=== [2/8] Setting up /data on $DISK ==="

# Wipe existing LVM if present
if vgs "$VG" &>/dev/null; then
    warn "Existing VG $VG found — wiping"
    umount "$MOUNT" 2>/dev/null || true
    lvremove -fy "$VG/$LV" 2>/dev/null || true
    vgremove -fy "$VG"     2>/dev/null || true
    pvremove -fy "$DISK"   2>/dev/null || true
fi

wipefs -a "$DISK"
pvcreate "$DISK"
vgcreate "$VG" "$DISK"
lvcreate -l 100%FREE -n "$LV" "$VG"
mkfs.xfs "/dev/$VG/$LV"
log "LVM created: $VG/$LV"

mkdir -p "$MOUNT"
mount "/dev/$VG/$LV" "$MOUNT"
log "$MOUNT mounted"

# fstab
sed -i "\|$MOUNT|d" /etc/fstab
echo "/dev/$VG/$LV  $MOUNT  xfs  defaults  0 0" >> /etc/fstab
log "fstab updated"

# ── 3. Install MySQL ──────────────────────────────────────────
echo ""
echo "=== [3/8] Installing MySQL ==="

# Add MySQL 8.0 repo if not present
if ! rpm -q mysql80-community-release &>/dev/null; then
    dnf install -y https://dev.mysql.com/get/mysql80-community-release-el9-1.noarch.rpm 2>/dev/null || \
    dnf install -y https://dev.mysql.com/get/mysql80-community-release-el8-1.noarch.rpm 2>/dev/null || \
    true
fi

dnf install -y mysql-server 2>/dev/null || \
dnf install -y --nogpgcheck mysql-community-server 2>/dev/null || \
dnf install -y --disablerepo=* --enablerepo=mysql80-community --nogpgcheck mysql-community-server 2>/dev/null || \
die "Could not install MySQL — check repo"

log "MySQL installed"

# ── 4. Configure datadir before first start ───────────────────
echo ""
echo "=== [4/8] Configuring datadir ==="

mkdir -p "$NEW_DATADIR"
chown mysql:mysql "$NEW_DATADIR"
chmod 750 "$NEW_DATADIR"

# SELinux
if command -v semanage &>/dev/null; then
    semanage fcontext -a -t mysqld_db_t "$MOUNT(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t mysqld_db_t "$MOUNT(/.*)?"
else
    dnf install -y policycoreutils-python-utils
    semanage fcontext -a -t mysqld_db_t "$MOUNT(/.*)?"
fi
restorecon -Rv "$MOUNT"
log "SELinux context set: mysqld_db_t"

# Write config
cat > /etc/my.cnf << EOF
[mysqld]
datadir=$NEW_DATADIR
socket=/var/lib/mysql/mysql.sock
log-error=/var/log/mysqld.log
pid-file=/var/run/mysqld/mysqld.pid

# Performance
innodb_buffer_pool_size=512M
innodb_log_file_size=128M
max_connections=200

# Logging
slow_query_log=1
slow_query_log_file=/var/log/mysql-slow.log
long_query_time=2

[client]
socket=/var/lib/mysql/mysql.sock
EOF

# Socket dir needs to exist
mkdir -p /var/lib/mysql
chown mysql:mysql /var/lib/mysql
restorecon -Rv /var/lib/mysql 2>/dev/null || true

log "Config written to /etc/my.cnf"

# ── 5. Initialize + start MySQL ───────────────────────────────
echo ""
echo "=== [5/8] Initializing MySQL ==="
mysqld --initialize --user=mysql --datadir="$NEW_DATADIR"
log "MySQL initialized"

systemctl enable mysqld
systemctl start mysqld
sleep 5
systemctl is-active --quiet mysqld || die "MySQL failed to start — check: journalctl -u mysqld -n 50"
log "MySQL started"

# ── 6. Set root password ──────────────────────────────────────
echo ""
echo "=== [6/8] Setting root password ==="
TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log | tail -1 | awk '{print $NF}')
log "Temp password: $TEMP_PASS"

mysql --connect-expired-password -u root -p"$TEMP_PASS" << EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
EOF
log "Root password set to: $MYSQL_ROOT_PASS"

# Helper alias for rest of script
MYSQL="mysql -u root -p${MYSQL_ROOT_PASS}"

# ── 7. Create zbx_odbc user + grants ─────────────────────────
echo ""
echo "=== [7/8] Creating zbx_odbc user ==="
$MYSQL << EOF
-- Allow connection from Zabbix server (any host)
CREATE USER IF NOT EXISTS '${ZBX_USER}'@'%'         IDENTIFIED BY '${ZBX_PASS}';
CREATE USER IF NOT EXISTS '${ZBX_USER}'@'localhost'  IDENTIFIED BY '${ZBX_PASS}';

-- Required for ODBC monitoring queries
GRANT SELECT, PROCESS, REPLICATION CLIENT ON *.* TO '${ZBX_USER}'@'%';
GRANT SELECT, PROCESS, REPLICATION CLIENT ON *.* TO '${ZBX_USER}'@'localhost';

-- Required for information_schema queries
GRANT SELECT ON performance_schema.* TO '${ZBX_USER}'@'%';
GRANT SELECT ON performance_schema.* TO '${ZBX_USER}'@'localhost';

FLUSH PRIVILEGES;
EOF
log "User '$ZBX_USER'@'%' created with password '$ZBX_PASS'"

# ── 8. Create appdb + verify ──────────────────────────────────
echo ""
echo "=== [8/8] Creating appdb + verifying ==="
$MYSQL << EOF
CREATE DATABASE IF NOT EXISTS appdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE appdb;
CREATE TABLE IF NOT EXISTS customers (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100),
    email VARCHAR(150),
    created_at DATETIME DEFAULT NOW()
);
INSERT INTO customers (name, email) VALUES
    ('Test User 1', 'test1@example.com'),
    ('Test User 2', 'test2@example.com'),
    ('Test User 3', 'test3@example.com');
EOF
log "appdb created with sample data"

echo ""
echo "=== VERIFICATION ==="
$MYSQL -e "SELECT @@datadir, @@version;"
$MYSQL -e "SELECT user, host FROM mysql.user WHERE user='${ZBX_USER}';"
$MYSQL -e "SHOW GRANTS FOR '${ZBX_USER}'@'%';"
$MYSQL -e "SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,2) AS size_mb FROM information_schema.tables GROUP BY table_schema;"

echo ""
echo "=============================="
log "DONE! MySQL fresh install complete"
echo ""
echo "  datadir  : $NEW_DATADIR"
echo "  root pass: $MYSQL_ROOT_PASS"
echo "  zbx_odbc : $ZBX_USER / $ZBX_PASS (from any host)"
echo ""
echo "Test ODBC connection:"
echo "  isql -v mysqlvm $ZBX_USER '$ZBX_PASS'"
echo "=============================="
