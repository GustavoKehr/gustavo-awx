# MySQL — Runbook Operacional AWX

Guia prático para executar operações de gestão de usuários MySQL via AWX Job Templates.

> **Para iniciantes:** Este runbook contém os passos exatos para criar, modificar e remover usuários no MySQL usando o AWX. Você não precisará digitar comandos no servidor — basta preencher o formulário (survey) e clicar em "Launch".

---

## Pré-requisitos

Antes de executar qualquer job:

1. **MySQL instalado** em `mysqlvm` (192.168.137.160, porta 13306)
2. **AWX sincronizado** com o repositório GitHub (`gustavo-awx` project)
3. **Credencial Machine** configurada no AWX (usuário `user_aap`)
4. **Job Template** configurado com o survey correto

---

## Job Template AWX — Configuração

Para o playbook `manage_mysql_users.yml`:

| Campo AWX | Valor |
|---|---|
| **Name** | `MYSQL \| Manage Users` |
| **Playbook** | `playbooks/manage_mysql_users.yml` |
| **Inventory** | `LINUX` |
| **Credentials** | `Machine: user_aap` |
| **Limit** | `mysqlvm` |
| **Extra Variables** | `mysql_manage_users_enabled: true` |
| **Survey** | Associar `awx_survey_mysql_manage_users.json` |

---

## Tag Map — O que Cada Tag Faz

| Tag | O que executa | Quando usar |
|---|---|---|
| `mysql` | Todas as tasks MySQL | Raramente — muito abrangente |
| `mysql_install` | Instala e configura o servidor | Primeira instalação |
| `mysql_users` | Todo o ciclo de gestão de usuários | Operação padrão |
| `mysql_users_validate` | Valida variáveis de entrada | Debug de erros |
| `mysql_db` | Cria/remove bancos de dados | Isolado com manage_databases=true |
| `mysql_grants` | Concede privilégios | Adicionar acesso a novo banco |
| `mysql_revoke` | Revoga privilégios | Remover acesso sem deletar usuário |
| `mysql_remove_user` | Remove o usuário | Quando state=absent |
| `db_patches` | Descoberta de patches | Verificação de patches |

---

## Cenários de Uso

### Cenário 1: Criar usuário de leitura para aplicação

**Situação:** Aplicação precisa ler dados do banco `appdb`.

| Campo | Valor |
|---|---|
| MySQL username | `webapp_reader` |
| Host de acesso | `%` |
| Password | `Reader#2024!` |
| User state | `present` |
| Privileges | `SELECT` |
| Target databases | `appdb` |
| Revoke access | `false` |
| Append privileges | `true` |
| Create databases | `false` |

**SQL equivalente:**
```sql
CREATE USER 'webapp_reader'@'%' IDENTIFIED BY '***';
GRANT SELECT ON appdb.* TO 'webapp_reader'@'%';
FLUSH PRIVILEGES;
```

---

### Cenário 2: Criar usuário com escrita completa

**Situação:** Serviço precisa ler e escrever no banco.

| Campo | Valor |
|---|---|
| MySQL username | `webapp` |
| Host de acesso | `192.168.1.50` |
| Password | `App#Secure2024!` |
| User state | `present` |
| Privileges | `SELECT,INSERT,UPDATE,DELETE` |
| Target databases | `appdb` |
| Revoke access | `false` |
| Append privileges | `false` |
| Create databases | `false` |

> **Nota:** `Append privileges: false` substitui todos os grants existentes pelos novos. Use quando quiser garantir exatamente os privilégios definidos.

---

### Cenário 3: Criar banco + usuário ao mesmo tempo

**Situação:** Nova aplicação do zero — banco e usuário ainda não existem.

| Campo | Valor |
|---|---|
| MySQL username | `newapp` |
| Host de acesso | `%` |
| Password | `NewApp#2024` |
| User state | `present` |
| Privileges | `SELECT,INSERT,UPDATE,DELETE` |
| Target databases | `newappdb` |
| Revoke access | `false` |
| Append privileges | `true` |
| **Create databases** | `true` |

