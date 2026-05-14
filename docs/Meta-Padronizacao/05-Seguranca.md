# 05 — Seguranca e Hardening de Bancos de Dados

## Principios Fundamentais

| Principio | Aplicacao em BD |
|-----------|----------------|
| **Least Privilege** | Usuario de app tem apenas SELECT/INSERT/UPDATE/DELETE nas tabelas necessarias; nunca DDL |
| **Defense in Depth** | Rede (firewall) + SO (SELinux) + Banco (auth/auditoria) + Aplicacao (prepared statements) |
| **Zero Trust** | Toda conexao autenticada e autorizada; sem confiar em IP ou rede interna implicitamente |
| **Auditabilidade** | Todo acesso e modificacao registrado, retido e imutavel |
| **Separacao de Funcoes** | DBA, desenvolvedor, auditoria, operacoes com permissoes distintas |
| **Minimal Attack Surface** | Desabilitar todas as features, contas, e servicos nao utilizados |

---

> **Por que a seguranca de banco de dados e responsabilidade do DBA, nao apenas do time de seguranca?**
> O DBA e o unico com acesso ao nivel de configuracao onde a maioria dos controles efetivos existem: autenticacao, auditoria, criptografia em repouso, controle granular de permissoes, e mascaramento de dados. O time de seguranca pode definir politicas, mas a implementacao tecnica vive no banco. Segundo o Verizon DBIR, 80%+ das violacoes de dados envolvem credenciais comprometidas ou acesso privilegiado indevido — ambos sao controles de DBA. Tratar seguranca de banco como responsabilidade exclusiva de outro time e um gap operacional documentado em auditorias PCI DSS e ISO 27001.

## Checklist Universal (todos os bancos)

### Controle de Acesso
- [ ] Remover todas as contas default, anonimas e com senha vazia
- [ ] Alterar senhas de contas administrativas padrao imediatamente apos instalacao
- [ ] Usuario dedicado por aplicacao — nunca compartilhar credenciais
- [ ] Principio de least privilege: somente o necessario por role
- [ ] MFA obrigatorio para contas DBA em producao
- [ ] Revisao trimestral de permissoes (access review)
- [ ] Processo de offboarding: revogar acesso no mesmo dia da demissao

### Rede
- [ ] Banco nunca exposto diretamente na internet
- [ ] Bind somente em interfaces necessarias (nunca `0.0.0.0` sem firewall)
- [ ] Firewall: apenas IPs/ranges autorizados (app servers, bastions, DBA workstations)
- [ ] Porta padrao alterada onde possivel
- [ ] TLS 1.2+ para todas as conexoes remotas; TLS 1.0/1.1 desabilitados
- [ ] Certificados de CA validos; nao usar self-signed em producao

### Criptografia
- [ ] Dados em repouso: TDE (AES-256)
- [ ] Dados em transito: TLS 1.2+
- [ ] Backups criptografados (AES-256)
- [ ] Chaves gerenciadas externamente (HSM, KMS)
- [ ] Campos altamente sensiveis: criptografia em nivel de coluna

### Auditoria e Logging
- [ ] Audit log habilitado: logins, DDL, acesso a dados sensiveis
- [ ] Logs armazenados em local separado (imutavel)
- [ ] Retencao minima: 1 ano online + 7 anos archive
- [ ] Alertas automaticos: multiplas falhas de login, acesso fora de horario, escalacao de privilegios
- [ ] Logs centralizados em SIEM (Splunk, Elastic, etc.)

### Patches
- [ ] CVE CVSS >= 9.0: patch em ate 72 horas
- [ ] CVE CVSS >= 7.0: patch em ate 30 dias
- [ ] Outros patches: proxima janela de manutencao mensal
- [ ] Assinar alertas de seguranca do vendor

---

> **Por que desabilitar contas default e remover bancos de teste imediatamente apos instalacao?**
> Instalacoes default de MySQL, PostgreSQL, Oracle e Redis incluem contas sem senha, bancos de teste acessiveis por qualquer usuario, e features habilitadas para facilitar primeiros passos — nao para producao. A conta `anonymous` do MySQL permite conexao sem senha. O banco `test` do MySQL da GRANT implicito para qualquer usuario. O `sa` do SQL Server com senha vazia foi vetor de worms como SQL Slammer (2003), que infectou 75.000 servidores em 10 minutos. CIS Benchmarks e DISA STIGs listam remocao de contas default como controle Nivel 1 (basico, obrigatorio).

## PostgreSQL — Hardening Completo

