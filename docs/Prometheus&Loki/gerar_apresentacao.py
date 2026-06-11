"""
Gera apresentação PowerPoint da Stack de Observabilidade.
Execute: py -3 gerar_apresentacao.py
"""
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN
from pptx.util import Inches, Pt
import copy

# ─── Paleta de cores ──────────────────────────────────────────────────────────
BG_DARK    = RGBColor(0x0F, 0x11, 0x17)   # fundo escuro
BG_CARD    = RGBColor(0x1E, 0x23, 0x30)   # card/box
ACCENT     = RGBColor(0x3B, 0x82, 0xF6)   # azul principal
ACCENT2    = RGBColor(0x22, 0xD3, 0xEE)   # ciano (Loki)
ACCENT3    = RGBColor(0xF5, 0x9E, 0x0B)   # laranja (Prometheus)
ACCENT4    = RGBColor(0x10, 0xB9, 0x81)   # verde (Alloy)
ACCENT5    = RGBColor(0xA7, 0x8B, 0xFA)   # roxo (Grafana)
WHITE      = RGBColor(0xFF, 0xFF, 0xFF)
GRAY       = RGBColor(0x94, 0xA3, 0xB8)
GRAY_LIGHT = RGBColor(0xE2, 0xE8, 0xF0)

prs = Presentation()
prs.slide_width  = Inches(13.33)
prs.slide_height = Inches(7.5)

BLANK = prs.slide_layouts[6]  # completely blank


def slide_add(title_txt, subtitle_txt=None):
    """Adiciona slide em branco com fundo escuro."""
    slide = prs.slides.add_slide(BLANK)
    # fundo
    bg = slide.background
    fill = bg.fill
    fill.solid()
    fill.fore_color.rgb = BG_DARK
    return slide


def add_rect(slide, l, t, w, h, fill_color, alpha=None):
    shape = slide.shapes.add_shape(1, Inches(l), Inches(t), Inches(w), Inches(h))
    shape.fill.solid()
    shape.fill.fore_color.rgb = fill_color
    shape.line.fill.background()
    return shape


def add_text(slide, text, l, t, w, h, size=18, bold=False, color=WHITE,
             align=PP_ALIGN.LEFT, italic=False, wrap=True):
    txBox = slide.shapes.add_textbox(Inches(l), Inches(t), Inches(w), Inches(h))
    tf = txBox.text_frame
    tf.word_wrap = wrap
    p = tf.paragraphs[0]
    p.alignment = align
    run = p.add_run()
    run.text = text
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.color.rgb = color
    run.font.italic = italic
    return txBox


def accent_bar(slide, color=ACCENT):
    """Barra colorida no topo do slide."""
    add_rect(slide, 0, 0, 13.33, 0.08, color)


def slide_title_only(title, subtitle="", accent_color=ACCENT):
    slide = slide_add(title)
    accent_bar(slide, accent_color)
    add_text(slide, title, 0.8, 0.3, 11.5, 1.2, size=38, bold=True,
             color=WHITE, align=PP_ALIGN.LEFT)
    if subtitle:
        add_text(slide, subtitle, 0.8, 1.5, 11.5, 0.8, size=18,
                 color=GRAY, align=PP_ALIGN.LEFT)
    return slide


# ═══════════════════════════════════════════════════════════════════════════════
# SLIDE 1 — Capa
# ═══════════════════════════════════════════════════════════════════════════════
s = slide_add("Capa")
add_rect(s, 0, 0, 13.33, 7.5, BG_DARK)
add_rect(s, 0, 0, 0.5, 7.5, ACCENT)
add_rect(s, 0.5, 3.1, 12.83, 0.06, ACCENT)

add_text(s, "Stack de Observabilidade", 1.0, 0.8, 11.3, 1.5,
         size=44, bold=True, color=WHITE)
