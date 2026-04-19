SET VERIFY OFF
connect "SYS"/"&&sysPassword" as SYSDBA
set echo on
spool /oracle/TSTOR/scripts/db_creation/TSTOR/CreateDB.log append
startup nomount pfile="/oracle/TSTOR/scripts/db_creation/TSTOR/init.ora";
CREATE DATABASE "TSTOR"
MAXINSTANCES 8
MAXLOGHISTORY 1
MAXLOGFILES 64
MAXLOGMEMBERS 3
MAXDATAFILES 1000
DATAFILE '/oracle/TSTOR/oradata1/system01.dbf' SIZE 1G REUSE
EXTENT MANAGEMENT LOCAL
SYSAUX DATAFILE '/oracle/TSTOR/oradata1/sysaux01.dbf SIZE 1G REUSE
SMALLFILE DEFAULT TEMPORARY TABLESPACE TEMP TEMPFILE '/oracle/TSTOR/temp/temp01.dbf' SIZE 1G REUSE
SMALLFILE UNDO TABLESPACE "UNDOTBS1" DATAFILE  '/oracle/TSTOR/undo/undotbs01.dbf' SIZE 1G REUSE
CHARACTER SET WE8MSWIN1252
NATIONAL CHARACTER SET AL16UTF16
LOGFILE GROUP 1 ('/oracle/TSTOR/ologA/redo01_a.log','/oracle/TSTOR/mirrlogA/redo01_b.log') SIZE 500M,
GROUP 2 ('/oracle/TSTOR/ologB/redo02_a.log','/oracle/TSTOR/mirrlogB/redo02_b.log') SIZE 500M,
USER SYS IDENTIFIED BY "&&sysPassword" USER SYSTEM IDENTIFIED BY "&&systemPassword";
spool off