### Configuracoes de Seguranca (postgresql.conf)
```ini
# Autenticacao
password_encryption = scram-sha-256     # NUNCA md5
ssl = on
ssl_cert_file = '/etc/ssl/certs/server.crt'
ssl_key_file = '/etc/ssl/private/server.key'
ssl_ca_file = '/etc/ssl/certs/ca.crt'
ssl_min_protocol_version = 'TLSv1.2'
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL'

# Logging de seguranca
log_connections = on
log_disconnections = on
log_failed_connections = on
log_statement = 'ddl'                   # 'all' para auditoria completa
log_min_duration_statement = 1000       # queries lentas
log_duration = off                      # nao logar duracao de todas queries
log_lock_waits = on
log_checkpoints = on
log_autovacuum_min_duration = 0

# Timeouts de seguranca
idle_in_transaction_session_timeout = 300000    # 5 minutos
lock_timeout = 10000                            # 10 segundos para locks
statement_timeout = 0                           # 0 = desabilitado global; definir por role

# Hardening geral
row_security = on                       # habilitar RLS globalmente
track_activities = on
track_counts = on
track_io_timing = on
```

### Auditoria com pgaudit
```sql
-- Instalar e configurar pgaudit
-- postgresql.conf:
-- shared_preload_libraries = 'pgaudit'
-- pgaudit.log = 'read,write,ddl,role,connection'
-- pgaudit.log_catalog = on
-- pgaudit.log_parameter = on
-- pgaudit.log_statement_once = off

-- Auditoria por role
ALTER ROLE app_user SET pgaudit.log = 'write';   -- auditar escritas do usuario

-- Auditoria por objeto
SELECT audit.audit_table('schema.tabela_sensivel');
```

### Controle de Acesso Granular
```sql
-- Criar roles hierarquicas
CREATE ROLE readonly_role;
CREATE ROLE readwrite_role;
CREATE ROLE admin_role;

-- Permissoes da role de leitura
GRANT CONNECT ON DATABASE mydb TO readonly_role;
GRANT USAGE ON SCHEMA public TO readonly_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly_role;

-- Permissoes de leitura+escrita
GRANT readonly_role TO readwrite_role;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO readwrite_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT INSERT, UPDATE, DELETE ON TABLES TO readwrite_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO readwrite_role;

-- Criar usuarios e associar roles
CREATE USER app_readonly LOGIN PASSWORD 'SenhaRO123!' CONNECTION LIMIT 50;
GRANT readonly_role TO app_readonly;

CREATE USER app_user LOGIN PASSWORD 'SenhaApp123!' CONNECTION LIMIT 200;
GRANT readwrite_role TO app_user;

-- Row-Level Security
ALTER TABLE customer_data ENABLE ROW LEVEL SECURITY;
CREATE POLICY customer_isolation ON customer_data
    USING (tenant_id = current_setting('app.tenant_id')::int);

-- Revogar acesso ao schema public
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE mydb FROM PUBLIC;

-- Remover conexao ao template1
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
```

**Fontes PostgreSQL Seguranca**:
- https://www.postgresql.org/docs/current/auth-pg-hba-conf.html
- https://www.postgresql.org/docs/current/ssl-tcp.html
- https://github.com/pgaudit/pgaudit
- https://www.enterprisedb.com/blog/how-to-secure-postgresql-security-hardening-best-practices-checklist-tips-encryption-authentication-vulnerabilities
- https://cheatsheetseries.owasp.org/cheatsheets/Database_Security_Cheat_Sheet.html
- https://www.cisecurity.org/benchmark/postgresql

---

## MySQL — Hardening Completo

### Configuracoes de Seguranca (my.cnf)
```ini
[mysqld]
# Autenticacao e seguranca
default_authentication_plugin = caching_sha2_password
require_secure_transport = ON             # Exigir SSL/TLS

# Arquivos
secure_file_priv = NULL                   # Desabilitar FILE privilege
local_infile = 0                          # Desabilitar LOAD DATA LOCAL
skip_symbolic_links = 1                   # Prevenir ataques via symlinks

# Modo estrito
sql_mode = STRICT_TRANS_TABLES,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION

# Rede
bind-address = 127.0.0.1                  # Alterar para IP especifico em producao

# Logging de seguranca
general_log = 0                           # Nao em producao (I/O intensivo)
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
log_queries_not_using_indexes = 1
log_error = /var/log/mysql/error.log
log_warnings = 2

# TLS
ssl_ca = /etc/mysql/tls/ca.crt
ssl_cert = /etc/mysql/tls/server.crt
ssl_key = /etc/mysql/tls/server.key
tls_version = TLSv1.2,TLSv1.3
```

