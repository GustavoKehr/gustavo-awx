# Oracle 19c AWX Runbook

Automates Oracle Database 19c installation on RHEL 9 via `playbooks/deploy_oracle.yml`.

## Prerequisites before running

1. The following files must exist on the AWX VM at `/opt/oracle/`:
   - `LINUX.X64_193000_db_home.zip` — Oracle 19c installer
   - `oracle-database-preinstall-19c-1.0.2.el9.x86_64.rpm` — preinstall RPM
   - `p6880880/OPatch/` — replacement OPatch
   - `p37641958/37641958/37642901/` — Release Update patch
   - `p37641958/37641958/37643161/` — one-off patch
   - `p38291812/38291812/` — post-install patch
   - `p32249704/32249704/` — post-install patch
   - `p3467298/3467298/` — post-install patch

2. AWX Execution Environment must have `/opt/oracle` mounted (already configured via operator patch).

3. The target VM (`oraclevm`, 192.168.137.158) must be running.

## Installation phases and tags

| Tag | Phase |
|---|---|
| `oracle_validate` | Variable assertion (SID, passwords) |
| `oracle_prereqs` | Install preinstall RPM, sysctl, init.d backup |
| `oracle_dirs` | Create directory layout, deploy config templates |
| `oracle_transfer` | Rsync software from AWX to target VM |
| `oracle_install_sw` | Unzip, OPatch swap, runInstaller (silent) |
| `oracle_patches` | Apply p38291812 → p32249704 → oradism → p3467298 → oradism restore |
| `oracle_dbcreate` | Create database, run catalog, datapatch, compile invalid objects |

## Standard job patterns

- **Full install (all phases):** run `deploy_oracle.yml` with no tags
- **Re-run only DB creation:** tag `oracle_dbcreate`
- **Re-transfer software only:** tag `oracle_transfer`
- **Patches only:** tag `oracle_patches`

## AWX job template setup

- Playbook: `playbooks/deploy_oracle.yml`
- Inventory: LINUX (limit to `oraclevm`)
- Credential: `user_aap`
- Survey file: `playbooks/awx_survey_oracle_install.json`
- Execution Environment: AWX EE 24.6.1 (has `/opt/oracle` mounted)

## Key variables

All variables below are exposed as AWX survey questions. The defaults in `roles/oracle_install/defaults/main.yml` serve as fallbacks only.

### Identity and passwords

| Variable | Default | Description |
|---|---|---|
| `oracle_sid` | `TSTOR` | SID + base directory name |
| `oracle_sys_password` | — | SYS DBA password (required) |
| `oracle_system_password` | — | SYSTEM password (required) |

### Memory and tuning

| Variable | Default | Description |
|---|---|---|
| `oracle_sga_target` | `2G` | SGA size (e.g. `2G`, `4G`, `1024M`) |
| `oracle_pga_target` | `512m` | PGA aggregate target |
| `oracle_hugepages` | `0` | Hugepages count. **0 = auto-calculate from SGA.** Set a fixed value only to override for a specific VM |
| `oracle_hugepage_size_mb` | `2` | Hugepage size in MB (default on x86_64) |
| `oracle_hugepages_overhead_pct` | `10` | % overhead added over the SGA requirement |
| `oracle_processes` | `1000` | Max OS processes |
| `oracle_open_cursors` | `3000` | Max open cursors per session |

> **HugePages auto-calculation:** when `oracle_hugepages = 0`, the role computes `ceil(SGA_MB / hugepage_size_MB) × (1 + overhead%)` and then validates that the result does not exceed 80% of the target VM's RAM. If it does, the play fails with a clear message before touching the system.

### Character set and locale

| Variable | Default | Description |
|---|---|---|
| `oracle_character_set` | `WE8MSWIN1252` | DB character set |
| `oracle_nchar_set` | `AL16UTF16` | National character set |
| `oracle_nls_language` | `AMERICAN` | NLS language |
| `oracle_nls_territory` | `AMERICA` | NLS territory |

### Listener

| Variable | Default | Description |
|---|---|---|
| `oracle_listener_port` | `1521` | TCP port for Oracle listener |

### Patch paths — update every quarter

| Variable | Default | Description |
|---|---|---|
| `oracle_opatch_dir` | `p6880880` | Folder with replacement OPatch |
| `oracle_ru_patch_dir` | `p37641958` | Top-level RU patch folder |
| `oracle_ru_subpath` | `37641958/37642901` | RU patch subfolder path |
| `oracle_oneoff_subpath` | `37641958/37643161` | One-off patch subfolder path |
| `oracle_post_patch1_dir` / `_sub` | `p38291812` / `38291812` | Post-install opatch #1 |
| `oracle_post_patch2_dir` / `_sub` | `p32249704` / `32249704` | Post-install opatch #2 |
| `oracle_post_patch3_dir` / `_sub` | `p3467298` / `3467298` | Post-install opatch #3 (needs oradism owner swap) |

## Directory layout on target VM

```
/oracle/{SID}/
├── 19.0.0/          ← ORACLE_HOME
├── oraInventory/
├── admin/{adump,dpdump,pfile,audit}
├── oradata1/        ← datafiles + control02
├── origlogA/           ← redo group 1 member A + control03
├── origlogB/           ← redo group 2 member A
├── mirrlogA/        ← redo group 1 member B (mirror) + control01
├── mirrlogB/        ← redo group 2 member B (mirror)
├── temp/            ← temporary tablespace
├── undo/            ← undo tablespace
├── oraarch/         ← archive log destination
└── scripts/db_creation/{SID}/   ← creation scripts + logs
```

## Offline replication notes (work environment)

> In the air-gapped work environment, all files under `/opt/oracle` must be staged locally before execution. No internet access required by the playbook itself — all software transfers are host-to-host via rsync (SSH).
