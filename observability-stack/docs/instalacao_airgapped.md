# Guia de Instalação — Stack de Observabilidade (Ambiente Air-Gapped)

> **Ambiente air-gapped** = servidores sem acesso à internet. Todos os pacotes e binários são baixados em uma máquina com internet e transferidos manualmente para os servidores.

---

## Visão Geral

Este guia instala a seguinte stack em servidores Linux **sem internet**:

| Componente | Função | Porta |
|---|---|---|
| **Grafana** | Interface web para visualizar logs e métricas | 3000 |
| **Loki** | Banco de dados de logs | 3100 |
| **Prometheus** | Banco de dados de métricas | 9090 |
| **Grafana Alloy** | Agente: coleta logs e métricas nos servidores | 12345 |

**Topologia mínima:**
```
Servidor A (obs-server)     →  Grafana + Loki + Prometheus
Servidor B (obs-agent1)     →  Grafana Alloy (agente)
Servidor C (obs-agent2)     →  Grafana Alloy (agente)
```
> Pode ser 1 servidor só (tudo junto) ou separado. O guia usa 3 servidores.

---

## Requisitos de Hardware

| Papel | CPU mínima | RAM mínima | Disco |
|---|---|---|---|
| obs-server | 2 vCPU | 4 GB | 50 GB |
| obs-agent | 1 vCPU | 2 GB | 20 GB |
| controller (Ansible) | qualquer | — | 5 GB livres para os pacotes |

> O **controller** é a máquina de onde você roda o Ansible. Pode ser o próprio obs-server, ou uma máquina separada (laptop, bastion host).

---

## Requisitos de Sistema Operacional

- **RHEL / AlmaLinux / Rocky Linux 8 ou 9** (testado em AlmaLinux 9.8)
- **Ubuntu 20.04 ou 22.04** (suportado, ajusta automaticamente)
- Ansible 2.13 ou superior no controller

---

## Pré-requisitos de Rede

- Controller consegue fazer SSH nos servidores alvo (obs-server, agentes)
- Servidores alvo **não precisam** de internet
- Portas abertas entre agentes e obs-server:
  - `3100/tcp` — Loki (push de logs)
  - `9090/tcp` — Prometheus (push de métricas)

---

## PARTE 1 — Preparar o Pacote de Instalação (com internet)

Execute esta parte em qualquer máquina **com acesso à internet** (seu laptop, por exemplo).

### 1.1 — Criar a estrutura de pastas

```bash
mkdir -p ~/obs-airgap/artifacts
mkdir -p ~/obs-airgap/collections
mkdir -p ~/obs-airgap/artifacts/dashboards
mkdir -p ~/obs-airgap/artifacts/plugins
cd ~/obs-airgap
```

### 1.2 — Baixar os binários da stack

Execute os comandos abaixo para baixar cada componente. Verifique o site oficial para versões mais recentes.

```bash
cd ~/obs-airgap/artifacts

# --- Loki 3.6.0 ---
# Site oficial: https://github.com/grafana/loki/releases
curl -LO https://github.com/grafana/loki/releases/download/v3.6.0/loki-linux-amd64.zip

# --- Grafana Enterprise 13.0.0 (RHEL/CentOS/AlmaLinux) ---
# Site oficial: https://grafana.com/grafana/download
curl -LO https://dl.grafana.com/enterprise/release/grafana-enterprise-13.0.0-1.x86_64.rpm

# Se usar Ubuntu/Debian — baixar o .deb em vez do .rpm:
# curl -LO https://dl.grafana.com/enterprise/release/grafana-enterprise_13.0.0_amd64.deb

# --- Prometheus 3.11.0 ---
# Site oficial: https://github.com/prometheus/prometheus/releases
curl -LO https://github.com/prometheus/prometheus/releases/download/v3.11.0/prometheus-3.11.0.linux-amd64.tar.gz

# --- Grafana Alloy 1.9.0 (RHEL/CentOS/AlmaLinux) ---
# Site oficial: https://github.com/grafana/alloy/releases
curl -LO https://github.com/grafana/alloy/releases/download/v1.9.0/alloy-1.9.0.amd64.rpm

# Se usar Ubuntu/Debian:
# curl -LO https://github.com/grafana/alloy/releases/download/v1.9.0/alloy-1.9.0.amd64.deb

# --- Node Exporter 1.11.0 (opcional — só se não usar Alloy para métricas) ---
curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.11.0/node_exporter-1.11.0.linux-amd64.tar.gz
```

