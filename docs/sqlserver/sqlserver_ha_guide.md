# SQL Server HA Guide — WSFC + FCI

## Architecture

Two Windows Server 2022 VMs in a workgroup WSFC cluster (no AD) running SQL Server 2025 as a Failover Cluster Instance (FCI). Shared storage provided by an iSCSI LUN exported from `repositoryvm`.

```
192.168.137.170  sqlvm01        ← Cluster node (active by default)
192.168.137.171  sqlvm02        ← Cluster node (standby)
192.168.137.172  SQLHACLUSTER   ← Cluster admin VIP
192.168.137.173  SQLHA-SQL:1433 ← SQL Server FCI VIP (clients connect here)

Shared disk: iSCSI LUN from repositoryvm (192.168.137.148) → drive S:
Quorum: File share witness  \\192.168.137.148\sqlwitness (Samba)
```

### How FCI works

- SQL Server is installed **once** as a clustered instance — not separately on each node
- All data/log files live on shared disk **S:** (iSCSI LUN)
- Only the **active node** has S: mounted and SQL Server running
- On failover: cluster unmounts S: from failed node → mounts on standby → starts SQL Server → VIP moves
- Clients always connect to `192.168.137.173:1433` — IP moves with the resource group

### Why repositoryvm for shared storage

The lab has no physical SAN. Proxmox `local-lvm` storage doesn't support concurrent multi-VM access. `repositoryvm` (already running) hosts an iSCSI target via `targetcli`, exporting a 40GB file-backed LUN. Both Windows nodes connect as iSCSI initiators — they see the same block device.

---

## Phases

| Phase | AWX Template | Playbook | What it does |
|---|---|---|---|
| 1 | SQL Server HA - VM Provisioning | `provision_sqlha_vms.yml` | Clone VMs from `templateWServer2022`, set IPs/hostnames |
| 2 | SQL Server HA - iSCSI Shared Storage | `setup_iscsi_storage.yml` | Create iSCSI target on repositoryvm; connect initiators on both nodes |
| 3 | SQL Server HA - WSFC Setup | `setup_wsfc.yml` | Install Failover-Clustering, exchange certs, create cluster, quorum, add disk resource |
| 4 | SQL Server HA - FCI Install | `setup_sql_fci.yml` | Download ISO, init shared disk, InstallFailoverCluster on primary, AddNode on secondary |
| 5 | SQL Server HA - Validation | `validate_sql_ha.yml` | Assert cluster + SQL Online, test failover + failback via `Move-ClusterGroup` |

> **Note:** The existing `deploy_sqlserver.yml` (standalone install) is **NOT used** for FCI nodes. FCI requires `ACTION=InstallFailoverCluster` which is a separate install flow.

---

## Roles reference

| Role | Purpose | Task files |
|---|---|---|
| `wsfc_setup` | WSFC cluster creation | 01_prerequisites, 02_certificates, 03_create_cluster, 04_verify_cluster, 05_quorum_witness, 06_add_cluster_disk |
| `iscsi_shared_storage` | iSCSI target (Linux) + initiator (Windows) | 01_iscsi_target, 02_iscsi_initiator, 03_verify_disk |
| `sql_fci_install` | SQL Server FCI install | 01_prepare, 02_install_primary, 03_add_secondary, 04_verify_fci |

---

## Key ports

| Port | Protocol | Purpose |
|---|---|---|
| 1433 | TCP | SQL Server client connections (FCI VIP) |
| 3260 | TCP | iSCSI (repositoryvm → Windows nodes) |
| 5985 | TCP | WinRM HTTP (Ansible) |
| 3343 | TCP/UDP | WSFC heartbeat |
| 135 | TCP | RPC (cluster coordination) |
| 445 | TCP | SMB (quorum witness share) |
| 3389 | TCP | RDP management |

---

## Tags reference

