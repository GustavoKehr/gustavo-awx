# Zabbix ODBC Monitoring — Oracle & MySQL Setup Guide

> How to replicate Oracle and MySQL ODBC monitoring at work using the exported templates.

---

## Files in this folder

| File | Use |
|------|-----|
| `template_mysql.yaml` | Import in Zabbix — 43 ODBC items, 9 triggers, 3 macros |
| `template_oracle.yaml` | Import in Zabbix — 73 items, 5 LLD discovery rules, 31 macros |
| `zabbix_odbc_monitoring_guide.md` | This file |

---

## Architecture

```
Zabbix Server (Linux)
  │
  ├── UnixODBC (libodbc.so)
  │     ├── Oracle ODBC driver: libsqora.so.21.1    ──► Oracle DB :1521
  │     └── MariaDB ODBC driver: libmaodbc.so        ──► MySQL     :3306
  │
  └── Item type: ODBC (db.odbc.select / db.odbc.get)
      Executed by the SERVER — drivers must be on the Zabbix server, NOT on the monitored host
```

---

## Step 1 — Install ODBC drivers on the Zabbix Server

### UnixODBC (required base)

```bash
dnf install -y unixODBC unixODBC-devel

# Verify
odbcinst -j
# DRIVERS: /etc/odbcinst.ini
# SYSTEM DATA SOURCES: /etc/odbc.ini
```

### Oracle Instant Client + ODBC driver

```bash
# Download RPMs from Oracle (free, needs Oracle account):
# https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html
# Packages needed:
#   oracle-instantclient21-basic-21.x.rpm
#   oracle-instantclient21-odbc-21.x.rpm

rpm -ivh oracle-instantclient21-basic-21.x.rpm
rpm -ivh oracle-instantclient21-odbc-21.x.rpm

# Default install path after RPM:
ls /usr/lib/oracle/21/client64/lib/
# libsqora.so.21.1  <-- ODBC driver
# libclntsh.so.21.1 <-- Oracle client lib

# Required env vars — add to /etc/profile.d/oracle.sh:
echo 'export ORACLE_HOME=/usr/lib/oracle/21/client64' > /etc/profile.d/oracle.sh
echo 'export LD_LIBRARY_PATH=/usr/lib/oracle/21/client64/lib:$LD_LIBRARY_PATH' >> /etc/profile.d/oracle.sh
source /etc/profile.d/oracle.sh

# Also add to the Zabbix server systemd unit if needed:
# /etc/systemd/system/zabbix-server.service.d/override.conf
# [Service]
# Environment="LD_LIBRARY_PATH=/usr/lib/oracle/21/client64/lib"
```

### MariaDB Connector/ODBC (for MySQL)

```bash
# Download from https://mariadb.com/downloads/connectors/
# or via repo:
dnf install -y MariaDB-connector-odbc

# Driver location (typical):
ls /usr/lib64/libmaodbc.so
```

---

## Step 2 — Register drivers in /etc/odbcinst.ini

```ini
# /etc/odbcinst.ini

[Oracle 21 ODBC driver]
Description = Oracle ODBC driver for Oracle 21
Driver      = /usr/lib/oracle/21/client64/lib/libsqora.so.21.1
Setup       =
FileUsage   = 1

[MariaDB ODBC 3.x Driver]
Description = MariaDB Connector/ODBC
Driver      = /usr/lib64/libmaodbc.so
```

```bash
# Verify both registered:
odbcinst -q -d
# Should list both driver names
```

---

## Step 3 — Configure /etc/odbc.ini (MySQL only)

Oracle uses DSN-less connection (driver path in the item key itself).
MySQL uses a named DSN.

```ini
# /etc/odbc.ini

[mysql_work]                        # <-- this name goes in {$MYSQL.DSN} macro
Description = MySQL Production
Driver      = MariaDB ODBC 3.x Driver
SERVER      = 192.168.x.x           # MySQL server IP
PORT        = 3306
DATABASE    = information_schema
OPTION      = 67108864
```

```bash
# Test DSN connection:
isql -v mysql_work zbx_odbc "YourPassword" <<< "SELECT VERSION()"
# Expected: | VERSION() | 8.0.xx |
```

---

## Step 4 — Create monitoring users on databases

### Oracle — zbx_monitor user

```sql
-- Connect as SYSDBA:
CREATE USER zbx_monitor IDENTIFIED BY "StrongPassword1!";
GRANT CREATE SESSION TO zbx_monitor;
GRANT SELECT ANY DICTIONARY TO zbx_monitor;
GRANT SELECT ON V_$SESSION TO zbx_monitor;
GRANT SELECT ON V_$INSTANCE TO zbx_monitor;
GRANT SELECT ON V_$DATABASE TO zbx_monitor;
GRANT SELECT ON V_$SYSMETRIC TO zbx_monitor;
GRANT SELECT ON DBA_TABLESPACES TO zbx_monitor;
GRANT SELECT ON DBA_DATA_FILES TO zbx_monitor;
GRANT SELECT ON V_$ASM_DISKGROUP TO zbx_monitor;
GRANT SELECT ON V_$ARCHIVE_DEST TO zbx_monitor;
GRANT SELECT ON V_$PDBS TO zbx_monitor;

-- For Multitenant (CDB):
ALTER USER zbx_monitor SET CONTAINER_DATA=ALL CONTAINER=CURRENT;

-- Test connection from Zabbix server:
# isql -v TEST_DSN zbx_monitor "StrongPassword1!"
```

### MySQL — zbx_odbc user

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

---

## Step 5 — Import templates in Zabbix

