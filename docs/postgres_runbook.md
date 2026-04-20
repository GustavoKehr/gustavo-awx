# PostgreSQL — Runbook Operacional AWX

Guia prático para executar operações de gestão de usuários PostgreSQL via AWX Job Templates.

> **Para iniciantes:** Este runbook contém os passos exatos para criar, modificar e remover usuários no PostgreSQL usando o AWX. Você não precisará digitar comandos no servidor — basta preencher o formulário (survey) no AWX e clicar em "Launch".

---

## Pré-requisitos

Antes de executar qualquer job:

1. **PostgreSQL instalado** em `postgresvm` (192.168.137.158, porta 15432)
2. **AWX sincronizado** com o repositório GitHub (`gustavo-awx` project)
3. **Credencial Machine** configurada no AWX (usuário `user_aap`)
4. **Job Template** configurado com o survey correto

---

## Job Template AWX — Configuração

Para o playbook `manage_postgres_users.yml` (ou `deploy_postgres.yml --tags postgres_users`):

| Campo AWX | Valor |
|---|---|
| **Name** | `POSTGRES \| Manage Users` |
| **Playbook** | `playbooks/manage_postgres_users.yml` |
| **Inventory** | `LINUX` |
| **Credentials** | `Machine: user_aap` |
| **Limit** | `postgresvm` (ou deixar em branco para todos os hosts) |
| **Extra Variables** | `postgres_manage_users_enabled: true` |
| **Survey** | Associar `awx_survey_postgres_manage_users.json` |

---

## Tag Map — O que Cada Tag Faz

Use tags para executar apenas uma parte da operação:

| Tag | O que executa | Quando usar |
|---|---|---|
| `postgres` | Todas as tasks PostgreSQL | Raramente — muito abrangente |
| `postgres_install` | Instala e configura o servidor | Primeira instalação ou reconfiguração |
| `postgres_users` | Todo o ciclo de gestão de usuários | Operação padrão de usuários |
| `postgres_users_validate` | Valida variáveis de entrada | Debug de erros de validação |
| `postgres_user` | Só cria/altera a role no banco | Testar criação sem tocar grants |
| `postgres_db` | Só cria os bancos de dados | Quando `manage_databases=true` |
| `postgres_grants` | Só concede privilégios de banco | Adicionar CONNECT em novo banco |
| `postgres_pg_roles` | Só concede roles predefinidas | Adicionar pg_read_all_data |
| `postgres_revoke` | Só revoga privilégios | Revogar sem remover usuário |
| `postgres_hba` | Só atualiza pg_hba.conf | Liberar acesso de novo IP |
| `postgres_remove_user` | Só remove a role | Quando state=absent |
| `db_patches` | Descoberta de patches | Verificação de patches disponíveis |

---

## Cenários de Uso

### Cenário 1: Criar usuário de aplicação básico

**Situação:** Nova aplicação precisa conectar ao banco `appdb` para leitura e escrita.

**Survey AWX a preencher:**

| Campo | Valor |
|---|---|
| PostgreSQL username | `webapp` |
| PostgreSQL password | `App#Secure2024!` |
| User state | `present` |
| Role attribute flags | `LOGIN` |
| Privileges | `CONNECT` |
| Target databases | `appdb` |
| Revoke access | `false` |
| Create target databases | `false` |
| Predefined roles | *(deixar em branco)* |
| Allowed IPs | `192.168.1.50` |

**O que o playbook executa:**
```sql
-- 1. Cria a role
CREATE ROLE webapp WITH LOGIN PASSWORD '***';

-- 2. Concede acesso ao banco
GRANT CONNECT ON DATABASE appdb TO webapp;

-- 3. Adiciona no pg_hba.conf:
-- host  appdb  webapp  192.168.1.50/32  scram-sha-256

-- 4. Reload do PostgreSQL (sem reiniciar)
```

---

### Cenário 2: Criar usuário DBA com poderes totais

**Situação:** Novo DBA precisa de acesso administrativo completo.

