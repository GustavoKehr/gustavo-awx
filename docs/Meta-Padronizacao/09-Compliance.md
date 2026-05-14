# 09 — Compliance e Regulamentacoes

## Visao Geral

> **Por que compliance e responsabilidade do DBA, nao apenas do juridico?**
> As regulamentacoes de compliance (GDPR, HIPAA, SOX, PCI DSS) definem REQUISITOS funcionais que precisam ser implementados no banco de dados — criptografia de colunas, audit logging, imutabilidade de registros, mascaramento de dados sensiveis. O juridico define o que precisa ser feito; o DBA implementa o como. Violacoes causadas por ausencia de controles tecnicos (banco sem criptografia, sem audit log, com usuarios compartilhados) sao de responsabilidade tecnica — as penalidades sao aplicadas a empresa, nao ao juridico.

| Regulamentacao | Jurisdicao / Setor | Foco Principal | Penalidade Maxima |
|----------------|-------------------|----------------|-------------------|
| **GDPR** | Uniao Europeia (dados de cidadaos EU, global) | Privacidade de dados pessoais | 4% do faturamento global ou EUR 20M |
| **LGPD** | Brasil | Privacidade de dados pessoais | 2% do faturamento (max R$ 50M por infracao) |
| **HIPAA** | EUA — setor de saude | Dados de saude (PHI/ePHI) | USD 100 a USD 50.000 por violacao |
| **SOX** | EUA — empresas publicas listadas | Integridade de dados financeiros | Prisao + multas para executivos |
| **PCI DSS** | Global — pagamentos com cartao | Dados de cartao de credito (CHD) | Suspensao do direito de processar pagamentos |

---

## GDPR — General Data Protection Regulation

> **Por que o GDPR tem impacto tao profundo no design de bancos de dados?**
> O GDPR nao e apenas uma lei de privacidade — e um requisito de engenharia de dados. O "Direito ao Esquecimento" (Art. 17) significa que o banco precisa ser capaz de deletar ou anonimizar todos os dados de um usuario especifico em todos os sistemas em ate 30 dias. Isso exige:
> - Mapeamento completo de onde dados pessoais sao armazenados (ROPA)
> - Chaves estrangeiras rastreando `user_id` em todas as tabelas relacionadas
> - Procedimentos de erasure testados e documentados
>
> Bancos de dados projetados sem pensar em GDPR desde o inicio precisam de refatoracao cara para atender esses requisitos depois.

### Impacto em Bancos de Dados

| Principio GDPR | Requisito de BD |
|----------------|----------------|
| Minimizacao de dados | Coletar e armazenar apenas dados estritamente necessarios |
| Limitacao de finalidade | Dados usados somente para a finalidade declarada no momento da coleta |
| Limitacao de armazenamento | Definir e implementar TTL/politica de retencao por tipo de dado |
| Integridade e confidencialidade | Criptografia, controle de acesso, auditoria completa |
| Responsabilidade | Capacidade de demonstrar conformidade (audit logs, ROPA, DPAs) |
| Privacy by Design | Campos de dados pessoais nao criados por padrao; necessidade justificada |

### Requisitos Tecnicos por Banco de Dados

