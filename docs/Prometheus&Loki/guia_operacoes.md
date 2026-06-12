# Guia de Operações — Stack de Observabilidade

> Este guia cobre o uso diário da stack: explorar logs, analisar métricas, criar dashboards e configurar alertas.

---

## 1. Conceitos Básicos

### O que cada componente faz

```
Alloy (agente nos servidores)
  │
  ├─ Coleta logs  ──────────────────────► Loki (armazena logs)
  │   systemd, /var/log/*, app logs             │
  │                                             │
  └─ Coleta métricas ──────────────────► Prometheus (armazena métricas)
      CPU, memória, disco, rede                  │
                                                 │
                                     Grafana ◄──┘
                                   (visualiza tudo)
```

**Loki** = banco de dados de logs. Você faz perguntas como: *"Me mostra todos os erros do servidor A nas últimas 2 horas"*.

**Prometheus** = banco de dados de métricas numéricas com timestamp. Você faz perguntas como: *"Qual era o uso de CPU do servidor B às 14h de ontem?"*.

**Grafana** = a "janela" para ver tudo. Conecta no Loki e no Prometheus e exibe de forma visual.

---

## 2. Push vs Pull - Como as Metricas Chegam ao Prometheus

### O modelo tradicional: Pull (scrape)

No modelo classico, o Prometheus e quem inicia a conexao. Ele vai periodicamente em cada servidor buscar as metricas:

```
Prometheus ──── GET /metrics ────► Node Exporter :9100 (servidor A)
Prometheus ──── GET /metrics ────► Node Exporter :9100 (servidor B)
Prometheus ──── GET /metrics ────► Node Exporter :9100 (servidor C)
```

Para isso funcionar:
- Cada servidor precisa expor porta `9100` acessivel pelo Prometheus
- O Prometheus precisa saber o IP de cada servidor (lista estatica ou service discovery)
- Se adicionar novo servidor, precisa atualizar o config do Prometheus

### O modelo do nosso stack: Push (remote-write)

O Alloy e quem inicia a conexao. Ele coleta as metricas localmente e envia ao Prometheus:

```
Alloy (servidor A) ──── POST /api/v1/write ────► Prometheus :9090
Alloy (servidor B) ──── POST /api/v1/write ────► Prometheus :9090
Alloy (servidor C) ──── POST /api/v1/write ────► Prometheus :9090
```

O Prometheus precisa do flag `--web.enable-remote-write-receiver` para aceitar esse push - e exatamente o que esta configurado no systemd unit do Prometheus nesse stack.

### Comparacao direta

| Criterio | Pull (scrape) | Push (remote-write) |
|---|---|---|
| Quem inicia | Prometheus vai buscar | Agente envia |
| Firewall | Prometheus precisa acessar porta 9100 de cada host | Agente precisa acessar somente `:9090` no servidor central |
| Novo servidor | Atualizar config do Prometheus | So instalar Alloy - ele ja sabe pra onde enviar |
| Agente extra | Precisa de Node Exporter separado | Alloy ja faz os dois (logs + metricas) |
| Complexidade | 2 processos por servidor (Node Exporter + config Prometheus) | 1 processo por servidor (Alloy) |

### Por que remote-write faz sentido aqui

O Alloy ja precisa rodar em cada servidor para coletar logs e enviar ao Loki. Como ele ja esta la, tambem coleta metricas e as envia ao Prometheus pelo mesmo modelo de push. Resultado: **1 agente por servidor** que faz tudo.

### O que acontece no Alloy (config simplificado)

```alloy
// 1. Coleta metricas locais (node_exporter integrado)
prometheus.exporter.unix "host" {}

// 2. Faz scrape interno dessas metricas
prometheus.scrape "host_metrics" {
  targets    = prometheus.exporter.unix.host.targets
  forward_to = [prometheus.remote_write.central.receiver]
}

// 3. Envia (push) para o Prometheus central
prometheus.remote_write "central" {
  endpoint {
    url = "http://OBS_SERVER:9090/api/v1/write"
  }
}
```

O `prometheus.scrape` faz o pull interno (localhost apenas) e o `prometheus.remote_write` faz o push externo para o servidor central.

### Regras de firewall resultantes

