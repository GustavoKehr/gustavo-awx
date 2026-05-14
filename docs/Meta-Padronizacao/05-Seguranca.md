# 05 — Seguranca e Hardening de Bancos de Dados

## Principios Fundamentais

1. **Least Privilege** — cada usuario/aplicacao recebe apenas as permissoes minimas necessarias
2. **Defense in Depth** — multiplas camadas de seguranca (rede, SO, banco, aplicacao)
3. **Zero Trust** — nenhum acesso e implicito; toda conexao deve ser autenticada e autorizada
4. **Auditabilidade** — todo acesso e modificacao deve ser registrado e auditavel
5. **Separacao de Funcoes** — DBA, desenvolvedor, auditoria, operacoes com permissoes distintas

---

## Checklist Universal (todos os bancos)

### Controle de Acesso
- [ ] Remover contas padrao, anonimas ou com senha vazia
- [ ] Alterar senhas de contas administrativas padrao (`postgres`, `root`, `sa`, `sys`, `system`)
- [ ] Criar usuario dedicado por aplicacao — nunca compartilhar credenciais
- [ ] Aplicar principio de least privilege: `SELECT` apenas para leitura, `INSERT/UPDATE/DELETE` somente onde necessario
- [ ] Proibir login direto com usuarios administrativos de alto privilegio (DBA autentica via sudo/escalacao)
- [ ] Implementar MFA para contas DBA em producao
- [ ] Revisao trimestral de permissoes de todos os usuarios

### Rede e Conectividade
- [ ] Banco de dados nunca exposto diretamente na internet
- [ ] Bind somente em interfaces necessarias (nao `0.0.0.0` sem controle)
- [ ] Firewall/Security Group permite conexoes apenas de IPs conhecidos (servidores de aplicacao, bastion)
- [ ] Alterar porta padrao quando possivel (seguranca por obscuridade + reducao de scanner attacks)
- [ ] TLS 1.2+ obrigatorio para todas as conexoes remotas (versoes anteriores desabilitadas)
- [ ] Certificados de CA validos — nao usar certificados autoassinados em producao

### Criptografia
- [ ] Dados em repouso: TDE (Transparent Data Encryption) ou criptografia em nivel de arquivo
- [ ] Dados em transito: TLS 1.2+ para todas as conexoes
- [ ] Backups criptografados (AES-256)
- [ ] Chaves de criptografia gerenciadas externamente (HSM, AWS KMS, Azure Key Vault, HashiCorp Vault)
- [ ] Campos altamente sensiveis (CPF, cartao de credito): criptografia em nivel de coluna

### Auditoria e Logging
- [ ] Habilitar audit log nativo do banco
- [ ] Registrar: logins com sucesso e falha, mudancas de schema (DDL), acesso a dados sensiveis (DML em tabelas criticas)
- [ ] Armazenar logs em local separado do banco (imutavel se possivel — WORM)
- [ ] Retencao minima de audit logs: 1 ano online + 7 anos em archive (SOX/HIPAA)
- [ ] Alertas automaticos para: multiplas falhas de login, acesso fora do horario comercial, acessos privilegiados incomuns

### Patches e Atualizacoes
- [ ] Processo definido para aplicacao de patches de seguranca
- [ ] Patches criticos (CVE CVSS >= 9.0): aplicar em ate 72 horas
- [ ] Patches de alta severidade (CVSS >= 7.0): aplicar em ate 30 dias
- [ ] Patches medios/baixos: aplicar na proxima janela de manutencao mensal
- [ ] Assinar alertas de seguranca do vendor de cada banco

### Varredura de Vulnerabilidades
- [ ] Scan de vulnerabilidades mensal no banco de dados
- [ ] Revisao anual com ferramenta CIS-CAT ou equivalente
- [ ] Pen-test anual ou apos mudancas arquiteturais significativas

---

## Hardening Especifico por Banco

