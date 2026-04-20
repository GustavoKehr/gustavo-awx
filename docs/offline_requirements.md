# Requisitos para Ambiente Offline

Guia passo a passo para preparar todos os artefatos necessários para execução em ambiente **sem internet**.

> **Para iniciantes:** Este projeto roda em VMs que não têm acesso à internet. Tudo o que o Ansible precisa (coleções, pacotes, binários, imagens de container) deve estar disponível localmente antes da execução.

---

## Visão Geral do que é Necessário

```
┌────────────────────────────────────────────────────────────────┐
│  Necessário offline:                                           │
│                                                                │
│  1. Coleções Ansible → /opt/collections/ no AWX EE            │
│  2. Pacotes RPM → repositoryvm (192.168.137.148:8080)         │
│  3. Binários Oracle → /opt/oracle/ no AWX VM                  │
│  4. ISO SQL Server → repositoryvm                             │
│  5. Imagem EE do AWX → podman no host AWX                     │
└────────────────────────────────────────────────────────────────┘
```

---

## 1. Coleções Ansible

As coleções são extensões do Ansible com módulos extras. Sem elas, os módulos `community.mysql.*`, `community.postgresql.*`, etc. não existem.

### 1.1 Instalar em máquina COM internet

```bash
# Rodar em máquina com acesso à internet:
ansible-galaxy collection install -r collections/requirements.yml -p /opt/collections

# Isso cria a estrutura:
# /opt/collections/ansible_collections/
#   ├── community/mysql/
#   ├── community/postgresql/
#   ├── community/windows/
#   ├── ansible/windows/
#   └── community/general/
```

### 1.2 Copiar para o AWX VM

```bash
# Opção A: SCP direto
scp -r /opt/collections/ansible_collections/ user_aap@192.168.137.153:/opt/collections/

# Opção B: tar + scp
tar czf collections.tar.gz -C /opt/collections ansible_collections/
scp collections.tar.gz user_aap@192.168.137.153:/tmp/
ssh user_aap@192.168.137.153 "sudo mkdir -p /opt/collections && sudo tar xzf /tmp/collections.tar.gz -C /opt/collections/"
```

### 1.3 Verificar coleções disponíveis offline

```bash
# No AWX VM:
ansible-galaxy collection list --collections-path /opt/collections

# Saída esperada:
# community.mysql    1.x.x
# community.postgresql  3.x.x
# ansible.windows    2.x.x
# ...
```

### 1.4 Configurar AWX para não buscar na internet

1. AWX → **Projects** → `gustavo-awx`
2. **Edit** → desmarcar **"Update Revision on Launch"**
3. **Source Control** → desmarcar **"Clean"** e **"Delete on Update"**
4. Verificar que `ansible.cfg` tem `collections_paths = /opt/collections:~/.ansible/collections`

---

## 2. Pacotes de Sistema Operacional (RHEL 9)

Os servidores de banco precisam de pacotes instalados durante a automação. Em RHEL sem internet, esses pacotes devem estar em um repositório local.

### 2.1 Pacotes necessários por engine

| Engine | Pacotes RHEL |
|---|---|
| **MySQL** | `mysql-server`, `python3-PyMySQL` |
| **PostgreSQL** | `postgresql-server`, `postgresql`, `python3-psycopg2` |
| **Oracle** | `oracle-database-preinstall-19c` (via RPM local) |
| **Baseline** | `vim`, `wget`, `curl`, `chrony`, `tcpdump`, `lsof`, `net-tools` |

### 2.2 Configurar `repositoryvm` como mirror

O `repositoryvm` (192.168.137.148) serve como mirror HTTP interno:

```bash
# No repositoryvm — criar repositório local RHEL:
sudo dnf install createrepo_c httpd

# Baixar pacotes com dependências (em máquina com internet):
dnf download --resolve --downloaddir=/var/www/html/rhel9/ mysql-server python3-PyMySQL postgresql-server postgresql python3-psycopg2

# Criar metadata do repositório:
createrepo /var/www/html/rhel9/

# Iniciar servidor HTTP:
systemctl enable --now httpd
```

### 2.3 Configurar os hosts para usar o mirror

Criar arquivo de repositório em cada host alvo:

```ini
# /etc/yum.repos.d/local-mirror.repo
[local-mirror]
name=Local Mirror
baseurl=http://192.168.137.148/rhel9/
enabled=1
gpgcheck=0
```

O template Ansible em `roles/baseline_system/` faz isso automaticamente.

---

## 3. Binários Oracle 19c

A instalação Oracle requer ~8 GB de binários e patches. Eles ficam em `/opt/oracle` no AWX VM e são transferidos para `oraclevm` via rsync.

### 3.1 Estrutura esperada em `/opt/oracle`

```
/opt/oracle/
├── LINUX.X64_193000_db_home.zip          ← ~3 GB — binários Oracle 19c
├── oracle-database-preinstall-19c-1.0.2.el9.x86_64.rpm
├── p6880880/                              ← OPatch substituto
│   └── OPatch/
├── p37641958/                             ← Release Update (RU)
│   └── 37641958/
│       ├── 37642901/                      ← patch RU
│       └── 37643161/                      ← patch one-off
├── p38291812/                             ← post-install patch 1
│   └── 38291812/
├── p32249704/                             ← post-install patch 2
│   └── 32249704/
└── p3467298/                              ← post-install patch 3
    └── 3467298/
```

### 3.2 Transferir para o AWX VM