### 1.3 — Gerar os checksums SHA256

Depois de baixar, gere e salve os checksums:

```bash
cd ~/obs-airgap/artifacts
sha256sum *.rpm *.zip *.tar.gz > checksums.txt
cat checksums.txt
```

> **Guarde esses valores!** Você vai colar no arquivo `group_vars/all.yml` do projeto Ansible.

### 1.4 — Baixar as coleções Ansible

```bash
cd ~/obs-airgap

# Instala ansible-galaxy localmente se não tiver
pip3 install ansible --user

# Baixa as coleções como arquivos .tar.gz para instalar offline
ansible-galaxy collection download \
  community.general \
  community.mysql \
  community.postgresql \
  ansible.windows \
  community.windows \
  -p ./collections/

ls collections/
# Vai listar arquivos como: community-general-9.x.x.tar.gz
```

### 1.5 — Baixar o projeto Ansible

Se você tem o projeto no GitHub ou no seu computador:

```bash
# Opção A: copiar do seu computador
cp -r /caminho/para/observability-stack ~/obs-airgap/

# Opção B: clonar do git (enquanto tem internet)
cd ~/obs-airgap
git clone https://github.com/seu-usuario/seu-repo.git observability-stack
```

### 1.6 — Verificar estrutura final

```bash
ls ~/obs-airgap/
# artifacts/
#   loki-linux-amd64.zip
#   grafana-enterprise-13.0.0-1.x86_64.rpm
#   prometheus-3.11.0.linux-amd64.tar.gz
#   alloy-1.9.0.amd64.rpm
#   node_exporter-1.11.0.linux-amd64.tar.gz
#   checksums.txt
#   dashboards/
#   plugins/
# collections/
#   community-general-x.x.x.tar.gz
#   community-mysql-x.x.x.tar.gz
#   ...
# observability-stack/
```

### 1.7 — Compactar tudo

```bash
cd ~
tar czf obs-airgap-package.tar.gz obs-airgap/
ls -lh obs-airgap-package.tar.gz
# Deve ter ~520 MB
```

---

## PARTE 2 — Transferir para o Servidor Controller

O **controller** é o servidor de onde o Ansible vai rodar. Pode ser o próprio obs-server ou uma máquina separada.

### 2.1 — Copiar o pacote via SCP

```bash
# Da sua máquina local para o controller
scp obs-airgap-package.tar.gz usuario@IP_DO_CONTROLLER:/opt/

# Exemplo:
scp obs-airgap-package.tar.gz user_aap@192.168.1.50:/opt/
```

> **Sem SCP?** Use um pendrive USB, compartilhamento de rede (CIFS/NFS), ou qualquer outro meio de transferência.

### 2.2 — Extrair no controller

```bash
# No servidor controller
cd /opt
tar xzf obs-airgap-package.tar.gz

ls /opt/obs-airgap/
# artifacts/  collections/  observability-stack/
```

---

## PARTE 3 — Instalar Ansible no Controller

### 3.1 — Se o controller tem RHEL/AlmaLinux/Rocky Linux

```bash
# Opção A: via DNF (se houver repositório interno/mirror)
sudo dnf install -y ansible-core

# Opção B: via pip (Python já vem no RHEL 9)
pip3 install ansible --user
echo 'export PATH=$PATH:~/.local/bin' >> ~/.bashrc
source ~/.bashrc
```

### 3.2 — Se o controller tem Ubuntu/Debian

```bash
sudo apt-get update
sudo apt-get install -y ansible
```

### 3.3 — Verificar a instalação

```bash
ansible --version
# Deve mostrar: ansible [core 2.13+]
```

### 3.4 — Instalar as coleções Ansible offline

```bash
# Cria o diretório de coleções
sudo mkdir -p /opt/collections

# Instala cada coleção do arquivo .tar.gz baixado
for f in /opt/obs-airgap/collections/*.tar.gz; do
  sudo ansible-galaxy collection install "$f" -p /opt/collections/
done

# Verifica
ansible-galaxy collection list --collections-path /opt/collections
```

---

## PARTE 4 — Configurar SSH entre Controller e Servidores Alvo

