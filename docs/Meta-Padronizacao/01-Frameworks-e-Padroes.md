# 01 — Frameworks e Padroes de Referencia

## CIS Benchmarks (Center for Internet Security)

**O que e**: guias de configuracao de seguranca baseados em consenso, aceitos por governos, empresas e academia. Fornecem implementacao pratica com scripts e parametros especificos.

**Bancos com benchmark disponivel**:

| Banco | Benchmark | Controles Aproximados |
|-------|-----------|----------------------|
| PostgreSQL | CIS PostgreSQL 17 Benchmark | ~80 controles |
| MySQL | CIS Oracle MySQL Benchmark | ~60 controles |
| SQL Server | CIS SQL Server Benchmark | ~80 controles |
| Oracle Database | CIS Oracle Database 19c/23ai | ~90 controles |
| IBM Db2 | CIS IBM Db2 Benchmark | ~50 controles |

**Areas cobertas pelo CIS**:
- Autenticacao e autorizacao
- Configuracao de rede e portas
- Auditoria e logging
- Criptografia em repouso e em transito
- Gerenciamento de contas e privilegios
- Configuracoes de sistema operacional relacionadas

**Ferramenta de validacao para PostgreSQL**: PGDSAT (PostgreSQL Database Security Assessment Tool) — verifica automaticamente aderencia aos ~80 controles CIS.

**Referencia**: https://www.cisecurity.org/cis-benchmarks

---

## DISA STIGs (Security Technical Implementation Guides)

**O que e**: guias mandatorios de configuracao de seguranca para sistemas do Departamento de Defesa dos EUA (DoD). Mais de 450 guias publicados.

**Bancos com STIG disponivel**:
- MySQL Enterprise Edition
- Oracle Database
- Microsoft SQL Server

**Requisitos comuns nos STIGs de banco de dados**:
- Desabilitar features e servicos desnecessarios
- Implementar autenticacao forte (sem autenticacao anonima)
- Auditoria abrangente de todos os acessos
- Criptografia de dados em transito e em repouso
- Aplicacao de patches de seguranca em janela definida
- Backups seguros com verificacao de integridade

**Acesso**: https://www.cyber.mil/stigs/ | Visualizador: https://www.stigviewer.com/stigs

---

## NIST SP 800-Series

### NIST SP 800-209 — Security Guidelines for Storage Infrastructure
Cobre recomendacoes de seguranca para infraestrutura de armazenamento:
- Autenticacao e autorizacao de acesso ao storage
- Gerenciamento de mudancas
- Resposta a incidentes
- Isolamento e protecao de dados
- Garantia de restauracao
- Requisitos de criptografia

### NIST SP 800-53 — Security and Privacy Controls
Catalogo de controles de seguranca para sistemas federais, amplamente adotado no setor privado:
- Controle de acesso (AC)
- Auditoria e prestacao de contas (AU)
- Gerenciamento de configuracao (CM)
- Planejamento de contingencia (CP)
- Protecao de sistemas e comunicacoes (SC)

**Relevancia para bancos de dados**: os controles AU (auditoria), AC (acesso), CM (configuracao), e SC (criptografia de comunicacoes) se aplicam diretamente a todos os SGBDs.

**Referencia**: https://csrc.nist.gov/publications/sp800

---

## ISO/IEC 27001:2022 e 27002:2022

**O que e**: norma internacional para Sistema de Gestao de Seguranca da Informacao (SGSI/ISMS). A ISO 27002 detalha 93 controles organizados em 4 categorias.

**Controles diretamente relevantes para bancos de dados**:

### Controles Organizacionais
- **A.5.23**: Seguranca da informacao para uso de servicos em nuvem (bancos gerenciados)
- **A.5.28**: Coleta de evidencias (audit trails)
- **A.5.33**: Protecao de registros (audit logs imutaveis)

### Controles Tecnologicos
- **A.8.3**: Restricao de acesso a informacao (RBAC, RLS)
- **A.8.5**: Autenticacao segura (MFA para contas privilegiadas)
- **A.8.11**: Mascaramento de dados (data masking para ambientes nao-producao)
- **A.8.12**: Prevencao de vazamento de dados (DLP)
- **A.8.24**: Uso de criptografia (TDE, TLS, criptografia de backup)

**Referencia**: https://www.iso.org/standard/27001

---

## COBIT 2019 (ISACA)

**O que e**: framework de governanca e gestao de TI com 40 objetivos distribuidos em 5 dominios. Amplamente usado para alinhamento de TI com negocios.

**Objetivos diretamente aplicaveis a bancos de dados**:

