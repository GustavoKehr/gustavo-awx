#!/usr/bin/env bash
# uninstall_postgres.sh — full PostgreSQL removal + LVM cleanup
set -euo pipefail

if [[ "${1:-}" != "--confirm" ]]; then
  echo "Usage: $0 --confirm"
  echo "WARNING: destroys PostgreSQL, /data, /postgres_temp and all LVM volumes."
  exit 1
fi

echo "[1/7] Stopping PostgreSQL..."
systemctl stop postgresql  2>/dev/null || true
systemctl disable postgresql 2>/dev/null || true

echo "[2/7] Removing packages..."
if command -v dnf &>/dev/null; then
  dnf remove -y postgresql-server postgresql python3-psycopg2 2>/dev/null || true
else
  apt-get purge -y postgresql postgresql-contrib python3-psycopg2 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
fi

echo "[3/7] Removing data directories..."
rm -rf /var/lib/pgsql /etc/postgresql

echo "[4/7] Unmounting /data and /postgres_temp..."
umount /data          2>/dev/null || true
umount /postgres_temp 2>/dev/null || true

echo "[5/7] Removing fstab entries..."
sed -i '/\/data/d'          /etc/fstab
sed -i '/\/postgres_temp/d' /etc/fstab

echo "[6/7] Removing LVM volumes..."
lvremove -f /dev/vg_data/lv_data                       2>/dev/null || true
vgremove -f vg_data                                    2>/dev/null || true
lvremove -f /dev/vg_postgres_temp/lv_postgres_temp     2>/dev/null || true
vgremove -f vg_postgres_temp                           2>/dev/null || true

echo "[7/7] Removing mount point directories..."
rm -rf /data /postgres_temp

echo ""
echo "Done. PostgreSQL fully removed. Reboot recommended."
