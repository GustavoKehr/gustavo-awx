# MySQL AWX Runbook

This runbook documents how to execute `playbooks/deploy_mysql.yml` with granular tags in AWX.

## Standard job patterns

- Full install and hardening: run `deploy_mysql.yml` with no tags.
- Install-only phases: use tags `mysql_install`.
- User lifecycle only: use tags `mysql_users`.
- Validation-only checks for user role inputs: use tags `mysql_users_validate`.

## Tag map

- `mysql`: umbrella tag for all MySQL tasks.
- `mysql_install`: role-level install/hardening execution.
- `bootstrap`: install phase in playbook orchestration.
- `post_install`: user-management phase in playbook orchestration.
- `mysql_validate`: platform validation before install.
- `mysql_packages`: package installation.
- `mysql_service`: service start/enable/restart.
- `mysql_config`: server configuration file changes.
- `mysql_hardening`: security hardening controls.
- `mysql_root`: root-account hardening and restrictions.
- `mysql_db`: test DB removal and optional DB creation in user ops.
- `mysql_users`: role-level user lifecycle execution.
- `mysql_users_validate`: survey variable normalization and assertions.
- `mysql_grants`: create/update user and grant privileges.
- `mysql_revoke`: revoke privileges without deleting user.
- `mysql_remove_user`: remove user account.

## Purpose of each survey question

- `db_username`: defines which MySQL account will be managed (create/update/revoke/remove).
- `db_user_host`: defines from where this account can connect (`user`@`host` scope).
- `db_password`: password applied when creating/updating the account.
- `db_privileges`: privileges to grant or revoke (for example `SELECT,INSERT,UPDATE`).
- `db_target_databases`: target databases where privileges will be applied.
- `db_user_state`: lifecycle mode (`present` ensures account exists, `absent` deletes account).
- `db_revoke_access`: when `true`, removes the informed privileges instead of granting.
- `db_append_privileges`: when `true`, adds privileges without removing existing grants.
- `db_manage_databases`: when `true`, creates target databases before user/grant actions.

### Common operation patterns

- Create or update user access: `db_user_state=present`, `db_revoke_access=false`.
- Revoke specific access: `db_user_state=present`, `db_revoke_access=true`.
- Remove user account: `db_user_state=absent`.

## AWX survey configuration (copy/paste checklist)

- `db_username`
  - Type: Text
  - Required: Yes
  - Default: empty
  - Description: MySQL account name to manage (create/update/revoke/remove).

- `db_user_host`
  - Type: Text
  - Required: Yes
  - Default: `%`
  - Description: Host scope for `user@host`; use `%`, IP or CIDR.

- `db_password`
  - Type: Password
  - Required: No
  - Default: empty
  - Description: Password for create/update flows.

- `db_privileges`
  - Type: Text
  - Required: Yes
  - Default: `SELECT`
  - Description: Privileges to grant/revoke (for example `SELECT,INSERT,UPDATE`).

- `db_target_databases`
  - Type: Textarea
  - Required: Yes
  - Default: `appdb`
  - Description: Target databases (comma-separated or list-style).

- `db_user_state`
  - Type: Multiple Choice (single)
  - Choices: `present`, `absent`
  - Required: Yes
  - Default: `present`
  - Description: `present` manages account; `absent` removes account.

- `db_revoke_access`
  - Type: Multiple Choice (single)
  - Choices: `false`, `true`
  - Required: Yes
  - Default: `false`
  - Description: When `true`, revokes privileges instead of granting.

- `db_append_privileges`
  - Type: Multiple Choice (single)
  - Choices: `false`, `true`
  - Required: Yes
  - Default: `false`
  - Description: When `true`, appends grants instead of replacing.

- `db_manage_databases`
  - Type: Multiple Choice (single)
  - Choices: `false`, `true`
  - Required: Yes
  - Default: `false`
  - Description: When `true`, creates target DBs before grants.

## Recommended AWX job templates

- `MYSQL | Deploy Base`: playbook `deploy_mysql.yml`, tags blank.
- `MYSQL | Install Only`: playbook `deploy_mysql.yml`, tags `mysql_install`.
- `MYSQL | Manage Users`: playbook `deploy_mysql.yml`, tags `mysql_users`.
- `MYSQL | Revoke Access`: playbook `deploy_mysql.yml`, tags `mysql_revoke`.
- `MYSQL | Remove User`: playbook `deploy_mysql.yml`, tags `mysql_remove_user`.

## Example extra vars for user operations

```yaml
db_username: app_user
db_user_host: 10.20.30.40
db_password: "ReplaceMeStrong!"
db_privileges: "SELECT,INSERT,UPDATE"
db_target_databases:
  - appdb
db_user_state: present
db_revoke_access: false
db_append_privileges: false
db_manage_databases: false
```
