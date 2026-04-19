SET VERIFY OFF
connect "SYS"/"&&sysPassword" as SYSDBA
set echo on
spool /oracle/TSTOR/scripts/db_creation/TSTOR/CreateDBCatalog.log append
@/oracle/TSTOR/19.0.0/rdbms/admin/catalog.sql;
@/oracle/TSTOR/19.0.0/rdbms/admin/catproc.sql;
@/oracle/TSTOR/19.0.0/rdbms/admin/catoctk.sql;
@/oracle/TSTOR/19.0.0/rdbms/admin/owminst.plb;
connect "SYSTEM"/"&&systemPassword"
@/oracle/TSTOR/19.0.0/sqlplus/admin/pupbld.sql;
connect "SYS"/"&&sysPassword" as SYSDBA
@/oracle/TSTOR/19.0.0/sqlplus/admin/pupdel.sql;
connect "SYSTEM"/"&&systemPassword"
set echo on
spool /oracle/TSTOR/scripts/db_creation/TSTOR/sqlPlusHelp.log append
@/oracle/TSTOR/19.0.0/sqlplus/admin/help/hlpbld.sql helplus.sql;
spool off
spool off