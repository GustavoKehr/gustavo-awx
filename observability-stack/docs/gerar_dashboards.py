#!/usr/bin/env python3
"""
Gera 3 dashboards Grafana JSON para a stack Loki + Prometheus + Alloy.
Saída: dashboard_*.json no diretório atual.
"""
import json, time

UID_PROM = "PBFA97CFB590B2093"
UID_LOKI = "P8E80F9AEF21F6940"

# ─── helpers ──────────────────────────────────────────────────────────────────

def ds(uid):
    t = "prometheus" if uid == UID_PROM else "loki"
    return {"type": t, "uid": uid}

def gridpos(x, y, w, h):
    return {"x": x, "y": y, "w": w, "h": h}

def timeseries(id_, title, targets, unit="short", desc="", x=0, y=0, w=12, h=8):
    return {
        "id": id_, "type": "timeseries", "title": title, "description": desc,
        "gridPos": gridpos(x, y, w, h),
        "datasource": ds(targets[0]["ds"]),
        "fieldConfig": {
            "defaults": {
                "unit": unit, "color": {"mode": "palette-classic"},
                "custom": {"lineWidth": 2, "fillOpacity": 10, "spanNulls": True}
            }
        },
        "options": {"tooltip": {"mode": "multi"}, "legend": {"displayMode": "table", "placement": "bottom"}},
        "targets": [
            {"datasource": ds(t["ds"]), "expr": t["expr"],
             "legendFormat": t.get("legend", ""), "refId": chr(65+i)}
            for i, t in enumerate(targets)
        ]
    }

def stat(id_, title, expr, unit="short", color="blue", x=0, y=0, w=6, h=4, thresholds=None):
    th = thresholds or [{"color": "green", "value": None}]
    return {
        "id": id_, "type": "stat", "title": title,
        "gridPos": gridpos(x, y, w, h),
        "datasource": ds(UID_PROM),
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "thresholds": {"mode": "absolute", "steps": th},
                "color": {"mode": "thresholds"}
            }
        },
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto",
                    "textMode": "auto", "colorMode": "background"},
        "targets": [{"datasource": ds(UID_PROM), "expr": expr, "legendFormat": "", "refId": "A"}]
    }

def gauge(id_, title, expr, unit="percent", min_=0, max_=100, x=0, y=0, w=6, h=8):
    return {
        "id": id_, "type": "gauge", "title": title,
        "gridPos": gridpos(x, y, w, h),
        "datasource": ds(UID_PROM),
        "fieldConfig": {
            "defaults": {
                "unit": unit, "min": min_, "max": max_,
                "thresholds": {"mode": "absolute", "steps": [
                    {"color": "green", "value": None},
                    {"color": "yellow", "value": 70},
                    {"color": "red", "value": 90}
                ]},
                "color": {"mode": "thresholds"}
            }
        },
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "showThresholdLabels": False},
        "targets": [{"datasource": ds(UID_PROM), "expr": expr, "legendFormat": "{{host}}", "refId": "A"}]
    }

def row(id_, title, y=0, collapsed=False):
    return {"id": id_, "type": "row", "title": title,
            "gridPos": gridpos(0, y, 24, 1), "collapsed": collapsed, "panels": []}

def logs_panel(id_, title, expr, x=0, y=0, w=24, h=10):
    return {
        "id": id_, "type": "logs", "title": title,
        "gridPos": gridpos(x, y, w, h),
        "datasource": ds(UID_LOKI),
        "options": {"dedupStrategy": "none", "enableLogDetails": True,
                    "prettifyLogMessage": False, "showTime": True,
                    "showLabels": True, "sortOrder": "Descending", "wrapLogMessage": True},
        "targets": [{"datasource": ds(UID_LOKI), "expr": expr, "refId": "A"}]
    }

