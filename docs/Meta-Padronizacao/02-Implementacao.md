# 02 — Padronizacao de Implementacao

## Database Lifecycle Management (DLM)

Todo banco de dados passa pelas seguintes fases. Cada fase exige documentacao e aprovacao:

```
Design → Develop → Test → Build → Deploy → Maintain → Monitor → Backup → Archive/Destroy
```

### Fase 1: Design
- Definir requisitos funcionais e nao-funcionais (RTO, RPO, SLA, volume)
- Selecionar o banco de dados adequado ao tipo de workload
- Projetar schema inicial com convencoes de nomenclatura padronizadas
- Definir estrategia de particionamento e indexacao
- Documentar no CMDB antes de qualquer provisionamento

### Fase 2: Develop
- Desenvolver schema via migrations versionadas (Liquibase, Flyway, ou DbUp)
- Criar scripts idempotentes (podem ser re-executados sem efeito colateral)
- Commits de schema somente via Pull Request com revisao obrigatoria

### Fase 3: Test
- Testes de schema em banco de dados de desenvolvimento isolado
- Validar migrations de upgrade e downgrade (rollback)
- Testes de performance com volume de dados representativo
- Verificacao de seguranca (privilegios, acesso anonimo, senhas padrao)

### Fase 4: Build
- Gerar artefatos de migration com versao semantica
- Armazenar no repositorio de artefatos (Nexus, Artifactory, S3)

### Fase 5: Deploy
- Deploy automatizado via pipeline CI/CD
- Sempre aplicar em homologacao antes de producao
- Verificacao pos-deploy: saude do banco, migrations aplicadas, indices criados

### Fase 6: Maintain
- Aplicar patches e atualizacoes de versao em janelas de manutencao
- Gerenciar crescimento de tabelas (particionamento, archiving)
- Revisar e otimizar indices periodicamente

### Fase 7: Monitor
- Monitoramento continuo de KPIs definidos (ver documento 07)
- Alertas automatizados para anomalias

### Fase 8: Backup
- Backups automatizados com verificacao de integridade (ver documento 06)
- Testes de restore mensais obrigatorios

### Fase 9: Archive/Destroy
- Arquivar dados historicos conforme politica de retencao
- Destruicao segura de dados ao final do ciclo (DOD 5220.22-M ou NIST 800-88)
- Remover instancia do CMDB apos descomissionamento

---

## Convencoes de Nomenclatura

Adotar convencoes consistentes elimina ambiguidades e facilita automacao.

### Nomenclatura de Objetos

| Objeto | Convencao | Exemplo |
|--------|-----------|---------|
| Tabelas | `snake_case`, singular | `customer_order` |
| Colunas | `snake_case` | `created_at`, `first_name` |
| Chave Primaria | `<tabela>_id` | `customer_order_id` |
| Chave Estrangeira | `<tabela_referenciada>_id` | `customer_id` |
| Indice | `idx_<tabela>_<coluna(s)>` | `idx_order_customer_id` |
| Indice Unico | `uq_<tabela>_<coluna(s)>` | `uq_customer_email` |
| Constraint CHECK | `chk_<tabela>_<descricao>` | `chk_order_status` |
| View | `vw_<descricao>` | `vw_monthly_sales` |
| Stored Procedure | `sp_<acao>_<objeto>` | `sp_get_customer_orders` |
| Function | `fn_<acao>_<objeto>` | `fn_calculate_tax` |
| Trigger | `trg_<tabela>_<evento>` | `trg_order_before_insert` |
| Sequence | `seq_<tabela>_<coluna>` | `seq_customer_order_id` |

### Regras Gerais
- **Sempre lowercase** — evita problemas de case sensitivity entre bancos
- **Sem abreviacoes** — use `customer_address` nao `cust_addr`
- **Sem espacos ou caracteres especiais** — use underscore como separador
- **Evite palavras reservadas** — nao use `order`, `user`, `table` como nomes de tabela
- **Maximo 30 caracteres** — compativel com Oracle e outros bancos com limites historicos
- **Prefixo de dominio** para esquemas multi-dominio: `sales_orders`, `hr_employees`

### Nomenclatura de Instancias e Bancos

```
Formato: <ambiente>-<tipo_banco>-<numero>
Exemplos:
  prod-pg-01       # PostgreSQL producao, instancia 1
  hml-mysql-02     # MySQL homologacao, instancia 2
  dev-oracle-01    # Oracle desenvolvimento
  prod-redis-01    # Redis producao
```

---

## Versionamento de Schema (Schema Migration)

### Ferramentas Padrao

| Banco | Ferramenta Recomendada | Alternativa |
|-------|------------------------|-------------|
| PostgreSQL | Flyway | Liquibase |
| MySQL | Flyway | Liquibase |
| SQL Server | Flyway | DbUp |
| Oracle | Liquibase | Flyway |
| Db2 | Liquibase | Flyway |