Cada agente precisa de saida TCP para:
- `OBS_SERVER:3100` - push de logs para o Loki
- `OBS_SERVER:9090` - push de metricas para o Prometheus

O servidor central nao precisa de acesso de entrada nas portas dos agentes.

---

## 3. Regras de Firewall - O que Solicitar ao Time de Network

### Visao geral da topologia

```
[Estacoes de trabalho / NOC]
         |
         | TCP 3000 (Grafana - interface web)
         |
    [obs-server]  <- IP fixo corporativo (ex: 10.10.5.50)
    Grafana  :3000
    Loki     :3100
    Prometheus :9090
         ^
         | TCP 3100 (push logs)
         | TCP 9090 (push metricas)
         |
    [Servidores monitorados]
    obs-agent1, obs-agent2, app-servers, db-servers...
    Alloy :12345 (UI - opcional, somente admin)
```

---

### Tabela de regras para o time de network

Entregar essa tabela exata ao time de rede/firewall:

| # | Origem | Destino | Porta | Protocolo | Direcao | Descricao |
|---|---|---|---|---|---|---|
| 1 | Estacoes de trabalho (admin/NOC) | obs-server | 3000 | TCP | Entrada no obs-server | Acesso a interface web do Grafana |
| 2 | Servidores monitorados (agentes) | obs-server | 3100 | TCP | Entrada no obs-server | Alloy envia logs ao Loki |
| 3 | Servidores monitorados (agentes) | obs-server | 9090 | TCP | Entrada no obs-server | Alloy envia metricas ao Prometheus |
| 4 | obs-server | Servidores monitorados | 22 | TCP | Saida do obs-server | Ansible SSH para deploy e manutencao |
| 5 | Admin / Ansible controller | obs-server | 22 | TCP | Entrada no obs-server | SSH para gerenciamento e deploy |
| 6 | Admin / Ansible controller | Servidores monitorados | 22 | TCP | Entrada nos agentes | SSH para deploy do Alloy |

**Regras opcionais (nao criticas):**

| # | Origem | Destino | Porta | Protocolo | Descricao |
|---|---|---|---|---|---|
| 7 | Admin | Servidores monitorados | 12345 | TCP | UI de debug do Alloy (diagnostico) |
| 8 | Admin | obs-server | 9090 | TCP | Acesso direto ao Prometheus (queries manuais) |
| 9 | Admin | obs-server | 3100 | TCP | Acesso direto ao Loki (queries manuais via curl) |

---

### O que NAO precisa de liberacao

- Prometheus NAO precisa acessar os agentes - e o Alloy que empurra as metricas (remote-write)
- Loki NAO precisa acessar os agentes - e o Alloy que empurra os logs
- Grafana NAO precisa de porta aberta para fora - ele consulta Loki e Prometheus localmente (loopback)

---

### Grafana acessivel pelo IP do servidor (nao localhost)

Por padrao o Grafana ja faz bind em `0.0.0.0:3000` - responde em todos os IPs da maquina.

O que pode bloquear o acesso externo sao **dois firewalls diferentes**:

**1. firewalld do proprio servidor (SO level)**

Se o firewalld estiver ativo no obs-server, liberar as portas:

```bash
# Verificar se firewalld esta ativo
sudo systemctl status firewalld

# Liberar portas permanentemente
sudo firewall-cmd --permanent --add-port=3000/tcp   # Grafana
sudo firewall-cmd --permanent --add-port=3100/tcp   # Loki
sudo firewall-cmd --permanent --add-port=9090/tcp   # Prometheus
sudo firewall-cmd --reload

# Verificar
sudo firewall-cmd --list-ports
```

Nos servidores com agente:
```bash
# Opcional - UI do Alloy para debug
sudo firewall-cmd --permanent --add-port=12345/tcp
sudo firewall-cmd --reload
```

**2. Firewall de rede (time de infraestrutura/network)**

Mesmo com firewalld liberado, se houver firewall de perimetro, VLAN ACL ou NSG (cloud), o time de network precisa liberar as regras da tabela acima.

---

### Verificar conectividade apos liberacao

Rodar do computador do admin ou estacao de trabalho:

