# AWX Survey and Template Matrix

This file centralizes which playbook, job tags, and survey spec to use for each database workflow.

> **Ambiente de destino:** Este projeto será replicado em ambiente **sem acesso à internet** (trabalho).
> Todos os artefatos necessários (coleções Ansible, pacotes RPM, imagens de container) devem estar
> armazenados localmente no AWX / repositório interno antes da execução. Ver seção de requisitos offline.

## Quick mapping

- `MYSQL | Deploy Base`
  - Playbook: `playbooks/deploy_mysql.yml`
  - Job tags: *(empty)*
  - Survey file: optional (not required for base install)

- `MYSQL | Manage Users`
  - Playbook: `playbooks/deploy_mysql.yml`
  - Job tags: `mysql_users`
  - Survey file: `playbooks/awx_survey_mysql_manage_users.json`

- `SQLSERVER | Deploy Base`
  - Playbook: `playbooks/install_sql_playbook.yml`
  - Job tags: *(empty)*
  - Survey file: optional (not required for base install)

- `SQLSERVER | Manage Users`
  - Playbook: `playbooks/install_sql_playbook.yml`
  - Job tags: `sql_users`
  - Survey file: `playbooks/awx_survey_sql_manage_users.json`

- `POSTGRES | Deploy Base`
  - Playbook: `playbooks/deploy_postgres.yml`
  - Job tags: *(empty)*
  - Survey file: optional (not required for base install)

- `POSTGRES | Manage Users`
  - Playbook: `playbooks/deploy_postgres.yml`
  - Job tags: `postgres_users`
  - Survey file: `playbooks/awx_survey_postgres_manage_users.json`

- `ORACLE | Deploy`
  - Playbook: `playbooks/deploy_oracle.yml`
  - Job tags: *(empty — runs all phases)*
  - Survey file: `playbooks/awx_survey_oracle_install.json`
  - Limit inventory to: `oraclevm`
  - **Requires:** `/opt/oracle` staged on awxvm before running

- `DB | Patch Discovery (no apply)`
  - Playbook: `deploy_mysql.yml` or `install_sql_playbook.yml` or `deploy_postgres.yml`
  - Job tags: `db_patches`
  - Survey vars:
    - `db_patches_enabled=true` (optional if tag already used)
    - `db_patches_root=/opt/patches`
    - `db_patch_apply_enabled=false`

## Notes for operators

- User-management templates should always run with their role tag:
  - MySQL: `mysql_users`
  - SQL Server: `sql_users`
  - PostgreSQL: `postgres_users`
- Patch execution is intentionally not implemented yet; keep `db_patch_apply_enabled=false`.
- Collection dependencies are declared in `collections/requirements.yml`.
- In offline AWX setups, use local collection path configuration and avoid internet collection sync.