def bargauge(id_, title, expr, unit="bytes", x=0, y=0, w=12, h=8):
    return {
        "id": id_, "type": "bargauge", "title": title,
        "gridPos": gridpos(x, y, w, h),
        "datasource": ds(UID_PROM),
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "thresholds": {"mode": "absolute", "steps": [
                    {"color": "green", "value": None},
                    {"color": "yellow", "value": None},
                    {"color": "red", "value": None}
                ]},
                "color": {"mode": "thresholds"}
            }
        },
        "options": {"orientation": "horizontal", "reduceOptions": {"calcs": ["lastNotNull"]},
                    "displayMode": "gradient"},
        "targets": [{"datasource": ds(UID_PROM), "expr": expr,
                     "legendFormat": "{{host}} {{mountpoint}}", "refId": "A"}]
    }

def table_panel(id_, title, targets, x=0, y=0, w=24, h=8):
    return {
        "id": id_, "type": "table", "title": title,
        "gridPos": gridpos(x, y, w, h),
        "datasource": ds(UID_PROM),
        "fieldConfig": {"defaults": {"custom": {"align": "auto"}}},
        "options": {"footer": {"show": False}, "sortBy": []},
        "targets": [
            {"datasource": ds(UID_PROM), "expr": t["expr"],
             "legendFormat": t.get("legend",""), "refId": chr(65+i), "instant": True}
            for i, t in enumerate(targets)
        ],
        "transformations": [
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {}}
        ]
    }

def var_host():
    return {
        "name": "host", "label": "Host", "type": "query",
        "datasource": ds(UID_PROM),
        "definition": "label_values(node_load1, host)",
        "query": {"query": "label_values(node_load1, host)", "refId": "StandardVariableQuery"},
        "refresh": 2, "multi": False, "includeAll": True, "allValue": ".*",
        "sort": 1, "current": {}
    }

def var_loki_host():
    return {
        "name": "host", "label": "Host", "type": "query",
        "datasource": ds(UID_LOKI),
        "definition": "label_values(host)",
        "query": {
            "label": "host",
            "stream": '{job="systemd-journal"}',
            "type": 1
        },
        "refresh": 2, "multi": True, "includeAll": False,
        "sort": 1, "current": {}
    }

def dashboard(title, uid, panels, variables=None, refresh="30s", desc=""):
    return {
        "title": title, "uid": uid, "description": desc,
        "schemaVersion": 38, "version": 1,
        "refresh": refresh,
        "time": {"from": "now-1h", "to": "now"},
        "timepicker": {},
        "timezone": "browser",
        "templating": {"list": variables or []},
        "annotations": {"list": []},
        "panels": panels,
        "tags": ["observability", "auto-generated"],
        "style": "dark",
        "editable": True,
        "fiscalYearStartMonth": 0,
        "graphTooltip": 1,
        "links": []
    }

# ─── DASHBOARD 1: Linux System Overview ───────────────────────────────────────