```bash
# Testar Grafana (deve retornar JSON com versao)
curl -s http://OBS_SERVER_IP:3000/api/health
# {"commit":"...","database":"ok","version":"13.0.0"}

# Testar Loki (deve retornar "ready")
curl -s http://OBS_SERVER_IP:3100/ready
# ready

# Testar Prometheus (deve retornar HTML/JSON)
curl -s http://OBS_SERVER_IP:9090/-/ready
# Prometheus Server is Ready.
```

Rodar de um servidor agente para testar que ele consegue enviar dados:

```bash
# Testar acesso ao Loki
curl -s http://OBS_SERVER_IP:3100/ready
# ready

# Testar acesso ao Prometheus remote-write (POST vazio - so testa conectividade)
curl -s -o /dev/null -w "%{http_code}" -X POST http://OBS_SERVER_IP:9090/api/v1/write
# 204 ou 400 = porta acessivel (400 = corpo invalido, mas chegou)
# Connection refused ou timeout = firewall bloqueando
```

---

### Configuracao do grafana.ini para IP fixo (opcional)

Por padrao `[server] http_addr =` fica em branco, o que significa bind em todos os IPs (`0.0.0.0`). Funciona para a maioria dos casos.

Se quiser restringir o Grafana a um IP especifico do servidor:

```ini
# /etc/grafana/grafana.ini
[server]
http_addr = 10.10.5.50    # IP do obs-server
http_port = 3000
domain    = 10.10.5.50    # usado em links de alerta e emails
root_url  = http://10.10.5.50:3000
```

Apos alterar, reiniciar o Grafana:
```bash
sudo systemctl restart grafana-server
```

No playbook Ansible, editar `group_vars/observability_server.yml`:
```yaml
grafana_http_addr: "0.0.0.0"   # bind em todos os IPs (padrao)
grafana_domain: "10.10.5.50"   # IP ou hostname do obs-server
grafana_root_url: "http://10.10.5.50:3000"
```

---

### Checklist completo antes de solicitar ao network

- [ ] Definir o IP fixo do obs-server (solicitar reserva de IP ao time de rede)
- [ ] Mapear quais estacoes/subnets precisam de acesso ao Grafana (porta 3000)
- [ ] Mapear quais servidores serao monitorados (precisam de saida para 3100 e 9090)
- [ ] Verificar se ha VLAN separada entre obs-server e servidores monitorados
- [ ] Confirmar se o Ansible controller e o mesmo obs-server ou maquina separada
- [ ] Verificar politica de firewall interno: SO usa firewalld? iptables? nftables?

---

## 3. Acessando o Grafana

**URL:** `http://IP_DO_SEU_SERVIDOR:3000`

**Login:** `admin` / (senha configurada na instalação)

### Navegação principal (menu lateral esquerdo)

| Ícone | Seção | Para que serve |
|---|---|---|
| 🔍 Explore | Explore | Consultas livres — logs e métricas |
| 🖥️ Dashboards | Dashboards | Painéis salvos |
| 🔔 Alerting | Alerting | Regras de alerta e notificações |
| ⚙️ Administration | Configurações | Datasources, usuários, etc |

---

## 4. Explorando Logs com o Loki (LogQL)

### Acessar o Explore de Logs

1. Clique em **Explore** (ícone de lupa no menu)
2. No topo, selecione o datasource **Loki**
3. Na caixa de busca, clique em **Code** (não Builder)
4. Digite sua query e aperte **Shift+Enter** ou clique em Run

### 3.1 — Estrutura de uma query LogQL

```logql
{label="valor"}  |  filtro  |  transformação
```

**Parte 1: seletor de stream (obrigatório)**
Escolhe quais logs buscar com base nos labels:

```logql
{job="systemd-journal"}           # todos os logs do journal
{host="obs-agent1"}               # só do servidor agent1
{job="varlogs", host="obs-agent1"} # logs de arquivos do agent1
```

**Labels disponíveis na sua stack:**

| Label | Valores | Descrição |
|---|---|---|
| `host` | obs-agent1, obs-agent2 | Qual servidor |
| `job` | systemd-journal, varlogs | Fonte do log |
| `env` | prod | Ambiente |

**Parte 2: filtros (opcional)**

```logql
|= "texto"        # contém exatamente "texto"
!= "texto"        # não contém "texto"
|~ "regex"        # match por expressão regular
!~ "regex"        # não faz match pela regex
```

### 3.2 — Queries prontas para uso