### Politica de Senha
```sql
-- Instalar e configurar component_validate_password (MySQL 8)
INSTALL COMPONENT 'file://component_validate_password';

SET GLOBAL validate_password.policy = STRONG;
SET GLOBAL validate_password.length = 12;
SET GLOBAL validate_password.mixed_case_count = 1;
SET GLOBAL validate_password.number_count = 1;
SET GLOBAL validate_password.special_char_count = 1;

-- Password expiration
ALTER USER 'appuser'@'%' PASSWORD EXPIRE INTERVAL 90 DAY;

-- Bloquear usuario apos tentativas falhas (MySQL 8)
ALTER USER 'appuser'@'%' FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
```

### Controle de Acesso Granular
```sql
-- Remover contas anonimas
DELETE FROM mysql.user WHERE User = '';
FLUSH PRIVILEGES;

-- Remover banco test
DROP DATABASE IF EXISTS test;

-- Verificar usuarios com privilegios excessivos
SELECT User, Host, Super_priv, File_priv, Grant_priv
FROM mysql.user
WHERE Super_priv = 'Y' OR File_priv = 'Y' OR Grant_priv = 'Y';

-- Criar usuario de aplicacao com privilegios minimos
CREATE USER 'appuser'@'10.0.1.%'
    IDENTIFIED WITH caching_sha2_password BY 'SenhaApp123!'
    REQUIRE SSL
    WITH MAX_CONNECTIONS_PER_HOUR 3600
         MAX_USER_CONNECTIONS 100;

GRANT SELECT, INSERT, UPDATE, DELETE ON mydb.* TO 'appuser'@'10.0.1.%';

-- Usuario somente leitura para relatorios
CREATE USER 'reporter'@'10.0.2.%'
    IDENTIFIED WITH caching_sha2_password BY 'SenhaRO456!'
    REQUIRE SSL;
GRANT SELECT ON mydb.* TO 'reporter'@'10.0.2.%';

-- Nao dar acesso ao banco mysql
REVOKE ALL ON mysql.* FROM 'appuser'@'10.0.1.%';
```

### Auditoria MySQL
```sql
-- MySQL Enterprise Audit (plugin enterprise)
INSTALL PLUGIN audit_log SONAME 'audit_log.so';
SET GLOBAL audit_log_policy = 'ALL';
SET GLOBAL audit_log_format = 'JSON';
SET GLOBAL audit_log_file = '/var/log/mysql/audit.log';

-- MariaDB Audit Plugin (open source)
INSTALL PLUGIN SERVER_AUDIT SONAME 'server_audit.so';
SET GLOBAL server_audit_logging = ON;
SET GLOBAL server_audit_events = 'CONNECT,QUERY,TABLE';
```

**Fontes MySQL Seguranca**:
- https://dev.mysql.com/doc/refman/8.0/en/security-guidelines.html
- https://dev.mysql.com/doc/mysql-secure-deployment-guide/8.0/en/
- https://www.cisecurity.org/benchmark/oracle_mysql
- https://www.percona.com/blog/mysql-database-security-best-practices/
- https://dev.mysql.com/doc/refman/8.0/en/audit-log-plugin.html

---

## SQL Server — Hardening Completo

### Configuracoes de Seguranca
```sql
-- Desabilitar features desnecessarias (surface area reduction)
EXEC sp_configure 'xp_cmdshell', 0;
EXEC sp_configure 'clr enabled', 0;
EXEC sp_configure 'Ole Automation Procedures', 0;
EXEC sp_configure 'Ad Hoc Distributed Queries', 0;
EXEC sp_configure 'Database Mail XPs', 0;
EXEC sp_configure 'SMO and DMO XPs', 0;
EXEC sp_configure 'Web Assistant Procedures', 0;
EXEC sp_configure 'Scan For Startup Procs', 0;
RECONFIGURE;

-- Desabilitar conta sa (substituir por conta nomeada)
ALTER LOGIN [sa] DISABLE;
ALTER LOGIN [sa] WITH NAME = [sa_disabled];

-- Configurar auditoria de login
USE [master];
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'AuditLevel', REG_DWORD, 3;  -- 3: logar sucesso e falha

-- Verificar membros de sysadmin
SELECT name, is_disabled, type_desc
FROM sys.server_principals sp
JOIN sys.server_role_members srm ON sp.principal_id = srm.member_principal_id
JOIN sys.server_principals r ON srm.role_principal_id = r.principal_id
WHERE r.name = 'sysadmin';

-- Forcar criptografia de conexoes (SQL Configuration Manager)
-- Ou via registro:
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib',
    N'ForceEncryption', REG_DWORD, 1;
```

