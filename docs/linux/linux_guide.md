# Guia Linux — Baseline & Hardening RHEL

Referência completa para o playbook `00_linux_guide.yml`: instalação de pacotes base, configuração de ambiente shell e hardening de segurança em hosts Red Hat/RHEL.

Parte do conjunto: [`general_guide.md`](general_guide.md) · [`mysql_guide.md`](mysql_guide.md) · [`postgres_guide.md`](postgres_guide.md) · [`sqlserver_guide.md`](sqlserver_guide.md) · [`oracle_guide.md`](oracle_guide.md)

---

## O que este playbook faz

O `00_linux_guide.yml` prepara o sistema operacional RHEL antes de qualquer instalação de banco de dados. Ele executa 4 roles em sequência:

1. **baseline_system** — instala pacotes essenciais, configura NTP (chrony), desabilita IPv6 e firewalld, configura journald persistente
2. **shell_environment** — configura histórico de shell, umask e profile.d
3. **hardening_security** — aplica políticas de senha via `/etc/login.defs`, configura SELinux
4. **monitoring_logs** — instala e configura Zabbix Agent 5.0, configura logrotate

Este playbook roda **antes** de qualquer `deploy_*.yml`. Nos playbooks de banco, as roles `baseline_system` e `shell_environment` já são invocadas automaticamente pelas tags `os_prep` e `bootstrap`. O `00_linux_guide.yml` existe para aplicar baseline em hosts que ainda não têm banco instalado ou para reforçar configurações de forma independente.

---

## Como executar

```bash
# Rodar tudo nos hosts padrão (all):
ansible-playbook playbooks/00_linux_guide.yml

# Limitar a um host específico:
ansible-playbook playbooks/00_linux_guide.yml -l postgresvm

# Limitar a um grupo (variável servidores):
ansible-playbook playbooks/00_linux_guide.yml -e "servidores=database_servers"

# Só a fase de pacotes base:
ansible-playbook playbooks/00_linux_guide.yml --tags baseline_system

# Só configuração de shell:
ansible-playbook playbooks/00_linux_guide.yml --tags shell_environment

# Só hardening de segurança:
ansible-playbook playbooks/00_linux_guide.yml --tags hardening_security

# Só instalar/configurar agente Zabbix:
ansible-playbook playbooks/00_linux_guide.yml --tags monitoring_logs

# Dry-run (simula sem executar):
ansible-playbook playbooks/00_linux_guide.yml --check

# Múltiplas tags:
ansible-playbook playbooks/00_linux_guide.yml --tags baseline_system,shell_environment
```

### Parâmetros do playbook

| Parâmetro | Valor | Descrição |
|---|---|---|
| `hosts` | `{{ servidores \| default('all') }}` | Hosts alvo. Padrão: `all`. Sobrescrever via `-e "servidores=mysqlvm"`. |
| `serial` | `10` | Processa 10 hosts por vez — evita sobrecarga em inventários grandes. |
| `max_fail_percentage` | `10` | Aborta se mais de 10% dos hosts falhar. |

---

## Mapa de Fases

| Fase | Role | Tags | O que faz |
|---|---|---|---|
| 1 | `baseline_system` | `baseline_system` | Pacotes, NTP, IPv6, firewalld, journald |
| 2 | `shell_environment` | `shell_environment` | Histórico shell, umask, profile.d |
| 3 | `hardening_security` | `hardening_security` | Políticas de senha, SELinux |
| 4 | `monitoring_logs` | `monitoring_logs` | Zabbix Agent, logrotate |

---

## Variáveis — `roles/baseline_system/defaults/main.yml`

### Controle de sistema

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `disable_ipv6` | bool | `true` | Desabilita IPv6 via sysctl. Reduz superfície de ataque em ambientes sem IPv6. |
| `disable_firewalld` | bool | `true` | Desabilita e para o firewalld. Controlado por IPsec/ACL externas no lab. |
| `journald_storage` | string | `persistent` | Modo de armazenamento do systemd-journal. `persistent` = guarda logs em `/var/log/journal` entre reboots. `volatile` = perde ao reiniciar. |