| Campo | Valor |
|---|---|
| PostgreSQL username | `dbadmin` |
| PostgreSQL password | `DBA#Admin2024!` |
| User state | `present` |
| Role attribute flags | `LOGIN,SUPERUSER,CREATEDB,CREATEROLE` |
| Privileges | `CONNECT` |
| Target databases | `appdb` |
| Revoke access | `false` |
| Create target databases | `false` |
| Predefined roles | *(deixar em branco)* |
| Allowed IPs | `192.168.137.1` |

> **Atenção:** `SUPERUSER` ignora todas as permissões — use apenas para DBAs confiáveis. Em produção, prefira `pg_monitor` ou roles granulares.

---

### Cenário 3: Criar usuário read-only para BI/Relatórios

**Situação:** Time de BI precisa de acesso de leitura a todas as tabelas do banco.

| Campo | Valor |
|---|---|
| PostgreSQL username | `bi_reader` |
| PostgreSQL password | `BI#Reader2024` |
| User state | `present` |
| Role attribute flags | `LOGIN` |
| Privileges | `CONNECT` |
| Target databases | `appdb` |
| Revoke access | `false` |
| Create target databases | `false` |
| **Predefined roles** | `pg_read_all_data` |
| Allowed IPs | `10.0.5.20,10.0.5.21` |

**O que a `pg_predefined_roles` faz:**
```sql
-- Além dos grants normais, executa:
GRANT pg_read_all_data TO bi_reader;
-- Isso concede SELECT em TODAS as tabelas, views e sequences do cluster
```

> **Dica:** `pg_read_all_data` é mais simples que conceder `SELECT` tabela por tabela. O PostgreSQL faz isso automaticamente.

---

### Cenário 4: Criar banco + usuário ao mesmo tempo

**Situação:** Nova aplicação precisa de banco e usuário criados do zero.

| Campo | Valor |
|---|---|
| PostgreSQL username | `newapp` |
| PostgreSQL password | `NewApp#2024` |
| User state | `present` |
| Role attribute flags | `LOGIN` |
| Privileges | `CONNECT` |
| Target databases | `newappdb` |
| Revoke access | `false` |
| **Create target databases** | `true` |
| Predefined roles | *(deixar em branco)* |
| Allowed IPs | `192.168.1.100` |

**Ordem de execução:**
1. Cria o banco `newappdb` via `postgresql_db`
2. Cria a role `newapp` via `psql`
3. Concede `CONNECT` no banco `newappdb`
4. Adiciona IP no pg_hba.conf

---

### Cenário 5: Revogar acesso sem remover usuário

**Situação:** Usuário precisa perder `CONNECT` no banco, mas manter a role.

| Campo | Valor |
|---|---|
| PostgreSQL username | `webapp` |
| PostgreSQL password | *(deixar em branco ou repetir senha)* |
| User state | `present` |
| Role attribute flags | `LOGIN` |
| Privileges | `CONNECT` |
| Target databases | `appdb` |
| **Revoke access** | `true` |
| Create target databases | `false` |
| Predefined roles | *(deixar em branco)* |
| Allowed IPs | *(deixar em branco)* |

```sql
-- O playbook executa:
REVOKE CONNECT ON DATABASE appdb FROM webapp;
```

---

### Cenário 6: Remover usuário completamente

**Situação:** Funcionário saiu da empresa — remover acesso.

| Campo | Valor |
|---|---|
| PostgreSQL username | `webapp` |
| PostgreSQL password | *(qualquer valor — ignorado)* |
| **User state** | `absent` |
| Role attribute flags | `LOGIN` |
| Privileges | `CONNECT` |
| Target databases | `appdb` |
| Revoke access | `false` |
| Create target databases | `false` |
| Predefined roles | *(deixar em branco)* |
| Allowed IPs | *(deixar em branco)* |

**O que o playbook executa (quando state=absent):**
```sql
-- 1. Remove todos os privilégios do usuário
DROP OWNED BY webapp;

-- 2. Remove a role
DROP ROLE webapp;
```

> **Por que `DROP OWNED BY` primeiro?** Sem isso, o PostgreSQL rejeita o `DROP ROLE` com erro: `role "webapp" cannot be dropped because some objects depend on it`. O `DROP OWNED BY` remove todos os grants e ownership antes da remoção.

---

## Checklist de Verificação Pós-Job

