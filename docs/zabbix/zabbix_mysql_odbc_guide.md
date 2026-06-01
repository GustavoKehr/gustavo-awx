# Zabbix ODBC Monitoring — MySQL

> Setup guide for MySQL monitoring via ODBC in Zabbix 7.x.
> Uses MariaDB Connector/ODBC driver with named DSN.

---

## Files needed

| File | Use |
|------|-----|
| `template_mysql.yaml` | Import in Zabbix — 43 ODBC items, 9 triggers, 3 macros |

---

## Architecture

```
Zabbix Server (Linux)
  │
  └── UnixODBC → libmaodbc.so (MariaDB Connector/ODBC)
        │
        └──[TCP 3306]──► MySQL server
                         Named DSN: mysql_work
```

**Key point:** ODBC items execute on the **Zabbix server**, not the agent.
Drivers and DSN config must be on the Zabbix server machine.

---

## Step 1 — Install packages on Zabbix Server

```bash
# UnixODBC base
dnf install -y unixODBC unixODBC-devel

# Verify
odbcinst -j
# DRIVERS............: /etc/odbcinst.ini
# SYSTEM DATA SOURCES: /etc/odbc.ini
```

```bash
# MariaDB Connector/ODBC
# Option A — via repo (if MariaDB repo configured):
dnf install -y MariaDB-connector-odbc

# Option B — download RPM from:
# https://mariadb.com/downloads/connectors/connector-odbc/
# Example:
rpm -ivh mariadb-connector-odbc-3.x.x-rhel8-amd64.rpm

# Verify install
ls /usr/lib64/libmaodbc.so
# or:
ls /usr/lib/x86_64-linux-gnu/libmaodbc.so
```

---

## Step 2 — Register MariaDB driver in /etc/odbcinst.ini

```ini
# /etc/odbcinst.ini

[MariaDB ODBC 3.x Driver]
Description = MariaDB Connector/ODBC
Driver      = /usr/lib64/libmaodbc.so
Setup       =
FileUsage   = 1
```

```bash
# Register and verify
odbcinst -q -d
# Should show: [MariaDB ODBC 3.x Driver]
```

> **Note:** Driver path may differ. Check with `rpm -ql MariaDB-connector-odbc | grep .so` or `find /usr -name 'libmaodbc.so' 2>/dev/null`.

---

## Step 3 — Create named DSN in /etc/odbc.ini

MySQL uses a **named DSN** — unlike Oracle (DSN-less), MySQL items reference a DSN name.

```ini
# /etc/odbc.ini

[mysql_work]
Description = MySQL Production
Driver      = MariaDB ODBC 3.x Driver
SERVER      = 192.168.1.60
PORT        = 3306
DATABASE    = information_schema
OPTION      = 67108864
```

| Field | Notes |
|-------|-------|
| `[mysql_work]` | This name goes in `{$MYSQL.DSN}` macro — must match exactly |
| `SERVER` | MySQL server IP or FQDN |
| `PORT` | Default 3306 |
| `DATABASE` | Use `information_schema` — always exists, monitoring queries hit perf_schema |
| `OPTION` | `67108864` = `CLIENT_MULTI_STATEMENTS` flag |

---

## Step 4 — Create zbx_odbc user in MySQL

Connect to MySQL as root or DBA:

```sql
CREATE USER 'zbx_odbc'@'%' IDENTIFIED BY 'StrongPassword1!';
GRANT USAGE ON *.* TO 'zbx_odbc'@'%';
GRANT REPLICATION CLIENT ON *.* TO 'zbx_odbc'@'%';
GRANT PROCESS ON *.* TO 'zbx_odbc'@'%';
GRANT SELECT ON performance_schema.* TO 'zbx_odbc'@'%';
GRANT SELECT ON information_schema.* TO 'zbx_odbc'@'%';
GRANT SELECT ON mysql.user TO 'zbx_odbc'@'%';
FLUSH PRIVILEGES;
```

> `mysql.user` grant required for "Users Without Password" security check item.