### Transparent Data Encryption (TDE)
```sql
-- Criar master key na instancia
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'MasterKey$Senha123!';

-- Criar certificado para TDE
CREATE CERTIFICATE TDE_Cert
    WITH SUBJECT = 'TDE Database Encryption Certificate',
    EXPIRY_DATE = '20291231';

-- IMPORTANTE: Fazer backup imediato do certificado
BACKUP CERTIFICATE TDE_Cert
    TO FILE = '/backup/tls/TDE_Cert.cer'
    WITH PRIVATE KEY (
        FILE = '/backup/tls/TDE_Cert.pvk',
        ENCRYPTION BY PASSWORD = 'SenhaCertBackup123!'
    );

-- Habilitar TDE no banco de dados
USE MeuBanco;
CREATE DATABASE ENCRYPTION KEY
    WITH ALGORITHM = AES_256
    ENCRYPTION BY SERVER CERTIFICATE TDE_Cert;

ALTER DATABASE MeuBanco SET ENCRYPTION ON;

-- Verificar status da criptografia
SELECT db.name, dek.encryption_state,
    dek.encryption_state_desc,
    dek.percent_complete
FROM sys.databases db
JOIN sys.dm_database_encryption_keys dek ON db.database_id = dek.database_id;
```

### Always Encrypted (para colunas com PII)
```sql
-- Criar Column Master Key e Column Encryption Key
-- (normalmente feito via SSMS ou PowerShell com Azure Key Vault)

-- Criptografar coluna existente
ALTER TABLE customers ALTER COLUMN cpf
    ADD MASKED WITH (FUNCTION = 'default()');  -- data masking simples

-- Data masking dinamico (mais seguro)
ALTER TABLE customers
    ALTER COLUMN cpf ADD MASKED WITH (FUNCTION = 'partial(0,"XXX.XXX.XXX-",2)');

ALTER TABLE customers
    ALTER COLUMN credit_card_number ADD MASKED WITH (FUNCTION = 'partial(0,"****-****-****-",4)');

-- Conceder acesso a dados reais (sem mascaramento) somente para roles autorizadas
GRANT UNMASK ON TABLE customers TO app_admin_role;
```

### SQL Server Audit
```sql
-- Criar especificacao de auditoria no nivel de servidor
CREATE SERVER AUDIT [ServerAudit]
TO FILE (
    FILEPATH = N'/var/opt/mssql/audit/',
    MAXSIZE = 100 MB,
    MAX_ROLLOVER_FILES = 20,
    RESERVE_DISK_SPACE = OFF
)
WITH (
    QUEUE_DELAY = 1000,
    ON_FAILURE = CONTINUE
);

ALTER SERVER AUDIT [ServerAudit] WITH (STATE = ON);

-- Auditoria de banco de dados
USE MeuBanco;
CREATE DATABASE AUDIT SPECIFICATION [DBAudit]
FOR SERVER AUDIT [ServerAudit]
ADD (INSERT, UPDATE, DELETE ON dbo.customer_data BY public),
ADD (SELECT ON dbo.payment_info BY public),
ADD (SCHEMA_OBJECT_CHANGE_GROUP),
ADD (DATABASE_PERMISSION_CHANGE_GROUP),
ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP);

ALTER DATABASE AUDIT SPECIFICATION [DBAudit] WITH (STATE = ON);

-- Ler audit log
SELECT event_time, action_id, succeeded, server_principal_name,
    database_name, object_name, statement
FROM sys.fn_get_audit_file('/var/opt/mssql/audit/*.sqlaudit', DEFAULT, DEFAULT)
ORDER BY event_time DESC;
```

**Fontes SQL Server Seguranca**:
- https://learn.microsoft.com/en-us/sql/relational-databases/security/sql-server-security-best-practices
- https://learn.microsoft.com/en-us/sql/relational-databases/security/encryption/transparent-data-encryption
- https://learn.microsoft.com/en-us/sql/relational-databases/security/auditing/sql-server-audit-database-engine
- https://www.cisecurity.org/benchmark/sql_server
- https://www.stigviewer.com/stig/ms_sql_server_2019_database/

---

## Oracle — Hardening Completo