```sql
-- ========== PostgreSQL ==========
-- Criptografia de colunas com dados pessoais (pgcrypto)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Armazenar email criptografado
ALTER TABLE user_profiles
    ADD COLUMN email_encrypted BYTEA,
    ADD COLUMN name_encrypted BYTEA;

UPDATE user_profiles SET
    email_encrypted = pgp_sym_encrypt(email, :encryption_key),
    name_encrypted  = pgp_sym_encrypt(name, :encryption_key);

-- Auditoria de acesso a dados pessoais (com pgaudit)
-- postgresql.conf
-- pgaudit.log = 'read,write'
-- pgaudit.log_relation = 'on'

-- View mascarada para uso geral (apenas ultimos 2 chars do email)
CREATE VIEW user_profiles_masked AS
SELECT
    user_id,
    REGEXP_REPLACE(email, '(.{2})(.+)(@.+)', '\1***\3') AS email_masked,
    REGEXP_REPLACE(phone, '(\d{2})(\d+)(\d{2})', '\1*****\3') AS phone_masked,
    created_at
FROM user_profiles;

-- Politica de retencao automatica (deletar contas inativas > 3 anos)
CREATE OR REPLACE FUNCTION enforce_data_retention() RETURNS void AS $$
BEGIN
    DELETE FROM user_profiles
    WHERE last_login_at < now() - INTERVAL '3 years'
      AND deletion_requested_at IS NOT NULL;
END;
$$ LANGUAGE plpgsql;

-- ========== MySQL ==========
-- Criptografia AES de coluna
CREATE TABLE user_pii (
    user_id       BIGINT PRIMARY KEY,
    email_enc     VARBINARY(256),
    cpf_enc       VARBINARY(128),
    created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO user_pii (user_id, email_enc, cpf_enc)
VALUES (1,
    AES_ENCRYPT('user@email.com', UNHEX(SHA2('chave_secreta_256bits', 256))),
    AES_ENCRYPT('123.456.789-00', UNHEX(SHA2('chave_secreta_256bits', 256)))
);

SELECT
    user_id,
    CAST(AES_DECRYPT(email_enc, UNHEX(SHA2('chave_secreta_256bits', 256))) AS CHAR) AS email
FROM user_pii;

-- ========== SQL Server ==========
-- Always Encrypted (chave protegida pelo cliente — BD nao ve os dados)
-- Configurado via SSMS ou PowerShell:
-- 1. Criar Column Master Key (CMK) no certificado Windows ou Azure Key Vault
-- 2. Criar Column Encryption Key (CEK) criptografada com a CMK
-- 3. Marcar coluna como ENCRYPTED

-- Via T-SQL (requer driver compativel com Always Encrypted no cliente):
CREATE COLUMN MASTER KEY [CMK_GDPR]
WITH (KEY_STORE_PROVIDER_NAME = N'MSSQL_CERTIFICATE_STORE',
      KEY_PATH = N'CurrentUser/My/THUMBPRINT123');

CREATE COLUMN ENCRYPTION KEY [CEK_PII]
WITH VALUES (
    COLUMN_MASTER_KEY = [CMK_GDPR],
    ALGORITHM = 'RSA_OAEP',
    ENCRYPTED_VALUE = 0x...  -- gerado automaticamente
);

-- Coluna criptografada (transparente para aplicacao com driver compativel)
ALTER TABLE user_profiles
    ADD email NVARCHAR(256)
    ENCRYPTED WITH (
        COLUMN_ENCRYPTION_KEY = [CEK_PII],
        ENCRYPTION_TYPE = Randomized,
        ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256'
    );

-- ========== Oracle ==========
-- Oracle Data Masking and Subsetting (para ambientes nao-producao)
-- Oracle Advanced Security: TDE por coluna
ALTER TABLE user_profiles
    MODIFY (cpf ENCRYPT USING 'AES256' NO SALT);

-- Oracle Database Vault: restricao de acesso por contexto
EXEC DBMS_MACADM.CREATE_REALM(
    realm_name  => 'GDPR_PII_Realm',
    description => 'Proteger tabelas com dados pessoais GDPR',
    enabled     => DBMS_MACADM.G_YES,
    audit_options => DBMS_MACADM.G_REALM_AUDIT_FAIL
);

EXEC DBMS_MACADM.ADD_OBJECT_TO_REALM(
    realm_name   => 'GDPR_PII_Realm',
    object_owner => 'APP_SCHEMA',
    object_name  => 'USER_PROFILES',
    object_type  => 'TABLE'
);
```

### Direito ao Esquecimento (Right to Erasure — Art. 17 GDPR)

```sql
-- ========== Procedimento universal de erasure ==========
-- Passo 1: Identificar todos os dados do titular em todos os bancos
SELECT table_schema, table_name, column_name
FROM information_schema.columns
WHERE column_name IN (
    'email', 'cpf', 'phone', 'name', 'address',
    'ip_address', 'user_id', 'document_number', 'birth_date'
)
ORDER BY table_schema, table_name;

-- Passo 2: Deletar dados que NAO precisam ser mantidos para obrigacao legal
DELETE FROM user_profiles WHERE user_id = :user_id;
DELETE FROM user_addresses WHERE user_id = :user_id;
DELETE FROM user_consents WHERE user_id = :user_id;

-- Passo 3: Anonimizar dados que precisam ser mantidos (ex: para estatisticas)
UPDATE orders SET
    customer_name = 'ANONIMIZADO',
    shipping_address = 'REMOVIDO',
    billing_name = 'ANONIMIZADO'
WHERE user_id = :user_id;

-- Passo 4: Pseudonimizar em tabelas de analytics (manter estatisticas sem identificar)
UPDATE analytics_events SET
    user_id = MD5(CONCAT(user_id::text, 'salt_gdpr'))  -- hash one-way
WHERE user_id = :user_id;

-- Passo 5: Registrar a execucao do erasure (para demonstracao de conformidade)
INSERT INTO gdpr_erasure_log (
    user_id, requested_at, completed_at, tables_affected, requestor
) VALUES (
    :user_id, :requested_at, NOW(), :tables_json, :requestor
);

-- Prazo: atender solicitacao em ate 30 dias (Art. 12 GDPR)
-- Estender para 90 dias em casos complexos (notificar o titular)
```

### Portabilidade de Dados (Art. 20 GDPR)

```sql
-- Exportar todos os dados do titular em formato JSON estruturado
-- PostgreSQL
SELECT json_build_object(
    'profile', (SELECT row_to_json(t) FROM (SELECT * FROM user_profiles WHERE user_id = :uid) t),
    'orders',  (SELECT json_agg(row_to_json(t)) FROM (SELECT * FROM orders WHERE user_id = :uid) t),
    'consents',(SELECT json_agg(row_to_json(t)) FROM (SELECT * FROM user_consents WHERE user_id = :uid) t)
) AS exported_data;

-- MySQL
SELECT JSON_OBJECT(
    'user_id', user_id,
    'email', email,
    'created_at', created_at
) AS json_export
FROM user_profiles
WHERE user_id = :user_id;
```

### Data Processing Agreement (DPA) e ROPA