O Ansible precisa se conectar via SSH nos servidores alvo **sem pedir senha**.

### 4.1 — Gerar chave SSH no controller (se não tiver uma)

```bash
ssh-keygen -t rsa -b 4096 -C "ansible-controller" -N "" -f ~/.ssh/id_rsa
# Aperta Enter em tudo (deixa sem passphrase)
```

### 4.2 — Copiar a chave pública para cada servidor alvo

```bash
# Para cada servidor alvo (obs-server, obs-agent1, obs-agent2):
ssh-copy-id user_aap@192.168.1.100    # obs-server
ssh-copy-id user_aap@192.168.1.101    # obs-agent1
ssh-copy-id user_aap@192.168.1.102    # obs-agent2
```

> Se `ssh-copy-id` não funcionar (primeira vez sem chave), use:
> ```bash
> ssh user_aap@192.168.1.100 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < ~/.ssh/id_rsa.pub
> ```

### 4.3 — Configurar sudo sem senha nos servidores alvo

Em **cada servidor alvo**, execute como root:

```bash
echo "user_aap ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ansible
chmod 440 /etc/sudoers.d/ansible
```

### 4.4 — Testar conectividade

```bash
# Teste rápido do Ansible
ansible all -i "192.168.1.100,192.168.1.101,192.168.1.102," \
  -u user_aap --private-key ~/.ssh/id_rsa -m ping
# Deve retornar: pong em todos os hosts
```

---

## PARTE 5 — Configurar o Projeto Ansible

### 5.1 — Copiar os artefatos para o diretório correto

```bash
sudo cp -r /opt/obs-airgap/artifacts /opt/observability-artifacts
sudo chown -R $(whoami): /opt/observability-artifacts
ls /opt/observability-artifacts/
```

### 5.2 — Posicionar o projeto Ansible

```bash
sudo cp -r /opt/obs-airgap/observability-stack /opt/
sudo chown -R $(whoami): /opt/observability-stack
cd /opt/observability-stack
```

### 5.3 — Editar o inventário de hosts

Arquivo: `/opt/observability-stack/inventories/production/hosts.ini`

```bash
nano /opt/observability-stack/inventories/production/hosts.ini
```

Conteúdo (substitua pelos IPs reais dos seus servidores):

```ini
[observability_server]
obs-server ansible_host=192.168.1.100

[rhel9]
obs-agent1 ansible_host=192.168.1.101
obs-agent2 ansible_host=192.168.1.102

[linux_agents:children]
rhel9

[windows_agents]
# win-host1 ansible_host=192.168.1.x ansible_connection=winrm ansible_winrm_transport=ntlm

[all:vars]
ansible_python_interpreter=/usr/bin/python3
```

> **Grupos importantes:**
> - `[observability_server]` — servidor que vai rodar Loki, Grafana, Prometheus
> - `[rhel9]` — agentes RHEL/AlmaLinux/Rocky
> - Para Ubuntu, crie um grupo `[ubuntu]` e adicione-o em `[linux_agents:children]`

### 5.4 — Editar as variáveis principais

Arquivo: `/opt/observability-stack/inventories/production/group_vars/all.yml`

```bash
nano /opt/observability-stack/inventories/production/group_vars/all.yml
```

**Variáveis que VOCÊ DEVE alterar:**

```yaml
# ── Caminho dos artefatos no controller ──
artifacts_base_dir: /opt/observability-artifacts

# ── Versões (confirme com os arquivos que baixou) ──
loki_version: "3.6.0"
grafana_version: "13.0.0"
prometheus_version: "3.11.0"
alloy_version: "1.9.0"

# ── IP do servidor principal ──
# Troque pelo IP real do seu obs-server
loki_endpoint: "http://192.168.1.100:3100/loki/api/v1/push"
prometheus_remote_write_endpoint: "http://192.168.1.100:9090/api/v1/write"

# ── Modo de coleta de métricas ──
# "alloy" = Alloy coleta e envia (recomendado, 1 agente só)
# "node_exporter" = Node Exporter separado + Prometheus scrape
metrics_mode: "alloy"

# ── Checksums SHA256 ──
# Cole os valores gerados no Passo 1.3
artifact_checksums:
  loki: "COLE_AQUI_O_SHA256_DO_LOKI_ZIP"
  grafana_rpm: "COLE_AQUI_O_SHA256_DO_GRAFANA_RPM"
  grafana_deb: ""
  alloy_rpm: "COLE_AQUI_O_SHA256_DO_ALLOY_RPM"
  alloy_deb: ""
  prometheus: "COLE_AQUI_O_SHA256_DO_PROMETHEUS_TARGZ"
  node_exporter: "COLE_AQUI_O_SHA256_DO_NODE_EXPORTER_TARGZ"
```

