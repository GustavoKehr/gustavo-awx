---
title: Oracle 19c — Deploy TSTOR (AWX)
date: 2026-05-05
tags:
  - oracle
  - awx
  - deploy
  - troubleshooting
status: success
---

# Oracle 19c — Deploy TSTOR via AWX

## Resultado Final

Oracle 19c installed and running on **tstor** (`192.168.137.158`).

| Campo | Valor |
|---|---|
| SID | TSTOR |
| Version | 19.0.0.0.0 |
| Status | OPEN |
| ORACLE_HOME | `/oracle/TSTOR/19.0.0` |
| ORACLE_BASE | `/oracle/TSTOR` |
| Character set | AL32UTF8 |
| Tablespaces | 9 |
| Redo logs | 100M × 4 (2 groups × 2 members) |
| Listener | port 1521 |
| AWX Job | Job 324 (successful) |

---

## Infrastructure

| Item | Value |
|---|---|
| Proxmox | 192.168.137.145 |
| awxvm (VM 101) | 192.168.137.153, NodePort 31911 |
| tstor (VM 109) | 192.168.137.158 |
| AWX Job Template | `ORACLE \| Deploy` (ID 20) |
| Playbook | `playbooks/deploy_oracle.yml` |
| Main role | `roles/oracle_install` |
| Git branch | `feature/survey-variables` |
| RAM awxvm | 8 GB (increased from 4 GB — OOMKilled) |
| RAM tstor | 6 GB (increased from 3.6 GB — SGA pressure) |
| Disk tstor `/dev/sdb` | 64 GB (extended from 32 GB in Proxmox) |

---

## Role `oracle_install` Architecture

### Phases (tasks included in `main.yml`)

| Phase | File | Tags | Description |
|---|---|---|---|
| 0 | `00_storage_setup.yml` | `oracle_storage` | Create PV/VG/LVs, format XFS, mount |
| 1 | `01_prereqs.yml` | `oracle_prereqs` | RPM preinstall, sysctl, limits, hugepages |
| 2 | `02_directories.yml` | `oracle_dirs` | Create Oracle dirs, deploy SQL/shell scripts |
| 3 | `03_transfer_software.yml` | `oracle_transfer` | Rsync from awxvm → tstor (installer + patches) |
| 4 | `04_install_software.yml` | `oracle_install_sw` | Silent runInstaller + root.sh |
| 5 | `05_apply_patches.yml` | `oracle_patches` | OPatch post-install (3 patches) |
| 6 | `06_create_database.yml` | `oracle_dbcreate` | CREATE DATABASE, SPFILE, custom tablespaces |

Phase 6 gated by: `when: create_initial_db | default(true) | bool`

---

## Storage Layout (LVM)

9 LVs created in `vg_data` on `oracle_data_disk`:

| LV | Mount | Default survey | TSTOR used |
|---|---|---|---|
| `lv_tstor` | `/oracle/TSTOR` | 60G | 40G (extended) |
| `lv_oradata` | `/oracle/TSTOR/oradata1` | 10G | 8G |
| `lv_mirrlogA` | `/oracle/TSTOR/mirrlogA` | 1G | 1G (was 512M → extended) |
| `lv_mirrlogB` | `/oracle/TSTOR/mirrlogB` | 1G | 1G |
| `lv_origlogA` | `/oracle/TSTOR/origlogA` | 1G | 1G (was 512M → extended) |
| `lv_origlogB` | `/oracle/TSTOR/origlogB` | 1G | 1G |
| `lv_oraarch` | `/oracle/TSTOR/oraarch` | 5G | 2G |
| `lv_undofile` | `/oracle/TSTOR/undofile` | 5G | 2G |
| `lv_tempfile` | `/oracle/TSTOR/tempfile` | 5G | 2G |

> **Note:** `lv_mirrlogB` and `lv_origlogB` **not in survey** — use default from `defaults/main.yml`.

---

## AWX Survey — Configurable Variables

17 fields in survey `awx_survey_oracle_install.json`:

