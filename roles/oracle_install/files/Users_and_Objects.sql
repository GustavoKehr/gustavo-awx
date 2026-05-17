-- Users_and_Objects.sql — managed by Ansible oracle_install role
-- Creates APPLICATION profile (if absent) then applies limits to both profiles.
-- DEFAULT profile exists in every Oracle DB — only ALTER needed.
-- PASSWORD_REUSE_TIME unit: days (Oracle converts internally).
-- PASSWORD_VERIFY_FUNCTION: verify_function_12C created by postDBCreation.sql

-- ── APPLICATION profile ───────────────────────────────────────────────────────
-- Create if not exists (idempotent: exception swallowed if already present)
BEGIN
  EXECUTE IMMEDIATE 'CREATE PROFILE "APPLICATION" LIMIT PASSWORD_LIFE_TIME UNLIMITED';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -2379 THEN RAISE; END IF;  -- ORA-02379: profile already exists
END;
/

ALTER PROFILE "APPLICATION" LIMIT
  COMPOSITE_LIMIT              DEFAULT
  SESSIONS_PER_USER            DEFAULT
  CPU_PER_SESSION              DEFAULT
  CPU_PER_CALL                 DEFAULT
  LOGICAL_READS_PER_SESSION    DEFAULT
  LOGICAL_READS_PER_CALL       DEFAULT
  IDLE_TIME                    DEFAULT
  CONNECT_TIME                 DEFAULT
  PRIVATE_SGA                  DEFAULT
  FAILED_LOGIN_ATTEMPTS        3
  PASSWORD_LIFE_TIME           UNLIMITED
  PASSWORD_REUSE_TIME          180
  PASSWORD_REUSE_MAX           1
  PASSWORD_VERIFY_FUNCTION     verify_function_12C
  PASSWORD_LOCK_TIME           1
  PASSWORD_GRACE_TIME          7;

-- ── DEFAULT profile ───────────────────────────────────────────────────────────
ALTER PROFILE "DEFAULT" LIMIT
  COMPOSITE_LIMIT              UNLIMITED
  SESSIONS_PER_USER            UNLIMITED
  CPU_PER_SESSION              UNLIMITED
  CPU_PER_CALL                 UNLIMITED
  LOGICAL_READS_PER_SESSION    UNLIMITED
  LOGICAL_READS_PER_CALL       UNLIMITED
  IDLE_TIME                    UNLIMITED
  CONNECT_TIME                 UNLIMITED
  PRIVATE_SGA                  UNLIMITED
  FAILED_LOGIN_ATTEMPTS        3
  PASSWORD_LIFE_TIME           90
  PASSWORD_REUSE_TIME          180
  PASSWORD_REUSE_MAX           1
  PASSWORD_VERIFY_FUNCTION     verify_function_12C
  PASSWORD_LOCK_TIME           1
  PASSWORD_GRACE_TIME          7;

EXIT;
