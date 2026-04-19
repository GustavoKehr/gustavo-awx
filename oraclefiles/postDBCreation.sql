SET VERIFY OFF
spool /oracle/TSTOR/scripts/db_creation/TSTOR/postDBCreation.log append
host /oracle/TSTOR/19.0.0/OPatch/datapatch -skip_upgrade_check -db TSTOR;
connect "SYS"/"&&sysPassword" as SYSDBA
set echo on
create spfile='/oracle/TSTOR/19.0.0/dbs/spfileTSTOR.ora' FROM pfile='/oracle/TSTOR/scripts/db_creation/TSTOR/init.ora';
connect "SYS"/"&&sysPassword" as SYSDBA
select 'utlrp_begin: ' || to_char(sysdate, 'HH:MI:SS') from dual;
@/oracle/TSTOR/19.0.0/rdbms/admin/utlrp.sql;
select 'utlrp_end: ' || to_char(sysdate, 'HH:MI:SS') from dual;
select comp_id, status from dba_registry;
shutdown immediate;
connect "SYS"/"&&sysPassword" as SYSDBA
startup ;
spool off
exit;