```
Zabbix UI → Configuration → Templates → Import (top right button)
  → Choose file: template_oracle.yaml  → Import
  → Choose file: template_mysql.yaml   → Import
```

---

## Step 6 — Create host and set macros

### Oracle host

```
Configuration → Hosts → Create host
  Host name:  your-oracle-server
  Groups:     Databases (or any)
  Interfaces: Agent — IP of Oracle server, port 10050 (just for agent items)
  Templates:  Oracle by ODBC
  Macros tab: (set the 6 macros below)
```

#### Required macros — Oracle

| Macro | Example value | Notes |
|-------|--------------|-------|
| `{$ORACLE.DRIVER}` | `/usr/lib/oracle/21/client64/lib/libsqora.so.21.1` | Path on **Zabbix server** |
| `{$ORACLE.HOST}` | `192.168.1.50` | Oracle server IP or hostname |
| `{$ORACLE.PORT}` | `1521` | **DO NOT skip** — missing causes ORA-12154 |
| `{$ORACLE.SERVICE}` | `ORCL` | Service name (not SID) |
| `{$ORACLE.USER}` | `zbx_monitor` | |
| `{$ORACLE.PASSWORD}` | `StrongPassword1!` | Set Type = Secret text |

### MySQL host

```
Configuration → Hosts → Create host
  Host name:  your-mysql-server
  Templates:  MySQL Comprehensive Monitoring
  Macros tab: (set the 3 macros below)
```

#### Required macros — MySQL

| Macro | Example value | Notes |
|-------|--------------|-------|
| `{$MYSQL.DSN}` | `mysql_work` | Must match entry name in /etc/odbc.ini |
| `{$MYSQL.USER}` | `zbx_odbc` | |
| `{$MYSQL.PASSWORD}` | `StrongPassword1!` | Set Type = Secret text |

---

## Connection string format (reference)

### Oracle — DSN-less (embedded in item key)

```
db.odbc.get[unique_name,,"Driver={$ORACLE.DRIVER};DBQ=//{$ORACLE.HOST}:{$ORACLE.PORT}/{$ORACLE.SERVICE};"]
```

Resolved at collection time:
```
Driver=/usr/lib/oracle/21/client64/lib/libsqora.so.21.1;DBQ=//192.168.1.50:1521/ORCL;
```

### MySQL — named DSN

```
db.odbc.select[key_name,"{$MYSQL.DSN}"]
```

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `ORA-12154: TNS could not resolve` | `{$ORACLE.PORT}` macro missing | Add `{$ORACLE.PORT}=1521` to host macros |
| `ORA-12154` even with port set | sqlnet.ora missing EZCONNECT | Add `NAMES.DIRECTORY_PATH=(EZCONNECT,TNSNAMES)` to `/etc/oracle/sqlnet.ora` |
| `ORA-01017: invalid username/password` | Wrong credentials | Check macros USER and PASSWORD |
| `ORA-00942: table or view does not exist` | Missing grants on zbx_monitor | Run `GRANT SELECT ANY DICTIONARY TO zbx_monitor` |
| `[IM002] Data source name not found` | DSN not in /etc/odbc.ini | Add DSN entry to `/etc/odbc.ini`, restart nothing needed |
| `Unsupported item key` | `db.odbc.query` used (removed in Zabbix 7.x) | Rename key to `db.odbc.select` or `db.odbc.get` |
| `[zbx_odbc] permission denied` | MySQL user lacks access | Run the GRANT statements from Step 4 |
| Items never collect, state=0, lastclock=0 | Items just created, poller queue not reached yet | Wait 1-2 min, check Monitoring → Latest data |

---

## SELinux (RHEL/Rocky — common in enterprise)

```bash
# Allow Zabbix server to make outbound network connections:
setsebool -P zabbix_can_network 1

# Fix Oracle lib context if restorecon needed:
restorecon -Rv /usr/lib/oracle/

# If zabbix_server can't write to /tmp (ODBC trace):
# Add custom policy or:
setsebool -P allow_user_mysql_connect 1
```

---

## What template_mysql.yaml collects

- Threads running / connected / max connections / connection usage %
- Buffer pool hit rate %, free %, dirty pages %, pending I/O
- Com_select / insert / update / delete (cumulative)
- Slow queries, full table scans, long running queries (>60s)
- InnoDB: row lock waits, deadlocks, active transactions, idle in transaction
- Metadata lock waits, table locks waited
- Bytes received/sent, max used connections, aborted clients/connects
- Server uptime, open tables, tmp tables on disk
- DB schema count, total DB size, fragmentation (MB)
- Users without password (security check)
- Binlog enabled status

**Triggers:** High aborted rate, buffer pool low, too many connections, slow queries spike, deadlocks, users without password, etc.

---

## What template_oracle.yaml collects

- Instance state, role, uptime, hostname, version
- Session counts: active user/background, inactive, total, limit
- SGA: buffer cache, shared pool, large pool, java pool, log buffer, fixed
- PGA: allocated, inuse, freeable, global bound, aggregate target
- Physical reads/writes: ops/s and bytes/s
- Cache hit ratios: buffer cache, library cache, cursor cache
- Sort operations: memory vs disk, rows per sort
- FRA: usable %, used space, number of files, space limit
- Redo: logs available to switch
- Datafiles count and limit
- SQL service response time
- Logons/s, user rollbacks/s, enqueue timeouts/s
- Long table scans/s, disk sorts/s
- Process count and limit
- zbx_monitor password expiry days
- **LLD Discovery:** tablespaces (usage%, free, max, status), PDBs, databases, archive logs, ASM disk groups
