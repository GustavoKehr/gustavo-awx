set verify off
ACCEPT sysPassword CHAR PROMPT 'Enter new password for SYS: ' HIDE
ACCEPT systemPassword CHAR PROMPT 'Enter new password for SYSTEM: ' HIDE
ACCEPT pdbAdminPassword CHAR PROMPT 'Enter new password for PDBADMIN: ' HIDE
host /oracle/TSTOR/19.0.0/bin/orapwd file=/oracle/TSTOR/19.0.0/dbs/orapwTSTOR force=y
@/oracle/TSTOR/scripts/db_creation/TSTOR/CreateDB.sql
@/oracle/TSTOR/scripts/db_creation/TSTOR/CreateDBFiles.sql
@/oracle/TSTOR/scripts/db_creation/TSTOR/CreateDBCatalog.sql
@/oracle/TSTOR/scripts/db_creation/TSTOR/lockAccount.sql
@/oracle/TSTOR/scripts/db_creation/TSTOR/postDBCreation.sql