add_text(s, "Loki  ·  Grafana  ·  Prometheus  ·  Alloy", 1.0, 2.2, 11.3, 0.8,
         size=22, bold=False, color=ACCENT2)
add_text(s, "Monitoramento unificado de logs e métricas\npara ambientes corporativos",
         1.0, 3.3, 10.0, 1.0, size=16, color=GRAY)
add_text(s, "Infraestrutura  ·  2026", 1.0, 6.7, 11.3, 0.6,
         size=12, color=GRAY, italic=True)


# ═══════════════════════════════════════════════════════════════════════════════
# SLIDE 2 — O Problema
# ═══════════════════════════════════════════════════════════════════════════════
s = slide_title_only("O Problema", "Como está hoje — sem observabilidade", ACCENT3)

boxes = [
    ("🔍  Logs espalhados", "Cada servidor tem seus logs em /var/log.\nNão há busca centralizada.", ACCENT3),
    ("⏱  Tempo de resposta lento", "Para investigar um erro, você precisa\nacessar servidor por servidor via SSH.", ACCENT3),
    ("📉  Sem visibilidade de métricas", "CPU alta? Disco cheio? Você só descobre\nquando o usuário liga reclamando.", ACCENT3),
    ("🔔  Sem alertas proativos", "Sem monitoramento, você reage\naos problemas, não os previne.", ACCENT3),
]
cols = [0.4, 3.5, 6.6, 9.7]
for i, (title, body, color) in enumerate(boxes):
    x = cols[i]
    add_rect(s, x, 1.8, 3.0, 4.0, BG_CARD)
    add_rect(s, x, 1.8, 3.0, 0.06, color)
    add_text(s, title, x+0.15, 2.0, 2.7, 0.7, size=13, bold=True, color=WHITE)
    add_text(s, body, x+0.15, 2.8, 2.7, 2.8, size=11, color=GRAY)


# ═══════════════════════════════════════════════════════════════════════════════
# SLIDE 3 — A Solução
# ═══════════════════════════════════════════════════════════════════════════════
s = slide_title_only("A Solução", "Uma plataforma única para logs, métricas e alertas", ACCENT)
add_text(s, "A stack de observabilidade traz visibilidade completa do ambiente com ferramentas open-source de mercado.",
         0.8, 1.6, 11.5, 0.6, size=14, color=GRAY_LIGHT)

comps = [
    ("Grafana", "Interface web unificada\npara visualizar logs\ne métricas em dashboards", ACCENT5),
    ("Loki", "Banco de dados de logs\nIndexação por labels\nRetenção configurável", ACCENT2),
    ("Prometheus", "Banco de dados de\nmétricas temporais\nAlertas e queries", ACCENT3),
    ("Alloy", "Agente unificado\nColeta logs e métricas\nem cada servidor", ACCENT4),
]
cx = [0.5, 3.5, 6.5, 9.5]
for i, (name, desc, color) in enumerate(comps):
    x = cx[i]
    add_rect(s, x, 2.5, 3.0, 3.8, BG_CARD)
    add_rect(s, x, 2.5, 3.0, 0.5, color)
    add_text(s, name, x+0.15, 2.55, 2.7, 0.4, size=15, bold=True, color=WHITE, align=PP_ALIGN.CENTER)
    add_text(s, desc, x+0.15, 3.15, 2.7, 2.8, size=11, color=GRAY_LIGHT)


# ═══════════════════════════════════════════════════════════════════════════════
# SLIDE 4 — Arquitetura
# ═══════════════════════════════════════════════════════════════════════════════
s = slide_title_only("Arquitetura", "Como os componentes se conectam", ACCENT4)

