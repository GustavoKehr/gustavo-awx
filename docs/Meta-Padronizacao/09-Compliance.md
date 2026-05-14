# 09 — Compliance e Regulamentacoes

## Visao Geral

| Regulamentacao | Jurisdicao / Setor | Foco Principal | Penalidade Maxima |
|----------------|-------------------|----------------|-------------------|
| **GDPR** | Uniao Europeia / global (dados de cidadaos EU) | Privacidade de dados pessoais | 4% do faturamento global ou EUR 20M |
| **LGPD** | Brasil | Privacidade de dados pessoais | 2% do faturamento (max R$ 50M por infração) |
| **HIPAA** | EUA — setor de saude | Dados de saude (PHI/ePHI) | USD 100 a USD 50.000 por violacao |
| **SOX** | EUA — empresas publicas | Integridade de dados financeiros | Prisao + multas para executivos |
| **PCI DSS** | Global — pagamentos com cartao | Dados de cartao de credito | Suspensao do direito de processar pagamentos |

---

## GDPR — General Data Protection Regulation

### Impacto em Bancos de Dados

**Principios do GDPR com impacto direto no BD**:

| Principio | Requisito de BD |
|-----------|----------------|
| Minimizacao de dados | Coletar e armazenar apenas dados estritamente necessarios |
| Limitacao de finalidade | Dados usados somente para a finalidade declarada |
| Limitacao de armazenamento | Definir e implementar TTL/politica de retencao por tipo de dado |
| Integridade e confidencialidade | Criptografia, controle de acesso, auditoria |
| Responsabilidade | Capacidade de demonstrar conformidade (audit logs) |

### Requisitos Tecnicos para Bancos de Dados

```
1. Criptografia em repouso: AES-256 minimo (TDE)
2. Criptografia em transito: TLS 1.2+
3. Controle de acesso: RBAC granular, princípio de menor privilegio
4. Auditoria: logs completos de acesso e modificacao de dados pessoais
5. Residencia de dados: dados de cidadaos EU armazenados dentro da EU (ou pais com nivel adequado)
```

### Direito ao Esquecimento (Right to Erasure)
```sql
-- Identificar todos os dados pessoais de um titular
SELECT table_name, column_name FROM information_schema.columns
WHERE column_name IN ('cpf', 'email', 'phone', 'ip_address', 'user_id');

-- Deletar ou anonimizar dados do titular
-- DELETAR: apenas se nao ha obrigacao legal de retencao
DELETE FROM user_profiles WHERE user_id = :user_id;

-- ANONIMIZAR: quando dados precisam ser mantidos para agregacoes
UPDATE user_profiles SET
    name = 'ANONYMIZED',
    email = CONCAT('anon_', user_id, '@deleted.local'),
    cpf = NULL,
    phone = NULL
WHERE user_id = :user_id;

-- Prazo: solicitacao deve ser atendida em ate 30 dias
```

### Portabilidade de Dados
```sql
-- Exportar todos os dados do titular em formato estruturado (JSON/CSV)
SELECT row_to_json(t) FROM (
    SELECT up.*, o.*, a.*
    FROM user_profiles up
    LEFT JOIN orders o ON o.user_id = up.user_id
    LEFT JOIN addresses a ON a.user_id = up.user_id
    WHERE up.user_id = :user_id
) t;
```

### Data Processing Agreement (DPA)
- Obrigatorio com todos os fornecedores que processam dados pessoais (incluindo cloud providers, SaaS de monitoramento, etc.)
- Verificar DPAs de: AWS, Azure, GCP, fornecedores de backup, ferramenta de monitoring

### Registro de Atividades de Tratamento (ROPA)
Manter registro documentando para cada banco:
- Quais dados pessoais sao armazenados
- Finalidade do tratamento
- Base legal (consentimento, contrato, obrigacao legal, etc.)
- Tempo de retencao
- Terceiros que recebem os dados

---

## LGPD — Lei Geral de Protecao de Dados (Brasil)

Estrutura similar ao GDPR com adaptacoes brasileiras:

| Aspecto | LGPD | GDPR |
|---------|------|------|
| Autoridade regulatoria | ANPD (Autoridade Nacional de Protecao de Dados) | EDPB / DPAs nacionais |
| Bases legais | 10 hipoteses (inclui consentimento, contrato, obrigacao legal, interesse legitimo...) | 6 bases legais |
| DPO | Encarregado de Dados (obrigatorio para algumas organizacoes) | DPO (obrigatorio em alguns casos) |
| Notificacao de incidente | Em prazo razoavel (regulamentacao em evolucao) | 72 horas |

