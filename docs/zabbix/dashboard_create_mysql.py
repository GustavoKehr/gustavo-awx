# -*- coding: utf-8 -*-
"""
Creates MySQL DB Monitoring dashboard on work Zabbix.
Edit HOST_NAME and ZBX credentials before running.
"""
import sys, io, urllib.request, json
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

# ============================================================
# EDIT THESE
ZBX       = "http://YOUR_ZABBIX_URL/api_jsonrpc.php"
ZBX_USER  = "Admin"
ZBX_PASS  = "zabbix"
HOST_NAME = "your-mysql-host-name"   # exact host name in Zabbix
# ============================================================

def login():
    p = json.dumps({"jsonrpc":"2.0","method":"user.login",
                    "params":{"username":ZBX_USER,"password":ZBX_PASS},"id":1}).encode()
    req = urllib.request.Request(ZBX, data=p, headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req) as r: return json.loads(r.read())["result"]

def api(method, params, token):
    p = json.dumps({"jsonrpc":"2.0","method":method,"params":params,"id":1}).encode()
    h = {"Content-Type":"application/json","Authorization":f"Bearer {token}"}
    req = urllib.request.Request(ZBX, data=p, headers=h)
    with urllib.request.urlopen(req) as r:
        resp = json.loads(r.read())
    if "error" in resp: raise Exception(str(resp["error"]))
    return resp.get("result")

TOKEN = login()

# --- Resolve host ---
hosts = api("host.get", {"output":["hostid","host"], "filter":{"host":[HOST_NAME]}}, TOKEN)
if not hosts:
    print(f"ERROR: host '{HOST_NAME}' not found in Zabbix")
    sys.exit(1)
HOST_ID = hosts[0]["hostid"]
print(f"Host: {HOST_NAME} -> id={HOST_ID}")

# --- Resolve items by key ---
items_resp = api("item.get", {
    "output": ["itemid","key_"],
    "hostids": HOST_ID,
    "webitems": True
}, TOKEN)
item_key_map = {i["key_"]: i["itemid"] for i in items_resp}
print(f"Found {len(item_key_map)} items on host")

# --- Resolve graphs by name (template graphs linked to host) ---
graphs_resp = api("graph.get", {
    "output": ["graphid","name"],
    "hostids": HOST_ID
}, TOKEN)
graph_name_map = {g["name"]: g["graphid"] for g in graphs_resp}
print(f"Found {len(graph_name_map)} graphs on host")

