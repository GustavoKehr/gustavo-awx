# deploy_oracle_with_vars

Oracle 19c deploy playbook with full survey-driven variables.
Branch: `feature/survey-variables`

## What changed from base deploy

| Variable | Old | New |
|---|---|---|
| Main LV name | `lv_awor` (hardcoded) | `lv_{{ oracle_sid \| lower }}` (dynamic) |
| LV size var | `oracle_lv_awor_size` | `oracle_lv_base_size` |
| LV device paths | `/dev/mapper/vg_data-*` (hardcoded) | `/dev/{{ oracle_vg_name }}/*` (dynamic) |
| `oracle_software_dst` | `/oracle/AWOR/software` (hardcoded) | `/oracle/{{ oracle_sid }}/software` |
| `oracle_character_set` | `WE8MSWIN1252` | `AL32UTF8` (default, survey-overridable) |
| SGA/PGA | hardcoded 40%/20% of RAM | `oracle_sga_pct` / `oracle_pga_pct` survey fields |
| Tablespace datafiles | 1 per TS (hardcoded) | `ts_audit_datafiles`, `ts_perfstat_datafiles`, `ts_sid_dat_datafiles`, `ts_sid_idx_datafiles` |

## Survey variables (awx_survey_oracle_install.json)

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `oracle_sid` | text | yes | AWOR | DB SID. Defines base dir + LV name |
| `oracle_vg_name` | text | yes | vg_data | LVM VG name |
| `oracle_lv_base_size` | text | yes | 60G | Main LV size (lv_\<SID\>) |
| `oracle_lv_oradata_size` | text | yes | 10G | Datafiles LV |
| `oracle_lv_oraarch_size` | text | yes | 5G | Archive log LV |
| `oracle_lv_undofile_size` | text | yes | 5G | Undo LV |
| `oracle_lv_tempfile_size` | text | yes | 5G | Temp LV |
| `oracle_lv_mirrlogA_size` | text | yes | 1G | Mirrored redo A+B LV |
| `oracle_lv_origlogA_size` | text | yes | 1G | Original redo A+B LV |
| `oracle_sga_pct` | integer | yes | 40 | % of VM RAM for SGA (10-80) |
| `oracle_pga_pct` | integer | yes | 20 | % of VM RAM for PGA (5-50) |
| `oracle_character_set` | text | no | AL32UTF8 | DB character set |
| `ts_audit_datafiles` | integer | no | 1 | TS_AUDIT_DAT01 datafile count |
| `ts_perfstat_datafiles` | integer | no | 1 | TS_PERFSTAT_DAT01 datafile count |
| `ts_sid_dat_datafiles` | integer | no | 1 | TS_\<SID\>_DAT01 datafile count |
| `ts_sid_idx_datafiles` | integer | no | 1 | TS_\<SID\>_IDX01 datafile count |

## Tablespace datafile naming

Files named `TS_<NAME>_01.DBF`, `_02.DBF`, etc.
Example with `ts_audit_datafiles=2`:
- `TS_AUDIT_DAT01_01.DBF`
- `TS_AUDIT_DAT01_02.DBF`

## SGA/PGA calculation

Computed in `roles/oracle_install/tasks/01_prereqs.yml`:
```
oracle_sga_target = (ansible_memtotal_mb * oracle_sga_pct / 100) MB
oracle_pga_target = (ansible_memtotal_mb * oracle_pga_pct / 100) MB
```

Example: 6144 MB VM, sga_pct=40 → SGA ~2457 MB

## Directory layout

```
deploy_oracle_with_vars/
├── ansible.cfg
├── inventory/
│   └── LINUX.yml
├── playbooks/
│   ├── deploy_oracle.yml
│   ├── awx_survey_oracle_install.json       # current survey (16 fields)
│   └── awx_survey_oracle_install_BACKUP_20260427.json
└── roles/
    └── oracle_install/
        ├── defaults/main.yml
        ├── files/
        │   ├── lockAccount.sql
        │   └── Users_and_Objects.sql
        ├── tasks/
        │   ├── main.yml
        │   ├── 00_storage_setup.yml
        │   ├── 01_prereqs.yml
        │   ├── 02_directories.yml
        │   ├── 03_transfer_software.yml
        │   ├── 04_install_software.yml
        │   ├── 05_apply_patches.yml
        │   └── 06_create_database.yml
        └── templates/
            ├── init.ora.j2
            ├── CreateDB.sql.j2
            ├── CreateDBCatalog.sql.j2
            ├── CreateDBFiles.sql.j2
            ├── bash_profile.j2
            ├── db_create.sh.j2
            ├── db_install.rsp.j2
            ├── postDBCreation.sql.j2
            └── sysctl_oracle.conf.j2
```

## AWX setup

1. Import survey: POST `awx_survey_oracle_install.json` to JT survey_spec endpoint
2. Set JT limit to target host or enable `ask_limit_on_launch`
3. Required AWX credential: SSH password for `user_aap` (password: see vault)
4. Required files on AWX controller at `/opt/oracle` and `/opt/patches`