Após rodar qualquer job, verificar:

**1. Status do job no AWX:**
- Job deve terminar em `Successful`
- `changed=N` mostra quantas tasks realmente modificaram o servidor

**2. Verificar no servidor (SSH):**
```bash
ssh user_aap@192.168.137.158

# Listar todas as roles
sudo -u postgres psql -p 15432 -c "\du"

# Verificar role específica
sudo -u postgres psql -p 15432 -c "SELECT rolname, rolsuper, rolcreatedb, rolcanlogin FROM pg_roles WHERE rolname='webapp';"

# Verificar privilégios em banco
sudo -u postgres psql -p 15432 -c "\l" | grep appdb

# Verificar pg_hba.conf
sudo cat /var/lib/pgsql/data/pg_hba.conf | grep webapp

# Verificar roles predefinidas concedidas
sudo -u postgres psql -p 15432 -c "SELECT grantor, grantee, role_name FROM information_schema.applicable_roles WHERE grantee='bi_reader';"
```

---

## Troubleshooting de Jobs

### Job falha em "Create or update PostgreSQL role" com output censurado

```
fatal: [postgresvm]: FAILED! => {"censored": "the output has been hidden due to the fact that 'no_log: true' was specified"}
```

**Possíveis causas e soluções:**
1. Senha com caracteres especiais que quebram o SQL → testar com senha simples primeiro
2. `role_attr_flags` com valores inválidos → verificar lista de atributos válidos
3. Porta errada → confirmar `postgres_port: 15432` no inventory
4. Unix socket não existe → verificar `/var/run/postgresql/.s.PGSQL.15432`

**Diagnóstico manual no servidor:**
```bash
sudo -u postgres psql -p 15432 -c "SELECT 1;"  # testa conexão básica
ls /var/run/postgresql/                          # confirmar socket existe
```

---

### Job falha em "Grant predefined roles" com `role X does not exist`

```
ERROR: role "pg_read_all_data" does not exist
```

**Causa:** Versão do PostgreSQL anterior à 14.

**Verificar versão:**
```bash
sudo -u postgres psql -p 15432 -c "SELECT version();"
```

Roles predefinidas (`pg_read_all_data`, `pg_write_all_data`, etc.) só existem no **PostgreSQL 14+**.

---

### Job termina com `ok=N changed=0 failed=0` mas usuário não foi criado

**Causa:** A role já existia — Ansible verificou e não precisou criar nada (idempotente por design).

**Verificar:**
```bash
sudo -u postgres psql -p 15432 -c "\du webapp"
```

---

### AWX não encontra o host `postgresvm`

**Causa:** Inventory não sincronizado ou host offline.

**Solução:**
1. AWX → Inventories → LINUX → Sync
2. Verificar se `postgresvm` (192.168.137.158) está acessível
3. Verificar se Proxmox está ligado e a VM está rodando

---

## Execução via CLI (fora do AWX)

Para testes locais sem AWX:

```bash
# Usando as mesmas variáveis do survey:
ansible-playbook playbooks/manage_postgres_users.yml \
  -l postgresvm \
  -e "postgres_manage_users_enabled=true" \
  -e "pg_username=webapp" \
  -e "pg_user_password=App#Secure2024!" \
  -e "pg_user_state=present" \
  -e "pg_role_attr_flags=LOGIN" \
  -e "pg_privileges=CONNECT" \
  -e "pg_target_databases=appdb" \
  -e "pg_revoke_access=false" \
  -e "pg_manage_databases=false" \
  -e "pg_predefined_roles=''" \
  -e "pg_allowed_ips=192.168.1.50"

# Dry-run (não executa, só mostra o que faria):
ansible-playbook playbooks/manage_postgres_users.yml \
  -l postgresvm \
  -e "postgres_manage_users_enabled=true" \
  -e "pg_username=webapp" \
  -e "pg_user_password=App#Secure2024!" \
  -e "pg_user_state=present" \
  --check
```

---

## Ver Também

- [`postgres_guide.md`](postgres_guide.md) — Documentação técnica completa (variáveis, módulos, conceitos)
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
- [`general_guide.md`](general_guide.md) — Arquitetura geral e comandos Ansible