# Servidor central
add_rect(s, 5.5, 1.8, 3.8, 4.5, BG_CARD)
add_rect(s, 5.5, 1.8, 3.8, 0.06, ACCENT)
add_text(s, "obs-server", 5.65, 1.9, 3.5, 0.5, size=13, bold=True, color=ACCENT)
add_text(s, "Grafana :3000", 5.65, 2.5, 3.5, 0.35, size=11, bold=True, color=ACCENT5)
add_text(s, "Loki :3100", 5.65, 2.95, 3.5, 0.35, size=11, bold=True, color=ACCENT2)
add_text(s, "Prometheus :9090", 5.65, 3.4, 3.5, 0.35, size=11, bold=True, color=ACCENT3)

# Agentes
for i, (name, y) in enumerate([("obs-agent1", 1.9), ("obs-agent2", 3.9)]):
    add_rect(s, 1.0, y, 3.0, 1.5, BG_CARD)
    add_rect(s, 1.0, y, 3.0, 0.06, ACCENT4)
    add_text(s, name, 1.15, y+0.15, 2.7, 0.4, size=12, bold=True, color=ACCENT4)
    add_text(s, "Alloy :12345", 1.15, y+0.6, 2.7, 0.3, size=10, color=GRAY)
    add_text(s, "logs + métricas", 1.15, y+1.0, 2.7, 0.3, size=10, color=GRAY)

# Setas (texto indicando fluxo)
add_text(s, "push logs → :3100\npush metrics → :9090",
         3.95, 2.3, 1.7, 0.7, size=9, color=GRAY, italic=True)
add_text(s, "push logs → :3100\npush metrics → :9090",
         3.95, 4.1, 1.7, 0.7, size=9, color=GRAY, italic=True)

# Usuário
add_rect(s, 10.3, 2.8, 2.5, 1.2, BG_CARD)
add_text(s, "👤  Usuário / Time", 10.4, 2.9, 2.3, 0.4, size=11, bold=True, color=WHITE)
add_text(s, "browser :3000", 10.4, 3.35, 2.3, 0.4, size=10, color=GRAY)


# ═══════════════════════════════════════════════════════════════════════════════
# SLIDE 5 — Loki: Logs
# ═══════════════════════════════════════════════════════════════════════════════
s = slide_title_only("Loki — Centralização de Logs", "", ACCENT2)

add_text(s, "O que é coletado automaticamente em cada servidor:",
         0.8, 1.5, 11.5, 0.5, size=14, color=GRAY_LIGHT)

sources = [
    ("📋  systemd journal", "Todos os logs do SO:\nSSH, sudo, cron, serviços"),
    ("📁  /var/log/messages", "Mensagens gerais do sistema"),
    ("🔒  /var/log/secure", "Acessos, autenticações, SSH"),
    ("⏰  /var/log/cron", "Execuções agendadas"),
    ("🌐  /var/log/httpd/*", "Logs de aplicações web"),
]
for i, (src, desc) in enumerate(sources):
    row = i // 3
    col = i % 3
    x = 0.8 + col * 4.1
    y = 2.2 + row * 1.7
    add_rect(s, x, y, 3.8, 1.5, BG_CARD)
    add_text(s, src, x+0.15, y+0.15, 3.5, 0.5, size=12, bold=True, color=WHITE)
    add_text(s, desc, x+0.15, y+0.65, 3.5, 0.7, size=10, color=GRAY)

add_text(s, "Exemplo de query (LogQL):", 0.8, 5.8, 3.5, 0.4, size=12, color=GRAY, bold=True)
add_rect(s, 0.8, 6.2, 11.5, 0.9, RGBColor(0x0D, 0x11, 0x1A))
add_text(s, '{job="systemd-journal"} |= "Failed password"   →  todos os logins SSH recusados',
         1.0, 6.3, 11.0, 0.6, size=11, color=ACCENT2)


# ═══════════════════════════════════════════════════════════════════════════════
# SLIDE 6 — Prometheus: Métricas
# ═══════════════════════════════════════════════════════════════════════════════
s = slide_title_only("Prometheus — Métricas de Infraestrutura", "", ACCENT3)

