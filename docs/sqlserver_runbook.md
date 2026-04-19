# SQL Server AWX Runbook

This runbook documents how to execute `playbooks/deploy_sqlserver.yml` with modular tags.

## Standard job patterns

- Full SQL Server deployment: run with no tags.
- User lifecycle only (day-2): run with tags `sql_users`.
- Patch repository discovery only: run with tags `db_patches`.

## Tag map

- `storage`: storage preparation role.
- `security`: security hardening role.
- `sql_pre`: SQL Server pre-requisites.
- `sql_install`: SQL Server engine installation.
- `sql_post`: post-install database setup.
- `sql_users`: SQL Server login/user lifecycle role.
- `sql_users_validate`: variable validation for SQL user ops.
- `sql_login`: server login create/update operations.
- `sql_db_user`: database user mapping operations.
- `sql_grants`: role memberships grant operations.
- `sql_revoke`: role memberships revoke operations.
- `sql_remove_user`: login removal operation.
- `db_patches`: shared patch discovery/apply guard role.
- `patch_discovery`: local patch file discovery under `/opt/patches`.
- `patch_apply`: reserved execution stage (currently blocked by design).

## AWX survey variables for SQL user management

- `sql_login_name`: login name to manage (required).
- `sql_login_password`: login password (required for SQL authentication and state=present).
- `sql_login_type`: `sql` or `windows`.
- `sql_login_state`: `present` or `absent`.
- `sql_login_default_db`: default DB for the login (default `master`).
- `sql_target_database`: target DB for user mapping and role membership.
- `sql_database_user`: database user name (defaults to login name when empty).
- `sql_database_roles`: list or comma-separated roles (for example `db_datareader,db_datawriter`).
- `sql_revoke_access`: when `true`, removes role membership instead of adding.
- `sql_manage_database_user`: when `true`, ensures DB user exists/mapped.

## Purpose of each SQL survey question

- `sql_login_name`: identity at SQL Server instance level.
- `sql_login_password`: secret for SQL-authenticated logins.
- `sql_login_type`: determines login creation method (`CREATE LOGIN ... WITH PASSWORD` or `FROM WINDOWS`).
- `sql_login_state`: lifecycle mode (`present` ensures login exists, `absent` drops login).
- `sql_login_default_db`: sets login default database.
- `sql_target_database`: DB context for user mapping and role operations.
- `sql_database_user`: DB principal name bound to the login.
- `sql_database_roles`: role memberships to add or remove.
- `sql_revoke_access`: switch between grant flow and revoke flow.
- `sql_manage_database_user`: controls whether DB user mapping is enforced.

## AWX survey configuration (copy/paste checklist)

- `sql_login_name`
  - Type: Text
  - Required: Yes
  - Default: empty
  - Description: SQL Server login name to manage.

- `sql_login_type`
  - Type: Multiple Choice (single)
  - Choices: `sql`, `windows`
  - Required: Yes
  - Default: `sql`
  - Description: Login type (`sql` uses password; `windows` creates Windows login).

- `sql_login_password`
  - Type: Password
  - Required: No
  - Default: empty
  - Description: Required when `sql_login_type=sql` and `sql_login_state=present`.

- `sql_login_state`
  - Type: Multiple Choice (single)
  - Choices: `present`, `absent`
  - Required: Yes
  - Default: `present`
  - Description: Login lifecycle mode.

- `sql_login_default_db`
  - Type: Text
  - Required: Yes
  - Default: `master`
  - Description: Default DB for SQL login.

- `sql_target_database`
  - Type: Text
  - Required: No
  - Default: empty
  - Description: Target database for user mapping and role operations.

- `sql_database_user`
  - Type: Text
  - Required: No
  - Default: empty
  - Description: DB user name; when empty, login name is reused.

- `sql_database_roles`
  - Type: Textarea
  - Required: No
  - Default: `db_datareader,db_datawriter`
  - Description: Roles to grant/revoke in target DB.

- `sql_revoke_access`
  - Type: Multiple Choice (single)
  - Choices: `false`, `true`
  - Required: Yes
  - Default: `false`
  - Description: When `true`, revokes role memberships instead of granting.

- `sql_manage_database_user`
  - Type: Multiple Choice (single)
  - Choices: `true`, `false`
  - Required: Yes
  - Default: `true`
  - Description: Controls DB user mapping creation/update.

## Optional patch survey (discovery only for now)

- `db_patches_enabled`
  - Type: Multiple Choice (single)
  - Choices: `false`, `true`
  - Required: Yes
  - Default: `false`
  - Description: Enables patch discovery phase.

- `db_patches_root`
  - Type: Text
  - Required: Yes
  - Default: `/opt/patches`
  - Description: Root folder containing patch files on AWX VM.

- `db_patch_apply_enabled`
  - Type: Multiple Choice (single)
  - Choices: `false`, `true`
  - Required: Yes
  - Default: `false`
  - Description: Keep false; apply flow is intentionally blocked for now.

## Patch scaffold (`/opt/patches`)

- Shared role: `roles/db_patches`.
- Scope: discovers files and reports counts only.
- Safety: execution is intentionally blocked for now.
- Enable discovery by:
  - setting `db_patches_enabled=true`, or
  - running with tag `db_patches`.
