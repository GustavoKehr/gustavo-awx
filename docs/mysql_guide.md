# Guia MySQL — Ansible & AWX

Referência técnica para os playbooks e roles MySQL deste repositório.
Parte do conjunto: `general_guide.md` · `mysql_guide.md` · `postgres_guide.md` · `sqlserver_guide.md` · `oracle_guide.md`

---

## Playbook — deploy_mysql.yml

```
Phase 1: mysql_install      → tags: mysql, mysql_install
Phase 2: mysql_manage_users → tags: mysql, mysql_users  (quando mysql_manage_users_enabled=true)
Phase 3: db_patches          → tags: mysql, db_patches   (quando db_patches_enabled=true)
```

```bash
ansible-playbook playbooks/deploy_mysql.yml                        # tudo
ansible-playbook playbooks/deploy_mysql.yml --tags mysql_install   # só instalar 
ansible-playbook playbooks/deploy_mysql.yml --tags mysql_users     # só usuários
ansible-playbook playbooks/deploy_mysql.yml -l mysqlvm             # limitado a um host
ansible-playbook playbooks/deploy_mysql.yml --check                # dry run
```

---

## Módulos community.mysql


# Criar/atualizar usuário e grants em uma operação
community.mysql.mysql_user:pl
  login_user: root
  login_password: "{{ mysql_root_password }}"
  name: "{{ db_username }}"
  host: "{{ db_user_host }}"     # % = qualquer host
  password: "{{ db_password }}"
  priv: "{{ mysql_priv_scope }}" # "db1.*:SELECT,INSERT/db2.*:SELECT"
  state: present
  append_privs: false            # false = substitui grants; true = adiciona
  no_log: true                   # OBRIGATÓRIO — não registrar senha em logs

# Remover usuário
community.mysql.mysql_user:
  name: "{{ db_username }}"
  host: "{{ db_user_host }}"
  state: absent

# Revogar sem remover (subtract_privs)
community.mysql.mysql_user:
  name: "{{ db_username }}"
  host: "{{ db_user_host }}"
  priv: "{{ mysql_priv_scope }}"
  subtract_privs: true
  state: present

# Criar banco
community.mysql.mysql_db:
  name: "{{ item }}"
  state: present
  login_user: root
  login_password: "{{ mysql_root_password }}"
```

**Formato de `priv`:**
```
"appdb.*:SELECT"                → SELECT em todas as tabelas de appdb
"appdb.*:SELECT,INSERT,UPDATE"  → múltiplos privilégios
"*.*:SELECT"                    → SELECT global
"db1.*:ALL/db2.*:SELECT"        → ALL em db1, SELECT em db2
```

---

## Variáveis críticas — mysql_install (`defaults/main.yml`)

| Variável | Padrão | Observação |
|---|---|---|
| `mysql_port` | `13306` | Porta não padrão — altere no `my.cnf` e no firewall |
| `mysql_innodb_buffer_pool_size` | `1G` | Principal parâmetro de performance — 70-80% da RAM em produção |
| `mysql_root_password` | `Admin#!123` | **Sobrescrever em produção** via `host_vars` ou Ansible Vault |
| `mysql_skip_name_resolve` | `true` | Desabilita DNS — hosts em `mysql_user.host` devem ser IPs ou `%` |
| `mysql_local_infile` | `0` | Segurança — impede `LOAD DATA LOCAL INFILE` |
| `mysql_symbolic_links` | `0` | Segurança — desabilita links simbólicos em tablespaces |
| `mysql_bind_address` | IP da VM | Aceitar conexões externas além do localhost |
| `mysql_max_connections` | `300` | Máximo de conexões simultâneas |

---

## Variáveis do survey AWX — mysql_manage_users

| Variável | Descrição | Exemplo |
|---|---|---|
| `db_username` | Nome do usuário | `app_user` |
| `db_user_host` | Host de acesso (`%` = qualquer) | `%` ou `192.168.1.0/255.255.255.0` |
| `db_password` | Senha | `MinhaSenh@123` |
| `db_privileges` | Privilégios | `SELECT,INSERT,UPDATE` |
| `db_target_databases` | Bancos alvo | `appdb,logs` |
| `db_user_state` | `present` / `absent` | `present` |
| `db_revoke_access` | `true` = revoga sem remover o usuário | `false` |
| `db_append_privileges` | `true` = adiciona sem substituir grants | `false` |
| `db_manage_databases` | `true` = cria os bancos se não existirem | `false` |

---

## Observações de design

### Por que `python3-PyMySQL` é obrigatório?
Os módulos `community.mysql.*` não fazem chamadas diretas ao MySQL — usam a biblioteca Python PyMySQL. Sem ela, qualquer task de usuário/banco falha com `"A MySQL module is required"`.

### Por que cluster NTFS de 64 KB? (não se aplica aqui — ver sqlserver_guide.md)

### Por que hardening remove usuários anônimos?
Instalações MySQL criam um usuário com nome vazio por padrão. Ele permite conexão sem senha. O role remove via `state: absent` com `name: ''`.