---

## Step 5 — Test connection from Zabbix server

```bash
# Basic connection test
isql -v mysql_work zbx_odbc "StrongPassword1!"
# If OK: shows SQL prompt
# Type: SELECT VERSION();
# Expected: MySQL version string
```

```bash
# One-liner test
isql -v mysql_work zbx_odbc "StrongPassword1!" <<< "SELECT VERSION();"
# Expected output: | 8.0.xx |
```

```bash
# Verify performance_schema access (template uses this heavily)
isql -v mysql_work zbx_odbc "StrongPassword1!" \
  <<< "SELECT COUNT(*) FROM performance_schema.threads;"
# Expected: numeric count, no error
```

---

## Step 6 — Import template in Zabbix

### Where to get the file

File: `template_mysql.yaml`  
Contains: MySQL Comprehensive Monitoring template — 43 ODBC items, 9 triggers, 3 macros, 3-page dashboard ("MySQL Monitoring")

### Import steps

```
1. Zabbix UI → Configuration → Templates
2. Click "Import" button (top-right corner)
3. Choose file: template_mysql.yaml
4. Import rules — keep defaults:
     ✓ createMissing   (creates new objects that don't exist yet)
     ✓ updateExisting  (updates if template already imported before)
     ✗ deleteMissing   (leave unchecked — would delete items not in file)
5. Click "Import"
6. Wait for success message: "Imported successfully"
```

### What gets imported

| Object | Count | Notes |
|--------|-------|-------|
| Template | 1 | "MySQL Comprehensive Monitoring" |
| Items | 43 | All ODBC via `db.odbc.select` |
| Triggers | 9 | High aborted rate, buffer pool low, deadlocks, etc. |
| Macros | 3 | `{$MYSQL.DSN}`, `{$MYSQL.USER}`, `{$MYSQL.PASSWORD}` |
| Graphs | 11 | Connections, InnoDB, DML, Network, Locks, Temp tables, etc. |
| Dashboard | 1 | "MySQL Monitoring" — 3 pages, 11 graphs |

### Dashboard pages included

| Page | Graphs |
|------|--------|
| Connections & Queries | Connections, Query Rates, DML Operations, Network Traffic |
| InnoDB & Transactions | Buffer Pool, InnoDB Contention, Transactions & Locks, Dirty & Log, Pending I/O |
| Storage & Security | Temp Tables & Open Objects, Connections & Security |

### After import — verify

```
Configuration → Templates
  → Search: MySQL
  → Should show: "MySQL Comprehensive Monitoring"
  → Click template name → Items tab → confirm 43 items listed
```

> **Note:** The dashboard ("MySQL Monitoring") appears under  
> `Monitoring → Hosts → [your host] → Dashboards`  
> only after you link the template to a host and the host collects data.

---

## Step 7 — Create host in Zabbix

```
Configuration → Hosts → Create host

  Host name:  your-mysql-server-name
  Groups:     Databases  (or any group)
  Interfaces: Agent type — IP of MySQL server, port 10050
              (needed for agent items like ping/uptime; ODBC items ignore interface)
  Templates:  MySQL Comprehensive Monitoring
```

Then go to **Macros** tab and set:

| Macro | Value | Type | Notes |
|-------|-------|------|-------|
| `{$MYSQL.DSN}` | `mysql_work` | Text | Must match entry name in `/etc/odbc.ini` exactly |
| `{$MYSQL.USER}` | `zbx_odbc` | Text | |
| `{$MYSQL.PASSWORD}` | `StrongPassword1!` | Secret text | |

Click **Add** → **Update**.

---

## Step 8 — Verify collection

```
Monitoring → Hosts → your-mysql-server
  → Latest data
  → Filter by: MySQL

Wait ~2 minutes. Items should show values, not errors.
```

Expected working items:
- `Threads running`, `Threads connected` — numeric
- `Buffer pool hit rate %` — percentage value
- `Slow queries` — counter
- `Com_select / Com_insert / Com_update / Com_delete` — counters
- `InnoDB row lock waits`, `Deadlocks` — counters
- `Server uptime` — seconds since last restart