| Variable | Type | Default | TSTOR used |
|---|---|---|---|
| `oracle_sid` | text | AWOR | TSTOR |
| `oracle_data_disk` | text | /dev/sdc | /dev/sdb |
| `oracle_vg_name` | text | vg_data | vg_data |
| `oracle_lv_base_size` | text | 60G | 30G→40G |
| `oracle_lv_oradata_size` | text | 10G | 8G |
| `oracle_lv_oraarch_size` | text | 5G | 2G |
| `oracle_lv_undofile_size` | text | 5G | 2G |
| `oracle_lv_tempfile_size` | text | 5G | 2G |
| `oracle_lv_mirrlogA_size` | text | 1G | 512M (problem) |
| `oracle_lv_origlogA_size` | text | 1G | 512M (problem) |
| `oracle_sga_pct` | integer | 40 | 40 |
| `oracle_pga_pct` | integer | 20 | 20 |
| `oracle_character_set` | text | AL32UTF8 | AL32UTF8 |
| `ts_audit_datafiles` | integer | 1 | 1 |
| `ts_perfstat_datafiles` | integer | 1 | 1 |
| `ts_sid_dat_datafiles` | integer | 1 | 1 |
| `ts_sid_idx_datafiles` | integer | 1 | 1 |

**Outside survey (only `defaults/main.yml`):**
- `oracle_sys_password` / `oracle_system_password` — default `"F9toqfd("` ⚠️ do not use in prod
- `oracle_listener_port` — default 1521
- `oracle_lv_mirrlogB_size` / `oracle_lv_origlogB_size` — default 1G
- `create_initial_db` — default `true`

---

## Patches Applied

| Order | ID | Type | Method | Variable |
|---|---|---|---|---|
| — | `p6880880` | OPatch replacement | Direct copy | `oracle_opatch_dir` |
| 1 (inline) | `p37641958/37642901` | RU 19.x | `runInstaller -applyRU` | `oracle_ru_patch_dir/subpath` |
| 2 (inline) | `p37641958/37643161` | One-off | `runInstaller -applyOneOffs` | `oracle_oneoff_subpath` |
| 3 | `p38291812` | Post-install (version) | `opatch apply` | `oracle_post_patch1_*` |
| 4 | `p38632161` | Post-install (Oracle 19.30) | `opatch apply` | `oracle_post_patch2_*` |
| 5 | `p34672698` | Post-install (oradism) | `opatch apply` | `oracle_post_patch3_*` |

> **oradism:** Before patch3, role does `chown oracle + chmod 750`; after restores `chown root + chmod 4750`.
>
> **Hugepages:** Role frees hugepages before applying patches (OPatch JVM needs RAM), restores after.

### Transfer mechanism (Phase 3)

Rsync **delegated to awxvm** (`delegate_to: awxvm`, `--rsync-path="sudo rsync"`):
- Source: `/opt/oracle/` (installer) and `/opt/patches/` (patches)
- Destination: `/oracle/{{ oracle_sid }}/software/`

Idempotency guard: checks if destination directory exists **and is not empty**. If non-empty → skip.

> ⚠️ **Bug:** If rsync is interrupted leaving partially-filled directory, guard skips (sees non-empty dir) but content is incomplete. Fix: `rm -rf <dir>` on destination to force re-rsync.

---

## Idempotency — Guards per Phase

| Phase | Guard | Behavior |
|---|---|---|
| Storage | `lvs vg/lv > /dev/null` | Skip creation if LV exists |
| Transfer | dest dir non-empty | Skip rsync if dir non-empty |
| Install | `test -s bin/oracle` | Skip runInstaller if binary exists |
| Install | lib `*.a` empty | Detect corrupted ORACLE_HOME → wipe |
| Patches | `opatch lsinventory \| grep "Patch N"` | Skip if patch already in inventory |
| DB Create | `test -f mirrlogA/cntrl/control01.ctl` | Skip CREATE DATABASE if control file exists |
| SPFILE | `test -f dbs/spfileTSTOR.ora` | Skip creation if SPFILE exists |

---

## Tablespaces Created

| Tablespace | File | Size |
|---|---|---|
| SYSTEM | oradata1/system01.dbf | 1G |
| SYSAUX | oradata1/sysaux01.dbf | 1G |
| UNDOTBS1 | undofile/undotbs01.dbf | 1G |
| TEMP | tempfile/temp01.dbf | 1G |
| TS_TSTOR_DAT01 | oradata1/TS_TSTOR_DAT01_01.DBF | 1000M |
| TS_TSTOR_IDX01 | oradata1/TS_TSTOR_IDX01_01.DBF | 1000M |
| TS_AUDIT_DAT01 | oradata1/TS_AUDIT_DAT01_01.DBF | via script |
| TS_PERFSTAT_DAT01 | oradata1/TS_PERFSTAT_DAT01_01.DBF | via script |

---

## Problems and Solutions

### 1. AWX OOMKilled — zombie jobs