```bash
# SCP de máquina local para AWX VM:
scp -r /local/oracle/ user_aap@192.168.137.153:/opt/oracle/

# Verificar estrutura no AWX:
ssh user_aap@192.168.137.153 "ls -la /opt/oracle/"
```

### 3.3 Verificar que o EE tem acesso ao /opt/oracle

O Execution Environment do AWX deve ter `/opt/oracle` montado. Verificar no AWX:

```bash
# No awxvm — verificar mount do EE:
sudo /usr/local/bin/kubectl exec -n awx <pod-task> -- ls /opt/oracle/
```

---

## 4. ISO SQL Server

O SQL Server é instalado a partir de um ISO baixado do `repositoryvm`.

### 4.1 Obter ISO

- Baixar de: [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-sql-server-2022) (máquina com internet)
- Colocar em `repositoryvm` em `/var/www/html/sql/`

### 4.2 Verificar acesso

```bash
# Testar que o repositoryvm serve o ISO:
curl -I http://192.168.137.148:8080/SQLServer2022-x64-ENU.iso
# Deve retornar HTTP 200
```

---

## 5. Imagem do Execution Environment (EE) AWX

AWX executa jobs em containers. A imagem `AWX EE 24.6.1` deve estar disponível localmente.

### 5.1 Exportar em máquina com internet

```bash
# Puxar a imagem:
podman pull ghcr.io/ansible/awx-ee:24.6.1

# Exportar como arquivo:
podman save ghcr.io/ansible/awx-ee:24.6.1 -o awx-ee-24.6.1.tar

# Compactar (opcional — ~3 GB → ~1 GB):
gzip awx-ee-24.6.1.tar
```

### 5.2 Importar no host AWX

```bash
# Copiar para awxvm:
scp awx-ee-24.6.1.tar.gz user_aap@192.168.137.153:/tmp/

# Importar no Podman:
ssh user_aap@192.168.137.153 "sudo podman load -i /tmp/awx-ee-24.6.1.tar.gz"

# Verificar:
ssh user_aap@192.168.137.153 "sudo podman images | grep awx-ee"
```

### 5.3 Configurar no AWX

1. AWX → **Execution Environments** → **Add**
2. Nome: `AWX EE 24.6.1`
3. Image: `ghcr.io/ansible/awx-ee:24.6.1` (apontando para imagem local)
4. Pull: `Never` (não tentar baixar da internet)

---

## 6. Checklist de Replicação para Novo Ambiente

Use este checklist ao replicar o projeto para um ambiente offline do zero:

### Pré-requisitos de infraestrutura

- [ ] Proxmox ligado e acessível
- [ ] `awxvm` ligado (192.168.137.153) — AWX acessível em :80
- [ ] `repositoryvm` ligado (192.168.137.148) — HTTP em :8080
- [ ] Hosts alvo ligados e SSH acessível com `user_aap`

### Coleções Ansible

- [ ] Coleções instaladas e copiadas para `/opt/collections/` no AWX VM
- [ ] Estrutura verificada: `ls /opt/collections/ansible_collections/`
- [ ] AWX Project configurado sem "Update on Launch" e sem "Install collections"
- [ ] `ansible.cfg` com `collections_paths = /opt/collections:~/.ansible/collections`

### Pacotes de SO

- [ ] `repositoryvm` configurado como mirror RPM com createrepo
- [ ] Pacotes MySQL e PostgreSQL disponíveis no mirror
- [ ] Hosts alvo configurados com `local-mirror.repo` apontando para repositoryvm

### Oracle (se aplicável)

- [ ] Todos os binários em `/opt/oracle/` no AWX VM
- [ ] Estrutura de diretórios verificada com `ls -la /opt/oracle/`
- [ ] EE tem `/opt/oracle` montado (verificar via kubectl exec)

### SQL Server (se aplicável)

- [ ] ISO SQL Server em `repositoryvm` acessível via HTTP
- [ ] URL de download configurada nos defaults do role `sql_pre_reqs`

### AWX Execution Environment

- [ ] Imagem `awx-ee:24.6.1` importada no Podman do awxvm
- [ ] EE configurado no AWX com Pull = "Never"
- [ ] Job Templates usando o EE correto

### Validação final

- [ ] `ansible all -m ping` — todos os hosts respondem
- [ ] Dry-run de um playbook: `ansible-playbook deploy_mysql.yml --check -l mysqlvm`
- [ ] AWX Job Template de teste executa sem erros de coleção

---

## Verificação de Conectividade SSH

```bash
# Testar SSH em todos os hosts:
ansible all -m ping

# Saída esperada:
# mysqlvm | SUCCESS => {"ping": "pong"}
# postgresvm | SUCCESS => {"ping": "pong"}
# oraclevm | SUCCESS => {"ping": "pong"}
# repositoryvm | SUCCESS => {"ping": "pong"}
```

Se algum host falhar:
1. Verificar se a VM está ligada no Proxmox
2. Verificar se o usuário `user_aap` existe: `ssh user_aap@<IP>`
3. Verificar sudo sem senha: `ssh user_aap@<IP> sudo whoami` (deve retornar `root`)

---

## Ver Também

- [`general_guide.md`](general_guide.md) — Arquitetura geral do projeto
- [`awx_surveys.md`](awx_surveys.md) — Referência de templates e surveys
- [`oracle_guide.md`](oracle_guide.md) — Detalhes dos binários Oracle necessários