add_text(s, "Métricas coletadas a cada 15 segundos via Grafana Alloy:",
         0.8, 1.5, 11.5, 0.5, size=14, color=GRAY_LIGHT)

metrics = [
    ("🖥️  CPU", "Uso por core e modo\n(user, system, idle, iowait)"),
    ("🧠  Memória", "Total, disponível,\nbuffers, cache"),
    ("💾  Disco", "Espaço usado/livre\npor partição, I/O"),
    ("🌐  Rede", "Bytes enviados/recebidos\npor interface"),
    ("⏱️  Uptime", "Tempo online,\nload average"),
    ("⚙️  Processos", "Processos em execução,\nzombies, forks"),
]
for i, (name, desc) in enumerate(metrics):
    row = i // 3
    col = i % 3
    x = 0.8 + col * 4.1
    y = 2.2 + row * 1.9
    add_rect(s, x, y, 3.8, 1.7, BG_CARD)
    add_text(s, name, x+0.15, y+0.15, 3.5, 0.5, size=13, bold=True, color=WHITE)
    add_text(s, desc, x+0.15, y+0.7, 3.5, 0.8, size=10, color=GRAY)

add_text(s, "Exemplo de query (PromQL):", 0.8, 6.2, 3.5, 0.4, size=12, color=GRAY, bold=True)
add_rect(s, 4.5, 6.1, 8.0, 0.9, RGBColor(0x0D, 0x11, 0x1A))
add_text(s, "100 - (avg by (host)(rate(node_cpu_seconds_total{mode='idle'}[5m]))*100)",
         4.7, 6.25, 7.6, 0.5, size=10, color=ACCENT3)


# ═══════════════════════════════════════════════════════════════════════════════
# SLIDE 7 — Grafana: Dashboards
# ═══════════════════════════════════════════════════════════════════════════════
s = slide_title_only("Grafana — Dashboards e Visualização", "", ACCENT5)

add_text(s, "Visualização unificada de logs e métricas em um só lugar:",
         0.8, 1.5, 11.5, 0.5, size=14, color=GRAY_LIGHT)

panels = [
    ("📈  Time Series", "Histórico de CPU, memória\ne rede ao longo do tempo", ACCENT3),
    ("🎯  Gauge", "Percentual atual de uso\nde recurso (0–100%)", ACCENT),
    ("🔢  Stat", "Valor único em destaque\ncomo load ou uptime", ACCENT4),
    ("📋  Logs Panel", "Stream de logs do Loki\ncom busca em tempo real", ACCENT2),
    ("📊  Bar Gauge", "Comparar uso de disco\nentre vários servidores", ACCENT5),
    ("🗺️  Heatmap", "Densidade de eventos\naolongo do tempo", ACCENT3),
]
for i, (name, desc, color) in enumerate(panels):
    row = i // 3
    col = i % 3
    x = 0.8 + col * 4.1
    y = 2.2 + row * 1.9
    add_rect(s, x, y, 3.8, 1.7, BG_CARD)
    add_rect(s, x, y, 0.06, 1.7, color)
    add_text(s, name, x+0.25, y+0.15, 3.4, 0.5, size=12, bold=True, color=WHITE)
    add_text(s, desc, x+0.25, y+0.7, 3.4, 0.8, size=10, color=GRAY)


# ═══════════════════════════════════════════════════════════════════════════════
# SLIDE 8 — Alertas
# ═══════════════════════════════════════════════════════════════════════════════
s = slide_title_only("Alertas Proativos", "Grafana Unified Alerting", ACCENT3)

add_text(s, "Regras de alerta que disparam automaticamente quando algo foge do normal:",
         0.8, 1.5, 11.5, 0.5, size=14, color=GRAY_LIGHT)