| Tag | Role | What it runs |
|---|---|---|
| `iscsi` | iscsi_shared_storage | All iSCSI tasks |
| `iscsi_target` | iscsi_shared_storage | targetcli setup on repositoryvm |
| `iscsi_initiator` | iscsi_shared_storage | Windows iSCSI initiator connect |
| `iscsi_verify` | iscsi_shared_storage | Disk visibility check |
| `wsfc` | wsfc_setup | All WSFC tasks |
| `wsfc_prereqs` | wsfc_setup | Feature install + hosts file + IPsec |
| `wsfc_certs` | wsfc_setup | Cert generation + exchange |
| `wsfc_create` | wsfc_setup | New-Cluster (DNS CAP) |
| `wsfc_verify` | wsfc_setup | Get-ClusterNode assertions |
| `wsfc_quorum` | wsfc_setup | Samba + Set-ClusterQuorum |
| `wsfc_disk` | wsfc_setup | Add iSCSI disk as cluster resource |
| `fci` | sql_fci_install | All FCI tasks |
| `fci_prepare` | sql_fci_install | ISO download + shared disk init |
| `fci_primary` | sql_fci_install | InstallFailoverCluster |
| `fci_secondary` | sql_fci_install | AddNode |
| `fci_verify` | sql_fci_install | Cluster resource + VIP + connect check |

---

## Verification commands

```powershell
# Cluster nodes:
Get-ClusterNode | Select Name, State

# All cluster resources:
Get-ClusterResource | Select Name, ResourceType, State, OwnerGroup, OwnerNode

# SQL resource owner (active node):
(Get-ClusterResource | Where-Object { $_.ResourceType -eq "SQL Server" }).OwnerNode

# Connect via FCI VIP:
sqlcmd -S "192.168.137.173,1433" -U sa -P <password> -C -Q "SELECT @@SERVERNAME, @@VERSION"

# Quorum:
Get-ClusterQuorum

# iSCSI sessions on Windows:
Get-IscsiSession | Select-Object TargetNodeAddress, ConnectionState
```

---

## AWX Job Templates

| Template | Playbook | Survey | Limit |
|---|---|---|---|
| SQL Server HA - VM Provisioning | `provision_sqlha_vms.yml` | `awx_survey_sqlha_provisioning.json` | — |
| SQL Server HA - iSCSI Shared Storage | `setup_iscsi_storage.yml` | — | `repositoryvm,sql_ha_nodes` |
| SQL Server HA - WSFC Setup | `setup_wsfc.yml` | `awx_survey_wsfc_setup.json` | `sql_ha_nodes` |
| SQL Server HA - FCI Install | `setup_sql_fci.yml` | `awx_survey_sql_fci.json` | `sql_ha_nodes` |
| SQL Server HA - Validation | `validate_sql_ha.yml` | — | `sql_ha_nodes` |

---

## Common errors and resolutions

| Error | Root cause | Fix |
|---|---|---|
| iSCSI disk not visible on Windows | MSiSCSI service not started or target unreachable | Verify port 3260 on repositoryvm open; restart MSiSCSI service; re-run `iscsi_initiator` tag |
| iSCSI disk "NOT_FOUND" after connect | targetcli LUN not exported correctly | `targetcli ls` on repositoryvm; check `generate_node_acls=1` and `authentication=0` |
| `New-Cluster` fails | IPsec blocks cluster ports or hosts file missing | Re-run `wsfc_prereqs` tag; verify peer IP in hosts file on both nodes |
| `Add-ClusterDisk` fails | Disk not initialized or still RAW | Re-run `fci_prepare` tag on primary; verify disk formatted S: |
| FCI install fails: cluster disk not found | `FAILOVERCLUSTERDISKS="Cluster Disk 1"` mismatch | Check actual resource name: `Get-ClusterResource | Where-Object ResourceType -eq 'Physical Disk'`; update ini accordingly |
| AddNode fails | Primary FCI not yet complete | Wait for SQL resource Online on primary before running secondary |
| VIP unreachable after failover | IP resource not moving with resource group | `Get-ClusterResource` check; manually bring Online: `Start-ClusterResource "SQL Server"` |
| SQL service fails to start after failover | Shared disk not online on new active node | Check iSCSI session active on new node; `Get-ClusterResource | Where-Object ResourceType -eq 'Physical Disk'` |
| WinRM timeout on cloned VM | Template WinRM not enabled | Boot VM manually, run `winrm quickconfig`, re-run provisioning Phase 1b |