### Auditoria Unificada (Oracle 12c+)
```sql
-- Verificar se auditoria unificada esta ativa
SELECT value FROM v$option WHERE parameter = 'Unified Auditing';

-- Criar politica de auditoria
CREATE AUDIT POLICY all_actions_on_hr
    ACTIONS
        INSERT ON hr.employees,
        UPDATE ON hr.employees,
        DELETE ON hr.employees,
        SELECT ON hr.payroll
    WHEN 'SYS_CONTEXT(''USERENV'',''SESSION_USER'') NOT IN (''HR'', ''HRADMIN'')'
    EVALUATE PER SESSION;

AUDIT POLICY all_actions_on_hr;

-- Auditoria de privilegios perigosos
CREATE AUDIT POLICY priv_audit
    PRIVILEGES
        CREATE ANY TABLE,
        DROP ANY TABLE,
        ALTER ANY TABLE,
        GRANT ANY PRIVILEGE,
        CREATE USER,
        DROP USER;

AUDIT POLICY priv_audit;

-- Auditoria de sys (obrigatoria)
-- initSID.ora: AUDIT_SYS_OPERATIONS=TRUE
-- Verificar:
SHOW PARAMETER audit_sys_operations;

-- Ler audit trail
SELECT timestamp, db_user, action_name, object_name, sql_text
FROM unified_audit_trail
WHERE timestamp > SYSDATE - 1
ORDER BY timestamp DESC;
```

### Privilegios — Revogar Excessos
```sql
-- Verificar privilegios do PUBLIC (muitos perigosos por padrao)
SELECT privilege, admin_option FROM dba_sys_privs WHERE grantee = 'PUBLIC' ORDER BY 1;

-- Revogar privilegios perigosos do PUBLIC
REVOKE EXECUTE ON UTL_FILE FROM PUBLIC;
REVOKE EXECUTE ON UTL_HTTP FROM PUBLIC;
REVOKE EXECUTE ON UTL_SMTP FROM PUBLIC;
REVOKE EXECUTE ON DBMS_ADVISOR FROM PUBLIC;
REVOKE EXECUTE ON DBMS_JAVA FROM PUBLIC;

-- Verificar usuarios com senha padrao
SELECT username, account_status FROM dba_users_with_defpwd ORDER BY username;
-- Todos devem ser LOCKED ou ter senha alterada

-- Verificar contas abertas com senha nunca expirada
SELECT username, profile, expiry_date, account_status
FROM dba_users
WHERE account_status = 'OPEN'
  AND expiry_date IS NULL
  AND username NOT IN ('SYS','SYSTEM');

-- TDE (Oracle 12c+)
-- Criar wallet
ADMINISTER KEY MANAGEMENT CREATE KEYSTORE '/etc/oracle/wallet' IDENTIFIED BY WalletSenha123!;
ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY WalletSenha123!;
ADMINISTER KEY MANAGEMENT SET KEY IDENTIFIED BY WalletSenha123! WITH BACKUP;

-- Criptografar tablespace
ALTER TABLESPACE users ENCRYPTION ONLINE USING 'AES256' ENCRYPT;

-- Verificar status de criptografia
SELECT ts#, encryptedts, status FROM v$encrypted_tablespaces;
```

### Oracle Database Vault
```sql
-- Oracle Database Vault previne acesso de DBAs a dados de aplicacao
-- (requer licenca Database Vault)

-- Criar realm (protege schema de aplicacao)
BEGIN
    DVSYS.DBMS_MACADM.CREATE_REALM(
        realm_name => 'HR Application Realm',
        description => 'Protects HR schema',
        enabled => 'Y',
        audit_options => DVSYS.DBMS_MACADM.G_REALM_AUDIT_FAIL + DVSYS.DBMS_MACADM.G_REALM_AUDIT_SUCCESS
    );
END;
/

EXEC DVSYS.DBMS_MACADM.ADD_OBJECT_TO_REALM('HR Application Realm', 'HR', '%', '%');
EXEC DVSYS.DBMS_MACADM.ADD_AUTH_TO_REALM('HR Application Realm', 'HR', '', DVSYS.DBMS_MACADM.G_OWNER_AUTH);
```

**Fontes Oracle Seguranca**:
- https://docs.oracle.com/en/database/oracle/oracle-database/19/dbseg/
- https://docs.oracle.com/en/database/oracle/oracle-database/19/dbseg/configuring-audit-policies.html
- https://docs.oracle.com/en/database/oracle/oracle-database/19/dbseg/configuring-transparent-data-encryption.html
- https://www.cisecurity.org/benchmark/oracle_database
- https://docs.oracle.com/en/database/oracle/oracle-database/19/dvadm/

---

## IBM Db2 — Hardening Completo