alerts = [
    ("🔴  CPU Alta", "CPU > 80% por 5 minutos\ncontinuamente", "critical"),
    ("🟡  Memória", "Memória > 90%\npor 2 minutos", "warning"),
    ("🔴  Disco Cheio", "Disco / > 85%\npor 10 minutos", "critical"),
    ("🟡  Host Down", "Agente parou de enviar\ndados por 5 minutos", "warning"),
    ("🟡  Muitos Erros", "Mais de 50 erros\nnos logs em 5 min", "warning"),
]
for i, (name, cond, sev) in enumerate(alerts):
    y = 2.2 + i * 0.92
    color = RGBColor(0xEF, 0x44, 0x44) if sev == "critical" else RGBColor(0xF5, 0x9E, 0x0B)
    add_rect(s, 0.8, y, 0.08, 0.75, color)
    add_text(s, name, 1.1, y+0.05, 3.0, 0.4, size=12, bold=True, color=WHITE)
    add_text(s, cond, 1.1, y+0.42, 3.0, 0.3, size=10, color=GRAY)
    add_rect(s, 4.5, y, 8.5, 0.75, BG_CARD)
    lbl = "Critical" if sev == "critical" else "Warning"
    add_text(s, lbl, 4.7, y+0.2, 1.5, 0.35, size=10, bold=True, color=color)
    add_text(s, "→  Email  ·  Slack  ·  Teams  ·  Webhook",
             6.3, y+0.2, 6.4, 0.35, size=10, color=GRAY)

add_text(s, "💡  Os alertas chegam no canal que você definir: Slack, Teams, e-mail, ou qualquer webhook",
         0.8, 6.8, 11.5, 0.5, size=11, color=GRAY, italic=True)


# ═══════════════════════════════════════════════════════════════════════════════
# SLIDE 9 — Implementação / Deploy
# ═══════════════════════════════════════════════════════════════════════════════
s = slide_title_only("Implementação", "Como é feito o deploy — Ansible Air-Gapped", ACCENT4)

add_text(s, "Toda a instalação é automatizada via Ansible. Funciona sem internet nos servidores alvo.",
         0.8, 1.5, 11.5, 0.5, size=14, color=GRAY_LIGHT)

steps = [
    ("1", "Baixar artefatos", "Na sua máquina (com internet): binários do Loki, Grafana, Prometheus e Alloy.", ACCENT),
    ("2", "Transferir para o controller", "Copia o pacote (~520 MB) para o servidor que vai rodar o Ansible.", ACCENT4),
    ("3", "Configurar inventário", "Edita um arquivo com os IPs dos servidores e as senhas de acesso.", ACCENT3),
    ("4", "Executar 3 comandos", "ansible-playbook preflight → server → agents. ~5 minutos no total.", ACCENT5),
    ("5", "Validar", "Grafana em http://servidor:3000. Logs e métricas chegando automaticamente.", ACCENT2),
]
for i, (num, title, desc, color) in enumerate(steps):
    y = 2.1 + i * 0.95
    add_rect(s, 0.8, y, 0.55, 0.75, color)
    add_text(s, num, 0.8, y+0.05, 0.55, 0.65, size=20, bold=True, color=WHITE, align=PP_ALIGN.CENTER)
    add_text(s, title, 1.6, y+0.05, 3.5, 0.4, size=12, bold=True, color=WHITE)
    add_text(s, desc, 1.6, y+0.42, 11.0, 0.35, size=10, color=GRAY)


# ═══════════════════════════════════════════════════════════════════════════════
# SLIDE 10 — Benefícios
# ═══════════════════════════════════════════════════════════════════════════════
s = slide_title_only("Benefícios", "", ACCENT)