def dash_linux_overview():
    H = "$host"
    panels = [
        # ── Row: Resumo ──────────────────────────────────────────────────────
        row(1, "📊 Resumo do Sistema", y=0),

        stat(2, "Uptime",
             f'(time() - node_boot_time_seconds{{host=~"{H}"}}) / 86400',
             unit="d", x=0, y=1, w=4, h=4,
             thresholds=[{"color": "green", "value": None}]),

        stat(3, "Load Average 1m",
             f'node_load1{{host=~"{H}"}}',
             unit="short", x=4, y=1, w=4, h=4,
             thresholds=[{"color":"green","value":None},{"color":"yellow","value":2},{"color":"red","value":4}]),

        stat(4, "CPU Cores",
             f'count(node_cpu_seconds_total{{host=~"{H}",mode="idle"}})',
             unit="short", x=8, y=1, w=4, h=4),

        stat(5, "RAM Total",
             f'node_memory_MemTotal_bytes{{host=~"{H}"}}',
             unit="bytes", x=12, y=1, w=4, h=4),

        stat(6, "RAM Disponível",
             f'node_memory_MemAvailable_bytes{{host=~"{H}"}}',
             unit="bytes", x=16, y=1, w=4, h=4,
             thresholds=[{"color":"red","value":None},{"color":"yellow","value":536870912},{"color":"green","value":1073741824}]),

        stat(7, "Processos Rodando",
             f'node_procs_running{{host=~"{H}"}}',
             unit="short", x=20, y=1, w=4, h=4),

        # ── Row: CPU ─────────────────────────────────────────────────────────
        row(10, "🖥️ CPU", y=5),

        timeseries(11, "CPU Usage por Modo (%)",
            [{"ds": UID_PROM,
              "expr": f'sum by (mode) (rate(node_cpu_seconds_total{{host=~"{H}",mode!="idle"}}[5m])) * 100',
              "legend": "{{mode}}"}],
            unit="percent", x=0, y=6, w=16, h=8, desc="Breakdown por modo: user, system, iowait, etc"),

        gauge(12, "CPU Usado (%)",
            f'100 - (avg(rate(node_cpu_seconds_total{{host=~"{H}",mode="idle"}}[5m])) * 100)',
            unit="percent", x=16, y=6, w=8, h=8),

        timeseries(13, "Load Average",
            [{"ds": UID_PROM, "expr": f'node_load1{{host=~"{H}"}}', "legend": "1m"},
             {"ds": UID_PROM, "expr": f'node_load5{{host=~"{H}"}}', "legend": "5m"},
             {"ds": UID_PROM, "expr": f'node_load15{{host=~"{H}"}}', "legend": "15m"}],
            unit="short", x=0, y=14, w=12, h=7, desc="Load médio do sistema"),

        timeseries(14, "Processos",
            [{"ds": UID_PROM, "expr": f'node_procs_running{{host=~"{H}"}}', "legend": "running"},
             {"ds": UID_PROM, "expr": f'node_procs_blocked{{host=~"{H}"}}', "legend": "blocked"}],
            unit="short", x=12, y=14, w=12, h=7),

        # ── Row: Memória ──────────────────────────────────────────────────────
        row(20, "💾 Memória", y=21),

        timeseries(21, "Uso de Memória",
            [{"ds": UID_PROM, "expr": f'node_memory_MemTotal_bytes{{host=~"{H}"}}', "legend": "Total"},
             {"ds": UID_PROM, "expr": f'node_memory_MemAvailable_bytes{{host=~"{H}"}}', "legend": "Disponível"},
             {"ds": UID_PROM,
              "expr": f'node_memory_MemTotal_bytes{{host=~"{H}"}} - node_memory_MemAvailable_bytes{{host=~"{H}"}}',
              "legend": "Usado"}],
            unit="bytes", x=0, y=22, w=16, h=8),

        gauge(22, "Memória Usada (%)",
            f'(1 - node_memory_MemAvailable_bytes{{host=~"{H}"}} / node_memory_MemTotal_bytes{{host=~"{H}"}}) * 100',
            unit="percent", x=16, y=22, w=8, h=8),

        timeseries(23, "Memória Detalhada",
            [{"ds": UID_PROM, "expr": f'node_memory_Buffers_bytes{{host=~"{H}"}}', "legend": "Buffers"},
             {"ds": UID_PROM, "expr": f'node_memory_Cached_bytes{{host=~"{H}"}}', "legend": "Cached"},
             {"ds": UID_PROM, "expr": f'node_memory_SwapTotal_bytes{{host=~"{H}"}}', "legend": "Swap Total"},
             {"ds": UID_PROM, "expr": f'node_memory_SwapFree_bytes{{host=~"{H}"}}', "legend": "Swap Livre"}],
            unit="bytes", x=0, y=30, w=24, h=7),

        # ── Row: Disco ────────────────────────────────────────────────────────
        row(30, "💿 Disco", y=37),

        bargauge(31, "Uso de Disco por Mountpoint",
            f'(1 - node_filesystem_avail_bytes{{host=~"{H}",fstype!~"tmpfs|overlay|devtmpfs"}} / node_filesystem_size_bytes{{host=~"{H}",fstype!~"tmpfs|overlay|devtmpfs"}}) * 100',
            unit="percent", x=0, y=38, w=12, h=8),

        timeseries(32, "I/O de Disco (bytes/s)",
            [{"ds": UID_PROM, "expr": f'rate(node_disk_read_bytes_total{{host=~"{H}"}}[5m])', "legend": "Leitura {{device}}"},
             {"ds": UID_PROM, "expr": f'rate(node_disk_written_bytes_total{{host=~"{H}"}}[5m])', "legend": "Escrita {{device}}"}],
            unit="Bps", x=12, y=38, w=12, h=8),

        timeseries(33, "IOPS",
            [{"ds": UID_PROM, "expr": f'rate(node_disk_reads_completed_total{{host=~"{H}"}}[5m])', "legend": "Reads {{device}}"},
             {"ds": UID_PROM, "expr": f'rate(node_disk_writes_completed_total{{host=~"{H}"}}[5m])', "legend": "Writes {{device}}"}],
            unit="iops", x=0, y=46, w=12, h=7),

        timeseries(34, "Latência de Disco (ms)",
            [{"ds": UID_PROM,
              "expr": f'rate(node_disk_read_time_seconds_total{{host=~"{H}"}}[5m]) / rate(node_disk_reads_completed_total{{host=~"{H}"}}[5m]) * 1000',
              "legend": "Read latency {{device}}"},
             {"ds": UID_PROM,
              "expr": f'rate(node_disk_write_time_seconds_total{{host=~"{H}"}}[5m]) / rate(node_disk_writes_completed_total{{host=~"{H}"}}[5m]) * 1000',
              "legend": "Write latency {{device}}"}],
            unit="ms", x=12, y=46, w=12, h=7),

        # ── Row: Rede ─────────────────────────────────────────────────────────
        row(40, "🌐 Rede", y=53),

        timeseries(41, "Tráfego de Rede (bytes/s)",
            [{"ds": UID_PROM, "expr": f'rate(node_network_receive_bytes_total{{host=~"{H}",device!~"lo|veth.*"}}[5m])', "legend": "RX {{device}}"},
             {"ds": UID_PROM, "expr": f'rate(node_network_transmit_bytes_total{{host=~"{H}",device!~"lo|veth.*"}}[5m])', "legend": "TX {{device}}"}],
            unit="Bps", x=0, y=54, w=16, h=8),

        timeseries(42, "Pacotes por segundo",
            [{"ds": UID_PROM, "expr": f'rate(node_network_receive_packets_total{{host=~"{H}",device!~"lo|veth.*"}}[5m])', "legend": "RX {{device}}"},
             {"ds": UID_PROM, "expr": f'rate(node_network_transmit_packets_total{{host=~"{H}",device!~"lo|veth.*"}}[5m])', "legend": "TX {{device}}"}],
            unit="pps", x=16, y=54, w=8, h=8),

        timeseries(43, "Erros de Rede",
            [{"ds": UID_PROM, "expr": f'rate(node_network_receive_errs_total{{host=~"{H}",device!~"lo"}}[5m])', "legend": "RX errs {{device}}"},
             {"ds": UID_PROM, "expr": f'rate(node_network_transmit_errs_total{{host=~"{H}",device!~"lo"}}[5m])', "legend": "TX errs {{device}}"}],
            unit="short", x=0, y=62, w=12, h=6),

        timeseries(44, "Conexões TCP",
            [{"ds": UID_PROM, "expr": f'node_netstat_Tcp_CurrEstab{{host=~"{H}"}}', "legend": "Estabelecidas"},
             {"ds": UID_PROM, "expr": f'node_sockstat_TCP_inuse{{host=~"{H}"}}', "legend": "Em uso"}],
            unit="short", x=12, y=62, w=12, h=6),

        # ── Row: Sistema ──────────────────────────────────────────────────────
        row(50, "⚙️ Sistema", y=68),

        timeseries(51, "File Descriptors",
            [{"ds": UID_PROM, "expr": f'node_filefd_allocated{{host=~"{H}"}}', "legend": "Abertos"},
             {"ds": UID_PROM, "expr": f'node_filefd_maximum{{host=~"{H}"}}', "legend": "Máximo"}],
            unit="short", x=0, y=69, w=12, h=7),

        timeseries(52, "Context Switches & Interrupções",
            [{"ds": UID_PROM, "expr": f'rate(node_context_switches_total{{host=~"{H}"}}[5m])', "legend": "Context switches/s"},
             {"ds": UID_PROM, "expr": f'rate(node_intr_total{{host=~"{H}"}}[5m])', "legend": "Interrupções/s"}],
            unit="short", x=12, y=69, w=12, h=7),
    ]

    return dashboard(
        title="🐧 Linux System Overview",
        uid="linux-overview-v1",
        desc="CPU, Memória, Disco, Rede e Sistema — por host",
        panels=panels,
        variables=[var_host()],
        refresh="30s"
    )

