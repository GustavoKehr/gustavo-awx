# Zabbix ODBC Monitoring — Oracle (Single Instance)

> Setup guide for Oracle monitoring via ODBC in Zabbix 7.x.
> Scope: **non-CDB single instance** only. No multitenant/PDB steps.

---

## Files needed

| File | Use |
|------|-----|
| `template_oracle.yaml` | Import in Zabbix — 73 items, 5 LLD rules, 31 macros |

---

## Architecture

```
Zabbix Server (Linux)
  │
  └── UnixODBC → libsqora.so.21.1 (Oracle ODBC driver)
        │
        └──[TCP 1521]──► Oracle DB server
                         Single Instance, non-CDB
```

**Key point:** ODBC items execute on the **Zabbix server**, not the agent.
Drivers must be installed on the Zabbix server machine.

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
# Oracle Instant Client 21c RPMs
# Download from: https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html
# Packages required:
#   oracle-instantclient21-basic-21.x.x.rpm
#   oracle-instantclient21-odbc-21.x.x.rpm

rpm -ivh oracle-instantclient21-basic-21.x.x.rpm
rpm -ivh oracle-instantclient21-odbc-21.x.x.rpm

# Verify install
ls /usr/lib/oracle/21/client64/lib/
# libsqora.so.21.1   <-- ODBC driver
# libclntsh.so.21.1  <-- Oracle client library
```

```bash
# Set Oracle env vars — Zabbix server process needs these
cat > /etc/profile.d/oracle.sh << 'EOF'
export ORACLE_HOME=/usr/lib/oracle/21/client64
export LD_LIBRARY_PATH=/usr/lib/oracle/21/client64/lib:$LD_LIBRARY_PATH
EOF
source /etc/profile.d/oracle.sh

# Also add to Zabbix server systemd unit so the service sees it:
mkdir -p /etc/systemd/system/zabbix-server.service.d/
cat > /etc/systemd/system/zabbix-server.service.d/oracle.conf << 'EOF'
[Service]
Environment="LD_LIBRARY_PATH=/usr/lib/oracle/21/client64/lib"
Environment="ORACLE_HOME=/usr/lib/oracle/21/client64"
EOF
systemctl daemon-reload
systemctl restart zabbix-server
```

---

## Step 2 — Register Oracle driver in /etc/odbcinst.ini

```ini
# /etc/odbcinst.ini

[Oracle 21 ODBC driver]
Description = Oracle ODBC driver for Oracle 21
Driver      = /usr/lib/oracle/21/client64/lib/libsqora.so.21.1
Setup       =
FileUsage   = 1
CPTimeout   =
CPReuse     =
```

```bash
# Register and verify
odbcinst -q -d
# Should show: [Oracle 21 ODBC driver]
```

---

## Step 3 — Create zbx_monitor user in Oracle

Connect as SYSDBA on the Oracle server:

```sql
-- Single instance / non-CDB grants
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

-- NOTE: V_$PDBS grant NOT needed for non-CDB single instance
-- The PDB discovery rule will return empty (no rows) — that is expected behavior
```

---

## Step 4 — Test connection from Zabbix server

Oracle uses DSN-less connection — no `/etc/odbc.ini` entry needed.
Test by creating a temporary isql DSN:

```bash
# Option A: test with temporary INI file
cat > /tmp/test_oracle.ini << 'EOF'
[TEST_ORA]
Driver = /usr/lib/oracle/21/client64/lib/libsqora.so.21.1
DBQ    = //192.168.1.50:1521/ORCL
EOF

ODBCINI=/tmp/test_oracle.ini isql -v TEST_ORA zbx_monitor "StrongPassword1!"
# If OK: shows SQL prompt
# Type: SELECT INSTANCE_NAME FROM V$INSTANCE;
# Expected: your instance name
```

```bash
# Option B: quick one-liner test
ODBCINI=/tmp/test_oracle.ini isql -v TEST_ORA zbx_monitor "StrongPassword1!" \
  <<< "SELECT INSTANCE_NAME FROM V\$INSTANCE;"
```

---

## Step 5 — Import template in Zabbix

### Where to get the file

File: `template_oracle.yaml`  
Contains: Oracle by ODBC template — 73 items, 5 LLD discovery rules, 31 macros, 1 built-in dashboard ("Oracle Performance")

### Import steps

```
1. Zabbix UI → Configuration → Templates
2. Click "Import" button (top-right corner)
3. Choose file: template_oracle.yaml
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
| Template | 1 | "Oracle by ODBC" |
| Items | 73 | ODBC + dependent items |
| LLD discovery rules | 5 | Tablespaces, Databases, Archive logs, ASM, PDBs |
| Macros | 31 | Defaults only — override per host |
| Graphs | built-in | Cache, I/O, datafiles, processes |
| Dashboard | 1 | "Oracle Performance" — appears on host after link |

### After import — verify

```
Configuration → Templates
  → Search: Oracle
  → Should show: "Oracle by ODBC"
  → Click template name → Items tab → confirm 73 items listed
```

> **Note:** The dashboard ("Oracle Performance") appears under  
> `Monitoring → Hosts → [your host] → Dashboards`  
> only after you link the template to a host and the host collects data.

---

## Step 6 — Create host in Zabbix

```
Configuration → Hosts → Create host

  Host name:  your-oracle-server-name
  Groups:     Databases  (or Templates/Applications — any group)
  Interfaces: Agent type — IP of Oracle server, port 10050
              (needed for agent items like ping/uptime; ODBC items ignore interface)
  Templates:  Oracle by ODBC
```