```
Registro de Atividades de Tratamento (ROPA — Art. 30 GDPR):
Para cada banco de dados em producao, documentar:
  - Nome do tratamento (ex: "Gerenciamento de Contas de Usuarios")
  - Responsavel pelo tratamento (DPO + sistema owner)
  - Tipos de dados pessoais armazenados (email, telefone, CPF, etc.)
  - Finalidade do tratamento (ex: "prestacao do servico contratado")
  - Base legal (consentimento, contrato, obrigacao legal, interesse legitimo)
  - Tempo de retencao (ex: "5 anos apos encerramento do contrato")
  - Terceiros que recebem os dados (fornecedores, parceiros, cloud providers)
  - Transferencias internacionais (ex: dados no AWS us-east-1 — EUA)
  - Medidas de seguranca implementadas (TDE, TLS, RBAC, auditoria)
```

**Fontes GDPR**:
- [Texto Integral do GDPR (EUR-Lex)](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A32016R0679)
- [GDPR — Article 17 Right to Erasure](https://gdpr-info.eu/art-17-gdpr/)
- [EDPB — Guidelines on GDPR and Databases](https://edpb.europa.eu/our-work-tools/our-documents_en)
- [CNIL (France DPA) — Technical Guidance](https://www.cnil.fr/en/home)

---

## LGPD — Lei Geral de Protecao de Dados (Brasil)

### Comparacao LGPD vs GDPR

| Aspecto | LGPD (Lei 13.709/2018) | GDPR |
|---------|------------------------|------|
| Autoridade | ANPD (Autoridade Nacional de Protecao de Dados) | EDPB + DPAs nacionais |
| Bases legais | 10 hipoteses (Art. 7) | 6 bases legais |
| DPO | Encarregado de Dados (obrigatorio para controladores) | DPO obrigatorio em alguns casos |
| Notificacao de incidente | "Em prazo razoavel" — regulamentacao em evolucao | 72 horas |
| Dados sensiveis | Saude, origem racial, crencas, biometria, dados de criancas | Categorias especiais (similares) |
| Penalidade maxima | 2% do faturamento (max R$ 50M por infracao) | 4% faturamento ou EUR 20M |

**Implementacao tecnica**: identica ao GDPR — mesmos controles de criptografia, acesso, auditoria e retencao.

### Categorias de Dados Sensiveis (Art. 11 LGPD)

```sql
-- Dados sensiveis requerem consentimento expresso ou base legal especifica
-- Identificar e marcar colunas com dados sensiveis no catalogo de dados

-- Exemplo de catalogo de dados sensiveis
CREATE TABLE data_catalog (
    table_schema    VARCHAR(100),
    table_name      VARCHAR(100),
    column_name     VARCHAR(100),
    data_category   VARCHAR(50),   -- 'SENSITIVE', 'PERSONAL', 'PUBLIC'
    lgpd_category   VARCHAR(100),  -- 'health', 'racial', 'biometric', etc.
    retention_days  INT,
    encryption      BOOLEAN,
    last_reviewed   DATE,
    owner           VARCHAR(100),
    PRIMARY KEY (table_schema, table_name, column_name)
);

INSERT INTO data_catalog VALUES
    ('app', 'patients', 'diagnosis_code', 'SENSITIVE', 'health', 2555, true, CURRENT_DATE, 'medical_team'),
    ('app', 'users', 'email', 'PERSONAL', 'contact', 1825, false, CURRENT_DATE, 'app_team'),
    ('app', 'users', 'cpf', 'SENSITIVE', 'government_id', 1825, true, CURRENT_DATE, 'compliance_team');
```

**Fontes LGPD**:
- [Lei 13.709/2018 — LGPD](https://www.planalto.gov.br/ccivil_03/_ato2015-2018/2018/lei/l13709.htm)
- [ANPD — Autoridade Nacional de Protecao de Dados](https://www.gov.br/anpd/)
- [ANPD — Guia Orientativo para Definicoes dos Agentes de Tratamento](https://www.gov.br/anpd/pt-br/documentos-e-publicacoes/guias-e-orientacoes)

---

## HIPAA — Health Insurance Portability and Accountability Act

### Safeguards Tecnicos (45 CFR § 164.312)

| Controle | Requisito | Implementacao em BD |
|----------|-----------|---------------------|
| Controle de Acesso (§164.312(a)(1)) | ID unico por usuario; MFA; controle baseado em funcao | Usuario individual por pessoa; RBAC; MFA obrigatorio para DBA |
| Controles de Auditoria (§164.312(b)) | Registrar e examinar atividade do sistema informatizado | Audit log com usuario, timestamp, operacao, dado acessado |
| Integridade (§164.312(c)(1)) | Proteger ePHI de alteracao/destruicao nao autorizada | Checksums, audit trail, controle de versao, imutabilidade |
| Autenticacao de Pessoa/Entidade (§164.312(d)) | Verificar identidade antes de acesso a ePHI | Autenticacao forte; certificados para aplicacoes |
| Seguranca na Transmissao (§164.312(e)(1)) | Criptografar ePHI em transito | TLS 1.2+ para todas as conexoes com ePHI |

### Implementacao de Audit Trail por Banco

```sql
-- ========== PostgreSQL com pgaudit ==========
-- /etc/postgresql/16/main/postgresql.conf
-- shared_preload_libraries = 'pgaudit'
-- pgaudit.log = 'read,write,ddl'
-- pgaudit.log_catalog = on
-- pgaudit.log_relation = on
-- pgaudit.log_statement_once = off
-- pgaudit.role = 'auditor'

-- Auditar acesso especifico a tabelas de saude
SET pgaudit.log = 'all';
SELECT * FROM patient_records WHERE patient_id = 12345;
-- Log gerado: AUDIT: SESSION,1,1,READ,SELECT,TABLE,app.patient_records,...

-- Query para auditoria de acesso a ePHI
SELECT log_time, user_name, database_name, command_tag, object_name, statement
FROM pg_catalog.pg_log  -- ou tabela de audit configurada
WHERE object_name IN ('patient_records', 'medical_history', 'prescriptions', 'diagnoses')
  AND log_time > now() - INTERVAL '30 days'
ORDER BY log_time DESC;

-- ========== MySQL com General Query Log ou Audit Plugin ==========
-- Habilitar Audit Plugin (MySQL Enterprise)
INSTALL PLUGIN audit_log SONAME 'audit_log.so';

-- my.cnf
-- audit_log_policy = ALL
-- audit_log_format = JSON
-- audit_log_file = /var/log/mysql/audit.log
-- audit_log_rotate_on_size = 100M
-- audit_log_rotations = 10

-- Verificar eventos de acesso a tabelas ePHI
SELECT
    TIMESTAMP,
    USER,
    HOST,
    EVENT,
    DATABASE_,
    QUERY
FROM mysql_audit_log_v
WHERE DATABASE_ = 'healthcare'
  AND TABLE_ IN ('patient_records', 'prescriptions')
ORDER BY TIMESTAMP DESC;

-- ========== SQL Server com SQL Server Audit ==========
-- Criar Server Audit (logs imutaveis no arquivo)
CREATE SERVER AUDIT [HIPAA_Audit]
    TO FILE (
        FILEPATH = N'/var/log/sqlserver/audit/',
        MAXSIZE = 1 GB,
        MAX_ROLLOVER_FILES = 365,
        RESERVE_DISK_SPACE = ON
    )
    WITH (
        QUEUE_DELAY = 1000,       -- 1 segundo (nao-sincrono para performance)
        ON_FAILURE = CONTINUE     -- continuar operacao mesmo se log cheio
    );
ALTER SERVER AUDIT [HIPAA_Audit] WITH (STATE = ON);

-- Criar Database Audit Specification para tabelas de ePHI
USE [HealthcareDB];
CREATE DATABASE AUDIT SPECIFICATION [HIPAA_PHI_Audit]
FOR SERVER AUDIT [HIPAA_Audit]
    ADD (SELECT, INSERT, UPDATE, DELETE ON dbo.patient_records BY PUBLIC),
    ADD (SELECT, INSERT, UPDATE, DELETE ON dbo.medical_history BY PUBLIC),
    ADD (SELECT, INSERT, UPDATE, DELETE ON dbo.prescriptions BY PUBLIC),
    ADD (SCHEMA_OBJECT_ACCESS_GROUP)
WITH (STATE = ON);

-- Consultar logs de audit
SELECT
    event_time,
    server_principal_name,
    database_name,
    object_name,
    statement,
    action_id,
    succeeded
FROM sys.fn_get_audit_file('/var/log/sqlserver/audit/*.sqlaudit', DEFAULT, DEFAULT)
WHERE object_name IN ('patient_records', 'medical_history', 'prescriptions')
ORDER BY event_time DESC;

-- ========== Oracle com Unified Auditing ==========
-- Criar politica de audit HIPAA
CREATE AUDIT POLICY hipaa_phi_policy
    ACTIONS SELECT, INSERT, UPDATE, DELETE
    ON healthcare.patient_records,
    ON healthcare.medical_history,
    ON healthcare.prescriptions
    WHEN 'SYS_CONTEXT(''USERENV'',''SESSION_USER'') != ''SYS'''
    EVALUATE PER SESSION;

-- Habilitar politica
AUDIT POLICY hipaa_phi_policy;

-- Consultar audit trail
SELECT
    EVENT_TIMESTAMP,
    DBUSERNAME,
    OS_USERNAME,
    ACTION_NAME,
    OBJECT_NAME,
    SQL_TEXT
FROM UNIFIED_AUDIT_TRAIL
WHERE OBJECT_NAME IN ('PATIENT_RECORDS', 'MEDICAL_HISTORY', 'PRESCRIPTIONS')
ORDER BY EVENT_TIMESTAMP DESC
FETCH FIRST 100 ROWS ONLY;
```

### Retencao de Dados HIPAA

| Tipo de Dado | Retencao Obrigatoria | Notas |
|-------------|---------------------|-------|
| Audit logs de acesso a ePHI | **6 anos** apos criacao ou ultima data de uso | Imutavel, WORM |
| Registros medicos (adultos) | 6-10 anos (varia por estado nos EUA) | Verificar legislacao local |
| Registros medicos (menores) | Ate 3 anos apos atingir maioridade | |
| Politicas e procedimentos | **6 anos** | |
| Analise de risco documentada | **6 anos** | |
| Documentacao de treinamento | **6 anos** | |

### Notificacao de Breach HIPAA (45 CFR § 164.400-414)

```
Cronograma de notificacao:
- Indivíduos afetados: ate 60 dias apos descoberta
- HHS (Dept. de Saude dos EUA): ate 60 dias
- Midia (se > 500 pessoas no mesmo estado): ate 60 dias
- HHS anual (breaches < 500 pessoas): 60 dias apos fim do ano calendario
```

**Fontes HIPAA**:
- [HHS — HIPAA Security Rule](https://www.hhs.gov/hipaa/for-professionals/security/index.html)
- [45 CFR § 164.312 — Technical Safeguards](https://www.law.cornell.edu/cfr/text/45/164.312)
- [HHS — Guidance on Risk Analysis Requirements](https://www.hhs.gov/hipaa/for-professionals/security/guidance/index.html)
- [NIST HIPAA Security Rule Toolkit](https://csrc.nist.gov/Projects/hipaa)

---

## SOX — Sarbanes-Oxley Act

> **Por que SOX exige audit trail imutavel no banco, nao apenas logs de aplicacao?**
> Logs de aplicacao podem ser alterados por qualquer desenvolvedor com acesso ao servidor. Um audit trail na tabela do banco com regra `NO UPDATE/DELETE` e mais difcil de adulterar — requer acesso direto de DBA E bypassar as triggers/rules. Para maxima imutabilidade, combinar:
> 1. Trigger/rule no banco (primeira linha de defesa)
> 2. Logs enviados para SIEM externo em tempo real (segunda linha — mesmo que o banco seja comprometido, os logs ja saíram)
> 3. Storage WORM para logs arquivados (terceira linha — imutabilidade fisica)
>
> **Por que segregacao de funcoes e critica para SOX?**
> O SOX Section 404 exige que nenhuma pessoa tenha controle total sobre um processo financeiro. Se o mesmo DBA pode alterar dados E aprovar mudancas E auditar o acesso, e possivel cobrir um fraude. A segregacao garante que fraude exija conluio de multiplas pessoas — drasticamente mais dificil.

### Secao 404 — Controles Internos sobre Relatorios Financeiros

Todo acesso e modificacao de dados financeiros DEVE ser registrado com:
- Identidade do usuario (usuario unico, nao compartilhado)
- Timestamp preciso (sincronizacao NTP obrigatoria em todos os servidores)
- Tipo de operacao (INSERT, UPDATE, DELETE)
- Valores anteriores e posteriores (before/after values)
- Aplicacao/sistema de origem (nome e versao)
- Hash/checksum do registro de audit (para prova de nao-adulteracao)

### Implementacao de Audit Trail Imutavel por Banco

```sql
-- ========== PostgreSQL — Tabela append-only com trigger ==========
CREATE TABLE financial_audit_log (
    audit_id        BIGSERIAL PRIMARY KEY,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_name       TEXT NOT NULL DEFAULT current_user,
    application     TEXT NOT NULL DEFAULT current_setting('application_name'),
    client_addr     INET DEFAULT inet_client_addr(),
    table_name      TEXT NOT NULL,
    operation       TEXT NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    record_id       TEXT NOT NULL,
    old_values      JSONB,
    new_values      JSONB,
    row_hash        TEXT GENERATED ALWAYS AS (
        MD5(COALESCE(old_values::text,'') || COALESCE(new_values::text,''))
    ) STORED
);

-- Regras para tornar o audit log imutavel
CREATE RULE no_update_audit AS ON UPDATE TO financial_audit_log DO INSTEAD NOTHING;
CREATE RULE no_delete_audit AS ON DELETE TO financial_audit_log DO INSTEAD NOTHING;

-- Trigger para capturar mudancas na tabela financeira
CREATE OR REPLACE FUNCTION financial_audit_trigger() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO financial_audit_log (table_name, operation, record_id, new_values)
        VALUES (TG_TABLE_NAME, TG_OP, NEW.id::text, row_to_json(NEW)::jsonb);
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO financial_audit_log (table_name, operation, record_id, old_values, new_values)
        VALUES (TG_TABLE_NAME, TG_OP, NEW.id::text, row_to_json(OLD)::jsonb, row_to_json(NEW)::jsonb);
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO financial_audit_log (table_name, operation, record_id, old_values)
        VALUES (TG_TABLE_NAME, TG_OP, OLD.id::text, row_to_json(OLD)::jsonb);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER financial_audit
    AFTER INSERT OR UPDATE OR DELETE ON journal_entries
    FOR EACH ROW EXECUTE FUNCTION financial_audit_trigger();

-- ========== SQL Server — Temporal Tables (audit nativo) ==========
-- Temporal Tables manteem historico completo de todas as mudancas
CREATE TABLE journal_entries (
    entry_id        INT PRIMARY KEY,
    account_code    CHAR(10) NOT NULL,
    debit_amount    DECIMAL(18,2),
    credit_amount   DECIMAL(18,2),
    description     NVARCHAR(500),
    created_by      NVARCHAR(100) DEFAULT SYSTEM_USER,
    valid_from      DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    valid_to        DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (valid_from, valid_to)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.journal_entries_history));

-- Consultar historico de mudancas
SELECT * FROM journal_entries
FOR SYSTEM_TIME BETWEEN '2024-01-01' AND '2024-12-31'
WHERE entry_id = 12345
ORDER BY valid_from;

-- ========== Oracle — Fine-Grained Auditing (FGA) ==========
-- Auditar mudancas em tabelas financeiras com valores before/after
BEGIN
    DBMS_FGA.ADD_POLICY(
        object_schema   => 'FINANCE',
        object_name     => 'JOURNAL_ENTRIES',
        policy_name     => 'SOX_JOURNAL_AUDIT',
        audit_column    => 'DEBIT_AMOUNT,CREDIT_AMOUNT,ACCOUNT_CODE',
        enable          => TRUE,
        statement_types => 'INSERT,UPDATE,DELETE'
    );
END;
/

-- ========== MySQL — Triggers para audit SOX ==========
DELIMITER //
CREATE TRIGGER journal_audit_after_update
AFTER UPDATE ON journal_entries
FOR EACH ROW
BEGIN
    INSERT INTO financial_audit_log (
        occurred_at, user_name, table_name, operation,
        record_id, old_debit, old_credit, new_debit, new_credit
    ) VALUES (
        NOW(), USER(), 'journal_entries', 'UPDATE',
        NEW.entry_id,
        OLD.debit_amount, OLD.credit_amount,
        NEW.debit_amount, NEW.credit_amount
    );
END//
DELIMITER ;

-- ========== Redis — para dados financeiros em cache ==========
-- Redis nao e adequado como banco primario de dados SOX
-- Se usado como cache de dados financeiros:
-- 1. Todos os writes devem passar pelo banco relacional com audit
-- 2. TTL obrigatorio em todos os dados financeiros em cache
-- 3. Audit log no banco relacional, nao no Redis
```

### Retencao de Dados Financeiros (SOX)

| Tipo de Dado | Retencao | Acesso Imediato |
|-------------|---------|-----------------|
| Registros financeiros (balancetes, DREs) | **7 anos** | 2 primeiros anos |
| Audit logs de acesso | **7 anos** | 2 primeiros anos |
| Contratos e acordos | 7 anos apos expiracao | Conforme necessario |
| Emails com dados financeiros | **7 anos** | 2 primeiros anos |
| Registros de patches e mudancas | **7 anos** | 3 primeiros anos |

### Segregacao de Funcoes (Separation of Duties — SOD)

```
Controles obrigatorios de SOD para ambientes SOX:

DBA de Producao:
  - PODE: executar scripts aprovados, monitorar performance, restaurar backups
  - NAO PODE: aprovar suas proprias mudancas, criar usuarios privilegiados sem aprovacao
  - NAO PODE: acessar dados financeiros em producao sem requisicao formal

Desenvolvedor:
  - PODE: acesso COMPLETO em dev/qa (incluindo dados mascarados)
  - NAO PODE: acesso direto a banco de producao
  - NAO PODE: executar migrations em producao (pipeline automatizado ou DBA)

Auditoria:
  - PODE: leitura de todos os audit logs (acesso independente, nao gerenciado pelo DBA)
  - NAO PODE: modificar ou deletar logs
  - NAO PODE: modificar dados

Change Manager:
  - PODE: aprovar mudancas em producao
  - NAO PODE: implementar as mudancas que aprova

Usuario de Aplicacao (service account):
  - PODE: apenas operacoes necessarias para a aplicacao (CRUD nas tabelas necessarias)
  - NAO PODE: DDL (CREATE, ALTER, DROP), acesso a outras schemas
```

**Fontes SOX**:
- [Sarbanes-Oxley Act — Section 404](https://www.soxlaw.com/s404.htm)
- [PCAOB — Auditing Standard No. 5](https://pcaobus.org/Standards/Auditing/Pages/Auditing_Standard_5.aspx)
- [ISACA — COBIT 2019 for SOX Compliance](https://www.isaca.org/resources/cobit)
- [AICPA — SOC 2 Type II Controls](https://www.aicpa.org/interestareas/frc/assuranceadvisoryservices/aicpasoc2report.html)

---

## PCI DSS — Payment Card Industry Data Security Standard

### Dados de Portador de Cartao (CHD) — O que Armazenar

| Dado | Pode Armazenar? | Requisito se Armazenar |
|------|----------------|------------------------|
| PAN (numero completo do cartao) | SIM (se necessario) | Mascarar na exibicao; criptografar; controle de acesso estrito |
| Nome do portador | SIM | Controle de acesso |
| Data de expiracao | SIM | Controle de acesso |
| CVV/CVC/CAV2 | **NUNCA** (mesmo criptografado) | Proibido por PCI DSS |
| PIN / PIN Block | **NUNCA** | Proibido por PCI DSS |
| Dados da trilha magnetica / chip | **NUNCA** | Proibido por PCI DSS |
| Numero de conta de servico | SIM (se necessario) | Mesmos controles do PAN |

### Implementacao dos Requisitos PCI DSS por Banco

```sql
-- ========== Requisito 3: Proteger CHD Armazenado ==========

-- PostgreSQL — criptografia de PAN com pgcrypto
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE payment_cards (
    card_id         BIGSERIAL PRIMARY KEY,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id),
    pan_encrypted   TEXT NOT NULL,           -- PAN criptografado
    pan_last4       CHAR(4) NOT NULL,        -- para exibicao na UI
    pan_hash        TEXT NOT NULL,           -- para busca sem descriptografar
    cardholder_name TEXT NOT NULL,
    expiry_month    SMALLINT NOT NULL,
    expiry_year     SMALLINT NOT NULL,
    card_brand      VARCHAR(20),
    created_at      TIMESTAMPTZ DEFAULT now()
);

-- Inserir card com PAN criptografado
INSERT INTO payment_cards (customer_id, pan_encrypted, pan_last4, pan_hash, cardholder_name, expiry_month, expiry_year)
VALUES (
    123,
    pgp_sym_encrypt('4111111111111111', :pci_encryption_key),  -- key de um KMS externo
    '1111',
    crypt('4111111111111111', gen_salt('bf', 12)),              -- hash para busca
    'JOAO SILVA',
    12, 2028
);

-- Buscar por PAN (sem descriptografar — usando hash)
SELECT card_id, pan_last4, cardholder_name, card_brand
FROM payment_cards
WHERE pan_hash = crypt(:pan_input, pan_hash)
  AND customer_id = :customer_id;

-- Exibir PAN mascarado (apenas ultimos 4 digitos)
SELECT
    card_id,
    cardholder_name,
    REPEAT('*', 12) || pan_last4 AS masked_pan,
    expiry_month || '/' || expiry_year AS expiry
FROM payment_cards
WHERE customer_id = :customer_id;

-- ========== SQL Server — Mascaramento de PAN ==========
-- Dynamic Data Masking para exibicao (nao criptografa — apenas mascara na exibicao)
ALTER TABLE payment_cards
    ALTER COLUMN pan ADD MASKED WITH (FUNCTION = 'partial(0,"XXXX-XXXX-XXXX-",4)');

-- Usuarios sem permissao veem: XXXX-XXXX-XXXX-1234
-- Usuarios com UNMASK permission veem o dado real
GRANT UNMASK ON payment_cards TO [pci_dss_approved_user];

-- ========== Oracle — Virtual Private Database (VPD) para PCI DSS ==========
-- Aplicar politica de acesso ao nivel do banco (nenhuma aplicacao burla)
CREATE OR REPLACE FUNCTION pci_access_policy(
    schema_name IN VARCHAR2,
    table_name  IN VARCHAR2
) RETURN VARCHAR2 AS
BEGIN
    -- Apenas aplicacoes com papel 'PAYMENT_SERVICE' podem ver o PAN completo
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') = 'PAYMENT_SERVICE_USER' THEN
        RETURN NULL;  -- sem restricao
    ELSE
        -- Outros usuarios veem PAN mascarado
        RETURN '1=0';  -- nao retorna nenhuma linha com PAN descriptografado
    END IF;
END;
/

DBMS_RLS.ADD_POLICY(
    object_schema   => 'PAYMENTS',
    object_name     => 'PAYMENT_CARDS',
    policy_name     => 'PCI_PAN_ACCESS',
    function_schema => 'PAYMENTS',
    policy_function => 'PCI_ACCESS_POLICY'
);

-- ========== MySQL — Controles de Acesso PCI ==========
-- Criar usuario com acesso minimo para servico de pagamento
CREATE USER 'payment_service'@'10.0.0.%'
    IDENTIFIED WITH caching_sha2_password BY 'PciServicePass@123!'
    REQUIRE X509  -- exige certificado TLS
    WITH MAX_QUERIES_PER_HOUR 10000;

-- Apenas permissoes necessarias (principle of least privilege)
REVOKE ALL ON payments.* FROM 'payment_service'@'10.0.0.%';
GRANT SELECT, INSERT ON payments.transactions TO 'payment_service'@'10.0.0.%';
GRANT SELECT ON payments.payment_cards TO 'payment_service'@'10.0.0.%';
-- Nao pode: UPDATE/DELETE payment_cards, acesso a outras tables

-- Redis — NAO armazenar PAN no Redis
-- Se dados de sessao de pagamento forem necessarios no Redis:
-- 1. Usar token de sessao (nao o PAN real)
-- 2. TTL obrigatorio e curto (ex: 15 minutos)
-- 3. Dados sensíveis de pagamento ficam no banco relacional

-- Configurar TTL obrigatorio para tokens de pagamento
SET payment:session:TOKEN123 "session_data_sem_pan"
EXPIRE payment:session:TOKEN123 900  -- 15 minutos
```

### Requisito 10 — Logs de Auditoria PCI DSS

```sql
-- Requisito 10.2: Auditar eventos especificos do PCI DSS
-- 10.2.1: Acesso individual ao CHD
-- 10.2.2: Acoes do root/admin
-- 10.2.3: Acesso a audit trails
-- 10.2.4: Tentativas invalidas de acesso logico
-- 10.2.5: Uso de mecanismos de identificacao e autenticacao
-- 10.2.6: Inicializacao/parada/pausada dos audit logs
-- 10.2.7: Criacao/exclusao de objetos no CDE

-- PostgreSQL — logar tentativas de acesso a CHD
ALTER SYSTEM SET log_connections = ON;
ALTER SYSTEM SET log_disconnections = ON;
ALTER SYSTEM SET log_failed_connections = ON;
ALTER SYSTEM SET pgaudit.log = 'read,write,ddl,role';
```

### Checklist PCI DSS para DBAs

- [ ] CVV/CVC **nunca** armazenado (verificar com `grep` em toda base de codigo e dumps)
- [ ] PAN criptografado com AES-128 ou AES-256 em repouso
- [ ] PAN mascarado na exibicao (mostrar apenas ultimos 4 ou primeiros 6 digitos)
- [ ] Acesso ao PAN descriptografado limitado a necessidade estrita de negocio
- [ ] Logs de acesso ao CHD retidos por minimo 1 ano (3 meses imediatamente acessiveis)
- [ ] Scan de vulnerabilidades trimestral (ASV aprovado pela PCI SSC)
- [ ] Pen-test anual no CDE
- [ ] Todos os servidores do CDE com NTP sincronizado (Requisito 10.6)
- [ ] Segmentacao de rede do CDE verificada anualmente
- [ ] Inventario de todos os componentes do CDE documentado e atualizado

**Fontes PCI DSS**:
- [PCI DSS v4.0 Requirements](https://www.pcisecuritystandards.org/document_library/)
- [PCI DSS v4.0 — Requirement 3: Protect Stored CHD](https://www.pcisecuritystandards.org/document_library/)
- [PCI SSC — Guidance for Tokenization](https://www.pcisecuritystandards.org/documents/Tokenization_Product_Security_Guidelines.pdf)
- [SANS — PCI DSS Database Security Considerations](https://www.sans.org/reading-room/whitepapers/pci/)

---

## Controles Tecnicos Comuns (todos os frameworks)

| Controle | GDPR | LGPD | HIPAA | SOX | PCI DSS |
|----------|:----:|:----:|:-----:|:---:|:-------:|
| Criptografia em repouso (AES-256) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Criptografia em transito (TLS 1.2+) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Controle de acesso RBAC | ✓ | ✓ | ✓ | ✓ | ✓ |
| Usuario individual (nao compartilhado) | ✓ | ✓ | ✓ | ✓ | ✓ |
| MFA para acesso privilegiado | ✓ | ✓ | ✓ | ✓ | ✓ |
| Audit logging completo | ✓ | ✓ | ✓ | ✓ | ✓ |
| Retencao de logs >= 1 ano | ✓ | ✓ | ✓ | ✓ | ✓ |
| Retencao de logs >= 6 anos | | | ✓ | | |
| Retencao de logs >= 7 anos | | | | ✓ | |
| Segregacao de funcoes | | | ✓ | ✓ | ✓ |
| Patch management formal | ✓ | ✓ | ✓ | ✓ | ✓ |
| Testes de penetracao anuais | | | | ✓ | ✓ |
| Analise de risco documentada | ✓ | ✓ | ✓ | ✓ | ✓ |
| Mascaramento de dados sensiveis | ✓ | ✓ | ✓ | | ✓ |
| Imutabilidade dos audit logs | | | ✓ | ✓ | ✓ |
| Notificacao de breach < 72h | ✓ | | | | |
| Notificacao de breach < 60 dias | | | ✓ | | |
| Inventario de dados sensiveis | ✓ | ✓ | ✓ | ✓ | ✓ |
| DPO / Encarregado de Dados | ✓ | ✓ | | | |

---

## Implementacao Pratica — Priorizacao para Organizacoes Sem Compliance

Para organizacoes iniciando o processo de compliance, implementar nesta ordem:

1. **Inventario de dados sensiveis** — saber o que voce tem antes de proteger
   - Catalogar todos os bancos com dados pessoais, financeiros, de saude
   - Classificar por tipo e framework aplicavel (LGPD/GDPR, HIPAA, SOX, PCI)

2. **Controle de acesso basico** — usuarios individuais, least privilege
   - Eliminar usuarios compartilhados (ex: "user_app" para 5 desenvolvedores)
   - Eliminar senhas de banco em variaveis de ambiente de producao

3. **Criptografia** — TDE para dados em repouso, TLS para transito
   - Habilitar TDE no banco (Oracle, SQL Server, MySQL Enterprise, PostgreSQL com pgcrypto)
   - Exigir TLS 1.2+ em todas as conexoes (incluindo aplicacoes e ferramentas de DBA)

4. **Audit logging** — habilitar e centralizar logs de todos os bancos em producao
   - Definir quais operacoes logar (DDL obrigatorio; DML em tabelas sensiveis)
   - Enviar logs para SIEM externo (imutabilidade)

5. **Politica de retencao** — definir TTL para cada tipo de dado e implementar automacao

6. **Plano de resposta a incidentes** — inclui notificacao dentro dos prazos legais

7. **Documentacao** — ROPA (GDPR/LGPD), analise de risco (SOX/HIPAA), DPAs

**Fontes Gerais de Compliance**:
- [ISO/IEC 27001:2022 — Information Security Management](https://www.iso.org/standard/27001)
- [NIST SP 800-53 Rev 5 — Security and Privacy Controls](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
- [ISACA COBIT 2019 — DSS06 Manage Business Process Controls](https://www.isaca.org/resources/cobit)
- [OWASP — Database Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Database_Security_Cheat_Sheet.html)