### Pacotes

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `install_baseline_packages` | bool | `true` | Se `false`, pula toda a instalação de pacotes. |
| `baseline_packages_network` | list | `[net-tools, bind-utils, tcpdump, nmap]` | Ferramentas de rede para diagnóstico. |
| `baseline_packages_tools` | list | `[vim-enhanced, curl, wget, tree, unzip, lsof, psmisc]` | Utilitários essenciais de sysadmin. |
| `baseline_packages_monitoring` | list | `[sysstat, iptraf-ng]` | Ferramentas de monitoramento de performance. |
| `baseline_packages_misc` | list | `[rsync, bash-completion, ed, ftp, yum-utils, mlocate, bzip2, telnet, perl]` | Pacotes miscellaneous de suporte. |
| `baseline_packages` | list | *(merge das 4 listas acima)* | Lista final usada na task de instalação. Sobrescrever para instalar pacotes customizados. |

### NTP / Chrony

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `chrony_enabled` | bool | `true` | Se `true`, instala e configura chrony como cliente NTP. |
| `chrony_servers` | list | `[0.pool.ntp.org, 1.pool.ntp.org, 2.pool.ntp.org]` | Servidores NTP. Em ambientes offline, trocar por servidor NTP interno. |
| `chrony_leapsecmode` | string | `slew` | Como lidar com segundos bissextos. `slew` = ajuste gradual (não causa salto de clock — recomendado para bancos). |
| `chrony_rc_local_enabled` | bool | `true` | Adiciona sync forçado no `/etc/rc.local` ao boot. Garante sincronismo antes do banco subir. |
| `chrony_rc_local_server` | string | `0.pool.ntp.org` | Servidor NTP para o sync forçado no rc.local. |

---

## Variáveis — `roles/monitoring_logs/defaults/main.yml`

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `zabbix_server` | string | `192.168.137.159` | IP do servidor Zabbix onde o agente envia dados. |
| `zabbix_repo_host` | string | `192.168.137.148` | IP do repositoryvm onde o RPM do Zabbix Agent está hospedado. |
| `zabbix_agent_rpm_url` | string | `http://{{ zabbix_repo_host }}:8080/zabbix/zabbix-agent-5.0.47-1.el9.x86_64.rpm` | URL completa do RPM. Composta automaticamente a partir de `zabbix_repo_host`. |

---

## Mapa de Tags Detalhado

### `baseline_system`

| Sub-tag | O que executa |
|---|---|
| `selinux` | Configura SELinux (permissive ou enforcing) |
| `packages` | Instala `baseline_packages` via dnf |
| `firewalld` | Para e desabilita firewalld |
| `ipv6` | Desabilita IPv6 via sysctl |
| `journald` | Configura `/etc/systemd/journald.conf` |
| `ctrlaltdel` | Desabilita Ctrl+Alt+Del (previne reboot acidental) |
| `chrony` | Instala e configura chrony como serviço NTP |
| `rclocal` | Configura sync NTP no `/etc/rc.local` |

### `shell_environment`

| Sub-tag | O que executa |
|---|---|
| `shell_environment` | Configura `HISTSIZE`, `HISTFILESIZE`, umask e profile.d |

### `hardening_security`

| Sub-tag | O que executa |
|---|---|
| `hardening_security` | Todas as tarefas de hardening |
| `login_defs` | Políticas de senha em `/etc/login.defs` (PASS_MAX_DAYS, PASS_MIN_DAYS, etc.) |
| `selinux` | Garante SELinux ativo |

### `monitoring_logs`

| Sub-tag | O que executa |
|---|---|
| `monitoring_logs` | Todas as tarefas de monitoramento |
| `logrotate` | Configura rotação de logs via logrotate |
| `zabbix` | Instala RPM, configura `zabbix_agentd.conf`, habilita serviço |

---

## Exemplos de Sobrescrita de Variáveis

### Trocar servidor NTP (ambiente isolado)

```yaml
# Em host_vars/mysqlvm.yml ou via -e:
chrony_servers:
  - "192.168.137.1"   # NTP interno do lab
chrony_rc_local_server: "192.168.137.1"
```

### Instalar pacotes adicionais

```yaml
# Adicionar ao baseline sem substituir a lista padrão:
ansible-playbook playbooks/00_linux_guide.yml \
  -e '{"baseline_packages_misc": ["rsync","bash-completion","ed","ftp","yum-utils","mlocate","bzip2","telnet","perl","strace"]}'
```

### Pular instalação de pacotes (só NTP)

```yaml
ansible-playbook playbooks/00_linux_guide.yml \
  --tags chrony \
  -e "install_baseline_packages=false"
```

---

## Ver Também

- [`general_guide.md`](general_guide.md) — Arquitetura geral do projeto
- [`utility_playbooks_guide.md`](utility_playbooks_guide.md) — Outros playbooks de suporte
- [`offline_requirements.md`](offline_requirements.md) — Como preparar ambiente offline
