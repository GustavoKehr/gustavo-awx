# -*- coding: utf-8 -*-
"""
Recreates dashboard 410 "MySQL - ODBC" from Proxmox Zabbix
exactly as-is on the target Zabbix, mapping all IDs by key/name.

Usage: python3 migrate_dashboard410.py
"""
import sys, json, requests

# ── CONFIG ────────────────────────────────────────────────────
TARGET_URL   = "http://localhost/zabbix"   # target Zabbix URL
TARGET_USER  = "Admin"
TARGET_PASS  = "zabbix"                    # change to your password
TARGET_HOST  = "mysqlvm"                   # MySQL host name in target Zabbix
SOURCE_HOST  = "odbcvm"                    # MySQL host name in source (Proxmox)
DASH_NAME    = "MySQL - ODBC"              # name for new dashboard
PORTABLE_JSON = "dashboard410_portable.json"
# ─────────────────────────────────────────────────────────────

def api(session, token, url, method, params):
    resp = session.post(f"{url}/api_jsonrpc.php",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"jsonrpc": "2.0", "method": method, "params": params, "id": 1},
        timeout=30)
    resp.raise_for_status()
    data = resp.json()
    if "error" in data:
        print(f"API error [{method}]: {data['error']}")
        sys.exit(1)
    return data["result"]

# ── Auth to target ────────────────────────────────────────────
session = requests.Session()
r = session.post(f"{TARGET_URL}/api_jsonrpc.php",
    headers={"Content-Type": "application/json"},
    json={"jsonrpc": "2.0", "method": "user.login",
          "params": {"username": TARGET_USER, "password": TARGET_PASS}, "id": 1},
    timeout=30)
TOKEN = r.json()["result"]
print(f"Auth OK. Token: {TOKEN[:8]}...")

# ── Get target host ───────────────────────────────────────────
hosts = api(session, TOKEN, TARGET_URL, "host.get",
    {"filter": {"host": TARGET_HOST}, "output": ["hostid", "host", "name"]})
if not hosts:
    print(f"ERROR: host '{TARGET_HOST}' not found in target Zabbix")
    sys.exit(1)
HOSTID = hosts[0]["hostid"]
HOST_VISIBLE = hosts[0]["name"]  # visible name for svggraph ds.hosts
print(f"Target host: {TARGET_HOST} (id={HOSTID}, visible='{HOST_VISIBLE}')")

# ── Get all items on target host ──────────────────────────────
all_items = api(session, TOKEN, TARGET_URL, "item.get",
    {"hostids": HOSTID, "output": ["itemid", "key_", "name"], "limit": 1000})
key_to_id  = {i["key_"]: i["itemid"] for i in all_items}
print(f"Target items: {len(all_items)}")

# ── Get all graphs on target host ─────────────────────────────
host_itemids = set(i["itemid"] for i in all_items)
# Get needed graph names from portable JSON first, then resolve only those
with open(PORTABLE_JSON, encoding="utf-8-sig") as _f:
    _src_check = json.load(_f)
needed_graphs = set()
for _page in _src_check["pages"]:
    for _w in _page["widgets"]:
        for _f in _w["fields"]:
            if _f["name"].startswith("graphid") and _f.get("_resolved", {}) and _f["_resolved"].get("gname"):
                needed_graphs.add(_f["_resolved"]["gname"])
print(f"Graphs needed: {len(needed_graphs)}")

name_to_gid = {}
for gname in needed_graphs:
    result = api(session, TOKEN, TARGET_URL, "graph.get",
        {"hostids": HOSTID, "search": {"name": gname}, "searchWildcardsEnabled": False,
         "output": ["graphid", "name"], "selectGraphItems": ["itemid"], "limit": 5})
    for g in result:
        if g["name"] == gname:
            bad = [gi for gi in g.get("gitems", []) if gi["itemid"] not in host_itemids]
            if not bad:
                name_to_gid[g["name"]] = g["graphid"]
print(f"Target graphs: {len(name_to_gid)} usable")

# ── Load portable dashboard ───────────────────────────────────
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

        # itemid.* → resolve by key_ at target
        if fname.startswith("itemid") and res and res.get("key_"):
            key = res["key_"]
            tid = key_to_id.get(key)
            if not tid:
                missing_items.append(key)
                print(f"  MISSING item: {key}")
                continue
            new_fields.append({"type": ftype, "name": fname, "value": tid})

        # graphid.* → resolve by name at target
        elif fname.startswith("graphid") and res and res.get("gname"):
            gname = res["gname"]
            tid = name_to_gid.get(gname)
            if not tid:
                missing_graphs.append(gname)
                print(f"  MISSING graph: {gname}")
                continue
            new_fields.append({"type": ftype, "name": fname, "value": tid})

        # hostids.* (problems widget) → resolve host at target
        elif fname.startswith("hostids") and res and res.get("host"):
            thost = api(session, TOKEN, TARGET_URL, "host.get",
                {"filter": {"host": res["host"]}, "output": ["hostid"]})
            if thost:
                new_fields.append({"type": ftype, "name": fname, "value": thost[0]["hostid"]})
            else:
                # fallback to target host
                new_fields.append({"type": ftype, "name": fname, "value": HOSTID})

        # svggraph ds.*.hosts.* → replace source host with target visible name
        elif fname.startswith("ds.") and fname.endswith(".hosts.0"):
            val = HOST_VISIBLE if fval == SOURCE_HOST else fval
            new_fields.append({"type": ftype, "name": fname, "value": val})

        # everything else → pass through unchanged
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

# ── Create dashboard at target ────────────────────────────────
print(f"\nCreating dashboard '{DASH_NAME}'...")
result = api(session, TOKEN, TARGET_URL, "dashboard.create", {
    "name": DASH_NAME,
    "display_period": int(src.get("display_period", 30)),
    "auto_start": int(src.get("auto_start", 1)),
    "pages": pages,
})
dash_id = result["dashboardids"][0]
print(f"\nDashboard created! ID: {dash_id}")
print(f"Open: {TARGET_URL}/zabbix.php?action=dashboard.view&dashboardid={dash_id}")

if missing_items:
    print(f"\nMissing items ({len(missing_items)}) — those widgets were skipped:")
    for k in missing_items: print(f"  {k}")
if missing_graphs:
    print(f"\nMissing graphs ({len(missing_graphs)}) — those widgets were skipped:")
    for g in missing_graphs: print(f"  {g}")