# ─── DASHBOARD 2: Logs & Análise ──────────────────────────────────────────────

def dash_logs():
    H = "$host"
    panels = [
        # ── Row: Resumo de Logs ───────────────────────────────────────────────
        row(1, "📝 Resumo", y=0),

        # stats de volume
        {
            "id": 2, "type": "stat", "title": "Total de Linhas (1h)",
            "gridPos": gridpos(0, 1, 6, 4),
            "datasource": ds(UID_LOKI),
            "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"},
                "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}}},
            "options": {"reduceOptions": {"calcs": ["sum"]}, "colorMode": "background"},
            "targets": [{"datasource": ds(UID_LOKI),
                         "expr": f'sum(count_over_time({{job="systemd-journal", host=~"{H}"}}[1h]))',
                         "refId": "A"}]
        },
        {
            "id": 3, "type": "stat", "title": "Erros (1h)",
            "gridPos": gridpos(6, 1, 6, 4),
            "datasource": ds(UID_LOKI),
            "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"},
                "thresholds": {"mode": "absolute", "steps": [
                    {"color": "green", "value": None},
                    {"color": "yellow", "value": 10},
                    {"color": "red", "value": 100}]}}},
            "options": {"reduceOptions": {"calcs": ["sum"]}, "colorMode": "background"},
            "targets": [{"datasource": ds(UID_LOKI),
                         "expr": f'sum(count_over_time({{job="systemd-journal", host=~"{H}"}} |~ "(?i)(error|failed|failure|critical)" [1h]))',
                         "refId": "A"}]
        },
        {
            "id": 4, "type": "stat", "title": "Warnings (1h)",
            "gridPos": gridpos(12, 1, 6, 4),
            "datasource": ds(UID_LOKI),
            "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"},
                "thresholds": {"mode": "absolute", "steps": [
                    {"color": "green", "value": None},
                    {"color": "yellow", "value": 50},
                    {"color": "orange", "value": 200}]}}},
            "options": {"reduceOptions": {"calcs": ["sum"]}, "colorMode": "background"},
            "targets": [{"datasource": ds(UID_LOKI),
                         "expr": f'sum(count_over_time({{job="systemd-journal", host=~"{H}"}} |~ "(?i)(warn|warning)" [1h]))',
                         "refId": "A"}]
        },
        {
            "id": 5, "type": "stat", "title": "Hosts Ativos",
            "gridPos": gridpos(18, 1, 6, 4),
            "datasource": ds(UID_LOKI),
            "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"},
                "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]}}},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
            "targets": [{"datasource": ds(UID_LOKI),
                         "expr": 'count(sum by (host) (count_over_time({job="systemd-journal", host=~".+"}[5m])))',
                         "refId": "A"}]
        },

        # ── Row: Taxa de Logs ─────────────────────────────────────────────────
        row(10, "📈 Taxa de Logs", y=5),

        {
            "id": 11, "type": "timeseries", "title": "Taxa de Logs por Host (linhas/min)",
            "gridPos": gridpos(0, 6, 24, 8),
            "datasource": ds(UID_LOKI),
            "fieldConfig": {"defaults": {"unit": "short", "custom": {"lineWidth": 2, "fillOpacity": 10}}},
            "options": {"tooltip": {"mode": "multi"}, "legend": {"displayMode": "table", "placement": "bottom"}},
            "targets": [{"datasource": ds(UID_LOKI),
                         "expr": f'sum by (host) (rate({{job="systemd-journal", host=~"{H}"}}[5m])) * 60',
                         "legendFormat": "{{host}}", "refId": "A"}]
        },

        {
            "id": 12, "type": "timeseries", "title": "Taxa de Erros por Host",
            "gridPos": gridpos(0, 14, 12, 8),
            "datasource": ds(UID_LOKI),
            "fieldConfig": {"defaults": {"unit": "short",
                "color": {"mode": "fixed", "fixedColor": "red"},
                "custom": {"lineWidth": 2, "fillOpacity": 15}}},
            "options": {"tooltip": {"mode": "multi"}},
            "targets": [{"datasource": ds(UID_LOKI),
                         "expr": f'sum by (host) (rate({{job="systemd-journal", host=~"{H}"}} |~ "(?i)(error|failed|critical)" [5m])) * 60',
                         "legendFormat": "{{host}} errors", "refId": "A"}]
        },

        {
            "id": 13, "type": "timeseries", "title": "Taxa de Warnings por Host",
            "gridPos": gridpos(12, 14, 12, 8),
            "datasource": ds(UID_LOKI),
            "fieldConfig": {"defaults": {"unit": "short",
                "color": {"mode": "fixed", "fixedColor": "orange"},
                "custom": {"lineWidth": 2, "fillOpacity": 15}}},
            "options": {"tooltip": {"mode": "multi"}},
            "targets": [{"datasource": ds(UID_LOKI),
                         "expr": f'sum by (host) (rate({{job="systemd-journal", host=~"{H}"}} |~ "(?i)(warn)" [5m])) * 60',
                         "legendFormat": "{{host}} warnings", "refId": "A"}]
        },

        # ── Row: Logs por Job ──────────────────────────────────────────────────
        row(20, "🗂️ Logs por Fonte", y=22),

        {
            "id": 21, "type": "timeseries", "title": "Taxa de Logs por Host e Job",
            "gridPos": gridpos(0, 23, 24, 7),
            "datasource": ds(UID_LOKI),
            "fieldConfig": {"defaults": {"unit": "short", "custom": {"lineWidth": 2}}},
            "options": {"tooltip": {"mode": "multi"}},
            "targets": [{"datasource": ds(UID_LOKI),
                         "expr": f'sum by (host) (rate({{job="systemd-journal", host=~"{H}"}}[5m])) * 60',
                         "legendFormat": "{{host}}", "refId": "A"}]
        },

        # ── Row: Logs ao vivo ──────────────────────────────────────────────────
        row(30, "🔴 Erros Recentes", y=30),

        logs_panel(31, "Erros e Falhas",
            f'{{job="systemd-journal", host=~"{H}"}} |~ "(?i)(error|failed|failure|critical|fatal)"',
            x=0, y=31, w=24, h=12),

        row(40, "📋 Logs Recentes do Journal", y=43),

        logs_panel(41, "systemd-journal",
            f'{{job="systemd-journal", host=~"{H}"}}',
            x=0, y=44, w=24, h=12),

        row(50, "📁 Todos os Logs (messages, secure, cron)", y=56),

        logs_panel(51, "systemd-journal — todos os logs",
            f'{{job="systemd-journal", host=~"{H}"}}',
            x=0, y=57, w=24, h=12),

        # ── Row: Autenticação ─────────────────────────────────────────────────
        row(60, "🔐 Segurança & Autenticação", y=69),

        {
            "id": 61, "type": "timeseries", "title": "Tentativas de Login SSH",
            "gridPos": gridpos(0, 70, 12, 7),
            "datasource": ds(UID_LOKI),
            "fieldConfig": {"defaults": {"unit": "short", "custom": {"lineWidth": 2}}},
            "targets": [
                {"datasource": ds(UID_LOKI),
                 "expr": f'sum by (host) (rate({{job="systemd-journal", host=~"{H}"}} |~ "sshd.*Accepted" [5m])) * 60',
                 "legendFormat": "{{host}} logins OK", "refId": "A"},
                {"datasource": ds(UID_LOKI),
                 "expr": f'sum by (host) (rate({{job="systemd-journal", host=~"{H}"}} |~ "sshd.*Failed" [5m])) * 60',
                 "legendFormat": "{{host}} logins FAILED", "refId": "B"},
            ]
        },

        logs_panel(62, "Eventos de Segurança (sudo, ssh, auth)",
            f'{{job="systemd-journal", host=~"{H}"}} |~ "(?i)(sudo|sshd|authentication|unauthorized|invalid user)"',
            x=12, y=70, w=12, h=7),

        # ── Row: Systemd Units ────────────────────────────────────────────────
        row(70, "⚙️ Serviços Systemd", y=77),

        logs_panel(71, "Falhas de Servico (systemd)",
            f'{{job="systemd-journal", host=~"{H}"}} |~ "(?i)(failed|start request|stopped|killed)"',
            x=0, y=78, w=24, h=10),
    ]

    return dashboard(
        title="📋 Logs & Análise",
        uid="logs-analysis-v1",
        desc="Análise de logs via Loki — taxa, erros, segurança, serviços",
        panels=panels,
        variables=[var_loki_host()],
        refresh="30s"
    )

