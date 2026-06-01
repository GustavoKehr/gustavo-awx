# -*- coding: utf-8 -*-
"""
Creates standalone MySQL Monitoring dashboard in Zabbix 7.0 via API.
Uses svggraph widgets (Zabbix 7.0 format) + item KPI cards.

Usage: python3 create_mysql_dashboard.py
"""
import sys, json, requests, string, random

# ── CONFIG ────────────────────────────────────────────────────
ZABBIX_URL  = "http://localhost/zabbix"
ZABBIX_USER = "Admin"
ZABBIX_PASS = "zabbix"
MYSQL_HOST  = "mysqlvm"
DASH_NAME   = "MySQL Monitoring"
# ─────────────────────────────────────────────────────────────

def api(session, token, method, params):
    resp = session.post(
        f"{ZABBIX_URL}/api_jsonrpc.php",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"jsonrpc": "2.0", "method": method, "params": params, "id": 1},
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    if "error" in data:
        print(f"API error [{method}]: {data['error']}")
        sys.exit(1)
    return data["result"]

def ref():
    return ''.join(random.choices(string.ascii_uppercase, k=5))

# ── Auth ──────────────────────────────────────────────────────
session = requests.Session()
r = session.post(f"{ZABBIX_URL}/api_jsonrpc.php",
    headers={"Content-Type": "application/json"},
    json={"jsonrpc": "2.0", "method": "user.login",
          "params": {"username": ZABBIX_USER, "password": ZABBIX_PASS}, "id": 1},
    timeout=30)
TOKEN = r.json()["result"]
print(f"Auth OK. Token: {TOKEN[:8]}...")

# ── Get host ──────────────────────────────────────────────────
hosts = api(session, TOKEN, "host.get", {"filter": {"host": MYSQL_HOST}, "output": ["hostid"]})
if not hosts:
    print(f"ERROR: host '{MYSQL_HOST}' not found.")
    sys.exit(1)
HOSTID = hosts[0]["hostid"]
print(f"Host: {MYSQL_HOST} (id={HOSTID})")

# ── Get items: id + key + name ────────────────────────────────
host_items = api(session, TOKEN, "item.get", {
    "hostids": HOSTID,
    "output": ["itemid", "key_", "name"],
    "limit": 500,
})
key_to_itemid = {i["key_"]: i["itemid"] for i in host_items}
itemid_to_name = {i["itemid"]: i["name"] for i in host_items}
host_itemids   = set(i["itemid"] for i in host_items)
print(f"Items: {len(host_items)}")

DSN = "{$MYSQL.DSN}"

def iid(key_name):
    full_key = f'db.odbc.select[{key_name},"{DSN}"]'
    v = key_to_itemid.get(full_key)
    if not v:
        print(f"  WARNING: item '{key_name}' not found")
    return v

# ── Get graphs + their items (color, sortorder) ───────────────
all_graphs_raw = api(session, TOKEN, "graph.get", {
    "hostids": HOSTID,
    "output": ["graphid", "name"],
    "selectGraphItems": ["itemid", "color", "sortorder", "yaxisside"],
    "limit": 300,
})

# graph_name -> graphid map (filter out template-owned graphs)
graph_map = {}
skipped = 0
for g in all_graphs_raw:
    gitems = g.get("gitems", [])
    bad = [gi for gi in gitems if gi["itemid"] not in host_itemids]
    if bad:
        skipped += 1
        continue
    graph_map[g["name"]] = g["graphid"]

print(f"Graphs: {len(graph_map)} usable, {skipped} skipped (template items)")

# ── Widget builders ───────────────────────────────────────────
def item_widget(key_name, label, x, y, _color=None):
    itemid = iid(key_name)
    if not itemid:
        return None
    return {
        "type": "item",
        "x": x, "y": y, "width": 6, "height": 4,
        "fields": [
            {"type": "4", "name": "itemid.0",  "value": itemid},
            {"type": "1", "name": "description","value": label},
            {"type": "0", "name": "show.0",    "value": "1"},
            {"type": "0", "name": "show.1",    "value": "2"},
        ],
    }

def graph_widget(graph_name, y):
    # type 6 = GRAPH in Zabbix 7.0 API
    gid = graph_map.get(graph_name)
    if not gid:
        print(f"  WARNING: graph '{graph_name}' not found, skipping")
        return None
    return {
        "type": "graph",
        "name": graph_name,
        "x": 0, "y": y, "width": 36, "height": 5,
        "fields": [
            {"type": "6", "name": "graphid.0",   "value": gid},
            {"type": "0", "name": "show_legend", "value": "1"},
        ],
    }