| Objetivo | Nome | Relevancia para BD |
|----------|------|--------------------|
| APO03 | Manage Enterprise Architecture | Arquitetura de dados e selecao de tecnologia |
| APO13 | Manage Security | Politica de seguranca, criptografia, acesso |
| **APO14** | **Manage Data** | **Governanca de dados, qualidade, ciclo de vida** |
| DSS01 | Manage Operations | Procedimentos operacionais, disponibilidade |
| DSS02 | Manage Service Requests and Incidents | Incidentes de banco de dados |
| DSS03 | Manage Problems | Analise de causa raiz de falhas |
| DSS05 | Manage Security Services | Implementacao de controles de seguranca |
| DSS06 | Manage Business Process Controls | Controles de processo de dados |

**APO14 — Manage Data** e o objetivo central para padronizacao:
- Politicas e procedimentos de dados
- Qualidade e catalogacao de dados
- Ciclo de vida completo (criacao, uso, arquivamento, destruicao)
- Proprietarios de dados (data owners) e custodiantes
- Classificacao de dados por sensibilidade

**Referencia**: https://www.isaca.org/resources/cobit

---

## ITIL 4 — Gestao de Servicos de TI

**O que e**: biblioteca de praticas para gestao de servicos de TI. Fornece processos padronizados para operacoes de banco de dados.

**Praticas relevantes para DBAs**:

### Service Asset and Configuration Management (CMDB)
- Registrar todos os bancos de dados como Configuration Items (CIs)
- Documentar: host, versao, instancias, dependencias de aplicacoes, responsaveis
- Integrar com processos de change management
- Usar descoberta automatizada para manter CMDB atualizado

### Incident Management
- Classificar incidentes de banco por severidade (P1–P4)
- P1: banco indisponivel em producao
- P2: degradacao severa de performance
- P3: falha de replicacao/backup
- P4: alertas de monitoramento sem impacto imediato
- Definir SLAs de resolucao por severidade

### Problem Management
- Analise de causa raiz (RCA) para todos os incidentes P1/P2
- Manter base de erros conhecidos (Known Error Database)
- Documentar workarounds aprovados ate correcao permanente

### Change Management
- Toda mudanca de configuracao de banco passa por CAB (Change Advisory Board)
- Classificacao: Padrao (pre-aprovado), Normal (revisao), Emergencial (pos-aprovado)
- Ambiente de homologacao obrigatorio antes de producao
- Plano de rollback documentado para toda mudanca

### Capacity Management
- Monitorar tendencias de crescimento de dados
- Planejar capacidade com 6-12 meses de antecedencia
- Alertas em 70% de uso de disco (warning) e 85% (critico)

---

## Relacao entre Frameworks

```
                    Governanca
                   ┌──────────┐
                   │ COBIT    │  ← estrategia e politica
                   └────┬─────┘
                        │
              ┌─────────┼─────────┐
              ▼         ▼         ▼
         ┌────────┐ ┌───────┐ ┌──────────┐
         │  ITIL  │ │  ISO  │ │  NIST    │  ← processos e controles
         │(ops)   │ │27001  │ │ SP800    │
         └────┬───┘ └───┬───┘ └────┬─────┘
              │         │          │
              └────┬────┘──────────┘
                   ▼
         ┌─────────────────┐
         │ CIS Benchmarks  │  ← implementacao tecnica especifica
         │ DISA STIGs      │
         │ Vendor Docs     │
         └─────────────────┘
```

**Recomendacao de implementacao**:
1. Adotar **COBIT APO14** para governanca e politica de dados
2. Implementar **ISO 27001** para ISMS formal (se certificacao for necessaria)
3. Usar **NIST SP 800-53** como catalogo de controles a implementar
4. Seguir **ITIL 4** para operacoes e processos
5. Aplicar **CIS Benchmarks** para hardening tecnico especifico de cada banco
6. Verificar conformidade com **DISA STIGs** se atender clientes governamentais

---

## Classificacao de Dados (Prerequisito para Padronizacao)

Antes de qualquer padronizacao, classificar os dados:

| Nivel | Descricao | Exemplos | Controles Minimos |
|-------|-----------|----------|-------------------|
| Publico | Pode ser divulgado sem restricao | Catalogo de produtos | Integridade basica |
| Interno | Uso interno, nao divulgar | Relatorios operacionais | Controle de acesso |
| Confidencial | Dados sensiveis de negocio | Dados financeiros, estrategia | Criptografia + auditoria |
| Restrito | Dados altamente sensiveis | PII, dados de saude, senhas | Criptografia forte + MFA + DLP |

A classificacao determina quais controles aplicar em cada banco de dados.