**Outros ajustes opcionais:**

```yaml
# Retenção de dados
loki_retention_period: "720h"    # 30 dias de logs
prometheus_retention: "30d"      # 30 dias de métricas

# Labels dos seus ambientes
environment_label: "producao"    # aparece em todos os logs/métricas

# Caminhos de log para monitorar nos agentes
alloy_log_paths:
  - /var/log/messages
  - /var/log/secure
  - /var/log/cron
  - /var/log/httpd/*           # Apache
  - /var/log/nginx/*           # Nginx (se tiver)
  - /opt/meu-app/logs/*.log    # Seu aplicativo
```

### 5.5 — Configurar a senha do Grafana

A senha do Grafana **não deve ficar no arquivo `all.yml`**. Passe como variável extra ou use Ansible Vault:

```bash
# Opção A: variável extra na linha de comando (mais simples para começar)
# Você vai adicionar --extra-vars "grafana_admin_password=SuaSenhaAqui" nos comandos do Passo 6

# Opção B: Ansible Vault (mais seguro — recomendado para produção)
ansible-vault create /opt/observability-stack/inventories/production/group_vars/vault.yml
# Vai abrir um editor. Digite:
#   grafana_admin_password: SuaSenhaSegura123
# Salva e fecha (Ctrl+X no nano, :wq no vim)
```

### 5.6 — Ajustar o ansible.cfg

Arquivo: `/opt/observability-stack/ansible.cfg`

```bash
cat /opt/observability-stack/ansible.cfg
```

Conteúdo esperado (edite se necessário):

```ini
[defaults]
inventory          = ./inventories/production
roles_path         = ./roles
collections_paths  = /opt/collections:~/.ansible/collections
remote_user        = user_aap
host_key_checking  = False

[privilege_escalation]
become       = True
become_method = sudo
```

> Se o usuário SSH for diferente de `user_aap`, troque `remote_user`.
> Se a chave SSH estiver num caminho diferente do padrão, adicione:
> `private_key_file = /caminho/para/sua/chave`

---

## PARTE 6 — Executar os Playbooks

### 6.1 — Verificar sintaxe primeiro (não faz nada, só valida)

```bash
cd /opt/observability-stack
ansible-playbook site.yml --syntax-check
# Deve retornar: playbook: site.yml (sem erros)
```

### 6.2 — Rodar o preflight (checagem de pré-requisitos)

```bash
ansible-playbook playbooks/00_preflight.yml
```

Este playbook verifica:
- OS suportado e versão mínima
- Acesso root via sudo
- Artefatos presentes no controller
- Checksums corretos
- Espaço em disco suficiente
- Portas livres no servidor

**Resultado esperado:**
```
obs-server  : ok=6  failed=0
obs-agent1  : ok=6  failed=0
obs-agent2  : ok=6  failed=0
```

> Se houver falha, o erro vai explicar o que está faltando. Veja a seção de **Troubleshooting** ao final.

### 6.3 — Instalar o servidor de observabilidade

```bash
ansible-playbook playbooks/10_observability_server.yml \
  --extra-vars "grafana_admin_password=SuaSenhaSegura123"
```

Instala nesta ordem:
1. **Loki** — banco de logs
2. **Grafana** — interface web
3. **Prometheus** — banco de métricas

Duração: ~3-5 minutos (maior parte é transferência do RPM do Grafana ~217MB).

**Resultado esperado:**
```
obs-server : ok=38  failed=0
```

### 6.4 — Instalar os agentes Linux

```bash
ansible-playbook playbooks/20_linux_agents.yml
```

Instala o Grafana Alloy em todos os servidores do grupo `[linux_agents]`.

**Resultado esperado:**
```
obs-agent1 : ok=14  failed=0
obs-agent2 : ok=14  failed=0
```