### Configuracao de Seguranca
```bash
# Configurar autenticacao no nível do gerenciador
db2 UPDATE DBM CFG USING AUTHENTICATION SERVER_ENCRYPT
db2 UPDATE DBM CFG USING SYSADM_GROUP db2iadm1
db2 UPDATE DBM CFG USING SYSCTRL_GROUP db2ctladm1
db2 UPDATE DBM CFG USING SYSMAINT_GROUP db2maint1
db2 UPDATE DBM CFG USING SYSMON_GROUP db2mongrp

# Habilitar SSL/TLS
db2 UPDATE DBM CFG USING SSL_SVR_KEYDB /home/db2inst1/sqllib/security/keystore/db2keys.kdb
db2 UPDATE DBM CFG USING SSL_SVR_STASH /home/db2inst1/sqllib/security/keystore/db2keys.sth
db2 UPDATE DBM CFG USING SSL_SVR_LABEL mydb2cert
db2 UPDATE DBM CFG USING SSL_SVCENAME 50001
db2 UPDATE DBM CFG USING SSL_VERSIONS 'TLSv12,TLSv13'
db2stop; db2start

# Configurar LABEL-BASED ACCESS CONTROL (LBAC)
db2 GRANT SECADM ON DATABASE TO USER lbacadmin
```

### Cripto e LBAC
```sql
-- LBAC: controle de acesso baseado em labels
-- Exige licenca DB2 Advanced Security Edition

-- Criar politica de seguranca
CREATE SECURITY POLICY hrpolicy
    COMPONENTS sensitivity WITH LEVELS PUBLIC < CONFIDENTIAL < RESTRICTED
    WITH GROUP ACCESS 'GROUP ACCESS';

-- Aplicar a tabela
ALTER TABLE hr.employees SECURITY POLICY hrpolicy;

-- Atribuir label de seguranca a usuario
GRANT SECURITY LABEL hrpolicy.public TO USER reporter;
GRANT SECURITY LABEL hrpolicy.confidential TO USER hradmin;
```

### Db2 Audit
```bash
# Configurar auditoria
db2audit configure scope AUDIT status both error type audit
db2audit configure scope CHECKING status both error type audit
db2audit configure scope OBJMAINT status both error type audit
db2audit configure scope SECMAINT status both error type audit
db2audit configure scope SYSADMIN status both error type audit
db2audit configure scope VALIDATE status both error type audit
db2audit configure scope CONTEXT status both error type audit

db2audit start

# Extrair logs de auditoria
db2audit extract file /tmp/db2audit.log delapidb database mydb

# Analisar log
db2audit list file /tmp/db2audit.log
```

**Fontes Db2 Seguranca**:
- https://www.ibm.com/docs/en/db2/11.5?topic=security-db2-model
- https://www.ibm.com/docs/en/db2/11.5?topic=security-auditing-database-activities
- https://www.ibm.com/docs/en/db2/11.5?topic=security-configuring-ssl-connections
- https://community.ibm.com/community/user/blogs/youssef-sbai-idrissi1/2023/07/27/how-to-set-up-security-for-ibm-db2-best-practices
- https://www.cisecurity.org/benchmark/ibm_db2

---

## Vertica — Hardening Completo

### TLS e Autenticacao
```sql
-- Verificar configuracao SSL
SELECT name, value FROM configuration_parameters WHERE name ILIKE '%ssl%' OR name ILIKE '%tls%';

-- Habilitar TLS
ALTER DATABASE mydb SET EnableSSL = 1;
ALTER DATABASE mydb SET TLSMode = 'REQUIRE';  -- rejeitar conexoes sem TLS
ALTER DATABASE mydb SET SSLCertificate = '/etc/vertica/tls/server.crt';
ALTER DATABASE mydb SET SSLPrivateKey = '/etc/vertica/tls/server.key';
ALTER DATABASE mydb SET SSLCA = '/etc/vertica/tls/ca.crt';

-- Forcar TLS por usuario
ALTER USER appuser TLSMODE 'REQUIRE';
```

### Controle de Acesso
```sql
-- Criar roles especificas
CREATE ROLE app_read;
CREATE ROLE app_write;
CREATE ROLE etl_user;
CREATE ROLE analyst;

-- Permissoes
GRANT USAGE ON SCHEMA public TO app_read, app_write, etl_user, analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_read, app_write, analyst;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_write;
GRANT INSERT ON ALL TABLES IN SCHEMA public TO etl_user;

-- Associar roles a usuarios
GRANT app_read TO reporter;
GRANT app_write TO appuser;
GRANT etl_user TO etl_process;
```