---

## Connection string reference

MySQL uses **named DSN** — DSN name goes in the item key:

```
db.odbc.select[threads_running,"{$MYSQL.DSN}"]
```

After macro expansion at collection time:
```
db.odbc.select[threads_running,"mysql_work"]
```

Zabbix looks up `mysql_work` in `/etc/odbc.ini` → connects via MariaDB driver.

### DSN-less alternative (optional)

If you don't want a `/etc/odbc.ini` entry, embed connection string directly:

```
db.odbc.select[key,,"Driver=MariaDB ODBC 3.x Driver;SERVER=192.168.1.60;PORT=3306;DATABASE=information_schema;"]
```

Template uses named DSN approach — no changes needed if DSN is configured.

---

## What the template collects

**Connections**
- Threads running, connected, max connections, connection usage %
- Aborted clients/s, aborted connects/s
- Max used connections

**InnoDB Buffer Pool**
- Hit rate %, free %, dirty pages %, pending reads/writes
- Buffer pool read requests, reads (physical)

**Queries**
- Com_select, Com_insert, Com_update, Com_delete (cumulative)
- Slow queries (count)
- Full table scans (select_scan)
- Long running queries (>60s active)

**Locks & Transactions**
- InnoDB row lock waits, deadlocks
- Active transactions, idle transactions (SLEEP state)
- Metadata lock waits, table locks waited

**I/O & Network**
- Bytes received/s, bytes sent/s
- Open tables, tmp tables created on disk

**Storage**
- Schema count, total DB size (MB), fragmentation (MB)

**Security**
- Users without password (security check item)
- Binlog enabled status

**Server**
- Server uptime
- MySQL version

**Triggers (9):** High aborted rate, buffer pool low, too many connections, slow query spike, deadlocks, users without password, long running query, high disk tmp tables, binlog disabled.

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `[IM002] Data source name not found` | DSN name in macro doesn't match `/etc/odbc.ini` | Check `{$MYSQL.DSN}` matches `[section_name]` in odbc.ini exactly |
| `[IM004] Driver's SQLAllocHandle on SQL_HANDLE_ENV failed` | `libmaodbc.so` not found / wrong path in odbcinst.ini | Run `find /usr -name 'libmaodbc.so'` and fix Driver path |
| `Access denied for user 'zbx_odbc'` | Wrong password or user not created | Verify user exists: `SELECT User, Host FROM mysql.user WHERE User='zbx_odbc';` |
| `SELECT command denied to user 'zbx_odbc'` | Missing grants | Run GRANT statements from Step 4 |
| `Table 'performance_schema.xxx' doesn't exist` | `performance_schema` disabled | Enable in MySQL: `performance_schema=ON` in `my.cnf`, restart MySQL |
| `Unsupported item key` | `db.odbc.query` in item key (removed Zabbix 7.x) | Rename key to `db.odbc.select` or `db.odbc.get` |
| Items `state=0`, lastclock=0 — no data | Items just created, not yet polled | Wait 1-2 min, check Latest data |
| Connection OK in isql but fails in Zabbix | LD_LIBRARY_PATH not set for Zabbix service | No special env needed for MariaDB driver (unlike Oracle) — check SELinux |

---

## SELinux (RHEL / Rocky Linux)

```bash
# Allow Zabbix server outbound network (needed for ODBC connections):
setsebool -P zabbix_can_network 1

# Verify Zabbix server can connect to MySQL port:
sudo -u zabbix bash -c "echo | nc -w2 192.168.1.60 3306" && echo "Port OK"

# If /tmp ODBC trace files cause SELinux denial:
setsebool -P allow_user_mysql_connect 1
```

> Unlike Oracle, MariaDB Connector/ODBC does **not** require `LD_LIBRARY_PATH` or `ORACLE_HOME` env vars. No systemd override needed.
