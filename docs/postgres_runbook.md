# PostgreSQL AWX Runbook

This runbook documents how to execute `playbooks/deploy_postgres.yml` with granular tags.

## Standard job patterns

- Full install and hardening: run `deploy_postgres.yml` with no tags.
- Install-only phases: use tags `postgres_install`.
- User lifecycle only: use tags `postgres_users`.
- Patch discovery only: use tags `db_patches`.

## Tag map

- `postgres`: umbrella tag for all PostgreSQL tasks.
- `postgres_install`: role-level install/hardening execution.
- `bootstrap`: install phase in playbook orchestration.
- `post_install`: user-management phase in playbook orchestration.
- `postgres_validate`: OS support validation.
- `postgres_packages`: package installation.
- `postgres_service`: service start/enable/restart.
- `postgres_config`: postgresql.conf settings.
- `postgres_hardening`: security-focused settings.
- `postgres_hba`: host-based authentication rules.
- `postgres_users`: role-level user lifecycle execution.
- `postgres_users_validate`: survey normalization and assertions.
- `postgres_user`: login role creation/update.
- `postgres_db`: optional DB creation.
- `postgres_grants`: privilege grants.
- `postgres_revoke`: privilege revokes.
- `postgres_remove_user`: role removal.
- `db_patches`: shared patch discovery/apply guard role.

## AWX survey configuration (copy/paste checklist)

- `pg_username`
  - Type: Text
  - Required: Yes
  - Default: empty
  - Description: PostgreSQL role name to manage.

- `pg_user_password`
  - Type: Password
  - Required: No
  - Default: empty
  - Description: Password for role when `pg_user_state=present`.

- `pg_user_state`
  - Type: Multiple Choice (single)
  - Choices: `present`, `absent`
  - Required: Yes
  - Default: `present`
  - Description: Role lifecycle mode.

- `pg_target_databases`
  - Type: Textarea
  - Required: No
  - Default: `appdb`
  - Description: Comma-separated target databases for privileges.

- `pg_manage_databases`
  - Type: Multiple Choice (single)
  - Choices: `false`, `true`
  - Required: Yes
  - Default: `false`
  - Description: Create target databases before grants.

- `pg_privileges`
  - Type: Text
  - Required: Yes
  - Default: `CONNECT`
  - Description: Database privileges to grant/revoke.

- `pg_revoke_access`
  - Type: Multiple Choice (single)
  - Choices: `false`, `true`
  - Required: Yes
  - Default: `false`
  - Description: Revoke privileges when true.

- `pg_role_attr_flags`
  - Type: Text
  - Required: Yes
  - Default: `LOGIN`
  - Description: PostgreSQL role flags (e.g. `LOGIN,CREATEDB`).

## Optional patch survey (discovery only for now)

- `db_patches_enabled`
  - Type: Multiple Choice (single)
  - Choices: `false`, `true`
  - Required: Yes
  - Default: `false`

- `db_patches_root`
  - Type: Text
  - Required: Yes
  - Default: `/opt/patches`

- `db_patch_apply_enabled`
  - Type: Multiple Choice (single)
  - Choices: `false`, `true`
  - Required: Yes
  - Default: `false`
  - Description: Keep false until patch execution is implemented.
