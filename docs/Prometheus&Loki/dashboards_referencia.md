# Referencia de Dashboards - Stack de Observabilidade

Documentacao dos dashboards Grafana do stack (Loki 3.6 + Prometheus 3.11 + Grafana 13.0).

---

## 1. Dashboards Disponiveis

### Linux Overview (`linux-overview-v1`)

**Proposito:** Visao geral de saude e performance dos servidores Linux monitorados.

**Arquivo:** `dashboard_linux_overview.json`

**Paineis:**

| Painel | Tipo | Fonte | Metrica |
|---|---|---|---|
| CPU Usage | Time series | Prometheus | `100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` |
| Memory Usage % | Gauge | Prometheus | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100` |
| Disk Usage % | Bar gauge | Prometheus | `(node_filesystem_size_bytes - node_filesystem_free_bytes) / node_filesystem_size_bytes * 100` |
| Network I/O | Time series | Prometheus | `rate(node_network_receive_bytes_total[5m])` / `rate(node_network_transmit_bytes_total[5m])` |
| System Load | Time series | Prometheus | `node_load1`, `node_load5`, `node_load15` |
| Uptime | Stat | Prometheus | `node_time_seconds - node_boot_time_seconds` |
| Open File Descriptors | Time series | Prometheus | `node_filefd_allocated` |
| Context Switches/s | Time series | Prometheus | `rate(node_context_switches_total[5m])` |

**Variaveis de template:**
- `instance` - selecao de host (label `instance` do Prometheus)

---

### Logs e Analise (`logs-analysis-v1`)

**Proposito:** Analise de logs do systemd-journal via Loki. Identificacao de erros, padroes e atividade por host.

**Arquivo:** `dashboard_logs_analysis.json`

**Paineis:**

| Painel | Tipo | Fonte | Query |
|---|---|---|---|
| Hosts Ativos | Stat | Loki | `count(sum by (host) (count_over_time({job="systemd-journal", host=~".+"}[5m])))` |
| Total de Linhas (1h) | Stat | Loki | `sum(count_over_time({job="systemd-journal", host=~".+"}[1h]))` |
| Log Rate (linhas/min) | Time series | Loki | `sum(rate({job="systemd-journal", host=~".+"}[5m]))` |
| Erros por Host | Bar chart | Loki | `sum by (host) (count_over_time({job="systemd-journal", host=~".+", level=~"err|crit|emerg"}[5m]))` |
| Log Tail (host selecionado) | Logs | Loki | `{job="systemd-journal", host="$host"}` |
| Top Units com Erros | Table | Loki | Agrupado por `_SYSTEMD_UNIT` |

**Variaveis de template:**
- `host` - selecao de host (label Loki, `includeAll: false`)

**Regras Loki obrigatorias:**
- Todas as queries devem incluir `job="systemd-journal"` como matcher fixo
- Usar `host=~".+"` em vez de `host=~".*"` (Loki 3.6 rejeita valores vazio-compativel)

---

### Comparativo de Infra (`infra-compare-v1`)

**Proposito:** Comparacao lado a lado de CPU, memoria e disco entre todos os servidores. Util para detectar host sobrecarregado vs ociosos.

**Arquivo:** `dashboard_infra_compare.json`

**Paineis:**

| Painel | Tipo | Fonte | Descricao |
|---|---|---|---|
| CPU por Host | Bar chart | Prometheus | % CPU uso por instancia, ordenado decrescente |
| Memoria por Host | Bar chart | Prometheus | % memoria usada por instancia |
| Disco por Host | Bar chart | Prometheus | % disco usado por ponto de montagem e host |
| Top Processos CPU | Table | Prometheus | `topk(10, ...)` por process name |
| Historico CPU 24h | Time series | Prometheus | Todas instancias sobrepostas para comparar tendencia |

---

## 2. Deploy de Dashboards

### Via Provisionamento Ansible (recomendado)

O playbook copia JSONs para `/var/lib/grafana/dashboards/` e o Grafana carrega automaticamente via provisionamento.

**Adicionar novo dashboard ao playbook:**
1. Salvar JSON em `roles/grafana/files/dashboards/meu_dashboard.json`
2. Grafana recarrega automaticamente (polling de 30s por padrao)

**Verificar provisionamento:**
```bash
sudo cat /etc/grafana/provisioning/dashboards/default.yml
# deve ter: path: /var/lib/grafana/dashboards, updateIntervalSeconds: 30
```

---

### Via SCP + Reinicio Manual

Metodo para atualizar dashboards sem re-executar playbook completo.

**1. Buscar UIDs reais dos datasources (obrigatorio antes de criar JSON):**
```bash
curl -s -u admin:'SENHA' http://192.168.137.200:3000/api/datasources
```

Exemplo de saida relevante:
```json
[
  {"uid": "PBFA97CFB590B2093", "name": "Prometheus", "type": "prometheus"},
  {"uid": "P8E80F9AEF21F6940", "name": "Loki",       "type": "loki"}
]
```

**2. Gerar JSON com UIDs corretos:**

Usar o script `gerar_dashboards.py` (em `docs/`). Editar as constantes no topo:
```python
PROMETHEUS_UID = "PBFA97CFB590B2093"
LOKI_UID       = "P8E80F9AEF21F6940"
```

Executar:
```bash
cd observability-stack/docs/
python3 gerar_dashboards.py
# gera: dashboard_linux_overview.json, dashboard_logs_analysis.json, dashboard_infra_compare.json
```

**3. Copiar para o servidor:**
```bash
scp dashboard_linux_overview.json user_aap@192.168.137.200:/tmp/
scp dashboard_logs_analysis.json  user_aap@192.168.137.200:/tmp/
scp dashboard_infra_compare.json  user_aap@192.168.137.200:/tmp/