**Symptom:** Jobs marked failed with `"Task was marked as running at system start up"`.
**Cause:** awxvm 4 GB RAM — task pod (`awx-server-task`) received SIGKILL.
**Fix:** `qm set 101 -memory 8192` on Proxmox → awxvm to 8 GB.

### 2. `become_timeout` short post-reboot

**Symptom:** Sudo timeout in tasks right after tstor reboot.
**Fix:** `become_timeout = 60` in `ansible.cfg`.

### 3. `lv_tstor` out of space

**Symptom:** Unzip of installer + patches exhausted 18G LV.
**Fix:** Extension sequence: 18G → 30G → 40G via `lvextend + xfs_growfs`.

> VG extended via Proxmox disk resize: `qm disk resize 109 scsi1 +32G` → `pvresize /dev/sdb`.

### 4. `p38632161` with incomplete content on tstor

**Symptom:** `opatch: NApply — FileNotFoundException: perl.zip`.
**Cause:** Dir existed on tstor (from previous interrupted run) → rsync guard saw non-empty → skipped → partial content.
**Fix:** `rm -rf /oracle/TSTOR/software/p38632161` → forced full re-rsync.

### 5. `CheckSystemSpace` — opatch out of space

**Symptom:** `Prerequisite check "CheckSystemSpace" failed. Required 9517 MB`.
**Cause:** `lv_tstor` with 4.5 GB free; p37641958 = 6.8 GB staging.
**Fix:** `lvextend -L +10G /dev/vg_data/lv_tstor` → 40G total, 15G free.

### 6. ORA-19502 / ORA-27072 — EINTR creating redo logs (500M)

**Symptom:** `ORA-27072: File I/O error, Additional info: 4 (EINTR), block 819201`.
**Root cause:** SGA 1.4G on VM with only 620 MB free → kernel interrupted AIO write (EINTR=4) creating 500M redo log.
**Diagnosis:** Trace file showed `ose[0]=4` (EINTR) and `errno=28` (ENOSPC in subsequent block).
**Fixes:**
- `qm set 109 -memory 6144` → tstor 3.6G → 6G RAM
- Template `CreateDB.sql.j2`: `SIZE 500M` → `SIZE {{ oracle_redo_log_size | default('100M') }}`
- `lvextend -L 1G lv_origlogA` and `lv_mirrlogA` (were 512M in survey — insufficient)

> **Caution:** Bug initially edited wrong file (`deploy_oracle_with_vars/roles/...`). Playbook uses `roles/oracle_install/` per `ansible.cfg`.

### 7. Guard `control01.ctl` blocking CREATE DATABASE

**Symptom:** DB never created — task "Run database creation script" returned `ok` without executing.
**Cause:** `06_create_database.yml` line 14: `test -f mirrlogA/cntrl/control01.ctl && exit 0`. Control file from failed run still existed.
**Fix:** `rm -rf /oracle/TSTOR/{mirrlogA,origlogA,oradata1}/cntrl` → relaunch → CREATE DATABASE executed.

### 8. awxvm shut down during CREATE DATABASE

**Symptom:** Monitor timeout; `qm status 101` returned `stopped`.
**Cause:** VM shut down (unknown reason) while job 291 was running.
**Fix:** `qm start 101` → wait for AWX → verify directly: `sqlplus / as sysdba → select status from v$instance` → **OPEN**. DB had finished. Relaunch completed post-DB tasks (SPFILE, Users_and_Objects).

---

## Files Modified in Repo

| File | Change | Commit |
|---|---|---|
| `ansible.cfg` | `become_timeout = 60` | `1710a3e` |
| `roles/oracle_install/templates/CreateDB.sql.j2` | Redo log SIZE `500M` → `{{ oracle_redo_log_size \| default('100M') }}` | `41324a9` |

---

## Useful Commands — Operation

```bash
# Check Oracle status
export ORACLE_HOME=/oracle/TSTOR/19.0.0 ORACLE_SID=TSTOR
PATH=$PATH:$ORACLE_HOME/bin
sqlplus -s / as sysdba <<'EOF'
select instance_name, status from v$instance;
exit;
EOF

# Check applied patches
export ORACLE_HOME=/oracle/TSTOR/19.0.0
$ORACLE_HOME/OPatch/opatch lsinventory | grep "Patch "

# Check LVs and space
lvs vg_data
df -h /oracle/TSTOR /oracle/TSTOR/origlogA /oracle/TSTOR/mirrlogA

# AWX — check job by ID
curl -sk -u "admin:<password>" \
  "http://192.168.137.153:31911/api/v2/jobs/<ID>/" | grep '"status"'
```
