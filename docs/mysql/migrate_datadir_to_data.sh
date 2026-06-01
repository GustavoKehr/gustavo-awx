#!/bin/bash
# ============================================================
# migrate_datadir_to_data.sh
# Moves MySQL datadir from /var/lib/mysql to /data/mysql
# Handles SELinux, config files, fstab, LVM if needed
# Run as root on mysqlvm
# ============================================================
set -euo pipefail

OLD_DIR="/var/lib/mysql"
NEW_DIR="/data/mysql"
DISK="/dev/sdb"
VG="datavg"
LV="datalv"
MOUNT="/data"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo "=============================================="
echo " MySQL datadir migration -> /data/mysql"
echo "=============================================="

# ── 1. Check disk / LVM ───────────────────────────────────────
echo ""
echo "=== [1/7] Checking /data mount ==="
if mountpoint -q "$MOUNT"; then
    log "$MOUNT already mounted"
    df -h "$MOUNT"
else
    warn "$MOUNT not mounted — setting up LVM on $DISK"

    # Check disk exists
    [ -b "$DISK" ] || die "$DISK not found"

    # PV
    if ! pvs "$DISK" &>/dev/null; then
        pvcreate "$DISK"
        log "PV created on $DISK"
    else
        log "PV already exists on $DISK"
    fi

    # VG
    if ! vgs "$VG" &>/dev/null; then
        vgcreate "$VG" "$DISK"
        log "VG $VG created"
    else
        log "VG $VG already exists"
    fi

    # LV
    if ! lvs "$VG/$LV" &>/dev/null; then
        lvcreate -l 100%FREE -n "$LV" "$VG"
        log "LV $LV created"
        mkfs.xfs "/dev/$VG/$LV"
        log "XFS formatted"
    else
        log "LV $LV already exists"
    fi

    # Mount
    mkdir -p "$MOUNT"
    mount "/dev/$VG/$LV" "$MOUNT"
    log "$MOUNT mounted"

    # fstab
    FSTAB_ENTRY="/dev/$VG/$LV  $MOUNT  xfs  defaults  0 0"
    if ! grep -q "$MOUNT" /etc/fstab; then
        echo "$FSTAB_ENTRY" >> /etc/fstab
        log "fstab entry added"
    fi
fi

# ── 2. Stop MySQL ─────────────────────────────────────────────
echo ""
echo "=== [2/7] Stopping MySQL ==="
systemctl stop mysqld || warn "MySQL was already stopped"
log "MySQL stopped"

# ── 3. Copy data ──────────────────────────────────────────────
echo ""
echo "=== [3/7] Copying data to $NEW_DIR ==="
mkdir -p "$NEW_DIR"
rsync -aH --info=progress2 "$OLD_DIR/" "$NEW_DIR/"
log "Data copied to $NEW_DIR"

# ── 4. Fix ownership ──────────────────────────────────────────
echo ""
echo "=== [4/7] Fixing ownership ==="
chown -R mysql:mysql "$NEW_DIR"
chmod 750 "$NEW_DIR"
log "Ownership set to mysql:mysql"

# ── 5. Fix SELinux ────────────────────────────────────────────
echo ""
echo "=== [5/7] Fixing SELinux context ==="
if command -v semanage &>/dev/null; then
    semanage fcontext -a -t mysqld_db_t "$MOUNT(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t mysqld_db_t "$MOUNT(/.*)?"
    restorecon -Rv "$MOUNT"
    log "SELinux context applied: mysqld_db_t on $MOUNT"
else
    warn "semanage not found — installing policycoreutils-python-utils"
    dnf install -y policycoreutils-python-utils
    semanage fcontext -a -t mysqld_db_t "$MOUNT(/.*)?"
    restorecon -Rv "$MOUNT"
    log "SELinux context applied"
fi

# Verify context
echo "SELinux context check:"
ls -laZ "$NEW_DIR" | head -5

# ── 6. Update MySQL config ────────────────────────────────────
echo ""
echo "=== [6/7] Updating MySQL config ==="

# Find all config files that set datadir and fix them
CONFIG_FILES=(
    /etc/my.cnf
    /etc/my.cnf.d/mysql-server.cnf
    /etc/my.cnf.d/mariadb-server.cnf
)

for cfg in "${CONFIG_FILES[@]}"; do
    if [ -f "$cfg" ] && grep -q "datadir" "$cfg"; then
        sed -i "s|datadir\s*=.*|datadir=$NEW_DIR|g" "$cfg"
        log "Updated datadir in $cfg"
        grep "datadir" "$cfg"
    fi
done

# If no config has datadir, add it to main config
if ! grep -rq "datadir" /etc/my.cnf /etc/my.cnf.d/ 2>/dev/null; then
    echo -e "\n[mysqld]\ndatadir=$NEW_DIR" >> /etc/my.cnf
    log "Added datadir to /etc/my.cnf"
fi

# ── 7. Start MySQL and verify ─────────────────────────────────
echo ""
echo "=== [7/7] Starting MySQL ==="
systemctl start mysqld
sleep 3

if systemctl is-active --quiet mysqld; then
    log "MySQL started successfully!"
    echo ""
    echo "Verifying datadir:"
    mysql -e "SELECT @@datadir;" 2>/dev/null || \
    mysql -u root -p"$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null | tail -1 | awk '{print $NF}')" \
          -e "SELECT @@datadir;" 2>/dev/null || \
    warn "Could not verify via mysql client — check manually"
    echo ""
    log "Migration complete! datadir = $NEW_DIR"
    echo ""
    echo "Old dir still at $OLD_DIR — remove manually after confirming:"
    echo "  rm -rf $OLD_DIR"
else
    echo ""
    die "MySQL failed to start. Check logs:"
    journalctl -u mysqld --no-pager -n 30
fi