**Requisitos tecnicos identicos ao GDPR** — implementar as mesmas controles.

---

## HIPAA — Health Insurance Portability and Accountability Act

### Safeguards Tecnicos (Technical Safeguards) — 45 CFR § 164.312

| Controle | Requisito | Implementacao em BD |
|----------|-----------|---------------------|
| Controle de Acesso | Identificacao e autenticacao unicas | Usuario unico por pessoa; MFA obrigatorio |
| Controles de Auditoria | Gravar e examinar atividade do sistema | Audit log com usuario, timestamp, acao, dado acessado |
| Integridade | Proteger ePHI de alteracao nao autorizada | Checksums, audit trail, controle de versao |
| Transmissao Segura | Criptografar ePHI em transito | TLS 1.2+ para todas as conexoes |

### Safeguards Administrativos

| Controle | Periodo de Retencao |
|----------|---------------------|
| Audit logs de acesso a ePHI | 6 anos apos criacao ou ultima data de uso |
| Politicas e procedimentos | 6 anos |
| Documentacao de treinamento | 6 anos |
| Analise de risco | 6 anos |

### Requisitos Especificos de BD
```sql
-- PostgreSQL: habilitar auditoria de acesso a tabelas com ePHI
-- Usando pgaudit:
ALTER SYSTEM SET pgaudit.log = 'read,write,ddl';
ALTER SYSTEM SET pgaudit.log_catalog = on;
SELECT pg_reload_conf();

-- Monitorar: quem acessou dados de pacientes
SELECT log_time, user_name, database_name, command_tag, object_name
FROM pgaudit_log
WHERE object_name IN ('patient_records', 'medical_history', 'prescriptions')
AND log_time > now() - interval '24 hours';
```

### Notificacao de Breach
- Notificar indivíduos afetados: ate 60 dias apos descoberta
- Notificar HHS (Dept. de Saude dos EUA): ate 60 dias
- Notificar midia (se > 500 pessoas no mesmo estado): ate 60 dias
- Breaches < 500 pessoas: notificar HHS anualmente

---

## SOX — Sarbanes-Oxley Act

### Secao 404 — Controles Internos sobre Relatorios Financeiros

Impacto em bancos de dados financeiros:

**Requisitos de Audit Trail (Secao 404)**:
```
Todo acesso e modificacao de dados financeiros DEVE ser registrado com:
- Identidade do usuario (usuario unico, nao compartilhado)
- Timestamp preciso (sincronizacao NTP obrigatoria)
- Tipo de operacao (INSERT, UPDATE, DELETE)
- Valores anteriores e posteriores (before/after)
- Aplicacao/sistema de origem
- Hash/checksum do registro de audit
```

**Imutabilidade dos Audit Logs**:
```sql
-- Os logs nao podem ser alterados ou deletados por ninguem
-- Opcoes de implementacao:
-- 1. Tabela append-only com trigger que proibe UPDATE/DELETE
-- 2. Armazenar logs em storage WORM (Write-Once-Read-Many)
-- 3. Enviar logs para sistema de logging centralizado imutavel

-- Exemplo PostgreSQL: tabela de audit imutavel
CREATE TABLE financial_audit_log (
    id BIGSERIAL PRIMARY KEY,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_name TEXT NOT NULL,
    table_name TEXT NOT NULL,
    operation TEXT NOT NULL,
    old_values JSONB,
    new_values JSONB,
    application_name TEXT,
    client_addr INET
);

-- Trigger que previne modificacao
CREATE RULE no_update_audit AS ON UPDATE TO financial_audit_log DO INSTEAD NOTHING;
CREATE RULE no_delete_audit AS ON DELETE TO financial_audit_log DO INSTEAD NOTHING;
```

### Retencao de Dados Financeiros
| Tipo de Dado | Retencao Obrigatoria | Acesso Rapido |
|-------------|---------------------|---------------|
| Registros financeiros | 7 anos | 2 primeiros anos |
| Audit logs de acesso | 7 anos | 2 primeiros anos |
| Contratos e acordos | 7 anos apos expiracao | Conforme necessario |
| Emails com dados financeiros | 7 anos | 2 primeiros anos |

### Segregacao de Funcoes (Separation of Duties)
```
- DBA nao pode aprovar mudancas em producao (apenas implementar com aprovacao do DBO/Change Manager)
- Usuario de aplicacao nao pode criar/alterar schema
- Desenvolvedor nao tem acesso a dados de producao sem processo formal
- Auditoria tem acesso de leitura independente, nao gerenciado pelo DBA
```

