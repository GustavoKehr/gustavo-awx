# Oracle 19c — Replicating the Environment at Work

Practical guide for setting up the Oracle 19c deployment project in a new environment (e.g., work network) using a copy of this repository.

---

## 1. Overview

What transfers as-is vs what must change:

| Item | Transfers? | Notes |
|---|---|---|
| Ansible roles and playbooks | Yes | No edits needed for new env |
| Survey JSON files | Yes | Import via API into new AWX |
| Inventory file | Edit required | Change IPs and hostnames |
| Role defaults | Review required | Patch IDs, OS user hardcoded |
| Oracle binaries | Download fresh | Oracle Support account required |
| AWX setup | Rebuild from scratch | New project, template, credentials |
| SSH keys | Generate new pair | Or reuse if user_aap exists |

---

## 2. Required Oracle Binaries

Download from [Oracle Support (support.oracle.com)](https://support.oracle.com) — need a valid CSI.

### `/opt/oracle/` on AWX VM

| File | Download From | Notes |
|---|---|---|
| `LINUX.X64_193000_db_home.zip` | Oracle eDelivery or Support — patch 73135379 or direct download | ~3 GB. Oracle 19c base installer. |
| `oracle-database-preinstall-19c-1.0-1.el9.x86_64.rpm` | Oracle yum repo or RPM download | RHEL 9 preinstall RPM. |
| `libnsl_libs/libnsl.so.1` | Extract from `libnsl-2.17` SRPM or copy from RHEL 8 | RHEL 9 minimal lacks these. |
| `libnsl_libs/libnsl.so.2` | Same source as above | |

### `/opt/patches/` on AWX VM

| Directory | Patch Number | Download From | Required | Notes |
|---|---|---|---|---|
| `p6880880/` | 6880880 | Oracle Support → search patch 6880880 | **YES** | OPatch replacement. Get latest version for 19c. |
| `p37641958/` | 37641958 | Oracle Support | **YES** | Legacy bundle — transferred to target. ~3 GB. runInstaller no longer uses it as -applyRU but role still transfers it. |
| `p38632161/38632161/` | 38632161 | Oracle Support | **YES** | Oracle 19.30 RU. Used as `-applyRU` in runInstaller and standalone opatch. |
| `p34672698/34672698/` | 34672698 | Oracle Support | **YES** | oradism binary patch. Applied via opatch post-install. |
| `p38291812/38291812/` | 38291812 | Oracle Support | Only if `oracle_post_patch1_enabled: true` | Optional version patch. Off by default. |

### Directory structure required on AWX VM

```
/opt/oracle/
├── LINUX.X64_193000_db_home.zip
├── oracle-database-preinstall-19c-1.0-1.el9.x86_64.rpm
└── libnsl_libs/
    ├── libnsl.so.1
    └── libnsl.so.2

/opt/patches/
├── p6880880/
│   └── OPatch/          ← must contain opatch binary
├── p37641958/           ← full bundle, unzipped
├── p38632161/
│   └── 38632161/        ← patch files here
├── p34672698/
│   └── 34672698/        ← patch files here
└── p38291812/           ← optional
    └── 38291812/
```

---

## 3. Environment Changes

Everything that differs between lab and work:

### AWX VM

| Item | Lab | Work (change to) |
|---|---|---|
| AWX IP | `192.168.137.153` | Your AWX IP |
| AWX port | `31911` | Usually `443` or `80` |
| AWX URL | `https://192.168.137.153:31911` | `https://<your-awx-host>` |
| k3s/kubernetes | Yes (lab) | May differ — could be bare metal AWX |

### Inventory — `inventory/LINUX.yml`

Change target host IPs and names. Lab uses:

```yaml
oraclevm:
  ansible_host: 192.168.137.165
```

At work — edit to match your target VM IPs. Group name (`oraclevm`) can stay the same or change; update the Job Template `limit` field to match.

### SSH User

Lab uses `user_aap` / `$RFVbgt5`. At work:
- Create `user_aap` on target VMs OR change `remote_user` in `ansible.cfg`
- Generate SSH key: `ssh-keygen -t ed25519 -f ~/.ssh/id_user_aap`
- Copy to targets: `ssh-copy-id -i ~/.ssh/id_user_aap user_aap@<target-ip>`
- User needs `sudo NOPASSWD` — add to `/etc/sudoers.d/user_aap`

### Storage Device

Lab target has extra disk at `/dev/sdb`. At work:
- Check with `lsblk` on target
- Set `oracle_data_disk` in survey to the correct device (e.g., `/dev/sdc`, `/dev/vdb`)
- If VG already exists, leave field empty and set `oracle_vg_name` to existing VG name

### SID Naming

Lab uses `AWOR`. At work — choose a meaningful 8-char SID. Set via survey field `oracle_sid`.

### LV Sizes for Production

Lab defaults (50G/5G/2G) are lab-sized. Production recommendations:

| LV | Lab Default | Production Minimum |
|---|---|---|
| `lv_<SID>` (base) | 50G | 80-100G (Oracle home ~10G + software staging ~8G + headroom) |
| `lv_oradata` | 5G | Size based on expected data volume |
| `lv_oraarch` | 2G | 20-50G for production archivelog mode |
| `lv_undofile` | 2G | 10-20G for active OLTP workloads |
| `lv_tempfile` | 2G | 5-20G depending on sort/hash join usage |
| `lv_mirrlogA/B` | 1G | 2-5G per redo log member |
| `lv_origlogA/B` | 1G | 2-5G per redo log member |

Set via survey — no role editing needed.

### Listener Port

Default `1521`. If firewall or policy requires different port, set `oracle_listener_port` via survey.

### VG Name

Lab uses `vg_data`. Set `oracle_vg_name` via survey to match your environment's LVM naming convention.

---

## 4. AWX Setup Checklist

### Step 1 — Create Organization and Credential

1. AWX → **Organizations** → Add → name it (e.g., `IT-DBA`)
2. AWX → **Credentials** → Add:
   - Type: `Machine`
   - Name: `user_aap`
   - Username: `user_aap`
   - SSH Private Key: paste content of `~/.ssh/id_user_aap`
   - Privilege Escalation: `sudo`, username `root`, no password (NOPASSWD in sudoers)

### Step 2 — Create Project

AWX → **Projects** → Add:

| Field | Value |
|---|---|
| Name | `gustavo-awx` (or your choice) |
| Organization | your org |
| Source Control Type | Git |
| Source Control URL | `https://github.com/GustavoKehr/gustavo-awx` |
| Source Control Branch | `feature/survey-variables` |
| Options | Uncheck "Update revision on launch" if offline; keep checked if internet available |

Sync the project — confirm green status.

### Step 3 — Create Inventory

AWX → **Inventories** → Add → **Add inventory**:
- Name: `LINUX`
- Organization: your org

Then → **Sources** → Add:
- Source: Sourced from a Project
- Project: `gustavo-awx`
- Inventory file: `inventory/LINUX.yml`

Sync → verify hosts appear (edit `inventory/LINUX.yml` first with correct IPs).

### Step 4 — Create Execution Environment

The EE must have `/opt/oracle` and `/opt/patches` accessible. Two options:

**Option A — Mount from AWX host (lab approach):**
- Requires AWX operator running on k3s with custom EE config
- Edit EE definition to add volume mounts: `/opt/oracle:/opt/oracle:ro` and `/opt/patches:/opt/patches:ro`

**Option B — NFS or shared storage:**
- Mount `/opt/oracle` and `/opt/patches` via NFS on the AWX host
- EE sees them through the host mount

In AWX → **Execution Environments** → Add:
- Name: `oracle-ee`
- Image: your custom EE image with volume mounts configured
- Pull: Never (if offline) or Always (if registry available)

### Step 5 — Create Job Template for ORACLE Deploy

AWX → **Templates** → Add → **Add job template**:

| Field | Value |
|---|---|
| Name | `ORACLE \| Deploy` |
| Job Type | Run |
| Inventory | `LINUX` |
| Project | `gustavo-awx` |
| Execution Environment | `oracle-ee` |
| Playbook | `playbooks/deploy_oracle.yml` |
| Credentials | `Machine: user_aap` |
| Limit | your oracle target host (e.g., `oraclevm`) |
| Verbosity | Normal (0) |
| Enable Privilege Escalation | checked |

Optional extra vars:

```yaml
oracle_post_patch1_enabled: false   # set true if p38291812 is available
create_initial_db: true
```

### Step 6 — Import Survey

```bash
# On AWX VM — get the Job Template ID first (check AWX UI URL or API)
JT_ID=<your-template-id>
AWX_HOST=https://localhost   # or your AWX URL

curl -sk -u admin:<your-password> \
  -X POST ${AWX_HOST}/api/v2/job_templates/${JT_ID}/survey_spec/ \
  -H "Content-Type: application/json" \
  -d @/path/to/gustavo-awx/playbooks/awx_survey_oracle_install.json
```

Enable survey in AWX UI: Template → Survey tab → toggle ON.

### Step 7 — Create Manage Users Template (optional)

Same process but:
- Playbook: `playbooks/manage_oracle_users.yml`
- Survey JSON: `playbooks/awx_survey_oracle_manage_users.json`
- Extra vars: `oracle_manage_users_enabled: true`

---

## 5. Role Defaults to Review

Before first run, check `roles/oracle_install/defaults/main.yml`:

| Variable | Current Value | Review Needed? |
|---|---|---|
| `oracle_post_patch2_dir` | `p38632161` | Yes — must match patch in `/opt/patches/` |
| `oracle_post_patch2_sub` | `38632161` | Yes — must match subdirectory name |
| `oracle_post_patch3_dir` | `p34672698` | Yes — must match patch in `/opt/patches/` |
| `oracle_post_patch3_sub` | `34672698` | Yes — must match subdirectory name |
| `oracle_ru_patch_dir` | `p37641958` | Legacy — still transferred, not used by runInstaller |
| `oracle_opatch_dir` | `p6880880` | Yes — must match OPatch dir in `/opt/patches/` |
| `oracle_installer_zip` | `LINUX.X64_193000_db_home.zip` | Yes — must match filename in `/opt/oracle/` |
| `oracle_preinstall_rpm` | `oracle-database-preinstall-19c-1.0-1.el9.x86_64.rpm` | Yes — must match filename |
| `oracle_os_user` | `oracle` | Only change if org has different naming policy |
| `oracle_os_group` | `oinstall` | Hardcoded — set by preinstall RPM (GID 54321) |
| `oracle_processes` | `1000` | Increase for high-concurrency production |
| `oracle_open_cursors` | `3000` | Adjust per application requirements |
| `oracle_db_block_size` | `8192` | Do not change after DB creation |

---

## 6. Pre-flight Checklist

Before launching the first job:

```bash
# On AWX VM — verify source files
ls -lh /opt/oracle/LINUX.X64_193000_db_home.zip      # ~3 GB
ls -lh /opt/oracle/oracle-database-preinstall-19c-1.0-1.el9.x86_64.rpm
ls -la /opt/oracle/libnsl_libs/
ls -la /opt/patches/p6880880/OPatch/
ls -la /opt/patches/p37641958/
ls -la /opt/patches/p38632161/38632161/
ls -la /opt/patches/p34672698/34672698/

# On target VM
ssh user_aap@<target-ip>
free -m          # RAM: minimum 6 GB (8 GB recommended)
lsblk            # confirm extra disk available
df -h            # confirm / has space
sudo -l          # confirm NOPASSWD sudo
```

AWX checks:
- Project sync: green
- Inventory sync: hosts visible
- EE: pulls successfully or marked as available
- Job Template: survey enabled, credentials attached

---

## 7. What's Hardcoded (Not Survey-Configurable)

These require editing role files to change:

| Item | Location | Value |
|---|---|---|
| OPatch source dir | `roles/oracle_install/defaults/main.yml` | `p6880880` |
| -applyRU target | `roles/oracle_install/defaults/main.yml` | `p38632161/38632161` |
| post_patch2 dir | `roles/oracle_install/defaults/main.yml` | `p38632161` |
| post_patch3 dir | `roles/oracle_install/defaults/main.yml` | `p34672698` |
| oradism chown/chmod sequence | `roles/oracle_patches/tasks/` | `chown oracle` → patch → `chown root 4750` |
| Oracle OS user | `roles/*/defaults/main.yml` | `oracle` |
| Oracle OS group | preinstall RPM | `oinstall` (GID 54321) |
| DBA group | preinstall RPM | `dba` (GID 54321) |
| DB block size | `CreateDB.sql.j2` | `8192` |
| oracle_processes | defaults | `1000` |
| oracle_open_cursors | defaults | `3000` |
| Redo log size | `CreateDB.sql.j2` | `100M` |
| Patch discovery apply | `roles/db_patches/` | `db_patch_apply_enabled: false` — hardcoded off |

---

## 8. Quarterly Patch Update Process

Oracle releases RUs quarterly (Jan, Apr, Jul, Oct). When new RU drops:

1. Download new RU from Oracle Support (search for "Oracle Database 19c Release Update")
2. Extract to AWX VM: `unzip p<NEW>.zip -d /opt/patches/p<NEW>/`
3. Edit `roles/oracle_install/defaults/main.yml`:
   ```yaml
   oracle_post_patch2_dir: "p<NEW>"
   oracle_post_patch2_sub: "<NEW_SUB_NUMBER>"
   ```
4. Download and extract any new oradism/post_patch3 if Oracle releases one
5. Update `oracle_post_patch3_dir` and `oracle_post_patch3_sub` similarly
6. Check if OPatch itself needs updating — download new p6880880 if patch readme requires it
7. Test on a fresh lab VM before applying to production:
   ```bash
   ansible-playbook playbooks/deploy_oracle.yml \
     --tags oracle_transfer,oracle_install_sw,oracle_patches -l oraclevm-test
   ```
8. Verify patches applied:
   ```bash
   sudo -u oracle /oracle/<SID>/19.0.0/OPatch/opatch lsinventory
   ```
9. Commit defaults change: `git commit -am "fix(oracle): update RU to <new-patch-number>"`
10. Push to `feature/survey-variables` → sync AWX project

> Keep old patch directories in `/opt/patches/` until new version is validated — rollback = revert defaults and re-run.

---

## 9. First Run — Survey Values for a Fresh VM

Recommended values for initial deployment on a new environment:

| Survey Field | Value | Notes |
|---|---|---|
| Oracle SID | `PROD` (or your SID) | 8 chars max, uppercase |
| SYS Password | `<strong password>` | Min 8 chars, mixed case + special |
| SYSTEM Password | `<strong password>` | Different from SYS |
| Data Disk | `/dev/sdb` | Check with `lsblk` first |
| VG Name | `vg_oracle` | Or your org's naming convention |
| LV base size | `80G` | Production: increase from lab 50G |
| LV oradata size | `20G` | Adjust per expected data size |
| LV oraarch size | `10G` | At least 10G for production |
| LV undofile size | `5G` | OLTP: 10-20G |
| LV tempfile size | `5G` | Adjust per sort/hash usage |
| LV mirrlog size | `2G` | 2G per redo log member |
| LV origlog size | `2G` | 2G per redo log member |
| SGA % of RAM | `40` | Start at 40% — tune after go-live |
| PGA % of RAM | `20` | Start at 20% |
| Listener Port | `1521` | Change only if required by policy |
| Character Set | `AL32UTF8` | Always — unless legacy app requires different |
| TS_AUDIT datafiles | `1` | Increase only if audit volume is high |
| TS_PERFSTAT datafiles | `1` | |
| TS_\<SID\>_DAT datafiles | `1` | |
| TS_\<SID\>_IDX datafiles | `1` | |

Do not specify tags — run all phases end to end. Expect ~12-15 min on hardware with adequate I/O.

---

## See Also

- [`oracle_runbook.md`](oracle_runbook.md) — Operational runbook (lab-focused, scenarios)
- [`oracle_guide.md`](oracle_guide.md) — Full technical reference (variables, decisions)
- [`awx_surveys.md`](awx_surveys.md) — Survey field reference for all engines
- [`offline_requirements.md`](offline_requirements.md) — Preparing Oracle binaries for offline AWX