**Ordem de execução:**
1. Cria o banco `newappdb`
2. Cria o usuário `newapp`
3. Concede `SELECT,INSERT,UPDATE,DELETE` em `newappdb.*`

---

### Cenário 4: Revogar acesso sem remover usuário

**Situação:** Usuário não deve mais ter acesso ao banco, mas a conta deve continuar existindo.

| Campo | Valor |
|---|---|
| MySQL username | `webapp` |
| Host de acesso | `%` |
| Password | *(deixar vazio)* |
| User state | `present` |
| Privileges | `SELECT,INSERT` |
| Target databases | `appdb` |
| **Revoke access** | `true` |
| Append privileges | `true` |
| Create databases | `false` |

```sql
-- Executado pelo playbook:
REVOKE SELECT, INSERT ON appdb.* FROM 'webapp'@'%';
```

---

### Cenário 5: Remover usuário completamente

**Situação:** Funcionário saiu — remover conta do banco.

| Campo | Valor |
|---|---|
| MySQL username | `webapp` |
| Host de acesso | `%` |
| Password | *(qualquer valor)* |
| **User state** | `absent` |
| Privileges | `SELECT` |
| Target databases | `appdb` |
| Revoke access | `false` |
| Append privileges | `true` |
| Create databases | `false` |

```sql
-- Executado pelo playbook:
DROP USER 'webapp'@'%';
```

---

## Checklist de Verificação Pós-Job

```bash
# SSH no servidor MySQL
ssh user_aap@192.168.137.160

# Verificar usuário criado
mysql -u root -p -e "SELECT user, host FROM mysql.user WHERE user='webapp';"

# Verificar privilégios
mysql -u root -p -e "SHOW GRANTS FOR 'webapp'@'%';"

# Testar conexão com o novo usuário
mysql -u webapp -p -h 192.168.137.160 -P 13306 appdb -e "SHOW TABLES;"
```

---

## Troubleshooting de Jobs

### Job falha: `A MySQL module is required`

**Causa:** PyMySQL não instalado.

```bash
# Instalar no servidor:
sudo dnf install python3-PyMySQL     # RHEL
sudo apt install python3-pymysql     # Debian
```

---

### Usuário criado mas não consegue conectar

**Causa comum 1:** Host do usuário não corresponde ao IP de origem.
```sql
-- Verificar como o usuário foi criado:
SELECT user, host FROM mysql.user WHERE user='webapp';
-- Se mostra 'webapp'@'192.168.1.50' mas app conecta de outro IP, é o problema.
```

**Causa comum 2:** Porta errada. MySQL está em `13306`, não em `3306`.
```bash
mysql -u webapp -p -h 192.168.137.160 -P 13306 appdb
#                                              ^ porta não padrão
```

---

### AWX não encontra o host `mysqlvm`

**Causa:** Inventory não sincronizado.

**Solução:**
1. AWX → Inventories → LINUX → Sync
2. Verificar se `mysqlvm` (192.168.137.160) está acessível: `ping 192.168.137.160`

---

## Execução via CLI (fora do AWX)

```bash
ansible-playbook playbooks/manage_mysql_users.yml \
  -l mysqlvm \
  -e "mysql_manage_users_enabled=true" \
  -e "db_username=webapp" \
  -e "db_user_host=%" \
  -e "db_password=App#Secure2024!" \
  -e "db_user_state=present" \
  -e "db_privileges=SELECT,INSERT,UPDATE,DELETE" \
  -e "db_target_databases=appdb" \
  -e "db_revoke_access=false" \
  -e "db_append_privileges=true" \
  -e "db_manage_databases=false"
```

---

## Ver Também

- [`mysql_guide.md`](mysql_guide.md) — Documentação técnica completa
- [`awx_surveys.md`](awx_surveys.md) — Referência de todos os surveys AWX
- [`general_guide.md`](general_guide.md) — Arquitetura geral do projeto