### 6.5 — (Opcional) Rodar tudo de uma vez

```bash
ansible-playbook site.yml \
  --extra-vars "grafana_admin_password=SuaSenhaSegura123"
```

---

## PARTE 7 — Validação

### 7.1 — Verificar se os serviços estão rodando

```bash
# No obs-server
ssh user_aap@192.168.1.100

# Verifica cada serviço
sudo systemctl status loki
sudo systemctl status grafana-server
sudo systemctl status prometheus

# Deve mostrar: Active: active (running)
```

### 7.2 — Verificar endpoints via curl

```bash
# Ainda no obs-server
curl http://localhost:3100/ready           # Loki: deve retornar "ready"
curl http://localhost:9090/-/ready         # Prometheus: "Prometheus Server is Ready."
curl http://localhost:3000/api/health      # Grafana: {"database":"ok",...}
```

### 7.3 — Verificar se os agentes estão enviando dados

```bash
# Métricas chegando no Prometheus
curl -s 'http://localhost:9090/api/v1/label/host/values' | python3 -m json.tool
# Deve listar os hostnames dos seus agentes

# Logs chegando no Loki
curl -s 'http://localhost:3100/loki/api/v1/label/host/values' | python3 -m json.tool
# Deve listar os hostnames dos seus agentes
```

### 7.4 — Acessar o Grafana no browser

Abra no navegador: `http://192.168.1.100:3000`

- Usuário: `admin`
- Senha: a que você definiu no Passo 6.3

---

## PARTE 8 — Adicionar Novos Servidores

Para adicionar um novo servidor para monitorar depois:

1. Adicione o IP no arquivo `hosts.ini` no grupo correto
2. Configure SSH e sudo no novo servidor (Passo 4.2 e 4.3)
3. Rode apenas o playbook de agentes:

```bash
ansible-playbook playbooks/20_linux_agents.yml --limit nome-do-novo-servidor
```

---

## Troubleshooting

### Erro: "Failed to connect to the host"
- Verifique se o servidor alvo está ligado e acessível via ping
- Confirme se a chave SSH foi copiada corretamente (Passo 4.2)
- Confirme o usuário em `ansible.cfg` → `remote_user`

### Erro: "Group loki does not exist" / "Group prometheus does not exist"
- Não deve ocorrer nesta versão do projeto (já corrigido)
- Se ocorrer: confirme que está usando a versão mais recente dos roles

### Erro: "ARTIFACT MISSING"
- O arquivo não está em `artifacts_base_dir`
- Confira o caminho: `ls /opt/observability-artifacts/`
- Confira o nome do arquivo e a versão em `all.yml`

### Erro: "CHECKSUM MISMATCH"
- O arquivo foi corrompido durante a transferência
- Re-transfira o arquivo e recalcule o checksum
- Para pular temporariamente, deixe o checksum como string vazia `""` no `all.yml`

### Serviço não sobe (systemd failed)
```bash
# Ver logs detalhados do serviço
sudo journalctl -xeu nome-do-servico.service --no-pager -n 50

# Exemplos:
sudo journalctl -xeu loki.service
sudo journalctl -xeu grafana-server.service
sudo journalctl -xeu prometheus.service
sudo journalctl -xeu alloy.service
```

### Agentes não aparecem no Grafana
- Verifique se o Alloy está rodando: `sudo systemctl status alloy`
- Verifique se consegue alcançar o obs-server: `curl http://192.168.1.100:3100/ready`
- Se houver firewall, abra as portas 3100 e 9090 no obs-server

---

## Referência Rápida — Comandos Úteis

```bash
# Restartar um serviço
sudo systemctl restart loki
sudo systemctl restart grafana-server
sudo systemctl restart prometheus
sudo systemctl restart alloy

# Ver logs em tempo real
sudo journalctl -u alloy -f

# Re-rodar só um componente específico
ansible-playbook playbooks/10_observability_server.yml --tags loki
ansible-playbook playbooks/10_observability_server.yml --tags grafana
ansible-playbook playbooks/10_observability_server.yml --tags prometheus
ansible-playbook playbooks/20_linux_agents.yml --tags alloy
```

---

*Documentação gerada em 2026-06-10. Versões: Loki 3.6.0 · Grafana 13.0.0 · Prometheus 3.11.0 · Alloy 1.9.0*
