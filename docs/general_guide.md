# Guia Geral — Ansible & AWX

Referência técnica de configuração base, módulos universais e comandos frequentes.
Parte do conjunto: `general_guide.md` · `mysql_guide.md` · `postgres_guide.md` · `sqlserver_guide.md` · `oracle_guide.md`

---

## ansible.cfg

```ini
host_key_checking = False        # Desabilitar em lab; HABILITAR em produção
remote_user = user_aap           # Usuário com sudo NOPASSWD em todos os hosts
collections_paths = /opt/collections:~/.ansible/collections
                                 # /opt/collections = caminho offline no AWX EE
```

---

## Inventário

```bash
ansible-inventory --list          # JSON com todos os hosts e variáveis
ansible-inventory --graph         # Hierarquia de grupos em árvore
ansible all -m ping               # Testar conectividade com todos os hosts
ansible database_servers -m ping  # Testar apenas grupo database_servers
```

---

## Módulos universais

### Pacotes e serviços

| Módulo | Uso no projeto | Nota |
|---|---|---|
| `ansible.builtin.package` | Instalar pacotes (agnóstico ao SO) | Usa dnf/apt conforme o OS |
| `ansible.builtin.dnf` | Instalar RPM com `disable_gpg_check: true` | Para repositórios internos sem GPG |
| `ansible.builtin.service` | Iniciar/habilitar serviços | `started` + `enabled: true` = inicia agora + persiste no boot |

### Arquivos e configuração

| Módulo | Uso no projeto | Nota |
|---|---|---|
| `ansible.builtin.file` | Criar diretórios, definir `owner:group:mode` | `recurse: true` aplica em toda a subárvore |
| `ansible.builtin.template` | Gerar arquivos de configuração via Jinja2 | Cada host pode receber conteúdo diferente |
| `ansible.builtin.copy` | Copiar arquivos para o host | `remote_src: true` = source já está no host remoto |
| `ansible.builtin.lineinfile` | Modificar linhas específicas em arquivos de config | `regexp` usa regex para localizar linha existente |
| `ansible.posix.synchronize` | Transferir arquivos grandes via rsync | Muito mais eficiente que `copy` para binários grandes |
| `ansible.builtin.unarchive` | Descompactar arquivos no host remoto | `creates:` torna idempotente |

### Execução de comandos

| Módulo | Quando usar | Restrição |
|---|---|---|
| `ansible.builtin.command` | Comandos simples sem shell: `sysctl --system` | Sem pipes, redirects, ou variáveis de ambiente |
| `ansible.builtin.shell` | Comandos com `export`, `\|`, `>`, heredocs | Usa /bin/sh — necessário para operações complexas |

**Padrões de idempotência para command/shell:**
```yaml
# Usando 'creates':
- command: mv /etc/init.d /etc/initd.back
  args:
    creates: /etc/initd.back

# Usando 'changed_when':
- shell: opatch lsinventory
  changed_when: false   # verificação, nunca "muda" nada

# Usando 'failed_when' para códigos de saída especiais:
- shell: "{{ oracle_home }}/runInstaller -silent ..."
  register: result
  failed_when: result.rc not in [0, 6]   # rc=6 = sucesso com avisos
```

---

## Playbook de entrada unificada — 01_db_provisioning.yml

```bash
ansible-playbook playbooks/01_db_provisioning.yml -e "db_type=mysql"
ansible-playbook playbooks/01_db_provisioning.yml -e "db_type=postgres"
ansible-playbook playbooks/01_db_provisioning.yml -e "db_type=oracle"
```

Seleciona o playbook de engine correspondente via variável `db_type`.

---

## Comandos de uso frequente

```bash
# --- Diagnóstico ---
ansible-playbook <playbook>.yml --list-hosts    # quais hosts serão afetados
ansible-playbook <playbook>.yml --list-tasks    # quais tasks serão executadas
ansible-playbook <playbook>.yml --list-tags     # quais tags estão disponíveis
ansible-playbook <playbook>.yml --check         # dry run (não altera nada)
ansible-playbook <playbook>.yml --check --diff  # dry run + mostra diffs de arquivo

# --- Execução controlada ---
ansible-playbook <playbook>.yml -l <host>         # limitar a um host específico
ansible-playbook <playbook>.yml --tags <tag>      # executar só essa fase
ansible-playbook <playbook>.yml --skip-tags <tag> # pular essa fase
ansible-playbook <playbook>.yml -e "var=valor"    # passar variável extra
ansible-playbook <playbook>.yml -v/-vv/-vvv       # verbosidade crescente

# --- Inventário ---
ansible-inventory --list                          # dump JSON do inventário
ansible all -m ping                               # testar todos os hosts
ansible all -m setup | grep ansible_os_family    # coletar facts dos hosts

# --- Collections offline ---
ansible-galaxy collection install -r collections/requirements.yml -p /opt/collections
ansible-galaxy collection list

# --- Debug de variáveis ---
# Adicionar task temporária:
# - debug:
#     var: mysql_priv_scope
```

---

## Decisões de design globais

### Por que portas não padrão (13306, 15432)?
Reduz ruído de scanners automatizados. Não é segurança real, mas complementa firewall e ACLs.

### Por que `no_log: true` em tasks de usuário?
Senhas em texto plano aparecem nos logs do AWX, `journalctl`, e sistemas de auditoria. `no_log` suprime o output da task inteira.

### Por que `db_patch_apply_enabled: false` hardcoded?
Patches de banco são operações de alto risco. A descoberta é segura para automatizar; a aplicação requer revisão manual e janela de manutenção.

### Por que `append_privs: false` no MySQL?
O comportamento padrão substitui todos os grants existentes, garantindo que o estado final é exatamente o solicitado no survey — sem grants "fantasma" de execuções anteriores.