Then go to **Macros** tab and set:

| Macro | Value | Type | Notes |
|-------|-------|------|-------|
| `{$ORACLE.DRIVER}` | `/usr/lib/oracle/21/client64/lib/libsqora.so.21.1` | Text | Path on Zabbix **server** |
| `{$ORACLE.HOST}` | `192.168.1.50` | Text | Oracle server IP or FQDN |
| `{$ORACLE.PORT}` | `1521` | Text | **Do not skip** — missing = ORA-12154 |
| `{$ORACLE.SERVICE}` | `ORCL` | Text | Service name — check with `lsnrctl status` |
| `{$ORACLE.USER}` | `zbx_monitor` | Text | |
| `{$ORACLE.PASSWORD}` | `StrongPassword1!` | Secret text | |

Click **Add** → **Update**.

---

## Step 7 — Verify collection

```
Monitoring → Hosts → your-oracle-server
  → Latest data
  → Filter by: Oracle

Wait ~2 minutes. Items should show values, not errors.
```

Expected working items:
- `Get instance state` — returns JSON with INSTANCE_NAME, STATUS, UPTIME, etc.
- `Get system metrics` — returns JSON with CPU ratio, wait time, logons/s, etc.
- `Session count`, `Number of processes`, `Uptime`, `Version` — single numeric/text values

Expected empty (no data, no error) for single instance:
- `Get PDB` — no PDBs in non-CDB, returns empty JSON `[]` — **normal**
- `Get ASM disk groups` — only if not using ASM storage

---

## Connection string reference

Oracle uses **DSN-less** connection — the driver path goes directly in the Zabbix item key:

```
db.odbc.get[get_instance_state,,"Driver={$ORACLE.DRIVER};DBQ=//{$ORACLE.HOST}:{$ORACLE.PORT}/{$ORACLE.SERVICE};"]
```

After macro expansion at collection time:
```
Driver=/usr/lib/oracle/21/client64/lib/libsqora.so.21.1;DBQ=//192.168.1.50:1521/ORCL;
```

No `/etc/odbc.ini` entry needed for Oracle.

---

## What the template collects

**Instance & Availability**
- Instance name, hostname, version, role, status, uptime
- Number of LISTENER processes, service TCP port state

**Sessions**
- Session count, limit, active user/background/inactive sessions
- Sessions concurrency %, lock rate, locked sessions count
- Sessions limit usage %

**Memory — SGA**
- Buffer cache, shared pool, large pool, java pool, log buffer, fixed SGA
- Shared pool free %

**Memory — PGA**
- Total allocated, inuse, freeable, global memory bound, aggregate target parameter

**Performance**
- Physical reads/writes: ops/s and bytes/s
- Buffer cache hit ratio, library cache hit ratio, cursor cache hit ratio
- Memory sorts ratio, disk sorts/s, rows per sort
- Database CPU time ratio %, database wait time ratio %
- SQL service response time (seconds)
- Logons/s, user rollbacks/s, enqueue timeouts/s, long table scans/s

**Storage**
- Datafiles count and limit
- FRA: usable %, used space, space limit, reclaimable, number of files, restore points
- Redo logs available to switch

**Security**
- zbx_monitor password expiry days

**LLD Discovery (auto-creates items per object)**
- Tablespaces: usage %, usage from max %, free bytes, allocated bytes, max bytes, open status
- Databases: name, open status, log mode, role, force logging (non-CDB returns 1 row)
- Archive log destinations: name, status (if archivelog mode enabled)
- ASM disk groups: name, usage (if using ASM)
- PDBs: empty for non-CDB — no items created, no errors

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `ORA-12154: TNS could not resolve` | `{$ORACLE.PORT}` macro missing or port wrong | Add `{$ORACLE.PORT}=1521` to host macros |
| `ORA-12154` with correct port | `sqlnet.ora` has `NAMES.DIRECTORY_PATH=(TNSNAMES)` only — no EZCONNECT | Add `NAMES.DIRECTORY_PATH=(EZCONNECT,TNSNAMES)` to `/etc/oracle/network/admin/sqlnet.ora` or `$ORACLE_HOME/network/admin/sqlnet.ora` |
| `ORA-01017: invalid username/password` | Wrong user/password in macros | Verify `{$ORACLE.USER}` and `{$ORACLE.PASSWORD}` |
| `ORA-00942: table or view does not exist` | Missing grants on zbx_monitor | Run GRANT statements from Step 3 |
| `Cannot load shared libraries: libsqora.so.21.1` | LD_LIBRARY_PATH not set in Zabbix service | Add systemd override (Step 1) |
| All items `state=1 error`, lastclock=0 | Port macro missing at creation time | Add `{$ORACLE.PORT}` macro, items auto-retry in ~30s |
| Items `state=0`, lastclock=0 — no data yet | Items created but not yet polled | Wait 1-2 min, check Latest data |
| `Get PDB` returns no data | Non-CDB instance has no PDBs | Expected — `V$PDBS` empty in non-CDB |

---

## SELinux (RHEL / Rocky Linux)

```bash
# Allow Zabbix server outbound network (needed for ODBC connections):
setsebool -P zabbix_can_network 1

# Fix Oracle client library SELinux context:
restorecon -Rv /usr/lib/oracle/

# Verify Zabbix server can connect to Oracle port:
sudo -u zabbix bash -c "echo | nc -w2 192.168.1.50 1521" && echo "Port OK"
```
