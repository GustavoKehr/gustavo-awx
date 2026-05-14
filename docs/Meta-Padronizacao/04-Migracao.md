# 04 — Padronizacao de Migracao de Banco de Dados

## Estrategias de Migracao (Framework Gartner)

Antes de iniciar qualquer migracao, definir a estrategia:

| Estrategia | Descricao | Quando Usar | Risco |
|------------|-----------|-------------|-------|
| **Rehost** (Lift & Shift) | Mover banco como esta para nova infraestrutura | Urgencia, sem tempo para reengenharia | Baixo |
| **Revise** | Otimizar para nova plataforma mantendo funcionalidade core | Migracao de on-premises para cloud | Medio |
| **Rearchitect** | Redesenhar para arquitetura cloud-native | Modernizacao completa | Alto |
| **Rebuild** | Reescrever completamente para banco de destino | Mudanca radical de tecnologia | Muito Alto |
| **Replace** | Substituir por solucao SaaS | Sistemas legados sem manucao ativa | Variavel |

**Recomendacao**: para a maioria das migracoes entre SGBDs, usar **Revise** — migrar com adaptacoes para o banco de destino, sem reescrever toda a aplicacao.

---

## Fases da Migracao

### Fase 1: Planejamento e Escopo

**Definicoes obrigatorias**:
- [ ] Escopo: migrar banco completo ou apenas schemas/tabelas especificas?
- [ ] Criterios de sucesso: o que define que a migracao foi bem-sucedida?
- [ ] RTO e RPO da janela de migracao
- [ ] Stakeholders e aprovadores
- [ ] Cronograma com datas e responsaveis
- [ ] Orçamento para ferramentas, infraestrutura e horas de trabalho
- [ ] Plano de comunicacao (quem notificar em cada fase)

**Planejamento de riscos**:

| Risco | Probabilidade | Impacto | Mitigacao |
|-------|--------------|---------|-----------|
| Incompatibilidade de tipos de dados | Alta | Alto | Mapeamento de tipos antes da execucao |
| Funcoes/procedures incompativeis | Alta | Alto | Auditoria de objetos PL/SQL/T-SQL antes |
| Performance inferior no destino | Media | Alto | Benchmark de carga antes do cutover |
| Perda de dados durante migracao | Baixa | Critico | Validacao automatica pos-migracao |
| Rollback necessario | Media | Alto | Plano de rollback testado |

---

### Fase 2: Assessment — Avaliacao do Ambiente Origem

**Inventario de objetos**:
```sql
-- PostgreSQL: contar objetos por tipo
SELECT table_type, count(*) FROM information_schema.tables GROUP BY table_type;
SELECT count(*) FROM information_schema.routines;
SELECT count(*) FROM information_schema.triggers;

-- Oracle: inventario completo
SELECT object_type, count(*) FROM user_objects GROUP BY object_type ORDER BY 2 DESC;

-- SQL Server
SELECT type_desc, count(*) FROM sys.objects GROUP BY type_desc ORDER BY 2 DESC;
```

**Data Profiling**:
- **Completude**: percentual de campos nulos vs nao-nulos por coluna
- **Consistencia**: validar constraints (FKs, CHECKs) — existem violacoes silenciosas?
- **Precisao**: tipos de dados adequados (VARCHAR muito largo, numeros em campos texto)
- **Volume**: tamanho total de cada tabela (linhas e bytes)
- **Crescimento**: taxa de crescimento mensal (impacta estimativas de tempo de migracao)

**Compatibilidade entre bancos**:

| Item | O que Verificar |
|------|----------------|
| Tipos de dados | Equivalencias entre o banco origem e destino |
| Funcoes nativas | Funcoes usadas que nao existem no destino |
| Procedimentos armazenados | PL/pgSQL, T-SQL, PL/SQL — re-escrever para o dialeto do destino |
| Triggers | Logica e eventos suportados |
| Collation / Encoding | Compatibilidade de charset (UTF-8 recomendado) |
| Sequences / Auto-Increment | Mecanismo diferente entre bancos |
| Case Sensitivity | Oracle e PostgreSQL tratam nomes de forma diferente |

---

### Fase 3: Preparacao

- [ ] Provisionar ambiente de destino com IaC (nao configurar manualmente)
- [ ] Aplicar baseline de configuracao do banco de destino (ver documento 03)
- [ ] Criar mapeamento de tipos de dados (planilha origem → destino)
- [ ] Selecionar e testar ferramentas de migracao
- [ ] Montar ambiente de testes com subconjunto de dados
- [ ] Treinar equipe nas ferramentas e procedimentos
- [ ] Documentar procedimento completo de rollback
- [ ] **Criar backup completo do banco origem** antes de qualquer acao

---

### Fase 4: Execucao

**Modos de execucao**:

| Modo | Descricao | Downtime | Risco | Quando Usar |
|------|-----------|----------|-------|-------------|
| **Big Bang** | Migrar tudo de uma vez | Alto | Alto | Bancos pequenos (<100GB) ou janela extensa disponivel |
| **Phased** | Migrar em fases logicas (por schema, aplicacao, dominio) | Medio | Medio | Bancos medios, aplicacoes modulares |
| **Trickle** | Migracao continua com CDC (Change Data Capture) | Minimo | Baixo | Grandes bancos em producao, SLAs rigidos |

