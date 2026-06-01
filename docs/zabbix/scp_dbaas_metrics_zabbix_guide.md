---
tags: [scp, dbaas, monitoring, zabbix, api, cli, metrics, cloud]
created: 2026-05-18
status: reference
---

# 16 — DBaaS Metrics: SCP Cloud via API + CLI + Zabbix Integration

> **Goal:** Collect metrics from DBaaS instances on Samsung Cloud Platform (SCP) via API and CLI, then feed those metrics into Zabbix for alerting and dashboards.
> 
> **Reference model:** SCP architecture mirrors AWS closely. Where SCP docs are not available, AWS equivalents (CloudWatch / RDS) are shown with `[AWS equiv]` tags so you can map concepts.

---

## Table of Contents

- [[#1. Concepts — How Cloud Metrics Work]]
- [[#2. Prerequisites]]
- [[#3. Method 1 — CLI (scp-cli)]]
- [[#4. Method 2 — REST API (curl + Python)]]
- [[#5. Automation Script — Collect and Export Metrics]]
- [[#6. Zabbix Integration]]
- [[#7. Practical Challenges]]

---

## 1. Concepts — How Cloud Metrics Work

Cloud platforms expose DB metrics through a **monitoring service** — not by connecting directly to the DB engine.

```
[DBaaS instance] ──► [SCP Monitoring Service] ──► [API endpoint] ──► [your script] ──► [Zabbix]
                          (CloudWatch equiv)
```

**Why this matters:** You don't need DB credentials to collect metrics like CPU, IOPS, connections, or storage. The cloud platform collects these from the hypervisor/storage layer and exposes them as time-series data. Your script authenticates to the **cloud API**, not the DB itself.

### Key SCP concepts (with AWS parallels)

| SCP Term                    | AWS Equivalent     | What it is                                          |
|-----------------------------|--------------------|-----------------------------------------------------|
| SCP Monitoring              | CloudWatch         | Time-series metric store for all cloud resources    |
| DBaaS Instance ID           | RDS DB Identifier  | Unique resource identifier for your DB              |
| Access Key ID + Secret Key  | AWS Access Key     | API credentials for programmatic access             |
| SCP Region                  | AWS Region         | Geographic location of your resources               |
| Namespace                   | CloudWatch NS      | Metric category (e.g., `SCP/DBaaS`)                 |
| Metric Name                 | MetricName         | e.g., `CPUUtilization`, `FreeStorageSpace`          |
| Statistics                  | Statistics         | Average, Maximum, Sum, SampleCount                  |
| Period                      | Period             | Aggregation window in seconds (60, 300, 3600...)    |

---

## 2. Prerequisites

### 2.1 SCP API Credentials

You need an **Access Key ID** and **Secret Access Key** from SCP IAM (Identity and Access Management).

1. Log in to SCP Console → IAM → Users → your user → **Security Credentials**
2. Create **Access Key** → save both `AccessKeyId` and `SecretAccessKey` immediately (secret shown once)
3. Assign the following policy/permission to the key (or user):
   - `monitoring:GetMetricData` — read metrics
   - `monitoring:ListMetrics` — discover available metrics
   - `dbaas:DescribeInstances` — list your DBaaS instances

> **Security note:** Never hardcode credentials in scripts. Use environment variables or a credentials file.

### 2.2 Store credentials securely

```bash
# Option A: environment variables (good for scripts/cron)
export SCP_ACCESS_KEY_ID="AKIAXXXXXXXXXXXXXXXX"
export SCP_SECRET_ACCESS_KEY="xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export SCP_REGION="kr-central-1"              # your SCP region

# Option B: credentials file (good for CLI)
mkdir -p ~/.scp
cat > ~/.scp/credentials << 'EOF'
[default]
access_key_id = AKIAXXXXXXXXXXXXXXXX
secret_access_key = xxxxxxxxxxxxxxxxxxxxxxxxxxxx
region = kr-central-1
EOF
chmod 600 ~/.scp/credentials
```

### 2.3 Python environment

```bash
# Install required libraries
pip3 install requests boto3 python-dateutil

# If SCP has an official SDK:
# pip3 install scp-sdk    (check SCP docs for official package name)
```

> **boto3 note:** If SCP's API is S3/CloudWatch-compatible (many platforms are), boto3 works with a custom `endpoint_url`. This is the most common approach for AWS-like clouds.

---

## 3. Method 1 — CLI (scp-cli)

### 3.1 Install SCP CLI

```bash
# Download and install (Linux/RHEL)
curl -O https://cli.samsungcloud.com/install.sh    # check official SCP docs for real URL
sudo bash install.sh

# Verify
scp-cli --version

# Configure
scp-cli configure
# Prompts: Access Key ID, Secret Access Key, Region, Output format (json/table/text)
```

> **[AWS equiv]:** This is identical to `aws configure`. Credentials stored in `~/.scp/credentials`.

### 3.2 List your DBaaS instances

```bash
# List all DBaaS instances
scp-cli dbaas describe-instances

# Filter by engine (mysql, postgresql, sqlserver, oracle)
scp-cli dbaas describe-instances --engine mysql

# Output as table (human-readable)
scp-cli dbaas describe-instances --output table
```

Note the **Instance ID** from output — you need it for all metric queries.

### 3.3 List available metrics for a DBaaS instance

```bash
# List all metrics available for your DBaaS namespace
scp-cli monitoring list-metrics \
  --namespace SCP/DBaaS \
  --dimensions Name=DBInstanceIdentifier,Value=my-mysql-prod-01

# [AWS equiv]:
# aws cloudwatch list-metrics \
#   --namespace AWS/RDS \
#   --dimensions Name=DBInstanceIdentifier,Value=my-db
```

### 3.4 Get a specific metric value

```bash
# Get average CPU utilization for last 5 minutes
scp-cli monitoring get-metric-statistics \
  --namespace SCP/DBaaS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=my-mysql-prod-01 \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Average

# Output example (JSON):
# {
#   "Datapoints": [
#     {"Timestamp": "2026-05-18T10:00:00Z", "Average": 12.34, "Unit": "Percent"}
#   ],
#   "Label": "CPUUtilization"
# }
```

### 3.5 Common DBaaS metrics to query

| Metric Name              | Unit        | What it measures                          |
|--------------------------|-------------|-------------------------------------------|
| `CPUUtilization`         | Percent     | DB engine CPU usage                       |
| `FreeStorageSpace`       | Bytes       | Available disk space                      |
| `DatabaseConnections`    | Count       | Active client connections                 |
| `ReadIOPS`               | Count/sec   | Read operations per second                |
| `WriteIOPS`              | Count/sec   | Write operations per second               |
| `ReadLatency`            | Seconds     | Average read I/O latency                  |
| `WriteLatency`           | Seconds     | Average write I/O latency                 |
| `FreeableMemory`         | Bytes       | Available RAM                             |
| `NetworkReceiveThroughput` | Bytes/sec | Inbound network traffic                   |
| `NetworkTransmitThroughput` | Bytes/sec| Outbound network traffic                  |
| `ReplicaLag`             | Seconds     | Replication lag (replicas only)           |

### 3.6 Quick shell script to check all critical metrics

```bash
#!/bin/bash
# File: check_dbaas_metrics.sh
# Usage: ./check_dbaas_metrics.sh my-mysql-prod-01

INSTANCE_ID="${1:?Usage: $0 <instance-id>}"
NAMESPACE="SCP/DBaaS"
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_TIME=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

METRICS=("CPUUtilization" "DatabaseConnections" "FreeStorageSpace" "ReadIOPS" "WriteIOPS")

for METRIC in "${METRICS[@]}"; do
  echo "--- $METRIC ---"
  scp-cli monitoring get-metric-statistics \
    --namespace "$NAMESPACE" \
    --metric-name "$METRIC" \
    --dimensions "Name=DBInstanceIdentifier,Value=${INSTANCE_ID}" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 300 \
    --statistics Average \
    --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
pts = data.get('Datapoints', [])
if pts:
    latest = sorted(pts, key=lambda x: x['Timestamp'])[-1]
    print(f\"  Value: {latest.get('Average', latest.get('Sum', 'N/A'))}\")
    print(f\"  Time:  {latest['Timestamp']}\")
else:
    print('  No datapoints returned')
"
done
```

---

## 4. Method 2 — REST API (curl + Python)

### 4.1 SCP API Authentication (AWS Signature V4)

SCP uses **AWS Signature Version 4** (the same signing algorithm as AWS). Every API request must be signed with your secret key.

**Why Sig V4?** It prevents credential theft in transit and replay attacks. The signature includes timestamp + request body hash, so stolen signed requests expire in 15 minutes.

#### curl example (manual signing is complex — use Python for production)

```bash
# This is for understanding the flow — use Python boto3 in real scripts
# SCP Monitoring endpoint (verify exact URL in SCP docs)
SCP_ENDPOINT="https://monitoring.samsungcloud.com"

# List metrics via curl (requires signing — shown simplified)
curl -X POST "${SCP_ENDPOINT}/" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Amz-Date: $(date -u +%Y%m%dT%H%M%SZ)" \
  --data-urlencode "Action=ListMetrics" \
  --data-urlencode "Namespace=SCP/DBaaS" \
  --aws-sigv4 "aws:amz:kr-central-1:monitoring" \
  --user "${SCP_ACCESS_KEY_ID}:${SCP_SECRET_ACCESS_KEY}"
# Note: --aws-sigv4 available in curl 7.75+
```

### 4.2 Python with boto3 (recommended approach)

boto3 handles Signature V4 automatically and works with any AWS-compatible API endpoint.

```python
#!/usr/bin/env python3
# File: scp_metrics.py
"""
Collect DBaaS metrics from SCP (Samsung Cloud Platform) monitoring API.
Uses boto3 with custom endpoint_url for SCP compatibility.
"""

import boto3
import os
from datetime import datetime, timedelta, timezone

# --- Configuration ---
SCP_ENDPOINT   = os.environ.get("SCP_MONITORING_ENDPOINT", "https://monitoring.samsungcloud.com")
SCP_REGION     = os.environ.get("SCP_REGION", "kr-central-1")
ACCESS_KEY_ID  = os.environ.get("SCP_ACCESS_KEY_ID")
SECRET_KEY     = os.environ.get("SCP_SECRET_ACCESS_KEY")
INSTANCE_ID    = os.environ.get("SCP_DBAAS_INSTANCE_ID", "my-mysql-prod-01")
NAMESPACE      = "SCP/DBaaS"

# --- Client setup ---
cloudwatch = boto3.client(
    "cloudwatch",
    endpoint_url=SCP_ENDPOINT,          # point boto3 to SCP instead of AWS
    region_name=SCP_REGION,
    aws_access_key_id=ACCESS_KEY_ID,
    aws_secret_access_key=SECRET_KEY,
)

def get_metric(metric_name: str, statistic: str = "Average", period: int = 300) -> float | None:
    """Fetch latest datapoint for a metric. Returns None if no data."""
    end   = datetime.now(timezone.utc)
    start = end - timedelta(seconds=period * 2)   # 2x period buffer for latency

    response = cloudwatch.get_metric_statistics(
        Namespace=NAMESPACE,
        MetricName=metric_name,
        Dimensions=[{"Name": "DBInstanceIdentifier", "Value": INSTANCE_ID}],
        StartTime=start,
        EndTime=end,
        Period=period,
        Statistics=[statistic],
    )

    datapoints = response.get("Datapoints", [])
    if not datapoints:
        return None

    latest = sorted(datapoints, key=lambda x: x["Timestamp"])[-1]
    return latest.get(statistic)


def collect_all_metrics() -> dict:
    """Collect all key DBaaS metrics and return as dict."""
    metrics_config = [
        ("CPUUtilization",             "Average", "%"),
        ("DatabaseConnections",        "Average", "count"),
        ("FreeStorageSpace",           "Average", "bytes"),
        ("FreeableMemory",             "Average", "bytes"),
        ("ReadIOPS",                   "Average", "ops/s"),
        ("WriteIOPS",                  "Average", "ops/s"),
        ("ReadLatency",                "Average", "s"),
        ("WriteLatency",               "Average", "s"),
        ("NetworkReceiveThroughput",   "Average", "bytes/s"),
        ("NetworkTransmitThroughput",  "Average", "bytes/s"),
        ("ReplicaLag",                 "Average", "s"),
    ]

    results = {}
    for metric_name, statistic, unit in metrics_config:
        value = get_metric(metric_name, statistic)
        results[metric_name] = {"value": value, "unit": unit, "statistic": statistic}
        print(f"  {metric_name:40s} = {value:>12.4f} {unit}" if value is not None
              else f"  {metric_name:40s} = NO DATA")

    return results


if __name__ == "__main__":
    print(f"Collecting metrics for instance: {INSTANCE_ID}")
    print(f"Endpoint: {SCP_ENDPOINT} | Region: {SCP_REGION}\n")
    metrics = collect_all_metrics()
```

Run:

```bash
export SCP_ACCESS_KEY_ID="AKIAXXXXXXXXXXXXXXXX"
export SCP_SECRET_ACCESS_KEY="xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export SCP_REGION="kr-central-1"
export SCP_MONITORING_ENDPOINT="https://monitoring.samsungcloud.com"
export SCP_DBAAS_INSTANCE_ID="my-mysql-prod-01"

python3 scp_metrics.py
```

---

## 5. Automation Script — Collect and Export Metrics

This script collects metrics and writes them in a format ready for Zabbix.

```python
#!/usr/bin/env python3
# File: /usr/local/bin/scp_dbaas_exporter.py
"""
SCP DBaaS metric exporter for Zabbix external checks.
Called by Zabbix with: scp_dbaas_exporter.py <instance_id> <metric_name>
Prints a single numeric value to stdout. Zabbix reads this value.
"""

import sys
import boto3
import os
from datetime import datetime, timedelta, timezone

def get_metric_value(instance_id: str, metric_name: str) -> str:
    """Returns single metric value as string, or 'ZBX_NOTSUPPORTED' on error."""

    endpoint  = os.environ.get("SCP_MONITORING_ENDPOINT", "https://monitoring.samsungcloud.com")
    region    = os.environ.get("SCP_REGION", "kr-central-1")
    access_key = os.environ.get("SCP_ACCESS_KEY_ID")
    secret_key = os.environ.get("SCP_SECRET_ACCESS_KEY")

    if not access_key or not secret_key:
        return "ZBX_NOTSUPPORTED: Missing SCP credentials in environment"

    try:
        cw = boto3.client(
            "cloudwatch",
            endpoint_url=endpoint,
            region_name=region,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
        )

        end   = datetime.now(timezone.utc)
        start = end - timedelta(minutes=10)

        response = cw.get_metric_statistics(
            Namespace="SCP/DBaaS",
            MetricName=metric_name,
            Dimensions=[{"Name": "DBInstanceIdentifier", "Value": instance_id}],
            StartTime=start,
            EndTime=end,
            Period=300,
            Statistics=["Average"],
        )

        datapoints = response.get("Datapoints", [])
        if not datapoints:
            return "ZBX_NOTSUPPORTED: No datapoints returned"

        latest = sorted(datapoints, key=lambda x: x["Timestamp"])[-1]
        value = latest.get("Average", 0)

        # Convert bytes to GB for storage/memory metrics for readability
        # (Zabbix can also do this with multipliers — keep raw bytes here)
        return str(value)

    except Exception as e:
        return f"ZBX_NOTSUPPORTED: {e}"


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: scp_dbaas_exporter.py <instance_id> <metric_name>")
        sys.exit(1)

    _, instance_id, metric_name = sys.argv
    print(get_metric_value(instance_id, metric_name))
```

---

## 6. Zabbix Integration

### 6.1 Architecture overview

```
[Zabbix Server/Proxy]
     │
     ├── External Check  ──► scp_dbaas_exporter.py (Python script, runs on Zabbix server)
     │                              │
     │                              └──► SCP Monitoring REST API ──► metric value
     │
     └── HTTP Agent      ──► SCP API directly (no script, pure Zabbix)
```

**Recommendation: use External Check** — easier to debug, handles Sig V4 signing in Python, reusable script. HTTP Agent requires manually implementing Sig V4 in Zabbix macros/preprocessing, which is complex.

---

### 6.2 Method A — External Check (recommended)

#### Step 1: Deploy script on Zabbix server

```bash
# Copy script to Zabbix external scripts directory
sudo cp scp_dbaas_exporter.py /usr/lib/zabbix/externalscripts/
sudo chmod 755 /usr/lib/zabbix/externalscripts/scp_dbaas_exporter.py
sudo chown zabbix:zabbix /usr/lib/zabbix/externalscripts/scp_dbaas_exporter.py
```

#### Step 2: Set credentials for zabbix user

```bash
# Create environment file for zabbix service
sudo cat > /etc/zabbix/scp_credentials.env << 'EOF'
SCP_ACCESS_KEY_ID=AKIAXXXXXXXXXXXXXXXX
SCP_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxx
SCP_REGION=kr-central-1
SCP_MONITORING_ENDPOINT=https://monitoring.samsungcloud.com
EOF
sudo chmod 600 /etc/zabbix/scp_credentials.env
sudo chown zabbix:zabbix /etc/zabbix/scp_credentials.env
```

Add to `/etc/zabbix/zabbix_server.conf` or zabbix service unit:

```bash
# /etc/systemd/system/zabbix-server.service.d/scp_env.conf
[Service]
EnvironmentFile=/etc/zabbix/scp_credentials.env
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart zabbix-server
```

#### Step 3: Test script manually as zabbix user

```bash
sudo -u zabbix /usr/lib/zabbix/externalscripts/scp_dbaas_exporter.py \
  my-mysql-prod-01 CPUUtilization
# Expected output: 12.34  (just the number)
```

#### Step 4: Create Zabbix items

In Zabbix UI: **Configuration → Hosts → your host → Items → Create item**

| Field            | Value                                                                 |
|------------------|-----------------------------------------------------------------------|
| Name             | `SCP DBaaS: CPU Utilization`                                         |
| Type             | `External check`                                                      |
| Key              | `scp_dbaas_exporter.py[my-mysql-prod-01,CPUUtilization]`             |
| Type of info     | `Numeric (float)`                                                     |
| Units            | `%`                                                                   |
| Update interval  | `5m`                                                                  |
| History          | `90d`                                                                 |
| Trends           | `365d`                                                                |

Repeat for each metric. Key pattern: `scp_dbaas_exporter.py[{$DBAAS_INSTANCE},{$METRIC}]`

**Using macros (better for multiple instances):**

| Macro                   | Value               |
|-------------------------|---------------------|
| `{$DBAAS_INSTANCE}`     | `my-mysql-prod-01`  |

Then item key becomes: `scp_dbaas_exporter.py[{$DBAAS_INSTANCE},CPUUtilization]`

#### Step 5: Create triggers

```
# CPU > 80% for 5 minutes
{host:scp_dbaas_exporter.py[{$DBAAS_INSTANCE},CPUUtilization].avg(5m)} > 80

# Connections > 80% of max_connections
{host:scp_dbaas_exporter.py[{$DBAAS_INSTANCE},DatabaseConnections].last()} > {$DBAAS_MAX_CONN} * 0.8

# Free storage < 10 GB
{host:scp_dbaas_exporter.py[{$DBAAS_INSTANCE},FreeStorageSpace].last()} < 10737418240

# Replica lag > 30 seconds
{host:scp_dbaas_exporter.py[{$DBAAS_INSTANCE},ReplicaLag].last()} > 30
```

---

### 6.3 Method B — Zabbix HTTP Agent (direct API call)

Use when you cannot run scripts on the Zabbix server (hosted Zabbix, restricted environments).

**Limitation:** Requires pre-signed URLs or an API gateway that removes the need for Sig V4 on Zabbix's side. Most practical if SCP supports API key auth via simple header (check SCP docs).

In Zabbix UI: **Configuration → Hosts → Items → Create item**

| Field                  | Value                                                                          |
|------------------------|--------------------------------------------------------------------------------|
| Type                   | `HTTP agent`                                                                   |
| URL                    | `https://monitoring.samsungcloud.com/`                                         |
| Request method         | `POST`                                                                         |
| Request body type      | `Raw data`                                                                     |
| Request body           | See below                                                                      |
| Headers                | `Content-Type: application/x-www-form-urlencoded`                              |
| Headers                | `X-Api-Key: {$SCP_API_KEY}` *(if SCP supports simple key auth)*                |
| Preprocessing          | `JSONPath: $.Datapoints[0].Average`                                            |

Request body:
```
Action=GetMetricStatistics&Namespace=SCP%2FDBaaS&MetricName=CPUUtilization&...
```

> This method is simpler only if SCP accepts `X-Api-Key` header auth. If Sig V4 is required, stick with Method A (External Check).

---

### 6.4 Zabbix Template structure (summary)

```
Template: SCP DBaaS Monitoring
├── Macros
│   ├── {$DBAAS_INSTANCE}    = my-mysql-prod-01
│   ├── {$DBAAS_MAX_CONN}    = 500
│   └── {$DBAAS_ENGINE}      = mysql
├── Items (External Check)
│   ├── CPU Utilization       → CPUUtilization
│   ├── Free Storage          → FreeStorageSpace
│   ├── Active Connections    → DatabaseConnections
│   ├── Freeable Memory       → FreeableMemory
│   ├── Read IOPS             → ReadIOPS
│   ├── Write IOPS            → WriteIOPS
│   ├── Read Latency          → ReadLatency
│   ├── Write Latency         → WriteLatency
│   └── Replica Lag           → ReplicaLag
├── Triggers
│   ├── HIGH: CPU > 80% (5m avg)
│   ├── HIGH: Free storage < 10 GB
│   ├── WARNING: Connections > 80% of max
│   ├── HIGH: Replica lag > 30s
│   └── DISASTER: Replica lag > 300s
└── Graphs
    ├── CPU + Connections (combined)
    ├── Storage free space (trend)
    └── IOPS (read vs write)
```

---

## 7. Practical Challenges

These reinforce the concepts above — work through them to internalize the flow.

1. **List all SCP DBaaS instances via CLI** and identify which engine (MySQL, PostgreSQL, etc.) each uses. Save the output to a file.

2. **Write a shell script** that accepts an instance ID and prints all 9 key metrics in a formatted table. Use `scp-cli monitoring get-metric-statistics`.

3. **Modify the Python exporter** to support `Maximum` and `Minimum` statistics in addition to `Average`. The Zabbix key should accept a third argument: `scp_dbaas_exporter.py[{$INSTANCE},ReadLatency,Maximum]`.

4. **Create a Zabbix item** for `FreeStorageSpace`. Add a Zabbix preprocessing step to convert bytes → GB (multiply by `0.000000000931322574`). Set a trigger at < 10 GB.

5. **Test what happens when credentials expire.** Change `SCP_SECRET_ACCESS_KEY` to an invalid value and run the exporter. Verify Zabbix receives `ZBX_NOTSUPPORTED` and generates a "no data" alert.

6. **For replica instances:** add a Zabbix trigger for `ReplicaLag > 30s` with severity WARNING and another for `> 300s` with DISASTER. Test by manually pausing replication (if you have a test DBaaS).

---

## Related Notes

- [[15_zabbix_odbc_monitoring]] — Zabbix ODBC direct DB monitoring (complement to this API approach)
- [[04_awx_api_controle]] — AWX API for automation control
- [[08_awx_operacoes_api]] — AWX operations via API
- [[14_variaveis_referencia_completa]] — Variables reference

---

*Documented: 2026-05-18 | Model: AWS-compatible (SCP) | Adjust endpoint URLs per official SCP documentation.*