### Access Policies (Row/Column Level Security)
```sql
-- Politica de linha (Row-Level Security)
CREATE ACCESS POLICY ON customer_data
    FOR ROWS WHERE tenant_id = LOCAL_USERID()  -- apenas dados do proprio tenant
    ENABLE;

-- Politica de coluna (Column-Level Security)
CREATE ACCESS POLICY ON employees
    FOR COLUMN salary
    CASE WHEN ENABLED_ROLE('hr_manager_role') THEN salary
         ELSE NULL
    END
    ENABLE;

-- Mascaramento de CPF para nao-admins
CREATE ACCESS POLICY ON customers
    FOR COLUMN cpf
    CASE WHEN ENABLED_ROLE('admin_role') THEN cpf
         ELSE REPEAT('*', LENGTH(cpf) - 3) || RIGHT(cpf, 3)
    END
    ENABLE;

-- Verificar politicas
SELECT * FROM ACCESS_POLICIES;
```

**Fontes Vertica Seguranca**:
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/AdministratorsGuide/Security/
- https://www.vertica.com/kb/Best-Practices-for-Creating-Access-Policies-on-Vertica/
- https://www.vertica.com/docs/latest/HTML/Content/Authoring/AdministratorsGuide/Security/Authentication/ConfiguringClientAuthentication.htm
- https://www.vertica.com/docs/11.1.x/HTML/Content/Authoring/AdministratorsGuide/ConfiguringTheDB/SecurityParameters.htm

---

## Redis — Hardening Completo

### Configuracao Completa de Seguranca
```bash
# /etc/redis/redis.conf — configuracoes de seguranca

# Rede
bind 127.0.0.1 10.0.0.10
protected-mode yes
port 0                          # desabilitar porta sem TLS
tls-port 6380

# TLS
tls-cert-file /etc/redis/tls/redis.crt
tls-key-file /etc/redis/tls/redis.key
tls-ca-cert-file /etc/redis/tls/ca.crt
tls-auth-clients yes            # exigir certificado do cliente
tls-protocols "TLSv1.2 TLSv1.3"
tls-ciphers "HIGH:!aNULL:!MD5"
tls-prefer-server-ciphers yes

# Desabilitar comandos perigosos
rename-command FLUSHDB      "b840fc02d524045429941cc15f59e41cb7be6c52"
rename-command FLUSHALL     "b840fc02d524045429941cc15f59e41cb7be6c53"
rename-command CONFIG       ""      # desabilitar completamente
rename-command DEBUG        ""
rename-command PEXPIRE      "b840fc02d524045429941cc15f59e41cb7be6c54"
rename-command SHUTDOWN     ""      # so via sistema operacional

# Limites
maxclients 5000
tcp-backlog 511

# Timeouts
timeout 300
tcp-keepalive 300

# Logging
loglevel notice
logfile /var/log/redis/redis-server.log
syslog-enabled yes
syslog-ident redis
syslog-facility local0

# Monitoramento de seguranca
latency-monitor-threshold 100
latency-tracking yes
slowlog-log-slower-than 10000   # 10ms em microsegundos
slowlog-max-len 10000
```

### ACLs — Redis 6+ (configuracao completa)
```
# /etc/redis/users.acl

# Desabilitar conta default
user default off nopass nokeys nocommands

# Usuario de aplicacao cache
user app_cache on >SenhaCache123! ~cache:* +GET +SET +DEL +EXPIRE +TTL +PEXPIRE +PERSIST +KEYS +MGET +MSET +EXISTS

# Usuario de sessoes
user app_session on >SenhaSess456! ~session:* +GET +SET +DEL +EXPIRE +TTL +PEXPIRE +EXISTS

# Usuario somente leitura
user readonly on >SenhaRO789! ~* +@read

# Usuario de backup
user backup on >SenhaBkp000! ~* +BGSAVE +BGREWRITEAOF +LASTSAVE

# Usuario de monitoramento (Prometheus exporter)
user monitoring on >SenhaMon111! ~* +INFO +PING +CLIENT +COMMAND +CONFIG|GET +DBSIZE +DEBUG|SLEEP +LATENCY +LOLWUT +MEMORY|DOCTOR +MEMORY|HELP +MEMORY|MALLOC-STATS +MEMORY|STATS +MEMORY|USAGE +MODULE|LIST +OBJECT|HELP +OBJECT|FREQ +OBJECT|ENCODING +OBJECT|REFCOUNT +OBJECT|IDLETIME +PSYNC +PTTL +SLOWLOG|GET +SLOWLOG|LEN +SLOWLOG|RESET +SLAVEOF +TIME +WAIT +XINFO

# Administrador (apenas para DBA em bastion)
user admin on >SenhaAdmin999! ~* &* +@all
```

**Fontes Redis Seguranca**:
- https://redis.io/docs/latest/operate/oss_and_stack/management/security/
- https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/
- https://redis.io/blog/5-basic-steps-to-secure-redis-deployments/
- https://redis.io/docs/latest/operate/rs/security/recommended-security-practices/
- https://www.cisecurity.org/controls/  (CIS Controls aplicados a cache servers)