**Todos os logs do sistema:**
```logql
{job="systemd-journal"}
```

**Logs de um servidor específico:**
```logql
{job="systemd-journal", host="obs-agent1"}
```

**Logins SSH (sucesso e tentativas):**
```logql
{job="systemd-journal"} |= "sshd"
```

**Tentativas de acesso negado / falha de autenticação:**
```logql
{job="systemd-journal"} |= "Failed password"
```
```logql
{job="systemd-journal"} |= "authentication failure"
```

**Comandos sudo executados:**
```logql
{job="systemd-journal"} |= "sudo"
```

**Apenas erros e falhas:**
```logql
{job="systemd-journal"} |~ "(?i)(error|failed|critical|fatal)"
```

> `(?i)` = case-insensitive (ignora maiúscula/minúscula)

**Logs de serviço específico (ex: httpd, nginx, postgresql):**
```logql
{job="systemd-journal"} |= "httpd"
{job="systemd-journal"} |= "postgresql"
{job="systemd-journal"} |= "mysqld"
```

**Logs de um arquivo específico:**
```logql
{job="varlogs"} |= "error"
```

**Logs dos últimos N minutos de todos os agentes:**
```logql
{job="systemd-journal"}
```
> Controle o período pelo seletor de tempo no canto superior direito.

### 3.3 — Transformando logs em métricas (Log Metrics)

Você pode contar linhas de log e criar gráficos:

**Quantidade de erros por hora (gráfico):**
```logql
sum by (host) (
  count_over_time(
    {job="systemd-journal"} |~ "(?i)error" [1h]
  )
)
```

**Taxa de logins SSH por minuto:**
```logql
rate(
  {job="systemd-journal"} |= "sshd" [5m]
)
```

### 3.4 — Dicas no Explore do Loki

- **Live** (botão no canto superior direito): atualiza os logs em tempo real
- **Seletor de tempo**: padrão "Last 1 hour", pode mudar para "Last 6 hours", "Last 24 hours", etc.
- **Labels**: clique numa linha de log para expandir e ver todos os labels
- **Log context**: clique em "Log context" numa linha para ver os logs antes/depois

---

## 4. Explorando Métricas com Prometheus (PromQL)

### Acessar o Explore de Métricas

1. Clique em **Explore**
2. Selecione o datasource **Prometheus**
3. Clique em **Code**
4. Digite a query e aperte Shift+Enter

### 4.1 — Estrutura de uma query PromQL

```promql
nome_da_métrica{label="valor"}
```

**Exemplos básicos:**
```promql
node_load1                           # load average 1 minuto (todos os hosts)
node_load1{host="obs-agent1"}        # load do agent1 especificamente
```

### 4.2 — Métricas disponíveis (via Alloy/Node Exporter)

O Alloy coleta ~400 métricas de cada servidor. As mais importantes:

| Métrica | Descrição |
|---|---|
| `node_load1` | Load average 1 minuto |
| `node_load5` | Load average 5 minutos |
| `node_cpu_seconds_total` | Tempo de CPU por modo (idle, user, system...) |
| `node_memory_MemTotal_bytes` | Memória total |
| `node_memory_MemAvailable_bytes` | Memória disponível |
| `node_filesystem_size_bytes` | Tamanho total do disco |
| `node_filesystem_avail_bytes` | Espaço disponível em disco |
| `node_network_receive_bytes_total` | Bytes recebidos pela rede |
| `node_network_transmit_bytes_total` | Bytes enviados pela rede |
| `node_boot_time_seconds` | Timestamp do boot (para calcular uptime) |

### 4.3 — Queries prontas para uso

**Load average de todos os hosts:**
```promql
node_load1
```

**Percentual de CPU em uso:**
```promql
100 - (
  avg by (host) (
    rate(node_cpu_seconds_total{mode="idle"}[5m])
  ) * 100
)
```

**Percentual de memória usada:**
```promql
100 * (
  1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
)
```

**Memória disponível em GB:**
```promql
node_memory_MemAvailable_bytes / (1024 * 1024 * 1024)
```

**Percentual de disco usado (partição raiz /):**
```promql
100 * (
  1 - node_filesystem_avail_bytes{mountpoint="/"} 
      / node_filesystem_size_bytes{mountpoint="/"}
)
```

