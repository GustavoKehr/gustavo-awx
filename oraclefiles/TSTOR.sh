#!/bin/sh

OLD_UMASK=`umask`
umask 0027
mkdir -p /oracle/TSTOR/admin/adump
mkdir -p /oracle/TSTOR/mirrlogA/cntrl
mkdir -p /oracle/TSTOR/oradata1/cntrl
mkdir -p /oracle/TSTOR/origlogA/cntrl
mkdir -p /oracle/TSTOR/admin/dpdump
mkdir -p /oracle/TSTOR/admin/pfile
mkdir -p /oracle/TSTOR/admin/audit
#mkdir -p /u01/app/oracle/cfgtoollogs/dbca/TSTOR
umask ${OLD_UMASK}
PERL5LIB=$ORACLE_HOME/rdbms/admin:$PERL5LIB; export PERL5LIB
ORACLE_SID=TSTOR; export ORACLE_SID
PATH=$ORACLE_HOME/bin:$ORACLE_HOME/perl/bin:$PATH; export PATH
echo You should Add this entry in the /etc/oratab: TSTOR:/oracle/TSTOR/19.0.0:Y
/oracle/TSTOR/19.0.0/bin/sqlplus /nolog @/oracle/TSTOR/scripts/db_creation/TSTOR/TSTOR.sql