### PostgreSQL
```sql
-- Verificar autenticacao configurada (deve ser scram-sha-256, nao trust ou md5)
-- em pg_hba.conf: substituir md5 por scram-sha-256

-- Revogar conexao publica em template databases
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;

-- Revogar CREATE em schema public para usuarios comuns
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- Habilitar Row Security em tabelas com dados sensiveis
ALTER TABLE dados_clientes ENABLE ROW LEVEL SECURITY;

-- Verificar superusers (deve ter o minimo possivel)
SELECT usename FROM pg_user WHERE usesuper = true;

-- Habilitar SSL
-- postgresql.conf:
-- ssl = on
-- ssl_cert_file = 'server.crt'
-- ssl_key_file = 'server.key'
-- ssl_min_protocol_version = 'TLSv1.2'
```

**Configuracoes recomendadas em postgresql.conf**:
```ini
log_connections = on
log_disconnections = on
log_failed_connections = on
log_statement = 'ddl'
log_min_duration_statement = 1000
password_encryption = scram-sha-256
```

### MySQL
```sql
-- Remover banco test e usuarios anonimos
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.user WHERE User = '';
DELETE FROM mysql.user WHERE Host != '%' AND Host != 'localhost';
FLUSH PRIVILEGES;

-- Verificar usuarios sem senha
SELECT User, Host, authentication_string FROM mysql.user WHERE authentication_string = '';

-- Habilitar politica de senha forte
INSTALL COMPONENT 'file://component_validate_password';
SET GLOBAL validate_password.policy = STRONG;
SET GLOBAL validate_password.length = 12;

-- Desabilitar LOAD DATA INFILE global
-- my.cnf: local_infile = 0

-- Verificar privilegios excessivos
SELECT User, Host, Super_priv, File_priv, Process_priv FROM mysql.user WHERE Super_priv = 'Y' OR File_priv = 'Y';
```

### SQL Server
```sql
-- Desabilitar features desnecessarias
EXEC sp_configure 'xp_cmdshell', 0; RECONFIGURE;
EXEC sp_configure 'clr enabled', 0; RECONFIGURE;
EXEC sp_configure 'Ole Automation Procedures', 0; RECONFIGURE;
EXEC sp_configure 'Ad Hoc Distributed Queries', 0; RECONFIGURE;

-- Verificar logins sem senha (SQL auth)
SELECT name, is_disabled FROM sys.sql_logins WHERE PWDCOMPARE('', password_hash) = 1;

-- Habilitar auditoria de login
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'AuditLevel', REG_DWORD, 3; -- 3 = sucesso e falha

-- Verificar membros de sysadmin (deve ser minimo)
SELECT l.name FROM sys.server_role_members rm
JOIN sys.server_principals l ON rm.member_principal_id = l.principal_id
JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
WHERE r.name = 'sysadmin';

-- Habilitar Transparent Data Encryption
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'SenhaForteAqui123!';
CREATE CERTIFICATE TDECert WITH SUBJECT = 'TDE Certificate';

USE SeuBanco;
CREATE DATABASE ENCRYPTION KEY WITH ALGORITHM = AES_256
    ENCRYPTION BY SERVER CERTIFICATE TDECert;
ALTER DATABASE SeuBanco SET ENCRYPTION ON;
```

### Oracle
```sql
-- Verificar e revogar privilegios excessivos de PUBLIC
SELECT * FROM dba_sys_privs WHERE grantee = 'PUBLIC' ORDER BY privilege;

-- Verificar usuarios com senha padrao
SELECT * FROM dba_users_with_defpwd;

-- Habilitar auditoria unificada
-- oracle-base.com/articles/12c/unified-auditing-12cr1

-- Politica de senha minima
ALTER PROFILE DEFAULT LIMIT
    PASSWORD_LIFE_TIME     60
    PASSWORD_REUSE_TIME    365
    PASSWORD_REUSE_MAX     5
    PASSWORD_VERIFY_FUNCTION ora12c_strong_verify_function
    FAILED_LOGIN_ATTEMPTS  5
    PASSWORD_LOCK_TIME     1/24;

-- Verificar contas com senha nunca expirada
SELECT username, profile, account_status FROM dba_users
WHERE account_status = 'OPEN' AND expiry_date IS NULL;

-- Configurar Oracle Wallet para autenticacao externa em scripts
-- Evita senhas em texto claro em scripts de backup/automacao
```