**Taxa de entrada de rede em Mbps:**
```promql
rate(node_network_receive_bytes_total{device!="lo"}[5m]) * 8 / 1024 / 1024
```

> `device!="lo"` exclui o loopback (interface interna)

**Uptime do servidor em dias:**
```promql
(node_time_seconds - node_boot_time_seconds) / 86400
```

**Verificar se um host está enviando dados (últimos 5 min):**
```promql
absent_over_time(node_load1{host="obs-agent1"}[5m])
```
> Retorna 1 se o agente parou de enviar. Retorna vazio se está OK.

### 4.4 — Funções PromQL essenciais

| Função | O que faz | Exemplo |
|---|---|---|
| `rate()` | Taxa por segundo de um contador | `rate(node_cpu_seconds_total[5m])` |
| `avg by ()` | Média agrupada por label | `avg by (host)(node_load1)` |
| `max by ()` | Máximo por label | `max by (host)(node_cpu_seconds_total)` |
| `sum by ()` | Soma por label | `sum by (host)(node_memory_MemFree_bytes)` |
| `absent()` | Retorna 1 se a métrica não existe | `absent(node_load1{host="x"})` |
| `histogram_quantile()` | Percentis | `histogram_quantile(0.99, rate(...[5m]))` |

---

## 5. Criando Dashboards

### 5.1 — Criar um novo dashboard

1. Menu lateral → **Dashboards** → **New** → **New dashboard**
2. Clique em **Add visualization**
3. Selecione o datasource (Prometheus ou Loki)
4. Escreva a query, configure o painel, clique **Apply**
5. **Ctrl+S** para salvar

### 5.2 — Tipos de painel e quando usar cada um

| Tipo | Quando usar | Exemplo |
|---|---|---|
| **Time series** | Valores que mudam no tempo | CPU, memória, rede ao longo do dia |
| **Stat** | Valor atual único e destaque | CPU agora, uptime |
| **Gauge** | Valor dentro de um range (0-100%) | % disco, % memória |
| **Bar gauge** | Comparar vários hosts | Disco % de 5 servidores |
| **Table** | Dados em formato de tabela | Lista de processos, top consumidores |
| **Logs** | Linhas de log do Loki | Stream de erros recentes |
| **Pie chart** | Proporções | Distribuição de CPU por modo |
| **Heatmap** | Densidade ao longo do tempo | Latência de requisições |

### 5.3 — Configurações importantes do painel

Após clicar em **Add visualization**, no painel de configuração à direita:

**Aba "Panel options":**
- **Title**: nome do painel
- **Description**: descrição (aparece no hover do (?))

**Aba "Standard options" (para métricas):**
- **Unit**: define a unidade de medida
  - `Misc > Percent (0-100)` → para percentuais
  - `Data > bytes(SI)` → para tamanhos de arquivo
  - `Data rate > bytes/sec(SI)` → para velocidade de rede
  - `Time > seconds` → para durações
- **Min / Max**: limites do eixo (ex: Min=0, Max=100 para percentual)
- **Decimals**: casas decimais

**Aba "Thresholds":**
Define cores de alerta visual:
- Verde (ok) → amarelo (atenção) → vermelho (crítico)
- Exemplo para CPU: `0=verde, 70=amarelo, 90=vermelho`

### 5.4 — Criar variáveis de template (multi-host)

Variáveis de template permitem criar um dashboard que funciona para qualquer servidor.

1. Abra o dashboard → botão de engrenagem ⚙️ → **Variables**
2. **Add variable**
3. Configure:
   ```
   Name: host
   Type: Query
   Datasource: Prometheus
   Query: label_values(node_load1, host)
   ```
4. Salve e volte ao dashboard

Agora use `$host` nas suas queries:
```promql
node_load1{host="$host"}
```

Um dropdown vai aparecer no topo para selecionar o servidor.

### 5.5 — Dashboard sugerido: "Visão Geral do Servidor"

**Painel 1 — CPU (Time series)**
```promql
100 - (avg by (host)(rate(node_cpu_seconds_total{mode="idle", host=~"$host"}[5m]))*100)
```
Tipo: Time series | Unit: Percent (0-100) | Thresholds: 70=yellow, 90=red