def disk_svggraph(fs_path, y):
    """svggraph for disk used/free — Zabbix agent vfs.fs.size items."""
    used = next((i for i in host_items if f"vfs.fs.size[{fs_path},used]" in i["key_"]), None)
    free = next((i for i in host_items if f"vfs.fs.size[{fs_path},free]" in i["key_"]), None)
    if not used or not free:
        print(f"  WARNING: vfs.fs.size[{fs_path}] items not found, skipping disk graph")
        return None
    return {
        "type": "svggraph",
        "name": f"Disk {fs_path}: Used vs Free",
        "x": 0, "y": y, "width": 36, "height": 5,
        "fields": [
            {"type": "1", "name": "ds.0.hosts.0",     "value": MYSQL_HOST},
            {"type": "1", "name": "ds.0.items.0",     "value": used["name"]},
            {"type": "1", "name": "ds.0.color",       "value": "E74C3C"},
            {"type": "0", "name": "ds.0.fill",        "value": "1"},
            {"type": "1", "name": "ds.1.hosts.0",     "value": MYSQL_HOST},
            {"type": "1", "name": "ds.1.items.0",     "value": free["name"]},
            {"type": "1", "name": "ds.1.color",       "value": "27AE60"},
            {"type": "0", "name": "ds.1.fill",        "value": "1"},
            {"type": "0", "name": "legend",           "value": "1"},
            {"type": "1", "name": "reference",        "value": ref()},
            {"type": "1", "name": "time_period.from", "value": "now-1h"},
            {"type": "1", "name": "time_period.to",   "value": "now"},
        ],
    }

def page(name, widget_list):
    return {"name": name, "widgets": [w for w in widget_list if w]}

# ── Pages ─────────────────────────────────────────────────────
p1 = page("Connections & InnoDB", [
    item_widget("custom_threads_running",     "Threads Running",  0,  0),
    item_widget("custom_threads_connected",   "Connected",        6,  0),
    item_widget("custom_connection_usage_pct","Conn Usage %",    12,  0),
    item_widget("custom_buffer_pool_hit_rate","BP Hit Rate %",   18,  0),
    item_widget("custom_active_transactions", "Active Trx",      24,  0),
    item_widget("custom_innodb_deadlocks",    "Deadlocks",       30,  0),
    graph_widget("MySQL ODBC: Connections",           4),
    graph_widget("MySQL ODBC: InnoDB Buffer Pool",    9),
    graph_widget("MySQL ODBC: InnoDB Contention",    14),
    graph_widget("MySQL ODBC: Transactions & Locks", 19),
    graph_widget("MySQL ODBC: InnoDB Dirty & Log",   24),
    graph_widget("MySQL ODBC: InnoDB Pending I/O",   29),
])

p2 = page("Queries & Network", [
    item_widget("custom_slow_queries",         "Slow Queries",    0,  0),
    item_widget("custom_long_running_queries", "Long Queries",    6,  0),
    item_widget("custom_select_scan",          "Full Scans",     12,  0),
    item_widget("custom_com_select",           "Com Select",     18,  0),
    item_widget("custom_uptime",               "Uptime (s)",     24,  0),
    item_widget("custom_handler_read_rnd",     "No-Index Reads", 30,  0),
    graph_widget("MySQL ODBC: Query Rates",            4),
    graph_widget("MySQL ODBC: DML Operations",         9),
    graph_widget("MySQL ODBC: Network Traffic",       14),
    graph_widget("MySQL ODBC: Connections & Security",19),
    graph_widget("MySQL: Query Performance",          24),
    graph_widget("MySQL: Connection Health",          29),
])

p3 = page("Storage & Security", [
    item_widget("custom_total_db_size_mb",       "DB Size (MB)",  0,  0),
    item_widget("custom_total_fragmentation_mb", "Fragmentation", 6,  0),
    item_widget("custom_user_schema_count",      "Schemas",      12,  0),
    item_widget("custom_total_tables",           "Total Tables", 18,  0),
    item_widget("custom_users_no_password",      "No-Pwd Users", 24,  0),
    item_widget("custom_binlog_enabled",         "Binlog",       30,  0),
    graph_widget("MySQL ODBC: Temp Tables & Open Objects", 4),
    graph_widget("MySQL: DB Overview",                     9),
    graph_widget("MySQL: Security Overview",              14),
    disk_svggraph("/data",                                19),   # adjust path if needed
    disk_svggraph("/",                                    24),
])

# ── Create ────────────────────────────────────────────────────
print(f"\nCreating dashboard '{DASH_NAME}'...")
result = api(session, TOKEN, "dashboard.create", {
    "name": DASH_NAME,
    "display_period": 30,
    "auto_start": 1,
    "pages": [p1, p2, p3],
    # p3 includes disk graphs — if agent not installed they'll be skipped
})
dash_id = result["dashboardids"][0]
print(f"\nDashboard created! ID: {dash_id}")
print(f"Open: {ZABBIX_URL}/zabbix.php?action=dashboard.view&dashboardid={dash_id}")