### Principios de Migration
1. **Cada migration e imutavel** — nunca editar migration ja aplicada em qualquer ambiente
2. **Migrations sao incrementais** — cada arquivo tem um numero de versao sequencial
3. **Scripts idempotentes** — usar `CREATE TABLE IF NOT EXISTS`, `DROP INDEX IF EXISTS`
4. **Rollback documentado** — toda migration de schema com rollback correspondente
5. **Separar DDL de DML** — mudancas de estrutura separadas de carga de dados

### Estrutura de Diretorio Sugerida
```
db/
├── migrations/
│   ├── V1__create_base_schema.sql
│   ├── V2__add_customer_table.sql
│   ├── V3__add_indexes.sql
│   └── V4__add_audit_columns.sql
├── callbacks/
│   ├── beforeMigrate.sql
│   └── afterMigrate.sql
└── seeds/
    └── R__reference_data.sql
```

---

## Connection Pooling

Obrigatorio em todo ambiente com multiplos clientes conectados.

### Padrao por Banco

| Banco | Ferramenta Padrao | Modos |
|-------|-------------------|-------|
| PostgreSQL | **PgBouncer** | Session / Transaction / Statement |
| MySQL | **ProxySQL** | — |
| SQL Server | Pool nativo do driver / **RDS Proxy** (AWS) | — |
| Oracle | **Connection Pool nativo** (JDBC/OCI) | — |
| Redis | Pool nativo do cliente (redis-py, Jedis, ioredis) | — |

### Configuracao Padrao — PgBouncer (PostgreSQL)

```ini
[databases]
mydb = host=127.0.0.1 port=5432 dbname=mydb

[pgbouncer]
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 5
server_idle_timeout = 600
client_idle_timeout = 0
```

### Configuracao Padrao — ProxySQL (MySQL)

```sql
-- Adicionar backend
INSERT INTO mysql_servers(hostgroup_id, hostname, port) VALUES (0, '10.0.0.1', 3306);

-- Configurar pool
UPDATE global_variables SET variable_value='25' WHERE variable_name='mysql-max_connections';
UPDATE global_variables SET variable_value='600000' WHERE variable_name='mysql-wait_timeout';

LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;
```

### Dimensionamento do Pool
- `pool_size` = `max_connections_do_banco / numero_de_aplicacoes`
- Nunca ultrapassar `max_connections` configurado no banco
- Monitorar utilizacao: alerta em 70% de uso do pool

---

## Infrastructure as Code (IaC)

### Padrao Terraform + Ansible

```
Terraform = provisiona infraestrutura (VMs, volumes, redes, security groups)
Ansible   = configura software de banco de dados, cria usuarios, aplica baseline
```

### Fluxo de Provisionamento

```
git push → CI trigger
    → Terraform plan (revisao humana obrigatoria)
    → Terraform apply (infraestrutura criada)
    → Ansible inventory atualizado dinamicamente com outputs do Terraform
    → Ansible playbook executa:
        → instala banco de dados
        → aplica configuracao baseline (parametros, listeners, pg_hba, etc.)
        → configura backup automatico
        → registra no monitoramento
        → adiciona ao CMDB
```

### Principios IaC para Bancos de Dados
1. **Toda configuracao em codigo** — nenhum parametro configurado manualmente em producao
2. **Idempotente** — re-executar playbook nao causa mudancas indesejadas
3. **Versionado** — todo arquivo de configuracao com historico no Git
4. **Ambientes como codigo** — dev, hml, prod provisionados a partir dos mesmos scripts (com variaveis)
5. **Secrets no vault** — credenciais nunca em texto plano no repositorio (usar HashiCorp Vault, AWS Secrets Manager, ou Ansible Vault)

---

## Padrao de Documentacao Operacional

Todo banco em producao deve ter documentado:

### Runbook Minimo (por instancia)
- [ ] Localizacao do servidor / endpoint de conexao
- [ ] Versao do banco e data da ultima atualizacao
- [ ] Responsavel tecnico (DBA) e contato de emergencia
- [ ] Janela de manutencao aprovada
- [ ] SLA de disponibilidade contratado
- [ ] Procedimento de restart/failover manual
- [ ] Localizacao dos logs e backups
- [ ] Monitoramento: URL do dashboard e canal de alertas
- [ ] Dependencias: aplicacoes que usam este banco
- [ ] Procedimento de escalacao de incidentes

### Diagrama de Arquitetura
- Topologia de replicacao (primario/standby/replica de leitura)
- Fluxo de backup e destino
- Integracao com connection pool
- Segmentacao de rede (VPC, subnets, security groups)