**Painel 2 — Memória (Gauge)**
```promql
100 * (1 - node_memory_MemAvailable_bytes{host=~"$host"} / node_memory_MemTotal_bytes{host=~"$host"})
```
Tipo: Gauge | Min: 0 | Max: 100 | Thresholds: 70=yellow, 85=red

**Painel 3 — Load (Stat)**
```promql
node_load1{host=~"$host"}
```
Tipo: Stat | Color mode: Background | Thresholds: 2=yellow, 4=red

**Painel 4 — Disco (Bar gauge)**
```promql
100 * (1 - node_filesystem_avail_bytes{mountpoint="/", host=~"$host"} / node_filesystem_size_bytes{mountpoint="/", host=~"$host"})
```
Tipo: Bar gauge | Unit: Percent | Thresholds: 70=yellow, 85=red

**Painel 5 — Rede entrada (Time series)**
```promql
rate(node_network_receive_bytes_total{device!="lo", host=~"$host"}[5m]) * 8 / 1024 / 1024
```
Tipo: Time series | Unit: Mbit/s

**Painel 6 — Últimos erros (Logs)**
```logql
{job="systemd-journal", host=~"$host"} |~ "(?i)(error|failed|critical)"
```
Tipo: Logs | Datasource: Loki

### 5.6 — Importar dashboards prontos (offline)

Você pode usar dashboards JSON prontos do Grafana Labs. Para ambientes air-gapped:

1. Com internet: acesse https://grafana.com/grafana/dashboards
2. Busque "Node Exporter Full" (ID: 1860) ou outro dashboard
3. Clique em **Download JSON**
4. No Grafana do servidor: **Dashboards → Import → Upload JSON file**

> Dashboard popular para Linux: **Node Exporter Full** (ID 1860)

---

## 6. Configurando Alertas

### 6.1 — Como funciona o sistema de alertas

```
Alert Rule (define a condição)
  └─ Avalia a cada X minutos
       └─ Se condição verdadeira por Y minutos
            └─ Dispara → Contact Point (email, Slack, Teams, webhook...)
```

### 6.2 — Criar uma regra de alerta

1. Menu → **Alerting** → **Alert rules** → **New alert rule**

**Passo a passo:**

**Seção 1: Define query and alert condition**
- Selecione o datasource (Prometheus ou Loki)
- Escreva a query métrica
- Em **Expressions**, configure a condição:
  - `IS ABOVE 80` = dispara quando o valor superar 80

**Seção 2: Set evaluation behavior**
- **Evaluate every**: frequência de verificação (ex: `1m`)
- **For**: quanto tempo a condição precisa ser verdadeira antes de disparar (ex: `5m`)
  > "For 5m" evita alertas falsos de picos momentâneos

**Seção 3: Configure labels and notifications**
- Adicione labels como `severity=warning` ou `severity=critical`
- Selecione o Notification policy

**Seção 4: Add annotations**
- **Summary**: descrição curta (ex: "CPU alta em {{ $labels.host }}")
- **Description**: detalhes e sugestões de ação

### 6.3 — Alertas prontos para copiar

**CPU alta por 5 minutos:**
```promql
100 - (avg by (host)(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100) > 80
```
Condition: IS ABOVE | Value: 80 | For: 5m

**Memória crítica:**
```promql
100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 90
```
Condition: IS ABOVE | Value: 90 | For: 2m

**Disco quase cheio:**
```promql
100 * (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) > 85
```
Condition: IS ABOVE | Value: 85 | For: 10m

**Agente parou de enviar dados (host down):**
```promql
absent_over_time(node_load1{host="obs-agent1"}[5m])
```
Condition: HAS VALUE | For: 0s (dispara imediatamente)

**Muitos erros nos logs (Loki):**
```logql
sum(count_over_time({job="systemd-journal"} |~ "(?i)(error|critical)" [5m])) > 50
```
Condition: IS ABOVE | Value: 50 | For: 0s

### 6.4 — Configurar onde os alertas chegam (Contact Points)

1. Menu → **Alerting** → **Contact points** → **Add contact point**

**Webhook (Slack, Teams, etc):**
```
Type: Webhook
URL: https://hooks.slack.com/services/xxx/yyy/zzz
```

**Email:**
```
Type: Email
Addresses: time@empresa.com;outro@empresa.com
```
> Requer configuração de SMTP em **Administration → SMTP settings** ou em `grafana.ini`

