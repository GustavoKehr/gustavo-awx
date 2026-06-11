# Referência Completa do Playbook — Stack de Observabilidade

**Versão documentada:** Loki 3.6 · Grafana 13.0 · Prometheus 3.11 · Alloy 1.9  
**Última atualização:** 2026-06-10  
**Objetivo:** Documentar como o playbook funciona internamente e como replicá-lo em um ambiente corporativo sem internet.

---

## Índice

1. [Visão geral da arquitetura](#1-visão-geral-da-arquitetura)
2. [Estrutura de diretórios](#2-estrutura-de-diretórios)
3. [Inventário e grupos de hosts](#3-inventário-e-grupos-de-hosts)
4. [Variáveis e configuração](#4-variáveis-e-configuração)
5. [Como cada playbook funciona](#5-como-cada-playbook-funciona)
6. [Como cada role funciona](#6-como-cada-role-funciona)
7. [Lógica air-gapped (artefatos locais)](#7-lógica-air-gapped-artefatos-locais)
8. [Checklist para replicar no trabalho](#8-checklist-para-replicar-no-trabalho)
9. [Adaptar para outro ambiente](#9-adaptar-para-outro-ambiente)
10. [Referência rápida de variáveis](#10-referência-rápida-de-variáveis)
11. [Tags disponíveis](#11-tags-disponíveis)
12. [Solução de problemas](#12-solução-de-problemas)

---

## 1. Visão geral da arquitetura

```
CONTROLLER (máquina com Ansible)
  └─ /opt/observability-artifacts/     ← todos os binários pré-baixados
       loki-linux-amd64.zip
       grafana-enterprise-13.0.0-1.x86_64.rpm
       prometheus-3.11.0.linux-amd64.tar.gz
       alloy-1.9.0.amd64.rpm
       node_exporter-1.11.0.linux-amd64.tar.gz

SERVIDOR DE OBSERVABILIDADE (obs-server)
  ├─ Loki :3100          ← banco de logs
  ├─ Prometheus :9090    ← banco de métricas
  └─ Grafana :3000        ← interface visual (dashboard + alertas)

AGENTES LINUX (obs-agent1, obs-agent2, ...)
  └─ Grafana Alloy :12345 (UI)
       ├─ Coleta logs via journald  →  envia para Loki
       ├─ Coleta logs de arquivos  →  envia para Loki
       └─ Coleta métricas do SO    →  envia para Prometheus
```

**Fluxo de dados:**
- Logs: `Alloy → Loki` (protocolo: HTTP/push via `/loki/api/v1/push`)
- Métricas: `Alloy → Prometheus` (protocolo: HTTP/push via `/api/v1/write`)
- Dashboards: `Grafana → consulta Loki e Prometheus` (datasources provisionados automaticamente)

**Por que Alloy e não Promtail/Grafana Agent?**  
Promtail e Grafana Agent foram descontinuados. Alloy é o substituto oficial unificado — coleta logs E métricas com um único agente.

---

## 2. Estrutura de diretórios

```
observability-stack/
├── site.yml                          ← entrada única: chama todos os playbooks em ordem
├── requirements.yml                  ← collections Ansible necessárias
│
├── playbooks/
│   ├── 00_preflight.yml              ← fase 0: validações pré-deploy
│   ├── 10_observability_server.yml   ← fase 1: instala servidor (Loki + Grafana + Prometheus)
│   ├── 20_linux_agents.yml           ← fase 2: instala agentes Linux (Alloy)
│   └── 30_windows_agents.yml         ← fase 3: (opcional) agentes Windows
│
├── inventories/
│   └── production/
│       ├── hosts.yml                 ← lista de hosts e grupos
│       └── group_vars/
│           ├── all.yml               ← variáveis globais (versões, endpoints, portas)
│           ├── observability_server.yml  ← variáveis só para o servidor
│           ├── linux_agents.yml          ← variáveis só para agentes Linux
│           └── windows_agents.yml        ← variáveis só para agentes Windows
│
├── roles/
│   ├── preflight/                    ← validações (OS, arquitetura, sudo, artefatos, portas)
│   ├── loki/                         ← instala e configura Loki
│   ├── grafana/                      ← instala e configura Grafana
│   ├── prometheus/                   ← instala e configura Prometheus
│   ├── alloy/                        ← instala e configura Alloy (Linux + Windows)
│   └── node_exporter/                ← (opcional) Node Exporter separado
│
└── docs/
    ├── instalacao_airgapped.md       ← guia completo de instalação sem internet
    ├── guia_operacoes.md             ← LogQL, PromQL, dashboards, alertas
    └── playbook_referencia.md        ← este arquivo
```

---

## 3. Inventário e grupos de hosts

O arquivo de inventário (`inventories/production/hosts.yml`) define três grupos:

```yaml
all:
  children:
    observability_server:     # recebe: Loki + Grafana + Prometheus
      hosts:
        obs-server:
          ansible_host: 192.168.137.200

    linux_agents:             # recebe: Alloy (+ Node Exporter se metrics_mode=node_exporter)
      hosts:
        obs-agent1:
          ansible_host: 192.168.137.201
        obs-agent2:
          ansible_host: 192.168.137.202

    windows_agents:           # recebe: Alloy para Windows (desativado por padrão)
      hosts: {}
```

**Regras de grupos:**
- Um host **pode** estar em `observability_server` E `linux_agents` ao mesmo tempo (servidor monitora a si mesmo).
- `windows_agents` vazio não causa erro — plays com grupo vazio são pulados automaticamente.
- Cada grupo tem seu próprio `group_vars/` com variáveis específicas.

---

## 4. Variáveis e configuração

### Hierarquia de variáveis (ordem de precedência — menor para maior)

```
defaults/main.yml de cada role
        ↓
group_vars/all.yml
        ↓
group_vars/<grupo>.yml
        ↓
host_vars/<host>.yml
        ↓
extra_vars (-e) passados na linha de comando
```

### Variáveis principais em `group_vars/all.yml`

| Variável | Valor padrão | Descrição |
|---|---|---|
| `artifacts_base_dir` | `/opt/observability-artifacts` | Onde os binários estão no controller |
| `loki_version` | `3.6.0` | Versão do Loki |
| `grafana_version` | `13.0.0` | Versão do Grafana |
| `prometheus_version` | `3.11.0` | Versão do Prometheus |
| `alloy_version` | `1.9.0` | Versão do Alloy |
| `metrics_mode` | `alloy` | `alloy` = Alloy faz push / `node_exporter` = scrape separado |
| `loki_endpoint` | `http://<IP>:3100/loki/api/v1/push` | URL de push para o Loki |
| `prometheus_remote_write_endpoint` | `http://<IP>:9090/api/v1/write` | URL de push para o Prometheus |
| `loki_retention_period` | `720h` (30 dias) | Retenção de logs |
| `prometheus_retention` | `30d` | Retenção de métricas |
| `environment_label` | `prod` | Label `env=` aplicada a todos os dados |
| `alloy_log_paths` | lista de caminhos | Arquivos de log coletados pelos agentes |

### Variáveis sensíveis (não colocar em texto puro)

```yaml
# Nunca coloque em all.yml ou group_vars/
# Use ansible-vault ou AWX Credentials:
grafana_admin_password: "{{ vault_grafana_admin_password }}"
```

---

## 5. Como cada playbook funciona

### `site.yml` — Entrada única

```yaml
- import_playbook: playbooks/00_preflight.yml
- import_playbook: playbooks/10_observability_server.yml
- import_playbook: playbooks/20_linux_agents.yml
- import_playbook: playbooks/30_windows_agents.yml
```

Executa tudo em sequência. Útil para um deploy completo do zero. Para atualizar só um componente, rode o playbook específico com tag.

---

### `00_preflight.yml` — Validações pré-deploy

**Hosts alvo:** `observability_server` + `linux_agents` + `windows_agents`  
**Tag:** `preflight`

Executa a role `preflight` que faz:

1. **OS suportado** — falha se não for RHEL 8+, Rocky, AlmaLinux, Ubuntu 20.04+
2. **Arquitetura** — exige `x86_64`
3. **Sudo** — executa `id` com `become: true` e verifica se retornou `uid=0(root)`
4. **Artefatos** — para cada host, verifica se o arquivo de instalação existe no controller; valida SHA256 se checksum configurado
5. **NTP** — avisa (não falha) se o relógio não está sincronizado (logs com timestamp errado são rejeitados pelo Loki)
6. **Portas** — verifica se as portas 3100, 3000, 9090 estão livres no servidor
7. **Disco** — exige 10+ GB livres em `/` ou `/var` no servidor

**Como a verificação de artefatos funciona:**

```yaml
# Mapa: host → lista de arquivos esperados
_preflight_artifact_map:
  _all:                                    # aplicado a todos os agentes Linux
    - file: alloy-1.9.0.amd64.rpm
      when: "{{ ansible_os_family == 'RedHat' }}"   # só verifica em RHEL
    - file: alloy-1.9.0.amd64.deb
      when: "{{ ansible_distribution == 'Ubuntu' }}"  # só verifica em Ubuntu
```

O `when:` dentro do item controla se a verificação deve ocorrer. Sem esse guarda, o preflight falharia em hosts RHEL tentando encontrar um `.deb` que não existe.

---

### `10_observability_server.yml` — Servidor central

**Hosts alvo:** `observability_server`  
**Tag:** `server`

Executa as roles em ordem:

```
loki (tag: loki) → grafana (tag: grafana) → prometheus (tag: prometheus)
```

A ordem importa: Grafana precisa ter o Loki e o Prometheus rodando para que os healthchecks dos datasources funcionem na primeira inicialização.

---

### `20_linux_agents.yml` — Agentes Linux

**Hosts alvo:** `linux_agents`  
**Tag:** `agents`

Executa:

```
alloy (tag: alloy) → node_exporter (tag: node_exporter, se metrics_mode=node_exporter)
```

O `node_exporter` é completamente pulado quando `metrics_mode: alloy` (padrão), pois o Alloy já exporta as métricas via `prometheus.exporter.unix` interno.

---

## 6. Como cada role funciona

### Role: `preflight`

```
tasks/main.yml
├── Verifica OS, arch, sudo
├── Constrói lista de artefatos para este host (set_fact)
├── stat dos arquivos no controller (delegate_to: localhost)
├── Falha se arquivo ausente E when: true
├── Falha se checksum diverge
├── Verifica NTP (timedatectl)
├── Verifica portas livres (wait_for state: stopped)
└── Verifica disco (ansible_mounts)
```

**defaults/main.yml:**
```yaml
preflight_supported_distributions: [RedHat, Rocky, AlmaLinux, CentOS, Ubuntu, Debian]
preflight_min_rhel_version: "8"
preflight_min_ubuntu_version: "20.04"
preflight_server_ports: [3100, 3000, 9090]
```

---

### Role: `loki`

```
tasks/main.yml
├── Cria grupo de sistema: loki
├── Cria usuário de sistema: loki (sem shell, sem home)
├── Cria diretórios: /etc/loki, /var/lib/loki/{chunks,rules,compactor,wal}
├── Verifica artefato no controller (delegate_to: localhost)
├── Extrai .zip no controller (delegate_to: localhost) → evita precisar de 'unzip' no host
├── Copia binário para /usr/local/bin/loki
├── Deploy config via template: /etc/loki/config.yml
├── Deploy systemd unit: /etc/systemd/system/loki.service
├── Habilita e inicia serviço
├── Aguarda healthcheck: GET /ready (10 tentativas, intervalo 5s)
└── Remove diretório temporário no controller

templates/
├── config.yml.j2      ← configuração monolítica TSDB, schema v13
└── loki.service.j2    ← systemd unit
```

**Por que extrair no controller?**  
Loki é distribuído como `.zip`. O AlmaLinux/RHEL 9 minimal não tem `unzip`. Ao usar `delegate_to: localhost`, o Ansible executa a extração na máquina controller (onde o `unzip` está disponível) e depois copia só o binário para o host remoto.

**Configuração gerada (`/etc/loki/config.yml`):**
```yaml
auth_enabled: false
server:
  http_listen_port: 3100
  grpc_listen_port: 9096
ingester:
  wal:
    dir: /var/lib/loki/wal
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
storage_config:
  tsdb_shipper:
    active_index_directory: /var/lib/loki/tsdb-index
    cache_location: /var/lib/loki/tsdb-cache
  filesystem:
    directory: /var/lib/loki/chunks
compactor:
  working_directory: /var/lib/loki/compactor
limits_config:
  retention_period: "{{ loki_retention_period }}"
```

---

### Role: `grafana`

```
tasks/main.yml
├── include_tasks: install_rhel.yml   (quando ansible_os_family == "RedHat")
│   ├── Verifica RPM no controller
│   ├── Copia RPM para /tmp/ no host
│   ├── Instala via yum (disable_gpg_check: true — pacote local)
│   └── Remove /tmp/grafana.rpm
├── include_tasks: install_debian.yml (quando ansible_os_family == "Debian")
├── Cria diretórios de provisioning e dashboards
├── Deploy /etc/grafana/grafana.ini via template
├── Deploy datasources.yml.j2   → /etc/grafana/provisioning/datasources/
├── Deploy dashboards.yml.j2    → /etc/grafana/provisioning/dashboards/
├── Copia dashboards JSON do controller → /var/lib/grafana/dashboards/
├── Instala plugins locais (se grafana_plugins não vazio)
├── Habilita e inicia grafana-server
└── Aguarda healthcheck: GET /api/health (12 tentativas, intervalo 5s)
```

**Datasources provisionados automaticamente** (`provisioning/datasources/datasources.yml`):
- Loki: `http://localhost:3100`
- Prometheus: `http://localhost:9090`

Isso significa que ao abrir o Grafana pela primeira vez, Loki e Prometheus já aparecem configurados — sem precisar adicionar manualmente.

**`grafana.ini` — partes importantes:**
```ini
[server]
http_port = 3000

[security]
admin_password = {{ grafana_admin_password }}

[unified_alerting]
enabled = true

# [alerting] NÃO existe mais no Grafana 13+
# Colocar [alerting] enabled = true causa erro de startup
```

---

### Role: `prometheus`

```
tasks/main.yml
├── Cria grupo: prometheus
├── Cria usuário: prometheus (sem shell, sem home)
├── Cria diretórios: /etc/prometheus, /var/lib/prometheus
├── Verifica artefato (.tar.gz) no controller
├── Copia arquivo para /tmp/prometheus.tar.gz no host
├── Extrai em /tmp/ (remote_src: true — extração no host, não no controller)
├── Copia binários: prometheus + promtool → /usr/local/bin/
├── Ajusta ownership de /etc/prometheus
├── Deploy /etc/prometheus/prometheus.yml via template (valida com promtool)
├── Deploy /etc/systemd/system/prometheus.service via template
├── Habilita e inicia serviço
├── Aguarda healthcheck: GET /-/ready
└── Remove /tmp/prometheus.tar.gz e /tmp/prometheus-X.X.X.linux-amd64/
```

**Por que o Prometheus precisa de `--web.enable-remote-write-receiver`?**  
No modo `alloy`, o Alloy faz **push** das métricas para o Prometheus (em vez do Prometheus fazer pull). O flag `--web.enable-remote-write-receiver` habilita o endpoint `/api/v1/write` que recebe esses dados.

**Nota:** Prometheus 3.x removeu os diretórios `consoles/` e `console_libraries/` do tarball. Os flags `--web.console.templates` e `--web.console.libraries` foram removidos do service template para evitar erro na inicialização.

---

### Role: `alloy`

```
tasks/main.yml
├── include_tasks: install_linux.yml   (quando Linux)
│   ├── Cria grupo: alloy
│   ├── Cria usuário: alloy (grupos: systemd-journal, adm)
│   ├── Cria /etc/alloy/
│   ├── Verifica RPM no controller
│   ├── Copia RPM para /tmp/ no host
│   ├── Instala via yum
│   └── Remove /tmp/alloy.rpm
├── include_tasks: install_windows.yml (quando Windows)
│
├── include_tasks: configure_linux.yml  (quando Linux)
│   ├── Configura rsyslog para criar logs com permissão 0640 (grupo adm)
│   ├── Corrige permissões de /var/log/{messages,secure,cron} (chmod g+r)
│   ├── Configura /etc/sysconfig/alloy: CUSTOM_ARGS="--server.http.listen-addr=0.0.0.0:12345"
│   ├── Deploy /etc/alloy/config.alloy via template (validado com alloy validate)
│   ├── Habilita e inicia alloy
│   └── Aguarda healthcheck: GET /ready na porta 12345
└── include_tasks: configure_windows.yml (quando Windows)
```

**Por que o usuário alloy precisa do grupo `adm`?**  
Em RHEL/AlmaLinux, os arquivos `/var/log/messages`, `/var/log/secure` e `/var/log/cron` são criados pelo rsyslog com permissão `600 root:root`. Adicionar alloy ao grupo `adm` **e** configurar rsyslog para usar `$FileGroup adm` + `$FileCreateMode 0640` permite que o Alloy leia esses arquivos sem precisar de root.

**Por que `--server.http.listen-addr=0.0.0.0:12345`?**  
Por padrão, o Alloy 1.9 escuta a UI de debug apenas em `127.0.0.1:12345`. Sem esse parâmetro, a UI não é acessível de fora da máquina.

**Configuração Alloy gerada (`/etc/alloy/config.alloy`):**
```hcl
// Loki — endpoint de destino
loki.write "central" {
  endpoint {
    url = "http://192.168.137.200:3100/loki/api/v1/push"
  }
}

// Coleta de logs via systemd journal (cobre TUDO: messages, secure, cron, units)
loki.source.journal "journal" {
  forward_to = [loki.write.central.receiver]
  labels = { job = "systemd-journal", host = "obs-agent1", env = "prod" }
}

// Coleta de arquivos de log específicos
local.file_match "log_files" {
  path_targets = [
    { __path__ = "/var/log/messages" },
    { __path__ = "/var/log/secure" },
    { __path__ = "/var/log/cron" },
    { __path__ = "/var/log/httpd/*" },
    { __path__ = "/opt/tomcat/logs/*" },
  ]
}
loki.source.file "log_files" {
  targets    = local.file_match.log_files.targets
  forward_to = [loki.process.add_labels.receiver]
}
loki.process "add_labels" {
  forward_to = [loki.write.central.receiver]
  stage.static_labels {
    values = { job = "varlogs", host = "obs-agent1", env = "prod" }
  }
}

// Métricas do SO via prometheus.exporter.unix (embutido no Alloy)
prometheus.exporter.unix "host" {}
prometheus.scrape "host_metrics" {
  targets    = prometheus.exporter.unix.host.targets
  forward_to = [prometheus.remote_write.central.receiver]
  job_name   = "node"
}
prometheus.remote_write "central" {
  endpoint {
    url = "http://192.168.137.200:9090/api/v1/write"
  }
  external_labels = { host = "obs-agent1", env = "prod" }
}
```

---

## 7. Lógica air-gapped (artefatos locais)

O playbook foi desenhado para funcionar **100% sem internet**. Nenhuma role faz download em runtime.

### Como funciona a distribuição de artefatos

```
controller (/opt/observability-artifacts/)
    │
    ├─ Loki ZIP → delegate_to: localhost → extrai → copy binário → host remoto
    ├─ Grafana RPM → copy RPM → host remoto → yum install /tmp/grafana.rpm
    ├─ Prometheus tar.gz → copy tar.gz → host remoto → unarchive (remote_src)
    └─ Alloy RPM → copy RPM → host remoto → yum install /tmp/alloy.rpm
```

**Pontos de decisão de extração:**

| Artefato | Extração | Motivo |
|---|---|---|
| Loki (`.zip`) | **No controller** (`delegate_to: localhost`) | `unzip` não disponível no AlmaLinux 9 minimal |
| Prometheus (`.tar.gz`) | **No host remoto** (`remote_src: true`) | `tar` sempre disponível no Linux |
| Grafana (`.rpm`) | **Instalação direta** (`yum install /tmp/`) | yum sabe extrair RPM |
| Alloy (`.rpm`) | **Instalação direta** (`yum install /tmp/`) | yum sabe extrair RPM |

### Validação de integridade (checksums SHA256)

Em `group_vars/all.yml`:

```yaml
artifact_checksums:
  loki: "a172d50e..."
  grafana_rpm: "69fba9d9..."
  prometheus: "ff799c3e..."
  alloy_rpm: "c31eb73a..."
```

Se o checksum estiver preenchido, o playbook valida antes de instalar. Deixar em `""` pula a validação (não recomendado em produção).

**Como obter o checksum:**
```bash
# Linux / Proxmox
sha256sum /opt/observability-artifacts/loki-linux-amd64.zip

# Windows (PowerShell)
Get-FileHash .\loki-linux-amd64.zip -Algorithm SHA256
```

---

## 8. Checklist para replicar no trabalho

### Pré-requisitos no ambiente corporativo

**Máquina controller (onde Ansible roda):**
- [ ] Python 3.8+
- [ ] Ansible Core 2.14+ (`pip install ansible`)
- [ ] `unzip` instalado (para extrair Loki)
- [ ] Acesso SSH às VMs alvo na porta 22
- [ ] Collections instaladas offline (ver abaixo)

**VMs alvo (servidor + agentes):**
- [ ] RHEL 8+, Rocky 8+, AlmaLinux 8+, ou Ubuntu 20.04+
- [ ] Arquitetura x86_64
- [ ] Usuário de serviço com `sudo NOPASSWD:ALL` configurado
- [ ] Python 3 instalado (`yum install python3`)
- [ ] 50 GB disco no servidor, 20 GB nos agentes

---

### Passo 1: Baixar os artefatos na sua máquina (com internet)

```bash
# Criar diretório de artefatos
mkdir -p ~/obs-artifacts

# Loki 3.6.0
curl -L -o ~/obs-artifacts/loki-linux-amd64.zip \
  https://github.com/grafana/loki/releases/download/v3.6.0/loki-linux-amd64.zip

# Grafana Enterprise 13.0.0 (RHEL/AlmaLinux)
curl -L -o ~/obs-artifacts/grafana-enterprise-13.0.0-1.x86_64.rpm \
  https://dl.grafana.com/enterprise/release/grafana-enterprise-13.0.0-1.x86_64.rpm

# Grafana Enterprise 13.0.0 (Ubuntu/Debian)
curl -L -o ~/obs-artifacts/grafana-enterprise_13.0.0_amd64.deb \
  https://dl.grafana.com/enterprise/release/grafana-enterprise_13.0.0_amd64.deb

# Prometheus 3.11.0
curl -L -o ~/obs-artifacts/prometheus-3.11.0.linux-amd64.tar.gz \
  https://github.com/prometheus/prometheus/releases/download/v3.11.0/prometheus-3.11.0.linux-amd64.tar.gz

# Grafana Alloy 1.9.0 (RHEL)
curl -L -o ~/obs-artifacts/alloy-1.9.0.amd64.rpm \
  https://github.com/grafana/alloy/releases/download/v1.9.0/alloy-1.9.0.amd64.rpm

# Node Exporter 1.11.0 (opcional, apenas se metrics_mode=node_exporter)
curl -L -o ~/obs-artifacts/node_exporter-1.11.0.linux-amd64.tar.gz \
  https://github.com/prometheus/node_exporter/releases/download/v1.11.0/node_exporter-1.11.0.linux-amd64.tar.gz
```

```bash
# Gerar checksums
sha256sum ~/obs-artifacts/* > ~/obs-artifacts/checksums.txt
cat ~/obs-artifacts/checksums.txt
```

---

### Passo 2: Baixar collections Ansible offline

```bash
# Instalar collections no diretório local
ansible-galaxy collection install -r observability-stack/requirements.yml \
  --collections-path ~/obs-collections

# Compactar para transferência
tar -czf ansible-collections.tar.gz -C ~/obs-collections ansible_collections
```

---

### Passo 3: Transferir para o controller corporativo

```bash
# Via SCP (ajuste o usuário e IP)
scp -r ~/obs-artifacts usuario@controller-corporativo:/opt/observability-artifacts/
scp ansible-collections.tar.gz usuario@controller-corporativo:~/
scp -r observability-stack/ usuario@controller-corporativo:/opt/observability-stack/

# No controller corporativo: instalar collections
ssh usuario@controller-corporativo
tar -xzf ansible-collections.tar.gz -C /usr/share/ansible/
# ou
mkdir -p ~/.ansible/collections
tar -xzf ansible-collections.tar.gz -C ~/.ansible/collections/
```

---

### Passo 4: Configurar o playbook para o ambiente

**Edite `inventories/production/hosts.yml`:**
```yaml
all:
  children:
    observability_server:
      hosts:
        meu-servidor-obs:
          ansible_host: 10.0.1.100    # IP real do servidor

    linux_agents:
      hosts:
        servidor-app-01:
          ansible_host: 10.0.1.101
        servidor-app-02:
          ansible_host: 10.0.1.102
        servidor-app-03:
          ansible_host: 10.0.1.103
```

**Edite `inventories/production/group_vars/all.yml`:**
```yaml
artifacts_base_dir: /opt/observability-artifacts   # caminho no controller

# Versões (devem bater com os arquivos baixados)
loki_version: "3.6.0"
grafana_version: "13.0.0"
prometheus_version: "3.11.0"
alloy_version: "1.9.0"

# IPs do servidor de observabilidade
loki_endpoint: "http://10.0.1.100:3100/loki/api/v1/push"
prometheus_remote_write_endpoint: "http://10.0.1.100:9090/api/v1/write"

# Retenção
loki_retention_period: "720h"    # 30 dias
prometheus_retention: "30d"

# Label de ambiente
environment_label: "producao"

# Logs a coletar nos agentes (adicione os caminhos da sua aplicação)
alloy_log_paths:
  - /var/log/messages
  - /var/log/secure
  - /var/log/cron
  - /var/log/app/*.log          # ajuste para sua aplicação
  - /opt/minha-app/logs/*.log

# Checksums (preencher com os valores de checksums.txt)
artifact_checksums:
  loki: ""            # cole o hash aqui
  grafana_rpm: ""
  prometheus: ""
  alloy_rpm: ""
```

**Configure SSH (`ansible.cfg`):**
```ini
[defaults]
inventory = ./inventories
remote_user = seu_usuario_de_servico
private_key_file = ~/.ssh/id_rsa

[privilege_escalation]
become = true
become_method = sudo
become_user = root
```

---

### Passo 5: Testar conectividade

```bash
# Teste de ping (sem deploy)
ansible all -m ping

# Teste de sudo
ansible all -m command -a "id" -b
# Esperado: uid=0(root) ...
```

---

### Passo 6: Executar deploy

```bash
cd /opt/observability-stack

# Validações primeiro
ansible-playbook playbooks/00_preflight.yml

# Se OK: servidor
ansible-playbook playbooks/10_observability_server.yml

# Agentes
ansible-playbook playbooks/20_linux_agents.yml

# OU tudo de uma vez
ansible-playbook site.yml
```

---

### Passo 7: Validar

```bash
# Verificar serviços
curl http://SEU_SERVIDOR:3100/ready        # Loki → "ready"
curl http://SEU_SERVIDOR:9090/-/ready      # Prometheus → "Prometheus Server is Ready."
curl http://SEU_SERVIDOR:3000/api/health   # Grafana → {"database":"ok","version":"13.0.0"}

# Verificar métricas chegando no Prometheus
curl 'http://SEU_SERVIDOR:9090/api/v1/query?query=node_load1'

# Verificar logs no Loki
curl 'http://SEU_SERVIDOR:3100/loki/api/v1/label/host/values'
```

Grafana: `http://SEU_SERVIDOR:3000` (usuário: `admin`, senha: a definida em `grafana_admin_password`)

---

## 9. Adaptar para outro ambiente

### Adicionar mais agentes

Em `hosts.yml`, adicione o host ao grupo `linux_agents`:
```yaml
linux_agents:
  hosts:
    novo-servidor:
      ansible_host: 10.0.1.105
```

Rode só o playbook de agentes no novo host:
```bash
ansible-playbook playbooks/20_linux_agents.yml -l novo-servidor
```

### Mudar caminhos de logs por host específico

Crie `inventories/production/host_vars/servidor-app-01.yml`:
```yaml
alloy_log_paths:
  - /var/log/messages
  - /opt/tomcat/logs/catalina.out
  - /opt/tomcat/logs/localhost_access_log*.txt
```

### Usar modo `node_exporter` em vez de `alloy`

Em `group_vars/all.yml`:
```yaml
metrics_mode: "node_exporter"
```

Isso instala Node Exporter separado e configura o Prometheus para fazer scrape ativo na porta 9100, em vez de receber push do Alloy.

### Ajustar retenção de dados

```yaml
loki_retention_period: "2160h"    # 90 dias
prometheus_retention: "90d"
```

Lembre de provisionar disco suficiente: aproximadamente 1-5 GB por dia de logs por servidor, dependendo do volume.

### Adicionar dashboards customizados

Coloque arquivos JSON de dashboard em `artifacts_base_dir/dashboards/`:
```
/opt/observability-artifacts/dashboards/
├── linux-hosts.json
└── minha-aplicacao.json
```

O Grafana os carrega automaticamente na próxima execução do playbook.

---

## 10. Referência rápida de variáveis

### Todas as variáveis configuráveis

| Variável | Padrão | Onde fica | Descrição |
|---|---|---|---|
| `artifacts_base_dir` | `/opt/observability-artifacts` | `all.yml` | Diretório dos binários no controller |
| `loki_version` | `3.6.0` | `all.yml` | Versão do Loki |
| `grafana_version` | `13.0.0` | `all.yml` | Versão do Grafana |
| `prometheus_version` | `3.11.0` | `all.yml` | Versão do Prometheus |
| `alloy_version` | `1.9.0` | `all.yml` | Versão do Alloy |
| `node_exporter_version` | `1.11.0` | `all.yml` | Versão do Node Exporter |
| `metrics_mode` | `alloy` | `all.yml` | `alloy` ou `node_exporter` |
| `manage_windows` | `false` | `all.yml` | `true` para habilitar agentes Windows |
| `loki_endpoint` | URL do Loki | `all.yml` | Destino de logs dos agentes |
| `prometheus_remote_write_endpoint` | URL do Prometheus | `all.yml` | Destino de métricas dos agentes |
| `loki_http_port` | `3100` | `all.yml` | Porta HTTP do Loki |
| `loki_grpc_port` | `9096` | `all.yml` | Porta gRPC do Loki |
| `grafana_port` | `3000` | `all.yml` | Porta do Grafana |
| `prometheus_port` | `9090` | `all.yml` | Porta do Prometheus |
| `node_exporter_port` | `9100` | `all.yml` | Porta do Node Exporter |
| `alloy_ui_port` | `12345` | `all.yml` | Porta da UI de debug do Alloy |
| `loki_retention_period` | `720h` | `all.yml` | Retenção de logs (ex: `720h`, `2160h`) |
| `prometheus_retention` | `30d` | `all.yml` | Retenção de métricas (ex: `30d`, `90d`) |
| `environment_label` | `prod` | `all.yml` | Label `env=` nos dados |
| `alloy_log_paths` | lista padrão | `all.yml` | Arquivos coletados pelos agentes |
| `grafana_admin_password` | — | vault/AWX | Senha admin do Grafana |
| `grafana_smtp_enabled` | `false` | `all.yml` | Habilitar envio de alertas por email |
| `grafana_plugins` | `[]` | `all.yml` | Plugins locais a instalar |
| `loki_user` / `loki_group` | `loki` | role defaults | Usuário/grupo do serviço |
| `prometheus_user` / `prometheus_group` | `prometheus` | role defaults | Usuário/grupo do serviço |
| `alloy_user` / `alloy_group` | `alloy` | role defaults | Usuário/grupo do serviço |
| `loki_data_dir` | `/var/lib/loki` | role defaults | Diretório de dados do Loki |
| `prometheus_data_dir` | `/var/lib/prometheus` | role defaults | Diretório de dados do Prometheus |
| `loki_config_dir` | `/etc/loki` | role defaults | Diretório de config do Loki |
| `prometheus_config_dir` | `/etc/prometheus` | role defaults | Diretório de config do Prometheus |

---

## 11. Tags disponíveis

| Tag | Playbook/Role | O que executa |
|---|---|---|
| `preflight` | `00_preflight.yml` | Todas as validações pré-deploy |
| `server` | `10_observability_server.yml` | Servidor completo (Loki + Grafana + Prometheus) |
| `loki` | dentro de `server` | Somente Loki |
| `grafana` | dentro de `server` | Somente Grafana |
| `prometheus` | dentro de `server` | Somente Prometheus |
| `agents` | `20_linux_agents.yml` | Agentes completos (Alloy + Node Exporter) |
| `alloy` | dentro de `agents` | Somente Alloy |
| `node_exporter` | dentro de `agents` | Somente Node Exporter |
| `windows` | `30_windows_agents.yml` | Agentes Windows |

**Exemplos de uso com tags:**

```bash
# Deploy completo
ansible-playbook site.yml

# Apenas preflight
ansible-playbook site.yml --tags preflight

# Apenas Loki (útil para atualizar só o Loki)
ansible-playbook site.yml --tags loki

# Apenas agentes (útil para adicionar novos hosts)
ansible-playbook site.yml --tags agents

# Excluir tags (deploy do servidor sem o Grafana)
ansible-playbook site.yml --tags server --skip-tags grafana

# Em host específico
ansible-playbook site.yml --tags agents -l novo-servidor
```

---

## 12. Solução de problemas

### Erro: `Group X does not exist`

```
TASK [loki : Loki | Create service user] ***
FAILED! => {"msg": "Group loki does not exist"}
```

**Causa:** A task de criação de usuário veio antes da de criação de grupo.  
**Solução:** Verificar que `ansible.builtin.group` está antes de `ansible.builtin.user` na role.

---

### Erro: `Unable to find required 'unzip' or 'zipinfo'`

```
FAILED! => {"msg": "Unable to find required 'unzip' or 'zipinfo' binary"}
```

**Causa:** Tentando extrair o Loki `.zip` no host remoto onde `unzip` não está instalado.  
**Solução:** A role deve usar `delegate_to: localhost` para extrair no controller.  
No controller: `apt install unzip` (Debian/Ubuntu) ou `yum install unzip` (RHEL).

---

### Erro: `[alerting].enabled cannot be true`

```
Error: invalid setting [alerting].enabled
Option '[alerting].enabled' cannot be true. Legacy Alerting is removed.
```

**Causa:** Grafana 10+ removeu o sistema de alertas legado. A seção `[alerting]` não existe mais.  
**Solução:** Remover `[alerting]` do `grafana.ini.j2`. Usar apenas `[unified_alerting]`.

---

### Erro: `Source .../consoles not found`

```
FAILED! => {"msg": "Source /tmp/prometheus-3.11.0.linux-amd64/consoles not found"}
```

**Causa:** Prometheus 3.x removeu os diretórios `consoles/` e `console_libraries/` do tarball.  
**Solução:** Remover as tasks que copiam esses diretórios e os flags `--web.console.templates` e `--web.console.libraries` do systemd unit.

---

### Alloy UI não acessível externamente

**Sintoma:** `curl http://IP:12345/` → connection refused.  
**Causa:** Por padrão, Alloy 1.9 escuta apenas em `127.0.0.1:12345`.  
**Solução:** Adicionar ao `/etc/sysconfig/alloy`:
```
CUSTOM_ARGS="--server.http.listen-addr=0.0.0.0:12345"
```
O playbook faz isso automaticamente via `lineinfile`.

---

### Alloy: `permission denied` em `/var/log/messages`

**Sintoma:**
```
level=error msg="failed to run tailer" err="open /var/log/messages: permission denied"
```

**Causa:** Em RHEL/AlmaLinux, `/var/log/messages` é criado como `600 root:root`. Mesmo com o grupo `adm`, não basta — rsyslog precisa ser configurado para criar os arquivos como `640 root:adm`.  
**Solução:**
1. Criar `/etc/rsyslog.d/10-fileperms.conf` com `$FileGroup adm` + `$FileCreateMode 0640`
2. Reiniciar rsyslog
3. Corrigir permissão nos arquivos existentes: `chmod 640 /var/log/messages /var/log/secure /var/log/cron`

O playbook aplica as três ações automaticamente via role `alloy`.

---

### Loki rejeita logs fora de ordem

**Sintoma:**
```
level=error msg="error pushing to ingestor" err="entry too far behind"
```

**Causa:** O servidor ou o agente tem relógio desajustado.  
**Solução:**
```bash
# Verificar sincronização
timedatectl show --property=NTPSynchronized --value

# Forçar sincronização
timedatectl set-ntp true
chronyc makestep
```

---

### Preflight falha com artefato DEB em host RHEL

**Sintoma:**
```
FAILED: ARTIFACT MISSING: alloy-1.9.0.amd64.deb not found
```

**Causa:** Bug na lógica de preflight — verificando artefato DEB em host RHEL.  
**Solução:** Na task `Preflight | Fail on missing artifacts`, garantir que o `when:` inclua `item.item.when | bool`:
```yaml
when:
  - item.item.when | bool     # ← sem isso, DEB é verificado em RHEL
  - not item.stat.exists
```

---

*Fim da documentação do playbook.*