# --- Page/widget definitions (auto-generated from lab) ---
PAGES_SPEC = [
  {
    "name": "InnoDB & Connections",
    "widgets": [
      {
        "type": "item",
        "name": "",
        "x": 0,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_threads_running,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Threads Running"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 4,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_threads_connected,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Connected"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 8,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_connection_usage_pct,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Conn Usage %"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 12,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_buffer_pool_hit_rate,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "BP Hit Rate %"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 16,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_active_transactions,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Active Trx"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 20,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_uptime,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Uptime (s)"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 0,
        "y": 4,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL: Connection Health"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 0,
        "y": 11,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: Connections"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 12,
        "y": 11,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: InnoDB Buffer Pool"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 0,
        "y": 18,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL: Locks & Transactions"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 12,
        "y": 18,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: Transactions & Locks"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 0,
        "y": 25,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: InnoDB Contention"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 12,
        "y": 25,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: InnoDB Dirty & Log"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 12,
        "y": 4,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL: InnoDB Buffer Pool Detail"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          }
        ]
      }
    ]
  },
  {
    "name": "Queries & Security",
    "widgets": [
      {
        "type": "item",
        "name": "",
        "x": 0,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_com_select,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "SELECTs"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 4,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_slow_queries,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Slow Queries"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 8,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_select_scan,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Full Scans"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 12,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_innodb_deadlocks,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Deadlocks"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 16,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_long_running_queries,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Long Queries"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 20,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_users_no_password,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "No-Pass Users"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 0,
        "y": 4,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL: Query Performance"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 12,
        "y": 4,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: DML Operations"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 0,
        "y": 11,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: Query Rates"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 12,
        "y": 11,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: Temp Tables & Open Objects"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 0,
        "y": 18,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL: Security Metrics"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 12,
        "y": 18,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: Connections & Security"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 0,
        "y": 25,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL: Network Traffic"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 12,
        "y": 25,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: Network Traffic"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      }
    ]
  },
  {
    "name": "Disk & Replication",
    "widgets": [
      {
        "type": "item",
        "name": "",
        "x": 0,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "vfs.fs.size[/data,pfree]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "/data Free %"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 4,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "vfs.fs.size[/data,free]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "/data Free"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 8,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "vfs.fs.size[/data,used]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "/data Used"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 12,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "vfs.fs.inode[/data,pfree]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Inode Free %"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 16,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_total_db_size_mb,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "DB Size (MB)"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 20,
        "y": 0,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_total_tables,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "User Tables"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 0,
        "y": 4,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: /data Disk Space"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 12,
        "y": 4,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL: /data Disk Usage"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 0,
        "y": 11,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: /data Disk IOPS"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "graph",
        "name": "",
        "x": 12,
        "y": 11,
        "width": 12,
        "height": 7,
        "fields": [
          {
            "name": "graphid",
            "type": 6,
            "graph_name": "MySQL ODBC: /data Disk Throughput"
          },
          {
            "name": "source_type",
            "type": 0,
            "value": "0"
          },
          {
            "name": "show_legend",
            "type": 0,
            "value": "1"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 0,
        "y": 18,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "mysql.slave_io_running[\"slave\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "IO Running"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 4,
        "y": 18,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "mysql.slave_sql_running[\"slave\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "SQL Running"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 8,
        "y": 18,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "mysql.seconds_behind_master[\"slave\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Lag (s)"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 12,
        "y": 18,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_user_schema_count,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Schemas"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 16,
        "y": 18,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_total_fragmentation_mb,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Fragmentation"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 20,
        "y": 18,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_long_transactions,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Long Trx"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 0,
        "y": 22,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[mysql_size,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "mysql"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 4,
        "y": 22,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[performance_schema_size,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "perf_schema"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 8,
        "y": 22,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[sys_size,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "sys"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 12,
        "y": 22,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[ecommerce_db_size,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "ecommerce"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 16,
        "y": 22,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_innodb_os_log_written,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Redo Log B"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      },
      {
        "type": "item",
        "name": "",
        "x": 20,
        "y": 22,
        "width": 4,
        "height": 4,
        "fields": [
          {
            "name": "itemid",
            "type": 4,
            "key": "db.odbc.select[custom_binlog_enabled,\"{$MYSQL.DSN}\"]"
          },
          {
            "name": "description",
            "type": 1,
            "value": "Binlog"
          },
          {
            "name": "show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "show",
            "type": 0,
            "value": "2"
          },
          {
            "name": "decimal_places",
            "type": 0,
            "value": "2"
          },
          {
            "name": "units_show",
            "type": 0,
            "value": "1"
          },
          {
            "name": "bold",
            "type": 0,
            "value": "1"
          },
          {
            "name": "override_color",
            "type": 1,
            "value": "FFFFFF"
          }
        ]
      }
    ]
  }
]

# --- Build pages ---
pages = []
skipped = 0
for page_spec in PAGES_SPEC:
    widgets = []
    for ws in page_spec["widgets"]:
        wfields = []
        skip_widget = False
        for f in ws["fields"]:
            if f["name"] == "itemid":
                key = f["key"]
                iid = item_key_map.get(key)
                if not iid:
                    print(f"  SKIP widget (item key not found): {key[:60]}")
                    skip_widget = True
                    skipped += 1
                    break
                wfields.append({"type": f["type"], "name": "itemid", "value": iid})
            elif f["name"] == "graphid":
                gname = f["graph_name"]
                gid = graph_name_map.get(gname)
                if not gid:
                    print(f"  SKIP widget (graph not found): {gname}")
                    skip_widget = True
                    skipped += 1
                    break
                wfields.append({"type": f["type"], "name": "graphid", "value": gid})
            else:
                wfields.append({"type": f["type"], "name": f["name"], "value": f["value"]})

        if not skip_widget:
            widgets.append({
                "type": ws["type"],
                "name": ws["name"],
                "x": ws["x"], "y": ws["y"],
                "width": ws["width"], "height": ws["height"],
                "fields": wfields
            })

    pages.append({"name": page_spec["name"], "widgets": widgets})

print(f"\nSkipped {skipped} widgets (items/graphs not on this host — lab-specific)")

# --- Create dashboard ---
result = api("dashboard.create", {
    "name": "MySQL DB Monitoring",
    "display_period": 30,
    "auto_start": 1,
    "pages": pages
}, TOKEN)

print(f"\nDashboard created! id={result['dashboardids'][0]}")
print(f"Open: {ZBX.replace('api_jsonrpc.php','zabbix.php?action=dashboard.view&dashboardid=')}{result['dashboardids'][0]}")