**Checklist de execucao**:
- [ ] Backup completo imediatamente antes do inicio
- [ ] Validar conectividade com banco de destino
- [ ] Executar migracao de schema primeiro (DDL)
- [ ] Executar migracao de dados (DML)
- [ ] Aplicar constraints e indices apos carga de dados (performance)
- [ ] Registrar inicio, fim e erros de cada etapa
- [ ] Monitorar progresso em tempo real

---

### Fase 5: Validacao Pos-Migracao

**Validacoes obrigatorias**:

```bash
# 1. Contagem de linhas por tabela (origem vs destino)
# Origem:
psql -c "SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY 1,2;"

# Destino: comparar com ferramenta de diff

# 2. Checksum de dados criticos
SELECT md5(string_agg(coluna::text, '')) FROM tabela ORDER BY id;

# 3. Validar constraints
SELECT * FROM information_schema.table_constraints WHERE constraint_type IN ('FOREIGN KEY','CHECK','UNIQUE');

# 4. Validar sequences/auto-increment (confirmar que proximos IDs nao colidem)
SELECT last_value FROM <sequence_name>;
```

**Testes de aplicacao**:
- [ ] Smoke tests: operacoes CRUD basicas
- [ ] Testes de regressao completos
- [ ] Testes de performance (comparar com baseline da origem)
- [ ] Testes de carga (simular pico de uso)
- [ ] Validacao de dados por amostragem manual

---

### Fase 6: Cutover

**Processo de cutover padrao**:
1. Comunicar janela de manutencao com antecedencia (usuarios + stakeholders)
2. Bloquear novas conexoes na origem
3. Aguardar drenagem de transacoes em andamento
4. Executar migracao delta (dados criados durante periodo de migracao)
5. Executar validacao final de contagens
6. Atualizar string de conexao das aplicacoes
7. Smoke test em producao
8. Comunicar conclusao

**Criterios de Go/No-Go**:
- [ ] Contagens de linhas batem entre origem e destino
- [ ] Todos os testes de aplicacao aprovados
- [ ] Performance dentro do baseline esperado
- [ ] Plano de rollback testado e pronto
- [ ] Aprovacao dos stakeholders

---

## Ferramentas por Par de Bancos

| Origem | Destino | Ferramenta Recomendada | Alternativa |
|--------|---------|------------------------|-------------|
| Oracle | PostgreSQL | `ora2pg` | AWS SCT + DMS |
| MySQL | PostgreSQL | `pgLoader` | AWS DMS |
| SQL Server | PostgreSQL | `pgLoader` | AWS SCT + DMS |
| SQL Server | MySQL | MySQL Workbench Migration Wizard | AWS DMS |
| Qualquer | AWS RDS | AWS DMS (Database Migration Service) | — |
| Qualquer | Azure | Azure Database Migration Service | — |
| Qualquer | GCP | Database Migration Service (GCP) | — |
| PostgreSQL | PostgreSQL | `pg_dump / pg_restore` | `pgcopydb` |
| MySQL | MySQL | `mysqldump / mysqlpump` | Percona XtraBackup |
| Oracle | Oracle | `exp/imp` ou `expdp/impdp` | RMAN DUPLICATE |
| Db2 | Db2 | `db2move` + `db2look` | SSV backup/restore |

---

## Checklist Completo de Migracao

### Pre-Migracao
- [ ] Estrategia de migracao definida e aprovada
- [ ] Inventario completo de objetos do banco origem
- [ ] Mapeamento de tipos de dados documentado
- [ ] Ambiente de destino provisionado e configurado
- [ ] Backup completo do banco origem verificado
- [ ] Ferramentas instaladas e testadas
- [ ] Procedimento de rollback documentado e testado
- [ ] Comunicacao enviada para stakeholders
- [ ] Janela de manutencao aprovada

### Durante a Migracao
- [ ] Monitoramento ativo durante toda a execucao
- [ ] Registrar erros e tempo de cada etapa
- [ ] Nao alterar dados na origem durante migracao Big Bang
- [ ] Backups intermediarios a cada fase significativa

### Pos-Migracao
- [ ] Contagem de linhas validada para todas as tabelas
- [ ] Constraints e indices verificados
- [ ] Testes de aplicacao aprovados
- [ ] Performance baseline validado
- [ ] Backups do novo banco configurados e testados
- [ ] Monitoramento configurado
- [ ] Runbook do novo banco documentado
- [ ] Licencas e custos do banco origem renegociados/cancelados
- [ ] Licoes aprendidas documentadas

---

## Migracao de Banco para Cloud

### Consideracoes Especiais

**1. Avaliacao de Compatibilidade**
- Usar AWS Schema Conversion Tool (SCT) ou equivalente para analise automatica
- AWS SCT identifica objetos incompativeis e sugere equivalentes
- Esperar 60–80% de conversao automatica; restante e manual

**2. Conectividade Durante Migracao**
- Usar VPN Site-to-Site ou Direct Connect/ExpressRoute entre on-premises e cloud
- Nunca migrar dados sensiveis pela internet publica sem criptografia

**3. Sizing no Cloud**
- Nao fazer lift-and-shift de sizing on-premises para cloud sem analise
- Cloud permite resize facil — comece conservador e ajuste com dados reais

**4. Servicos Gerenciados vs. Self-Managed**
- Preferir RDS/Aurora, Azure Database, Cloud SQL para reducao de overhead operacional
- Self-managed (EC2/VM) quando precisar de controles nao disponíveis em PaaS

**5. Teste de Latencia de Rede**
- Aplicacoes chatty (muitas chamadas de BD) sofrem com latencia cloud
- Medir RTT atual e RTT esperado na cloud antes de decidir pela migracao
