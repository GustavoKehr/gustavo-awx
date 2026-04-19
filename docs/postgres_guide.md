# Guia PostgreSQL — Ansible & AWX

Referência técnica para os playbooks e roles PostgreSQL deste repositório.
Parte do conjunto: `general_guide.md` · `mysql_guide.md` · `postgres_guide.md` · `sqlserver_guide.md` · `oracle_guide.md`

---

## Playbook — deploy_postgres.yml

```
Phase 1: postgres_install      → tags: postgres, postgres_install
Phase 2: postgres_manage_users → tags: postgres, postgres_users
Phase 3: db_patches             → tags: postgres, db_patches
```

```bash
ansible-playbook playbooks/deploy_postgres.yml                          # tudo
ansible-playbook playbooks/deploy_postgres.yml --tags postgres_install  # só instalar
ansible-playbook playbooks/deploy_postgres.yml --tags postgres_users    # só usuários
ansible-playbook playbooks/deploy_postgres.yml -l postgresvm --check    # dry run
```

---

## Módulos community.postgresql

```yaml
# Configurar parâmetros em postgresql.conf
community.postgresql.postgresql_set:
  name: shared_buffers
  value: "512MB"
become_user: postgres   # OBRIGATÓRIO — PG só aceita de seu próprio usuário do SO

# pg_hba.conf — controle de acesso host-based
community.postgresql.postgresql_pg_hba:
  dest: /var/lib/pgsql/data/pg_hba.conf
  contype: host              # TCP/IP (vs 'local' para unix socket)
  databases: all
  users: all
  source: "0.0.0.0/0"       # Em produção: restringir ao CIDR da aplicação
  method: scram-sha-256      # Mais seguro que md5
become_user: postgres

# Criar role (usuário)
community.postgresql.postgresql_user:
  name: "{{ pg_username }}"
  password: "{{ pg_user_password }}"
  role_attr_flags: LOGIN     # LOGIN = usuário que pode se autenticar
  state: present
become_user: postgres
no_log: true

# Criar banco
community.postgresql.postgresql_db:
  name: "{{ item }}"
  state: present
become_user: postgres

# Conceder privilégios no banco
community.postgresql.postgresql_privs:
  db: "{{ item }}"
  roles: "{{ pg_username }}"
  type: database
  privs: CONNECT             # CONNECT permite a conexão; grants adicionais via SQL
  state: present             # state: absent = revoga
become_user: postgres
```

---

## Variáveis críticas — postgres_install (`defaults/main.yml`)

| Variável | Padrão | Observação |
|---|---|---|
| `postgres_port` | `15432` | Porta não padrão |
| `postgres_shared_buffers` | `512MB` | ~25% da RAM; o OS cuida do resto via page cache |
| `postgres_work_mem` | `16MB` | Multiplicado por conexões paralelas — cuidado com OOM |
| `postgres_password_encryption` | `scram-sha-256` | SCRAM; não usar `md5` em instalações novas |
| `postgres_hba_cidr` | `0.0.0.0/0` | Em produção: restringir ao CIDR da aplicação |
| `postgres_max_connections` | `300` | Máximo de conexões simultâneas |
| `postgres_bind_address` | IP da VM | Aceitar conexões externas |

---

## Variáveis do survey AWX — postgres_manage_users

| Variável | Descrição | Exemplo |
|---|---|---|
| `pg_username` | Nome da role | `app_user` |
| `pg_user_password` | Senha | `MinhaSenh@123` |
| `pg_user_state` | `present` ou `absent` | `present` |
| `pg_target_databases` | Bancos alvo | `appdb,logs` |
| `pg_manage_databases` | `true` = cria os bancos | `false` |
| `pg_privileges` | Privilégios no banco | `CONNECT` |
| `pg_revoke_access` | `true` = revoga sem remover a role | `false` |
| `pg_role_attr_flags` | Atributos da role | `LOGIN` |

---

## Observações de design

### Por que `become_user: postgres` é obrigatório?
O PostgreSQL usa o usuário `postgres` do SO como superusuário do sistema. Modificar configurações via módulo requer conexão autenticada como esse usuário. Tentar como root resulta em `authentication failed`.

### Por que `python3-psycopg2` é obrigatório?
Os módulos `community.postgresql.*` usam a biblioteca Python psycopg2 para se comunicar. Sem ela, qualquer task de PG retorna erro de dependência.

### `CONNECT` não é suficiente para acessar tabelas
`CONNECT` no banco permite apenas a conexão. Para ler tabelas, o usuário ainda precisa de `USAGE` no schema e `SELECT` nas tabelas. Grants adicionais são feitos via SQL depois da role.

### Roles vs usuários no PostgreSQL
Usuários e grupos são o mesmo conceito: **roles**. Uma role com atributo `LOGIN` vira um usuário. Uma role sem `LOGIN` é um grupo de permissões.