---

## OWASP — Prevencao de SQL Injection

> **Por que SQL Injection ainda e o ataque mais comum contra bancos de dados em 2024?**
> SQL Injection figura no OWASP Top 10 desde 2003 e continua relevante porque: (1) e trivial de explorar — uma unica query mal construida expoe o banco inteiro; (2) muitos frameworks ORM ainda permitem queries dinamicas sem parameterizacao; (3) legado: sistemas de 10-15 anos raramente foram refatorados para prepared statements. Em 2023, o breach da MOVEit (50M+ registros) e o ataque ao Progress Software foram via SQL Injection. A mitigacao e tecnicamente simples — prepared statements — mas requer disciplina consistente em todo o codigo.

**A unica prevencao efetiva**: sempre usar prepared statements / parameterized queries.

```python
# ERRADO (vulneravel a SQL injection)
query = "SELECT * FROM users WHERE name = '" + user_input + "'"

# CORRETO (parameterized query)
cursor.execute("SELECT * FROM users WHERE name = %s", (user_input,))
```

```java
// ERRADO
String query = "SELECT * FROM users WHERE id = " + userId;

// CORRETO
PreparedStatement stmt = conn.prepareStatement("SELECT * FROM users WHERE id = ?");
stmt.setInt(1, userId);
```

```csharp
// CORRETO com Dapper
var user = conn.QueryFirstOrDefault<User>(
    "SELECT * FROM users WHERE id = @Id",
    new { Id = userId }
);
```

**Fontes OWASP**:
- https://cheatsheetseries.owasp.org/cheatsheets/Database_Security_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html
- https://owasp.org/www-project-top-ten/

---

## Gestao de Credenciais

> **Por que TLS 1.2+ e obrigatorio e TLS 1.0/1.1 devem ser desabilitados?**
> TLS 1.0 e 1.1 tem vulnerabilidades conhecidas e documentadas: POODLE (2014), BEAST (2011), CRIME, BREACH — todos exploram fraquezas do protocolo que nao podem ser corrigidas por patches. PCI DSS 3.2+ proibiu TLS 1.0 em 2018. NIST SP 800-52 Rev 2 proibe TLS 1.1. TLS 1.2 com cipher suites AEAD (AES-GCM) e considerado seguro; TLS 1.3 remove cipher suites inseguros completamente. Em bancos de dados, conexoes sem criptografia exponem credenciais e dados em qualquer ponto da rede interna — assumir que rede interna e segura e um premissa obsoleta (Zero Trust).

### O que NUNCA fazer
- Senhas em texto plano em arquivos, scripts, ou Git
- Compartilhar credenciais entre aplicacoes ou usuarios
- Usar usuario administrativo em strings de conexao de aplicacao
- Hardcode de senha no codigo fonte
- Senhas no mesmo arquivo que backups

> **Por que secrets nunca devem estar em arquivos de configuracao, scripts ou repositorios Git?**
> Git e um sistema de versionamento imutavel — uma senha comittada permanece no historico mesmo apos ser "removida" com um commit posterior. Qualquer pessoa com acesso ao repositorio (incluindo forks e clones) pode recuperar a senha com `git log -p` ou `git show`. O GitGuardian reporta que em 2023 foram detectados 10 milhoes+ de secrets expostos em repositorios publicos. Rotacao de credenciais tambem e impossivel com hardcode. A solucao correta e gerenciadores de secrets que injetam credenciais em runtime: HashiCorp Vault, AWS Secrets Manager, Azure Key Vault, ou variaveis de ambiente injetadas pelo CI/CD.

### Ferramentas de Gestao de Secrets

| Ferramenta | Quando Usar |
|-----------|-------------|
| **HashiCorp Vault** | On-premises e multi-cloud |
| **AWS Secrets Manager** | AWS (com rotacao automatica) |
| **Azure Key Vault** | Azure |
| **GCP Secret Manager** | GCP |
| **Ansible Vault** | Automacao Ansible |
| **CyberArk** | Enterprise PAM (Privileged Access Management) |

### Rotacao de Credenciais

| Tipo de Credencial | Frequencia |
|-------------------|------------|
| Aplicacao (service account) | 90 dias (automatizado) |
| DBA interativo | 30 dias + apos cada offboarding |
| Chave TDE/TLS | Rotacao anual |
| Certificados TLS | Antes do vencimento (automatizar com cert-manager) |
| Credenciais de backup | 180 dias |
| Emergencia (break-glass) | Apos cada uso |