# ─── DASHBOARD 3: Comparação de Infraestrutura ────────────────────────────────

def dash_infra_compare():
    panels = [
        row(1, "🖥️ Visão Geral — Todos os Hosts", y=0),

        table_panel(2, "Status Atual dos Hosts",
            [{"expr": 'node_load1', "legend": ""},
             {"expr": '(1 - node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes)*100', "legend": ""},
             {"expr": '100 - avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m]))*100', "legend": ""}],
            x=0, y=1, w=24, h=8),

        # CPU comparison
        row(10, "🖥️ CPU — Comparação", y=9),

        timeseries(11, "CPU Usage % — Todos os Hosts",
            [{"ds": UID_PROM,
              "expr": '100 - (avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)',
              "legend": "{{host}}"}],
            unit="percent", x=0, y=10, w=24, h=8),

        timeseries(12, "Load Average 1m — Todos os Hosts",
            [{"ds": UID_PROM, "expr": "node_load1", "legend": "{{host}}"}],
            unit="short", x=0, y=18, w=12, h=7),

        timeseries(13, "Load Average 5m — Todos os Hosts",
            [{"ds": UID_PROM, "expr": "node_load5", "legend": "{{host}}"}],
            unit="short", x=12, y=18, w=12, h=7),

        # Memory comparison
        row(20, "💾 Memória — Comparação", y=25),

        timeseries(21, "Memória Usada % — Todos os Hosts",
            [{"ds": UID_PROM,
              "expr": '(1 - node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes) * 100',
              "legend": "{{host}}"}],
            unit="percent", x=0, y=26, w=16, h=8),

        {
            "id": 22, "type": "bargauge", "title": "RAM Usada Atual",
            "gridPos": gridpos(16, 26, 8, 8),
            "datasource": ds(UID_PROM),
            "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100,
                "thresholds": {"mode": "absolute", "steps": [
                    {"color": "green", "value": None},
                    {"color": "yellow", "value": 70},
                    {"color": "red", "value": 90}]},
                "color": {"mode": "thresholds"}}},
            "options": {"orientation": "horizontal", "reduceOptions": {"calcs": ["lastNotNull"]},
                        "displayMode": "gradient"},
            "targets": [{"datasource": ds(UID_PROM),
                         "expr": '(1 - node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes) * 100',
                         "legendFormat": "{{host}}", "refId": "A"}]
        },

        # Disk comparison
        row(30, "💿 Disco — Comparação", y=34),

        {
            "id": 31, "type": "bargauge", "title": "Uso de Disco / (root) por Host",
            "gridPos": gridpos(0, 35, 12, 8),
            "datasource": ds(UID_PROM),
            "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100,
                "thresholds": {"mode": "absolute", "steps": [
                    {"color": "green", "value": None},
                    {"color": "yellow", "value": 70},
                    {"color": "red", "value": 90}]},
                "color": {"mode": "thresholds"}}},
            "options": {"orientation": "horizontal", "reduceOptions": {"calcs": ["lastNotNull"]},
                        "displayMode": "gradient"},
            "targets": [{"datasource": ds(UID_PROM),
                         "expr": '(1 - node_filesystem_avail_bytes{mountpoint="/"}/node_filesystem_size_bytes{mountpoint="/"}) * 100',
                         "legendFormat": "{{host}}", "refId": "A"}]
        },

        timeseries(32, "I/O de Disco Total (bytes/s) — Todos os Hosts",
            [{"ds": UID_PROM,
              "expr": 'sum by (host) (rate(node_disk_read_bytes_total[5m]) + rate(node_disk_written_bytes_total[5m]))',
              "legend": "{{host}}"}],
            unit="Bps", x=12, y=35, w=12, h=8),

        # Network comparison
        row(40, "🌐 Rede — Comparação", y=43),

        timeseries(41, "Tráfego RX — Todos os Hosts",
            [{"ds": UID_PROM,
              "expr": 'sum by (host) (rate(node_network_receive_bytes_total{device!~"lo|veth.*"}[5m]))',
              "legend": "{{host}}"}],
            unit="Bps", x=0, y=44, w=12, h=8),

        timeseries(42, "Tráfego TX — Todos os Hosts",
            [{"ds": UID_PROM,
              "expr": 'sum by (host) (rate(node_network_transmit_bytes_total{device!~"lo|veth.*"}[5m]))',
              "legend": "{{host}}"}],
            unit="Bps", x=12, y=44, w=12, h=8),

        # Logs comparison
        row(50, "📋 Logs — Comparação", y=52),

        {
            "id": 51, "type": "timeseries", "title": "Taxa de Logs por Host",
            "gridPos": gridpos(0, 53, 12, 8),
            "datasource": ds(UID_LOKI),
            "fieldConfig": {"defaults": {"unit": "short", "custom": {"lineWidth": 2}}},
            "options": {"tooltip": {"mode": "multi"}},
            "targets": [{"datasource": ds(UID_LOKI),
                         "expr": 'sum by (host) (rate({job="systemd-journal", host=~".+"}[5m])) * 60',
                         "legendFormat": "{{host}}", "refId": "A"}]
        },

        {
            "id": 52, "type": "timeseries", "title": "Taxa de Erros por Host",
            "gridPos": gridpos(12, 53, 12, 8),
            "datasource": ds(UID_LOKI),
            "fieldConfig": {"defaults": {"unit": "short",
                "custom": {"lineWidth": 2, "fillOpacity": 15}}},
            "options": {"tooltip": {"mode": "multi"}},
            "targets": [{"datasource": ds(UID_LOKI),
                         "expr": 'sum by (host) (rate({job="systemd-journal", host=~".+"} |~ "(?i)(error|failed|critical)" [5m])) * 60',
                         "legendFormat": "{{host}} errors", "refId": "A"}]
        },
    ]

    return dashboard(
        title="🏗️ Infrastructure Comparison",
        uid="infra-compare-v1",
        desc="Comparação lado a lado de todos os hosts — CPU, RAM, Disco, Rede, Logs",
        panels=panels,
        variables=[],
        refresh="30s"
    )

# ─── main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import os
    out_dir = os.path.dirname(os.path.abspath(__file__))

    dashboards = [
        ("dashboard_linux_overview.json", dash_linux_overview()),
        ("dashboard_logs_analysis.json", dash_logs()),
        ("dashboard_infra_compare.json", dash_infra_compare()),
    ]

    for fname, dash in dashboards:
        path = os.path.join(out_dir, fname)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(dash, f, indent=2, ensure_ascii=False)
        print(f"OK  {fname}  ({os.path.getsize(path)//1024} KB)")

    print("\nDone. Copy to Grafana dashboards dir:")
    print("  /var/lib/grafana/dashboards/")