---

## PCI DSS — Payment Card Industry Data Security Standard

### Dados de Portador de Cartao (CHD) — O que NAO Armazenar

| Dado | Pode Armazenar? | Observacao |
|------|----------------|------------|
| PAN (numero do cartao) | SIM (se necessario) | Deve ser mascarado na exibicao e criptografado |
| Nome do portador | SIM | |
| Data de expiracao | SIM | |
| CVV/CVC | **NUNCA** | Proibido por PCI DSS |
| PIN | **NUNCA** | Proibido por PCI DSS |
| Dados da trilha magnetica | **NUNCA** | Proibido por PCI DSS |

### Requisitos Tecnicos de BD

**Requisito 3 — Protecao de Dados Armazenados**:
```sql
-- Mascarar PAN na exibicao (mostrar apenas ultimos 4 digitos)
SELECT
    customer_name,
    REPEAT('*', LENGTH(pan) - 4) || RIGHT(pan, 4) AS masked_pan
FROM payment_cards;

-- Criptografia de coluna para PAN
-- PostgreSQL com pgcrypto:
INSERT INTO payment_cards (pan_encrypted)
VALUES (pgp_sym_encrypt('4111111111111111', :encryption_key));

SELECT pgp_sym_decrypt(pan_encrypted::bytea, :encryption_key) AS pan
FROM payment_cards;
```

**Requisito 7 — Restricao de Acesso**:
```sql
-- Apenas sistema de pagamento acessa tabelas com CHD
REVOKE ALL ON payment_cards FROM PUBLIC;
GRANT SELECT, INSERT ON payment_cards TO payment_service;
-- Nenhum usuario humano deve ter acesso direto a PAN descriptografado
```

**Requisito 10 — Auditoria**:
- Logar todo acesso a dados de portador de cartao
- Reter logs por minimo 1 ano (3 meses imediatamente acessiveis)
- Sincronizar tempo em todos os sistemas (NTP)

**Requisito 11 — Testes de Seguranca**:
- Scan de vulnerabilidades trimestral
- Pen-test anual (ou apos mudancas significativas)
- Verificacao de deteccao de intrusao (IDS/IPS)

### Escopo do CDE (Cardholder Data Environment)
- Identificar todos os bancos de dados que armazenam, processam ou transmitem CHD
- Segmentar CDE do restante da rede (network segmentation reduz escopo)
- Auditar todos os fluxos de dados de cartao

---

## Controles Tecnicos Comuns (todos os frameworks)

| Controle | GDPR | LGPD | HIPAA | SOX | PCI DSS |
|----------|:----:|:----:|:-----:|:---:|:-------:|
| Criptografia em repouso | ✓ | ✓ | ✓ | ✓ | ✓ |
| Criptografia em transito | ✓ | ✓ | ✓ | ✓ | ✓ |
| Controle de acesso (RBAC) | ✓ | ✓ | ✓ | ✓ | ✓ |
| MFA para acesso privilegiado | ✓ | ✓ | ✓ | ✓ | ✓ |
| Audit logging completo | ✓ | ✓ | ✓ | ✓ | ✓ |
| Retencao de logs >= 1 ano | ✓ | ✓ | ✓ | ✓ | ✓ |
| Retencao de logs >= 7 anos | | | | ✓ | |
| Segregacao de funcoes | | | ✓ | ✓ | ✓ |
| Patch management formal | ✓ | ✓ | ✓ | ✓ | ✓ |
| Testes de penetracao anuais | | | | ✓ | ✓ |
| Analise de risco documentada | ✓ | ✓ | ✓ | ✓ | ✓ |
| Mascaramento de dados sensiveis | ✓ | ✓ | ✓ | | ✓ |
| Notificacao de breach < 72h | ✓ | | | | |
| Notificacao de breach < 60 dias | | | ✓ | | |

---

## Implementacao Pratica — Priorizacao

Para organizacoes sem compliance formal implementado, priorizar nesta ordem:

1. **Inventario de dados sensiveis** — saber o que voce tem antes de proteger
2. **Controle de acesso basico** — usuarios individuais, least privilege, sem compartilhamento
3. **Criptografia de dados sensiveis** — TDE para dados em repouso, TLS para transito
4. **Audit logging** — habilitar e centralizar logs de todos os bancos em producao
5. **Politica de retencao** — definir TTL para cada tipo de dado
6. **Plano de resposta a incidentes** — inclui notificacao dentro dos prazos legais
7. **Documentacao** — ROPA (GDPR/LGPD), analise de risco (SOX/HIPAA), DPAs