**Grafana internal (só notificação dentro do Grafana — sem SMTP):**
```
Type: Grafana internal
```
> Útil para lab sem servidor de email

### 6.5 — Notification policies

Define qual Contact Point recebe qual alerta baseado em labels.

**Exemplo:**
- Label `severity=critical` → Email do plantão 24h
- Label `severity=warning` → Canal #alertas-infra no Slack

1. **Alerting → Notification policies**
2. Clique em **...** → **Edit** na Default policy
3. Ou crie políticas específicas com matchers de label

### 6.6 — Testando alertas

Para testar sem esperar uma condição real:

1. Vá em **Alerting → Alert rules**
2. Clique na regra → **View** → **Test rule**
3. Ou crie temporariamente um alerta com condição fácil de atingir (ex: CPU > 1%)

---

## 7. Operações do Dia a Dia

### 7.1 — Adicionar um novo servidor para monitorar

1. Edite o inventário:
   ```bash
   nano /opt/observability-stack/inventories/production/hosts.ini
   # Adicione o IP no grupo correto
   ```

2. Configure SSH e sudo no novo servidor:
   ```bash
   ssh-copy-id user_aap@IP_NOVO_SERVIDOR
   ssh user_aap@IP_NOVO_SERVIDOR "sudo bash -c 'echo user_aap ALL=\(ALL\) NOPASSWD:ALL > /etc/sudoers.d/ansible'"
   ```

3. Rode o playbook só no novo servidor:
   ```bash
   cd /opt/observability-stack
   ansible-playbook playbooks/20_linux_agents.yml --limit IP_NOVO_SERVIDOR
   ```

4. O servidor aparece automaticamente no Grafana em ~2 minutos.

### 7.2 — Adicionar novos caminhos de log

1. Edite o `group_vars/all.yml`:
   ```yaml
   alloy_log_paths:
     - /var/log/messages
     - /var/log/meu-novo-app/*.log   # ← adicione aqui
   ```

2. Re-rode o playbook de agentes:
   ```bash
   ansible-playbook playbooks/20_linux_agents.yml
   ```

### 7.3 — Ver saúde da stack

```bash
# No obs-server
sudo systemctl status loki grafana-server prometheus

# Ver uso de disco (dados do Prometheus e Loki)
du -sh /var/lib/loki/
du -sh /var/lib/prometheus/

# Ver logs do Alloy em um agente
ssh user_aap@IP_AGENTE
sudo journalctl -u alloy -f
```

### 7.4 — Acessar a UI do Alloy (debug)

- Agent 1: `http://IP_AGENT1:12345`
- Agent 2: `http://IP_AGENT2:12345`

Na UI do Alloy:
- **Graph**: visualiza o pipeline de componentes
- **Components**: status de cada componente (verde = saudável)
- **Clustering**: se estiver usando clustering de agentes

---

## 8. Referência Rápida

### LogQL — Cheatsheet

```logql
# Básico
{job="systemd-journal"}
{job="systemd-journal", host="servidor1"}

# Filtros de texto
|= "palavra"          # contém
!= "palavra"          # não contém
|~ "regex"            # match regex
!~ "regex"            # não match regex

# Parsing (extrair campos)
| json                # parse JSON
| logfmt              # parse logfmt (key=value)
| pattern "<ip> - <user> [<date>]"  # parse por padrão

# Métricas de log
count_over_time({...}[5m])          # contagem em janela
rate({...}[5m])                     # taxa por segundo
bytes_over_time({...}[5m])          # volume de bytes
```

### PromQL — Cheatsheet

```promql
# Instante atual
node_load1
node_load1{host="servidor1"}

# Funções de range
rate(counter[5m])           # taxa por segundo
increase(counter[1h])       # aumento total em 1h
avg_over_time(gauge[1h])    # média de 1h

# Agregações
sum by (host)(métrica)
avg by (host)(métrica)
max by (host)(métrica)
min by (host)(métrica)
count by (host)(métrica)

# Aritmética
métrica * 100               # multiplica por 100
(a - b) / b * 100           # variação percentual
```

---

*Documentação gerada em 2026-06-10. Stack: Loki 3.6.0 · Grafana 13.0.0 · Prometheus 3.11.0 · Alloy 1.9.0*
