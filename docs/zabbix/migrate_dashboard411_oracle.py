# -*- coding: utf-8 -*-
"""
Recreates Oracle dashboard from Proxmox Zabbix on target Zabbix.
Maps all IDs by item key_ and graph name.

Usage: python3 migrate_dashboard411_oracle.py
"""
import sys, json, requests

# ── CONFIG ────────────────────────────────────────────────────
TARGET_URL    = "http://localhost/zabbix"
TARGET_USER   = "Admin"
TARGET_PASS   = "zabbix"                   # change to your password
TARGET_HOST   = "oraclevm"                 # Oracle host name in target Zabbix
SOURCE_HOST   = "LINKPARK"                 # Oracle host name in source (Proxmox)
DASH_NAME     = "Oracle DB Monitoring"     # name without LINKPARK suffix
PORTABLE_JSON = "dashboard411_portable.json"
# ─────────────────────────────────────────────────────────────

def api(session, token, method, params):
    resp = session.post(f"{TARGET_URL}/api_jsonrpc.php",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"jsonrpc": "2.0", "method": method, "params": params, "id": 1},
        timeout=30)
    resp.raise_for_status()
    data = resp.json()
    if "error" in data:
        print(f"API error [{method}]: {data['error']}")
        sys.exit(1)
    return data["result"]

# ── Auth ──────────────────────────────────────────────────────
session = requests.Session()
r = session.post(f"{TARGET_URL}/api_jsonrpc.php",
    headers={"Content-Type": "application/json"},
    json={"jsonrpc": "2.0", "method": "user.login",
          "params": {"username": TARGET_USER, "password": TARGET_PASS}, "id": 1},
    timeout=30)
TOKEN = r.json()["result"]
print(f"Auth OK. Token: {TOKEN[:8]}...")

# ── Get target host ───────────────────────────────────────────
hosts = api(session, TOKEN, "host.get",
    {"filter": {"host": TARGET_HOST}, "output": ["hostid", "host", "name"]})
if not hosts:
    print(f"ERROR: host '{TARGET_HOST}' not found in target Zabbix")
    sys.exit(1)
HOSTID       = hosts[0]["hostid"]
HOST_VISIBLE = hosts[0]["name"]
print(f"Target host: {TARGET_HOST} (id={HOSTID}, visible='{HOST_VISIBLE}')")

# ── Items + graphs on target host ─────────────────────────────
all_items = api(session, TOKEN, "item.get",
    {"hostids": HOSTID, "output": ["itemid", "key_", "name"], "limit": 1000})
key_to_id    = {i["key_"]: i["itemid"] for i in all_items}
host_itemids = set(i["itemid"] for i in all_items)
print(f"Target items: {len(all_items)}")

all_graphs = api(session, TOKEN, "graph.get",
    {"hostids": HOSTID, "output": ["graphid", "name"],
     "selectGraphItems": ["itemid"], "limit": 500})
name_to_gid = {}
for g in all_graphs:
    bad = [gi for gi in g.get("gitems", []) if gi["itemid"] not in host_itemids]
    if not bad:
        name_to_gid[g["name"]] = g["graphid"]
print(f"Target graphs: {len(name_to_gid)} usable")

# ── Load portable JSON ────────────────────────────────────────
with open(PORTABLE_JSON, encoding="utf-8-sig") as f:
    src = json.load(f)

# ── Translate widgets ─────────────────────────────────────────
missing_items  = []
missing_graphs = []

def translate_fields(fields):
    new_fields = []
    for f in fields:
        fname = f["name"]
        ftype = f["type"]
        fval  = f["value"]
        res   = f.get("_resolved")

        if fname.startswith("itemid") and res and res.get("key_"):
            tid = key_to_id.get(res["key_"])
            if not tid:
                missing_items.append(res["key_"])
                print(f"  MISSING item: {res['key_']}")
                continue
            new_fields.append({"type": ftype, "name": fname, "value": tid})

        elif fname.startswith("graphid") and res and res.get("gname"):
            tid = name_to_gid.get(res["gname"])
            if not tid:
                missing_graphs.append(res["gname"])
                print(f"  MISSING graph: {res['gname']}")
                continue
            new_fields.append({"type": ftype, "name": fname, "value": tid})

        elif fname.startswith("hostids") and res and res.get("host"):
            thost = api(session, TOKEN, "host.get",
                {"filter": {"host": res["host"]}, "output": ["hostid"]})
            hid = thost[0]["hostid"] if thost else HOSTID
            new_fields.append({"type": ftype, "name": fname, "value": hid})

        elif fname.startswith("ds.") and fname.endswith(".hosts.0"):
            val = HOST_VISIBLE if fval == SOURCE_HOST else fval
            new_fields.append({"type": ftype, "name": fname, "value": val})

        else:
            new_fields.append({"type": ftype, "name": fname, "value": fval})

    return new_fields

pages = []
for page in src["pages"]:
    widgets = []
    for w in page["widgets"]:
        new_w = {
            "type": w["type"],
            "x": int(w["x"]), "y": int(w["y"]),
            "width": int(w["width"]), "height": int(w["height"]),
            "fields": translate_fields(w["fields"]),
        }
        if w.get("name"):
            new_w["name"] = w["name"]
        if w.get("view_mode") and w["view_mode"] != "0":
            new_w["view_mode"] = int(w["view_mode"])
        widgets.append(new_w)
    pages.append({"name": page["name"], "widgets": widgets})

# ── Create dashboard ──────────────────────────────────────────
print(f"\nCreating dashboard '{DASH_NAME}'...")
result = api(session, TOKEN, "dashboard.create", {
    "name": DASH_NAME,
    "display_period": int(src.get("display_period", 30)),
    "auto_start": int(src.get("auto_start", 1)),
    "pages": pages,
})
dash_id = result["dashboardids"][0]
print(f"\nDashboard created! ID: {dash_id}")
print(f"Open: {TARGET_URL}/zabbix.php?action=dashboard.view&dashboardid={dash_id}")

if missing_items:
    print(f"\nMissing items ({len(missing_items)}):")
    for k in set(missing_items): print(f"  {k}")
if missing_graphs:
    print(f"\nMissing graphs ({len(missing_graphs)}):")
    for g in set(missing_graphs): print(f"  {g}")