### IBM Db2
```bash
# Configurar auditoria
db2audit configure scope all status both error type audit
db2audit start

# Verificar configuracao de seguranca
db2 GET DBM CFG | grep -i auth
db2 GET DB CFG FOR mydb | grep -i log

# Usar grupos do SO para controle de acesso
# Db2 autentica no SO e autoriza internamente
# SYSADM_GROUP, SYSCTRL_GROUP, SYSMAINT_GROUP, SYSMON_GROUP
```

### Vertica
```sql
-- Criar politica de acesso por coluna (Column-Level Security)
CREATE ACCESS POLICY ON tabela_sensivel
    FOR COLUMN cpf
    CASE WHEN ENABLED_ROLE('dba_role') THEN cpf
         ELSE REGEXP_REPLACE(cpf, '.', 'X')
    END;

-- Verificar politicas existentes
SELECT * FROM ACCESS_POLICIES;

-- Criar roles e associar a usuarios
CREATE ROLE app_read;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_read;
GRANT app_read TO usuario_app;

-- Habilitar TLS
-- No arquivo de parametros do banco:
-- EnableTLS = 1
-- TLSMode = REQUIRE
```

### Redis
```bash
# redis.conf — configuracoes de seguranca

# Desabilitar comandos perigosos
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command CONFIG ""
rename-command DEBUG ""
rename-command SHUTDOWN SHUTDOWN_SECRET_COMMAND

# Limitar clientes
maxclients 1000

# Habilitar TLS (Redis 6+)
tls-port 6380
port 0
tls-cert-file /etc/redis/tls/redis.crt
tls-key-file /etc/redis/tls/redis.key
tls-ca-cert-file /etc/redis/tls/ca.crt
tls-auth-clients yes

# ACL — criar usuarios com permissoes minimas
ACL SETUSER appuser on >SenhaApp123! ~chave_prefixo:* +GET +SET +DEL
ACL SETUSER readonly on >SenhaRO456! ~* +@read
ACL SETUSER default off
```

---

## OWASP Database Security — Top Riscos

| Risco | Prevencao |
|-------|-----------|
| **SQL Injection** | Usar prepared statements / parameterized queries; nunca concatenar input do usuario em SQL |
| **Excesso de Privilegios** | Aplicar least privilege; usuario de app nao precisa de DDL |
| **Senhas Fracas** | Politica de senha forte + rotacao; nunca senhas padrao |
| **Dados em Texto Claro** | TDE + TLS + criptografia de coluna para dados sensiveis |
| **Falta de Auditoria** | Habilitar audit log nativo; monitorar automaticamente |
| **Patches Atrasados** | Processo de patch management com SLA definido |
| **Backup Inseguro** | Criptografar backups; armazenar offsite; restringir acesso |
| **Exposicao Direta na Internet** | Banco atras de firewall; nunca IP publico em producao |

---

## Gestao de Credenciais

### O que NUNCA fazer
- Senhas em texto plano em arquivos de configuracao, scripts, ou repositorios Git
- Compartilhar credenciais entre aplicacoes ou usuarios
- Usar usuario administrativo em strings de conexao de aplicacao
- Hardcode de senha no codigo fonte

### Ferramentas de Gestao de Secrets
| Ferramenta | Onde Usar |
|-----------|-----------|
| **HashiCorp Vault** | On-premises e multi-cloud |
| **AWS Secrets Manager** | AWS |
| **Azure Key Vault** | Azure |
| **GCP Secret Manager** | GCP |
| **Ansible Vault** | Automacao com Ansible |

### Rotacao de Credenciais
- Credenciais de aplicacao: rotacao a cada 90 dias (automatizar)
- Credenciais de DBA: rotacao a cada 30 dias + apos cada offboarding
- Chaves de criptografia: rotacao anual (key rotation sem re-criptografia de dados com TDE)
- Credenciais de servico/batch: rotacao a cada 180 dias