ssh user_aap@192.168.137.200
sudo cp /tmp/dashboard_*.json /var/lib/grafana/dashboards/
sudo chown grafana:grafana /var/lib/grafana/dashboards/*.json
```

**4. Recarregar dashboards (sem reiniciar Grafana):**
```bash
# Opcao 1 - API reload (nao precisa reiniciar)
curl -X POST -u admin:'SENHA' http://localhost:3000/api/admin/provisioning/dashboards/reload

# Opcao 2 - Reiniciar servico
sudo systemctl restart grafana-server
```

---

### Via API Grafana (import direto)

Alternativa sem SCP, usa a API HTTP.

```bash
# Importar dashboard via API
curl -X POST \
  -H "Content-Type: application/json" \
  -u admin:'SENHA' \
  -d @dashboard_linux_overview.json \
  http://192.168.137.200:3000/api/dashboards/import
```

**Atencao:** O formato para import via API e diferente do formato de provisionamento. O JSON precisa ter `dashboard` e `overwrite` no nivel raiz:
```json
{
  "dashboard": { ...conteudo do dashboard... },
  "overwrite": true,
  "folderId": 0
}
```

---

## 3. Acessar Dashboards

**URL base:** `http://192.168.137.200:3000`

**Credenciais:** `admin` / `Obs@2026!`

**Navegacao:**
- Menu lateral: Dashboards → Browse
- Ou acesso direto por UID:
  - `http://192.168.137.200:3000/d/linux-overview-v1`
  - `http://192.168.137.200:3000/d/logs-analysis-v1`
  - `http://192.168.137.200:3000/d/infra-compare-v1`

---

## 4. Script Gerador de Dashboards (codigo completo)

Script Python que gera os 3 JSONs completos. Copiar para qualquer maquina com Python 3, ajustar os 2 UIDs no topo, executar.

**Executar:**
```bash
# Ajustar UIDs no topo do script antes de rodar
python3 gerar_dashboards.py
# saida: dashboard_linux_overview.json, dashboard_logs_analysis.json, dashboard_infra_compare.json
```

**Quando re-gerar:**
- Apos reinstalar Grafana (UIDs mudam)
- Ao adicionar/remover paineis
- Ao mudar datasources

**`gerar_dashboards.py` (codigo completo):**

```python
#!/usr/bin/env python3
"""
Gera 3 dashboards Grafana JSON para a stack Loki + Prometheus + Alloy.
Saida: dashboard_*.json no diretorio atual.

ANTES DE RODAR: buscar UIDs reais dos datasources:
  curl -s -u admin:SENHA http://GRAFANA_IP:3000/api/datasources
Atualizar UID_PROM e UID_LOKI abaixo.
"""
import json, os

UID_PROM = "PBFA97CFB590B2093"   # <- buscar via API
UID_LOKI = "P8E80F9AEF21F6940"   # <- buscar via API

# helpers

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

# Dashboard 1: Linux System Overview
def dash_linux_overview():
    H = "$host"
    panels = [
        row(1, "Resumo do Sistema", y=0),
        stat(2, "Uptime",
             f'(time() - node_boot_time_seconds{{host=~"{H}"}}) / 86400',
             unit="d", x=0, y=1, w=4, h=4,
             thresholds=[{"color": "green", "value": None}]),
        stat(3, "Load Average 1m", f'node_load1{{host=~"{H}"}}',
             unit="short", x=4, y=1, w=4, h=4,
             thresholds=[{"color":"green","value":None},{"color":"yellow","value":2},{"color":"red","value":4}]),
        stat(4, "CPU Cores",
             f'count(node_cpu_seconds_total{{host=~"{H}",mode="idle"}})',
             unit="short", x=8, y=1, w=4, h=4),
        stat(5, "RAM Total",
             f'node_memory_MemTotal_bytes{{host=~"{H}"}}',
             unit="bytes", x=12, y=1, w=4, h=4),
        stat(6, "RAM Disponivel",
             f'node_memory_MemAvailable_bytes{{host=~"{H}"}}',
             unit="bytes", x=16, y=1, w=4, h=4,
             thresholds=[{"color":"red","value":None},{"color":"yellow","value":536870912},{"color":"green","value":1073741824}]),
        stat(7, "Processos Rodando",
             f'node_procs_running{{host=~"{H}"}}',
             unit="short", x=20, y=1, w=4, h=4),
        row(10, "CPU", y=5),
        timeseries(11, "CPU Usage por Modo (%)",
            [{"ds": UID_PROM,
              "expr": f'sum by (mode) (rate(node_cpu_seconds_total{{host=~"{H}",mode!="idle"}}[5m])) * 100',
              "legend": "{{mode}}"}],
            unit="percent", x=0, y=6, w=16, h=8),
        gauge(12, "CPU Usado (%)",
            f'100 - (avg(rate(node_cpu_seconds_total{{host=~"{H}",mode="idle"}}[5m])) * 100)',
            unit="percent", x=16, y=6, w=8, h=8),
        timeseries(13, "Load Average",
            [{"ds": UID_PROM, "expr": f'node_load1{{host=~"{H}"}}', "legend": "1m"},
             {"ds": UID_PROM, "expr": f'node_load5{{host=~"{H}"}}', "legend": "5m"},
             {"ds": UID_PROM, "expr": f'node_load15{{host=~"{H}"}}', "legend": "15m"}],
            unit="short", x=0, y=14, w=12, h=7),
        timeseries(14, "Processos",
            [{"ds": UID_PROM, "expr": f'node_procs_running{{host=~"{H}"}}', "legend": "running"},
             {"ds": UID_PROM, "expr": f'node_procs_blocked{{host=~"{H}"}}', "legend": "blocked"}],
            unit="short", x=12, y=14, w=12, h=7),
        row(20, "Memoria", y=21),
        timeseries(21, "Uso de Memoria",
            [{"ds": UID_PROM, "expr": f'node_memory_MemTotal_bytes{{host=~"{H}"}}', "legend": "Total"},
             {"ds": UID_PROM, "expr": f'node_memory_MemAvailable_bytes{{host=~"{H}"}}', "legend": "Disponivel"},
             {"ds": UID_PROM,
              "expr": f'node_memory_MemTotal_bytes{{host=~"{H}"}} - node_memory_MemAvailable_bytes{{host=~"{H}"}}',
              "legend": "Usado"}],
            unit="bytes", x=0, y=22, w=16, h=8),
        gauge(22, "Memoria Usada (%)",
            f'(1 - node_memory_MemAvailable_bytes{{host=~"{H}"}} / node_memory_MemTotal_bytes{{host=~"{H}"}}) * 100',
            unit="percent", x=16, y=22, w=8, h=8),
        timeseries(23, "Memoria Detalhada",
            [{"ds": UID_PROM, "expr": f'node_memory_Buffers_bytes{{host=~"{H}"}}', "legend": "Buffers"},
             {"ds": UID_PROM, "expr": f'node_memory_Cached_bytes{{host=~"{H}"}}', "legend": "Cached"},
             {"ds": UID_PROM, "expr": f'node_memory_SwapTotal_bytes{{host=~"{H}"}}', "legend": "Swap Total"},
             {"ds": UID_PROM, "expr": f'node_memory_SwapFree_bytes{{host=~"{H}"}}', "legend": "Swap Livre"}],
            unit="bytes", x=0, y=30, w=24, h=7),
        row(30, "Disco", y=37),
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
        timeseries(34, "Latencia de Disco (ms)",
            [{"ds": UID_PROM,
              "expr": f'rate(node_disk_read_time_seconds_total{{host=~"{H}"}}[5m]) / rate(node_disk_reads_completed_total{{host=~"{H}"}}[5m]) * 1000',
              "legend": "Read latency {{device}}"},
             {"ds": UID_PROM,
              "expr": f'rate(node_disk_write_time_seconds_total{{host=~"{H}"}}[5m]) / rate(node_disk_writes_completed_total{{host=~"{H}"}}[5m]) * 1000',
              "legend": "Write latency {{device}}"}],
            unit="ms", x=12, y=46, w=12, h=7),
        row(40, "Rede", y=53),
        timeseries(41, "Trafego de Rede (bytes/s)",
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
        timeseries(44, "Conexoes TCP",
            [{"ds": UID_PROM, "expr": f'node_netstat_Tcp_CurrEstab{{host=~"{H}"}}', "legend": "Estabelecidas"},
             {"ds": UID_PROM, "expr": f'node_sockstat_TCP_inuse{{host=~"{H}"}}', "legend": "Em uso"}],
            unit="short", x=12, y=62, w=12, h=6),
        row(50, "Sistema", y=68),
        timeseries(51, "File Descriptors",
            [{"ds": UID_PROM, "expr": f'node_filefd_allocated{{host=~"{H}"}}', "legend": "Abertos"},
             {"ds": UID_PROM, "expr": f'node_filefd_maximum{{host=~"{H}"}}', "legend": "Maximo"}],
            unit="short", x=0, y=69, w=12, h=7),
        timeseries(52, "Context Switches e Interrupcoes",
            [{"ds": UID_PROM, "expr": f'rate(node_context_switches_total{{host=~"{H}"}}[5m])', "legend": "Context switches/s"},
             {"ds": UID_PROM, "expr": f'rate(node_intr_total{{host=~"{H}"}}[5m])', "legend": "Interrupcoes/s"}],
            unit="short", x=12, y=69, w=12, h=7),
    ]
    return dashboard(
        title="Linux System Overview",
        uid="linux-overview-v1",
        desc="CPU, Memoria, Disco, Rede e Sistema por host",
        panels=panels,
        variables=[var_host()],
        refresh="30s"
    )

# Dashboard 2: Logs & Analise
def dash_logs():
    H = "$host"
    panels = [
        row(1, "Resumo de Logs", y=0),
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
        row(10, "Taxa de Logs", y=5),
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
        row(30, "Erros Recentes", y=22),
        logs_panel(31, "Erros e Falhas",
            f'{{job="systemd-journal", host=~"{H}"}} |~ "(?i)(error|failed|failure|critical|fatal)"',
            x=0, y=23, w=24, h=12),
        row(40, "Logs Recentes do Journal", y=35),
        logs_panel(41, "systemd-journal",
            f'{{job="systemd-journal", host=~"{H}"}}',
            x=0, y=36, w=24, h=12),
        row(60, "Seguranca e Autenticacao", y=48),
        {
            "id": 61, "type": "timeseries", "title": "Tentativas de Login SSH",
            "gridPos": gridpos(0, 49, 12, 7),
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
        logs_panel(62, "Eventos de Seguranca (sudo, ssh, auth)",
            f'{{job="systemd-journal", host=~"{H}"}} |~ "(?i)(sudo|sshd|authentication|unauthorized|invalid user)"',
            x=12, y=49, w=12, h=7),
        row(70, "Servicos Systemd", y=56),
        logs_panel(71, "Falhas de Servico (systemd)",
            f'{{job="systemd-journal", host=~"{H}"}} |~ "(?i)(failed|start request|stopped|killed)"',
            x=0, y=57, w=24, h=10),
    ]
    return dashboard(
        title="Logs e Analise",
        uid="logs-analysis-v1",
        desc="Analise de logs via Loki - taxa, erros, seguranca, servicos",
        panels=panels,
        variables=[var_loki_host()],
        refresh="30s"
    )

# Dashboard 3: Comparacao de Infraestrutura
def dash_infra_compare():
    panels = [
        row(1, "Visao Geral - Todos os Hosts", y=0),
        table_panel(2, "Status Atual dos Hosts",
            [{"expr": 'node_load1', "legend": ""},
             {"expr": '(1 - node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes)*100', "legend": ""},
             {"expr": '100 - avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m]))*100', "legend": ""}],
            x=0, y=1, w=24, h=8),
        row(10, "CPU - Comparacao", y=9),
        timeseries(11, "CPU Usage % - Todos os Hosts",
            [{"ds": UID_PROM,
              "expr": '100 - (avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)',
              "legend": "{{host}}"}],
            unit="percent", x=0, y=10, w=24, h=8),
        timeseries(12, "Load Average 1m - Todos os Hosts",
            [{"ds": UID_PROM, "expr": "node_load1", "legend": "{{host}}"}],
            unit="short", x=0, y=18, w=12, h=7),
        timeseries(13, "Load Average 5m - Todos os Hosts",
            [{"ds": UID_PROM, "expr": "node_load5", "legend": "{{host}}"}],
            unit="short", x=12, y=18, w=12, h=7),
        row(20, "Memoria - Comparacao", y=25),
        timeseries(21, "Memoria Usada % - Todos os Hosts",
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
        row(30, "Disco - Comparacao", y=34),
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
        timeseries(32, "I/O de Disco Total (bytes/s) - Todos os Hosts",
            [{"ds": UID_PROM,
              "expr": 'sum by (host) (rate(node_disk_read_bytes_total[5m]) + rate(node_disk_written_bytes_total[5m]))',
              "legend": "{{host}}"}],
            unit="Bps", x=12, y=35, w=12, h=8),
        row(40, "Rede - Comparacao", y=43),
        timeseries(41, "Trafego RX - Todos os Hosts",
            [{"ds": UID_PROM,
              "expr": 'sum by (host) (rate(node_network_receive_bytes_total{device!~"lo|veth.*"}[5m]))',
              "legend": "{{host}}"}],
            unit="Bps", x=0, y=44, w=12, h=8),
        timeseries(42, "Trafego TX - Todos os Hosts",
            [{"ds": UID_PROM,
              "expr": 'sum by (host) (rate(node_network_transmit_bytes_total{device!~"lo|veth.*"}[5m]))',
              "legend": "{{host}}"}],
            unit="Bps", x=12, y=44, w=12, h=8),
        row(50, "Logs - Comparacao", y=52),
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
        title="Infrastructure Comparison",
        uid="infra-compare-v1",
        desc="Comparacao lado a lado de todos os hosts - CPU, RAM, Disco, Rede, Logs",
        panels=panels,
        variables=[],
        refresh="30s"
    )

# main
if __name__ == "__main__":
    out_dir = os.path.dirname(os.path.abspath(__file__))
    dashboards = [
        ("dashboard_linux_overview.json", dash_linux_overview()),
        ("dashboard_logs_analysis.json",  dash_logs()),
        ("dashboard_infra_compare.json",  dash_infra_compare()),
    ]
    for fname, dash in dashboards:
        path = os.path.join(out_dir, fname)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(dash, f, indent=2, ensure_ascii=False)
        print(f"OK  {fname}  ({os.path.getsize(path)//1024} KB)")
```

---

## 5. Problemas Conhecidos e Solucoes

### "Data source not found" em todos os paineis

**Causa:** UIDs no JSON nao correspondem aos UIDs do Grafana atual.

**Fix:**
```bash
# Buscar UIDs atuais
curl -s -u admin:'SENHA' http://IP:3000/api/datasources | python3 -c "
import json,sys
for ds in json.load(sys.stdin):
    print(f\"{ds['name']}: {ds['uid']}\")
"

# Atualizar PROMETHEUS_UID e LOKI_UID no gerar_dashboards.py
# Re-executar o script e re-copiar os JSONs
```

---

### Painel Loki vazio / "No data"

**Passos de diagnostico:**

1. Verificar se Loki esta recebendo logs:
```bash
curl -s 'http://192.168.137.200:3100/loki/api/v1/labels' | python3 -m json.tool
# deve retornar labels incluindo "host" e "job"
```

2. Verificar se o job existe:
```bash
curl -s 'http://192.168.137.200:3100/loki/api/v1/label/job/values'
# deve incluir "systemd-journal"
```

3. Testar query diretamente:
```bash
curl -G -s 'http://192.168.137.200:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={job="systemd-journal"}' \
  --data-urlencode 'limit=5' \
  --data-urlencode "start=$(date -d '5 minutes ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000"
```

---

### Erro: `queries require at least one regexp or equality matcher`

**Causa:** Query usa `host=~".*"` que o Loki 3.6 rejeita.

**Fix:** Trocar `.*` por `.+` ou adicionar matcher fixo:
```logql
# ERRADO
{job="systemd-journal", host=~".*"}

# CORRETO
{job="systemd-journal", host=~".+"}
# ou
{job="systemd-journal"}
```

---

### Variavel `$host` nao lista hosts

**Causa:** Query da variavel usa formato Prometheus (`label_values(...)`).

**Fix:** Editar a variavel no dashboard:
- Tipo: `Query`
- Data source: Loki
- Query:
```json
{"label": "host", "stream": "{job=\"systemd-journal\"}", "type": 1}
```
- `Include All`: desativado (`includeAll: false`)

---

## 6. Estrutura do JSON de Dashboard (Resumo)

Para criar dashboards programaticamente, os campos criticos sao:

```json
{
  "uid": "meu-dashboard-v1",
  "title": "Titulo do Dashboard",
  "refresh": "30s",
  "time": {"from": "now-1h", "to": "now"},
  "templating": {
    "list": [
      {
        "name": "host",
        "type": "query",
        "datasource": {"type": "loki", "uid": "LOKI_UID"},
        "query": {"label": "host", "stream": "{job=\"systemd-journal\"}", "type": 1},
        "includeAll": false
      }
    ]
  },
  "panels": [
    {
      "title": "Meu Painel",
      "type": "timeseries",
      "datasource": {"type": "prometheus", "uid": "PROMETHEUS_UID"},
      "targets": [
        {
          "expr": "node_load1",
          "legendFormat": "{{instance}}"
        }
      ]
    }
  ]
}
```

---

## 7. Checklist de Deploy em Novo Ambiente

- [ ] Grafana instalado e acessivel em `:3000`
- [ ] Datasources configurados (Prometheus + Loki)
- [ ] Buscar UIDs reais: `curl -s -u admin:SENHA http://IP:3000/api/datasources`
- [ ] Atualizar UIDs no `gerar_dashboards.py`
- [ ] Executar `python3 gerar_dashboards.py`
- [ ] Copiar JSONs para `/var/lib/grafana/dashboards/`
- [ ] Verificar que `/etc/grafana/provisioning/dashboards/default.yml` aponta para essa pasta
- [ ] Recarregar: `curl -X POST -u admin:SENHA http://IP:3000/api/admin/provisioning/dashboards/reload`
- [ ] Abrir Grafana e verificar os 3 dashboards no menu

---

*Ver tambem: `playbook_referencia.md` (secao 13) para problemas na instalacao manual.*