benefits = [
    ("⚡  Resposta mais rápida", "Identifique a causa raiz de incidentes\nem minutos, não em horas.", ACCENT),
    ("🔔  Alertas proativos", "Seja notificado antes que\no usuário perceba o problema.", ACCENT4),
    ("🔒  Segurança e auditoria", "Todos os logins, comandos sudo\ne acessos SSH ficam registrados.", ACCENT2),
    ("📊  Visibilidade completa", "CPU, memória, disco, rede\nde todos os servidores em um painel.", ACCENT3),
    ("🆓  Open-source", "Grafana, Loki e Prometheus são\nopen-source. Sem licença.", ACCENT5),
    ("🚀  Deploy automatizado", "Adicionar um novo servidor\nleva menos de 5 minutos.", ACCENT4),
]
for i, (title, desc, color) in enumerate(benefits):
    row = i // 2
    col = i % 2
    x = 0.8 + col * 6.3
    y = 1.5 + row * 1.8
    add_rect(s, x, y, 6.0, 1.6, BG_CARD)
    add_rect(s, x, y, 6.0, 0.06, color)
    add_text(s, title, x+0.2, y+0.15, 5.6, 0.5, size=13, bold=True, color=WHITE)
    add_text(s, desc, x+0.2, y+0.7, 5.6, 0.7, size=11, color=GRAY)


# ═══════════════════════════════════════════════════════════════════════════════
# SLIDE 11 — Próximos Passos
# ═══════════════════════════════════════════════════════════════════════════════
s = slide_title_only("Próximos Passos", "", ACCENT5)

steps2 = [
    ("📦  Fase 1 — Infraestrutura base", "Deploy da stack no servidor de monitoramento.\nInstalar agentes nos servidores críticos.", "2 servidores · ~1 dia"),
    ("📋  Fase 2 — Dashboards e alertas", "Criar dashboards por equipe.\nConfigurar alertas de CPU, disco, serviços.", "~3 dias"),
    ("🔌  Fase 3 — Integrar aplicações", "Adicionar caminhos de log das aplicações.\nConfigurar parsing de logs JSON.", "Por demanda"),
    ("📣  Fase 4 — Notificações", "Integrar com Slack/Teams.\nDefinir canais por severidade.", "~1 dia"),
]
for i, (title, desc, effort) in enumerate(steps2):
    y = 1.7 + i * 1.35
    add_rect(s, 0.8, y, 11.5, 1.2, BG_CARD)
    add_rect(s, 0.8, y, 0.06, 1.2, ACCENT5)
    add_text(s, title, 1.1, y+0.1, 7.5, 0.5, size=13, bold=True, color=WHITE)
    add_text(s, desc, 1.1, y+0.6, 7.5, 0.5, size=10, color=GRAY)
    add_rect(s, 10.0, y+0.25, 2.1, 0.6, RGBColor(0x2D, 0x37, 0x48))
    add_text(s, effort, 10.1, y+0.35, 2.0, 0.4, size=9, color=GRAY_LIGHT, align=PP_ALIGN.CENTER)


# ═══════════════════════════════════════════════════════════════════════════════
# SLIDE 12 — Perguntas
# ═══════════════════════════════════════════════════════════════════════════════
s = slide_add("Perguntas")
add_rect(s, 0, 0, 0.5, 7.5, ACCENT)
add_rect(s, 0.5, 3.5, 12.83, 0.06, ACCENT)

add_text(s, "Obrigado!", 1.2, 1.0, 10.5, 1.5, size=52, bold=True, color=WHITE)
add_text(s, "Perguntas?", 1.2, 2.5, 10.5, 1.0, size=30, color=ACCENT2)

add_text(s, "Stack:  Loki 3.6  ·  Grafana 13.0  ·  Prometheus 3.11  ·  Alloy 1.9",
         1.2, 3.8, 10.5, 0.6, size=13, color=GRAY)
add_text(s, "Documentação completa: docs/instalacao_airgapped.md  ·  docs/guia_operacoes.md",
         1.2, 4.4, 10.5, 0.5, size=12, color=GRAY)

# ─── Salvar ───────────────────────────────────────────────────────────────────
out = "stack_observabilidade.pptx"
prs.save(out)
print(f"✅  Apresentação gerada: {out}")
print(f"    Slides: {len(prs.slides)}")
