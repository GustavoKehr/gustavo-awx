#!/usr/bin/env bash
# -----------------------------------------------------------------------------#
# Script Name:   checklist_validations.sh
# Description:   Checklist validations for RHEL servers (7–10)
#
# Written by:    Alexandre Machado  - a.doamaral@samsung.com
# Owner/Team:    Linux Infrastructure
# Version:       v1.1
# Last update:   2026-02-19
#

set -u

# ------------------------------------------------------------
# Linux Guide Validation - Sections 3 to 5 (RHEL 7–10) 
#
# 3.x covered:
# 3.1 SELinux, 3.2 Firewalld, 3.3 IPv6, 3.4 journald persistent,
# 3.5 CTRL+ALT+DEL, 3.6 Subscription Manager (fast/offline),
# 3.7 Last update date (fast/offline),
# 3.8 baseline packages, 3.9 Chrony, 3.10 rc.local, 3.11 shell_environment
#
# 4.x covered:
# 4.1 login.defs (PASS_*), 4.2 SSH guide-only options + Ports 22/20022,
# 4.3 Sysstat HISTORY=90, 4.4 PAM conf files (faillock/pwhistory/pwquality),
# 4.5 chage (min/max), 4.6 perms (last/ifconfig),
# 4.7 Banner (/etc/banner + /etc/motd + ssh Banner),
# 4.8 sysstat-collect.timer,
# 4.9 UTMP/BTMP via tmpfiles (var.conf + apply + perms)
#
# 5.x covered:
# 5.1 logrotate.conf (monthly, rotate 12, compress),
# 5.2 logrotate.d rules: btmp, wtmp, dnf, + validate logrotate dry-run
# 5.3 Zabbix repo local (/etc/yum.repos.d/zabbix.repo) baseurl uses RHEL major
# 5.4 Zabbix agent config (/etc/zabbix/zabbix_agentd.conf) + service enabled/active
#
# Output: OK/FAIL per item + summary
# Exit code: 0 (all OK) | 2 (one or more FAIL)
# Report file: /tmp/linux_guide_validation_3x_4x_5x.txt (default)
# ------------------------------------------------------------

REPORT_PATH="${REPORT_PATH:-/tmp/linux_guide_validation_3x_4x_5x.txt}"
VERBOSE="${VERBOSE:-0}"

CMD_TIMEOUT="${CMD_TIMEOUT:-2}"                      # seconds for potentially slow commands
USE_FAST_OFFLINE_CHECKS="${USE_FAST_OFFLINE_CHECKS:-1}"  # 1=use fast checks for 3.6/3.7

PASS=0
FAIL=0

have_cmd() { command -v "$1" >/dev/null 2>&1; }

sanitize_detail() {
  local s="$1"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  s="${s//$'\t'/ }"
  echo "$s" | tr -s ' '
}

run_timeout() {
  local t="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${t}" "$@"
  else
    "$@"
  fi
}

result_ok() {
  local code="$1" msg="$2"
  PASS=$((PASS+1))
  printf "%-6s | %-55s | %s\n" "OK" "$code" "$(sanitize_detail "$msg")"
}

result_fail() {
  local code="$1" msg="$2"
  FAIL=$((FAIL+1))
  printf "%-6s | %-55s | %s\n" "FAIL" "$code" "$(sanitize_detail "$msg")"
}

check_sysctl_eq() {
  local key="$1" expected="$2"
  local v
  v="$(/sbin/sysctl -n "$key" 2>/dev/null || true)"
  [[ "$v" == "$expected" ]]
}

os_major() {
  local v=""
  if [[ -r /etc/os-release ]]; then
    v="$(. /etc/os-release; echo "${VERSION_ID:-}")"
  fi
  echo "${v%%.*}"
}

file_mode() { stat -c '%a' "$1" 2>/dev/null || echo ""; }
file_owner() { stat -c '%U' "$1" 2>/dev/null || echo ""; }
file_group() { stat -c '%G' "$1" 2>/dev/null || echo ""; }

grep_kv_eq() {
  local f="$1" key="$2" exp="$3"
  [[ -f "$f" ]] || return 1
  grep -Eiq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=[[:space:]]*${exp}[[:space:]]*$" "$f"
}

grep_login_defs_exact() {
  local key="$1" val="$2"
  [[ -f /etc/login.defs ]] || return 1
  grep -Eq "^[[:space:]]*${key}[[:space:]]+${val}[[:space:]]*$" /etc/login.defs
}

sshd_has_kv() {
  [[ -f /etc/ssh/sshd_config ]] || return 1
  grep -Eiq "^[[:space:]]*${1}[[:space:]]+${2}([[:space:]]+#.*)?$" /etc/ssh/sshd_config
}

sshd_has_port() {
  [[ -f /etc/ssh/sshd_config ]] || return 1
  grep -Eiq "^[[:space:]]*Port[[:space:]]+${1}([[:space:]]+#.*)?$" /etc/ssh/sshd_config
}

chage_get_field() {
  local user="$1" field="$2"
  chage -l "$user" 2>/dev/null | awk -F':' -v f="$field" '
    $1 ~ f {
      v=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print v
      exit
    }'
}

# logrotate helpers
lr_has_directive() {
  local f="$1" directive="$2"
  [[ -f "$f" ]] || return 1
  grep -Eq "^[[:space:]]*${directive}[[:space:]]*$" "$f"
}

lr_rule_has_line() {
  local f="$1" line_re="$2"
  [[ -f "$f" ]] || return 1
  grep -Eq "$line_re" "$f"
}

# zabbix helpers
zbx_repo_expected_baseurl() {
  local maj
  maj="$(os_major)"
  echo "baseurl=http://192.168.137.148:8080/zabbix"
}


{
  echo "Linux Guide Validation - Sections 3.x + 4.x + 5.x (offline-friendly)"
  echo "Host: $(hostname -f 2>/dev/null || hostname)"
  echo "OS major: $(os_major)"
  echo "Date: $(date -Is)"
  echo "------------------------------------------------------------"
  printf "%-6s | %-55s | %s\n" "STATUS" "ITEM" "DETAIL"
  echo "------------------------------------------------------------"

  #####################################
  # 3.1 - SELinux
  #####################################
  if [[ -f /etc/selinux/config ]] && grep -Eq '^\s*SELINUX\s*=\s*disabled\s*$' /etc/selinux/config; then
    if have_cmd getenforce; then
      ge="$(getenforce 2>/dev/null || true)"
      if [[ "$ge" == "Disabled" ]]; then
        result_ok "3.1 - Desabilitar SELinux" "Config disabled and runtime Disabled"
      else
        result_ok "3.1 - Desabilitar SELinux" "Config disabled (runtime=$ge) - reboot may be pending"
      fi
    else
      result_ok "3.1 - Desabilitar SELinux" "Config disabled (getenforce not available)"
    fi
  else
    result_fail "3.1 - Desabilitar SELinux" "SELINUX=disabled not found in /etc/selinux/config"
  fi

  #####################################
  # 3.2 - Firewalld
  #####################################
  if have_cmd systemctl; then
    en="$(systemctl is-enabled firewalld 2>/dev/null || true)"
    ac="$(systemctl is-active firewalld 2>/dev/null || true)"
    if [[ "$en" == "disabled" || "$en" == "masked" ]] && [[ "$ac" == "inactive" || "$ac" == "failed" || "$ac" == "unknown" ]]; then
      result_ok "3.2 - Desabilitar Firewalld" "enabled=$en active=$ac"
    else
      result_fail "3.2 - Desabilitar Firewalld" "enabled=$en active=$ac"
    fi
  else
    result_fail "3.2 - Desabilitar Firewalld" "systemctl not found"
  fi

  #####################################
  # 3.3 - IPv6 (GRUB)
  #####################################
  cmdline="$(cat /proc/cmdline 2>/dev/null || true)"

  if echo "$cmdline" | grep -qw "ipv6.disable=1"; then
    if [[ ! -e /proc/net/if_inet6 ]]; then
      result_ok "3.3 - Desabilitar IPv6" "ipv6.disable=1 ativo e IPv6 não carregado no kernel"
    else
      result_fail "3.3 - Desabilitar IPv6" "ipv6.disable=1 presente, mas IPv6 ainda ativo"
    fi
  else
    result_fail "3.3 - Desabilitar IPv6" "ipv6.disable=1 não encontrado em /proc/cmdline"
  fi


  #####################################
  # 3.4 - journald persistente
  #####################################
  jdir_ok=false
  [[ -d /var/log/journal ]] && jdir_ok=true
  storage_line="$(grep -E '^\s*Storage\s*=' /etc/systemd/journald.conf 2>/dev/null | tail -n 1 || true)"
  if $jdir_ok && echo "$storage_line" | grep -Eq '^\s*Storage\s*=\s*persistent\s*$'; then
    result_ok "3.4 - Configurar journald para logs persistentes" "/var/log/journal exists and Storage=persistent"
  else
    result_fail "3.4 - Configurar journald para logs persistentes" "dir=$([[ -d /var/log/journal ]] && echo yes || echo no) Storage_line='${storage_line:-none}'"
  fi

  #####################################
  # 3.5 - CTRL+ALT+DEL masked
  #####################################
  if have_cmd systemctl; then
    st="$(systemctl status ctrl-alt-del.target 2>/dev/null | tr -d '\r' || true)"
    if echo "$st" | grep -Eq 'Loaded:\s+masked'; then
      result_ok "3.5 - Desabilitar atalho CTRL+ALT+DEL" "ctrl-alt-del.target is masked"
    else
      link1="$(readlink -f /etc/systemd/system/ctrl-alt-del.target 2>/dev/null || true)"
      link2="$(readlink -f /usr/lib/systemd/system/ctrl-alt-del.target 2>/dev/null || true)"
      if [[ "$link1" == "/dev/null" || "$link2" == "/dev/null" ]]; then
        result_ok "3.5 - Desabilitar atalho CTRL+ALT+DEL" "ctrl-alt-del.target masked via symlink to /dev/null"
      else
        ie="$(systemctl is-enabled ctrl-alt-del.target 2>/dev/null || true)"
        result_fail "3.5 - Desabilitar atalho CTRL+ALT+DEL" "Not masked. is-enabled=${ie}"
      fi
    fi
  else
    result_fail "3.5 - Desabilitar atalho CTRL+ALT+DEL" "systemctl not found"
  fi

  #####################################
  # 3.6 - Subscription Manager (FAST/OFFLINE)
  #####################################
  if have_cmd subscription-manager; then
    if [[ "$USE_FAST_OFFLINE_CHECKS" == "1" ]]; then
      if run_timeout "$CMD_TIMEOUT" subscription-manager identity >/dev/null 2>&1; then
        result_ok "3.6 - Registro Subscription Manager" "identity=OK (offline-fast)"
      else
        if [[ -s /etc/pki/consumer/cert.pem ]]; then
          result_ok "3.6 - Registro Subscription Manager" "consumer cert present (offline-fast)"
        else
          result_fail "3.6 - Registro Subscription Manager" "not registered (identity failed; no consumer cert)"
        fi
      fi
    else
      id_out="$(run_timeout "$CMD_TIMEOUT" subscription-manager identity 2>/dev/null || true)"
      if echo "$id_out" | grep -qiE 'system identity|org name|name:'; then
        st_out="$(run_timeout "$CMD_TIMEOUT" subscription-manager status 2>/dev/null || true)"
        overall="$(echo "$st_out" | awk -F': ' '/Overall Status:/ {print $2; exit}')"
        overall="${overall:-unknown}"
        if echo "$overall" | grep -qiE 'Current|Disabled'; then
          result_ok "3.6 - Registro Subscription Manager" "identity=OK overall_status=${overall}"
        else
          result_fail "3.6 - Registro Subscription Manager" "identity=OK overall_status=${overall}"
        fi
      else
        result_fail "3.6 - Registro Subscription Manager" "identity failed (not registered?)"
      fi
    fi
  else
    result_fail "3.6 - Registro Subscription Manager" "subscription-manager command not found"
  fi

  #####################################
  # 3.7 - Atualizacao de pacotes (FAST/OFFLINE)
  #####################################
  if [[ "$USE_FAST_OFFLINE_CHECKS" == "1" ]]; then
    rpmdb_ts=""
    if [[ -f /var/lib/rpm/rpmdb.sqlite ]]; then
      rpmdb_ts="$(stat -c '%y' /var/lib/rpm/rpmdb.sqlite 2>/dev/null | cut -d'.' -f1 || true)"
    else
      rpmdb_ts="$(stat -c '%y' /var/lib/rpm/Packages 2>/dev/null | cut -d'.' -f1 || true)"
    fi

    if [[ -n "$rpmdb_ts" ]]; then
      result_ok "3.7 - Atualizacao de pacotes" "RPM DB last change: ${rpmdb_ts}"
    else
      result_fail "3.7 - Atualizacao de pacotes" "Could not read rpmdb timestamp"
    fi
  else
    last_update_date=""
    if have_cmd dnf; then
      hist_line="$(run_timeout "$CMD_TIMEOUT" dnf -q history 2>/dev/null | awk 'NR>2 && $1 ~ /^[0-9]+$/ {print; exit}')"
      if [[ -n "$hist_line" ]]; then
        if echo "$hist_line" | grep -q '|'; then
          last_update_date="$(echo "$hist_line" | awk -F'\\|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $3}')"
        else
          last_update_date="$(echo "$hist_line" | awk '{print $3, $4, $5, $6}')"
        fi
        result_ok "3.7 - Atualizacao de pacotes" "Last dnf transaction: ${last_update_date}"
      else
        result_fail "3.7 - Atualizacao de pacotes" "Nenhum historico dnf encontrado (dnf history vazio)"
      fi
    elif have_cmd yum; then
      hist_line="$(run_timeout "$CMD_TIMEOUT" yum -q history 2>/dev/null | awk 'NR>2 && $1 ~ /^[0-9]+$/ {print; exit}')"
      if [[ -n "$hist_line" ]]; then
        if echo "$hist_line" | grep -q '|'; then
          last_update_date="$(echo "$hist_line" | awk -F'\\|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $3}')"
        else
          last_update_date="$(echo "$hist_line" | awk '{print $3, $4, $5, $6}')"
        fi
        result_ok "3.7 - Atualizacao de pacotes" "Last yum transaction: ${last_update_date}"
      else
        result_fail "3.7 - Atualizacao de pacotes" "Nenhum historico yum encontrado (yum history vazio)"
      fi
    else
      result_fail "3.7 - Atualizacao de pacotes" "dnf/yum nao encontrado"
    fi
  fi

  #####################################
  # 3.8 - baseline packages
  #####################################
  missing=()
  baseline_packages=(
    net-tools rsync ed bind-utils bash-completion wget tcpdump
    perl sysstat mlocate lsof curl ftp yum-utils unzip nmap tree bzip2 iptraf-ng psmisc telnet
  )

  vim_ok=false
  rpm -q vim-enhanced >/dev/null 2>&1 && vim_ok=true

  for p in "${baseline_packages[@]}"; do
    rpm -q "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  $vim_ok || missing+=("vim-enhanced")

  if [[ ${#missing[@]} -eq 0 ]]; then
    result_ok "3.8 - Instalar pacotes necessarios" "All baseline packages installed"
  else
    result_fail "3.8 - Instalar pacotes necessarios" "Missing: ${missing[*]}"
  fi

  #####################################
  # 3.9 - Chrony (NTP)
  #####################################
  chrony_ok=true
  if have_cmd systemctl; then
    cen="$(systemctl is-enabled chronyd 2>/dev/null || true)"
    cac="$(systemctl is-active chronyd 2>/dev/null || true)"
    [[ "$cen" == "enabled" && "$cac" == "active" ]] || chrony_ok=false
  else
    chrony_ok=false
    cen="N/A"; cac="N/A"
  fi

  chrony_servers=("0.pool.ntp.org" "1.pool.ntp.org" "2.pool.ntp.org")
  if [[ -f /etc/chrony.conf ]]; then
    for s in "${chrony_servers[@]}"; do
      grep -Eq "^\s*server\s+${s}\s+iburst\s*$" /etc/chrony.conf || chrony_ok=false
    done
  else
    chrony_ok=false
  fi

  if $chrony_ok; then
    result_ok "3.9 - Configurar Chrony (NTP)" "chronyd enabled+active and servers present in /etc/chrony.conf"
  else
    result_fail "3.9 - Configurar Chrony (NTP)" "chronyd enabled=$cen active=$cac; check /etc/chrony.conf servers"
  fi

  #####################################
  # 3.10 - rc.local
  #####################################
  rc_ok=true
  link_ok="no"

  if [[ -f /etc/rc.d/rc.local && -x /etc/rc.d/rc.local ]]; then :; else rc_ok=false; fi

  if [[ -L /etc/rc.local ]]; then
    [[ "$(readlink -f /etc/rc.local 2>/dev/null || true)" == "/etc/rc.d/rc.local" ]] && link_ok="yes" || rc_ok=false
  else
    [[ -f /etc/rc.local && -x /etc/rc.local ]] && link_ok="yes" || rc_ok=false
  fi

  if [[ -f /etc/rc.d/rc.local ]]; then
    grep -Eq '^\s*systemctl\s+stop\s+chronyd\s*$' /etc/rc.d/rc.local || rc_ok=false
    grep -Eq '^\s*chronyd\s+-t\s+6\s+-q\s+"server\s+[a-zA-Z0-9._-]+\s+iburst"\s*$' /etc/rc.d/rc.local || rc_ok=false
    grep -Eq '^\s*hwclock\s+-w\s*$' /etc/rc.d/rc.local || rc_ok=false
    grep -Eq '^\s*systemctl\s+start\s+chronyd\s*$' /etc/rc.d/rc.local || rc_ok=false
  else
    rc_ok=false
  fi

  if have_cmd systemctl; then
    rcen="$(systemctl is-enabled rc-local.service 2>/dev/null || true)"
    rcac="$(systemctl is-active rc-local.service 2>/dev/null || true)"
    [[ "$rcen" == "enabled" || "$rcen" == "enabled-runtime" ]] || rc_ok=false
    [[ "$rcac" == "active" ]] || rc_ok=false
  else
    rcen="N/A"; rcac="N/A"
    rc_ok=false
  fi

  if $rc_ok; then
    result_ok "3.10 - Configurar \"/etc/rc.local\"" "file_exec=yes link_ok=$link_ok rc-local enabled=$rcen active=$rcac"
  else
    file_exec="$([[ -x /etc/rc.d/rc.local ]] && echo yes || echo no)"
    result_fail "3.10 - Configurar \"/etc/rc.local\"" "file_exec=$file_exec link_ok=$link_ok rc-local enabled=$rcen active=$rcac"
  fi

  #####################################
  # 3.11 - shell_environment (profile.d + /sysadmin/histlog)
  #####################################
  se_ok=true

  for f in /etc/profile.d/01-prompt-env.sh /etc/profile.d/02-umask.sh /etc/profile.d/03-history.sh /etc/profile.d/04-autologout.sh; do
    [[ -f "$f" ]] || se_ok=false
  done

  if [[ -d /sysadmin ]]; then
    [[ "$(file_mode /sysadmin)" == "755" ]] || se_ok=false
  else
    se_ok=false
  fi

  if [[ -d /sysadmin/histlog ]]; then
    [[ "$(file_mode /sysadmin/histlog)" == "777" ]] || se_ok=false
  else
    se_ok=false
  fi

  if [[ -f /etc/profile.d/02-umask.sh ]]; then
    grep -Eq '^\s*umask\s+022\s*$' /etc/profile.d/02-umask.sh || se_ok=false
  else
    se_ok=false
  fi

  if [[ -f /etc/profile.d/04-autologout.sh ]]; then
    grep -Eq '^\s*TMOUT\s*=\s*1800\s*$' /etc/profile.d/04-autologout.sh || se_ok=false
  else
    se_ok=false
  fi

  if $se_ok; then
    result_ok "3.11 - User Shell Environment Settings" "/etc/profile.d files present; /sysadmin=0755 /sysadmin/histlog=0777; umask 022; TMOUT=1800"
  else
    result_fail "3.11 - User Shell Environment Settings" "Check /etc/profile.d/* and /sysadmin perms"
  fi

  #####################################
  # 4.1 - login.defs
  #####################################
  if [[ -f /etc/login.defs ]] \
     && grep_login_defs_exact PASS_MAX_DAYS 90 \
     && grep_login_defs_exact PASS_MIN_DAYS 7 \
     && grep_login_defs_exact PASS_WARN_AGE 7 \
     && grep_login_defs_exact PASS_MIN_LEN 8; then
    result_ok "4.1 - Politica de Senhas (/etc/login.defs)" "PASS_MAX_DAYS=90 PASS_MIN_DAYS=7 PASS_WARN_AGE=7 PASS_MIN_LEN=8"
  else
    d1="$(grep -E '^[[:space:]]*PASS_MAX_DAYS' /etc/login.defs 2>/dev/null | tail -n1 || true)"
    d2="$(grep -E '^[[:space:]]*PASS_MIN_DAYS' /etc/login.defs 2>/dev/null | tail -n1 || true)"
    d3="$(grep -E '^[[:space:]]*PASS_WARN_AGE' /etc/login.defs 2>/dev/null | tail -n1 || true)"
    d4="$(grep -E '^[[:space:]]*PASS_MIN_LEN' /etc/login.defs 2>/dev/null | tail -n1 || true)"
    result_fail "4.1 - Politica de Senhas (/etc/login.defs)" "Found: '${d1:-none}' | '${d2:-none}' | '${d3:-none}' | '${d4:-none}'"
  fi

  #####################################
  # 4.2 - SSH guide-only
  #####################################
  ssh_ok=true
  if [[ -f /etc/ssh/sshd_config ]]; then
    sshd_has_kv LoginGraceTime 0 || ssh_ok=false
    sshd_has_kv ClientAliveInterval 0 || ssh_ok=false
    sshd_has_kv UseDNS no || ssh_ok=false
    sshd_has_kv PermitRootLogin no || ssh_ok=false
    sshd_has_port 22 || ssh_ok=false
    sshd_has_port 20022 || ssh_ok=false
  else
    ssh_ok=false
  fi

  if $ssh_ok; then
    if have_cmd sshd; then
      if run_timeout "$CMD_TIMEOUT" sshd -t >/dev/null 2>&1; then
        result_ok "4.2 - SSH hardening (sshd_config)" "Keys+ports present and sshd -t OK"
      else
        result_fail "4.2 - SSH hardening (sshd_config)" "Keys+ports present but sshd -t FAILED"
      fi
    else
      result_ok "4.2 - SSH hardening (sshd_config)" "Keys+ports present (sshd binary not found for -t)"
    fi
  else
    result_fail "4.2 - SSH hardening (sshd_config)" "Missing one or more required keys/ports in /etc/ssh/sshd_config"
  fi

  #####################################
  # 4.3 - Sysstat HISTORY=90
  #####################################
  if rpm -q sysstat >/dev/null 2>&1; then
    if [[ -f /etc/sysconfig/sysstat ]]; then
      if grep -Eq '^\s*HISTORY\s*=\s*90\s*$' /etc/sysconfig/sysstat; then
        result_ok "4.3 - Sysstat (/etc/sysconfig/sysstat)" "HISTORY=90"
      else
        line="$(grep -E '^\s*#?\s*HISTORY\s*=' /etc/sysconfig/sysstat 2>/dev/null | tail -n1 || true)"
        result_fail "4.3 - Sysstat (/etc/sysconfig/sysstat)" "Expected HISTORY=90, found '${line:-none}'"
      fi
    else
      result_fail "4.3 - Sysstat (/etc/sysconfig/sysstat)" "sysstat installed but /etc/sysconfig/sysstat not found"
    fi
  else
    result_fail "4.3 - Sysstat (/etc/sysconfig/sysstat)" "sysstat package not installed"
  fi

  #####################################
  # 4.4.1 - faillock.conf
  #####################################
  if [[ -f /etc/security/faillock.conf ]]; then
    if grep_kv_eq /etc/security/faillock.conf deny 4 && grep_kv_eq /etc/security/faillock.conf unlock_time 1800; then
      result_ok "4.4.1 - PAM faillock (/etc/security/faillock.conf)" "deny=4 unlock_time=1800"
    else
      l1="$(grep -E '^\s*#?\s*deny\s*=' /etc/security/faillock.conf 2>/dev/null | tail -n1 || true)"
      l2="$(grep -E '^\s*#?\s*unlock_time\s*=' /etc/security/faillock.conf 2>/dev/null | tail -n1 || true)"
      result_fail "4.4.1 - PAM faillock (/etc/security/faillock.conf)" "Found: '${l1:-none}' | '${l2:-none}'"
    fi
  else
    result_fail "4.4.1 - PAM faillock (/etc/security/faillock.conf)" "file not present"
  fi

  #####################################
  # 4.4.2 - pwhistory.conf
  #####################################
  if [[ -f /etc/security/pwhistory.conf ]]; then
    if grep_kv_eq /etc/security/pwhistory.conf remember 2; then
      result_ok "4.4.2 - PAM pwhistory (/etc/security/pwhistory.conf)" "remember=2"
    else
      l="$(grep -E '^\s*#?\s*remember\s*=' /etc/security/pwhistory.conf 2>/dev/null | tail -n1 || true)"
      result_fail "4.4.2 - PAM pwhistory (/etc/security/pwhistory.conf)" "Expected remember=2, found '${l:-none}'"
    fi
  else
    result_fail "4.4.2 - PAM pwhistory (/etc/security/pwhistory.conf)" "file not present"
  fi

  #####################################
  # 4.4.3 - pwquality.conf
  #####################################
  if [[ -f /etc/security/pwquality.conf ]]; then
    pw_ok=true
    grep_kv_eq /etc/security/pwquality.conf minlen 8 || pw_ok=false
    grep_kv_eq /etc/security/pwquality.conf dcredit -1 || pw_ok=false
    grep_kv_eq /etc/security/pwquality.conf ucredit -1 || pw_ok=false
    grep_kv_eq /etc/security/pwquality.conf lcredit -1 || pw_ok=false
    grep_kv_eq /etc/security/pwquality.conf ocredit -1 || pw_ok=false
    grep_kv_eq /etc/security/pwquality.conf minclass 1 || pw_ok=false
    grep_kv_eq /etc/security/pwquality.conf maxrepeat 2 || pw_ok=false
    grep_kv_eq /etc/security/pwquality.conf maxclassrepeat 0 || pw_ok=false

    if $pw_ok; then
      result_ok "4.4.3 - PAM pwquality (/etc/security/pwquality.conf)" "minlen=8 credits=-1 minclass=1 maxrepeat=2 maxclassrepeat=0"
    else
      result_fail "4.4.3 - PAM pwquality (/etc/security/pwquality.conf)" "One or more required keys not set as expected"
    fi
  else
    result_fail "4.4.3 - PAM pwquality (/etc/security/pwquality.conf)" "file not present"
  fi

  #####################################
  # 4.5 - Expiração de senha (chage)
  #####################################
  if have_cmd chage; then
    root_min="$(chage_get_field root "Minimum number of days between password change")"
    root_max="$(chage_get_field root "Maximum number of days between password change")"
    if [[ "$root_min" == "1" && "$root_max" == "90" ]]; then
      result_ok "4.5 - Expiracao senha (root)" "chage min=1 max=90"
    else
      result_fail "4.5 - Expiracao senha (root)" "chage min=${root_min:-?} max=${root_max:-?} (expected 1/90)"
    fi

    if getent passwd serverteam >/dev/null 2>&1; then
      st_min="$(chage_get_field serverteam "Minimum number of days between password change")"
      st_max="$(chage_get_field serverteam "Maximum number of days between password change")"
      if [[ "$st_min" == "1" && "$st_max" == "90" ]]; then
        result_ok "4.5 - Expiracao senha (serverteam)" "chage min=1 max=90"
      else
        result_fail "4.5 - Expiracao senha (serverteam)" "chage min=${st_min:-?} max=${st_max:-?} (expected 1/90)"
      fi
    else
      result_ok "4.5 - Expiracao senha (serverteam)" "N/A - user does not exist"
    fi
  else
    result_fail "4.5 - Expiracao senha (root/serverteam)" "chage command not found"
  fi

  #####################################
  # 4.6 - Permissões em binários (last/ifconfig)
  #####################################
  if [[ -f /usr/bin/last ]]; then
    m="$(file_mode /usr/bin/last)"
    if [[ "$m" == "700" ]]; then
      result_ok "4.6 - Permissoes binarios (/usr/bin/last)" "mode=700"
    else
      result_fail "4.6 - Permissoes binarios (/usr/bin/last)" "mode=${m:-?} (expected 700)"
    fi
  else
    result_fail "4.6 - Permissoes binarios (/usr/bin/last)" "/usr/bin/last not found"
  fi

  if rpm -q net-tools >/dev/null 2>&1; then
    if [[ -f /usr/sbin/ifconfig ]]; then
      m="$(file_mode /usr/sbin/ifconfig)"
      if [[ "$m" == "700" ]]; then
        result_ok "4.6 - Permissoes binarios (/usr/sbin/ifconfig)" "mode=700"
      else
        result_fail "4.6 - Permissoes binarios (/usr/sbin/ifconfig)" "mode=${m:-?} (expected 700)"
      fi
    else
      result_fail "4.6 - Permissoes binarios (/usr/sbin/ifconfig)" "net-tools installed but /usr/sbin/ifconfig not found"
    fi
  else
    result_fail "4.6 - Permissoes binarios (/usr/sbin/ifconfig)" "net-tools package not installed"
  fi

  #####################################
  # 4.7 - Banner (/etc/banner + /etc/motd + ssh)
  #####################################
  b_ok=true
  if [[ -f /etc/banner ]]; then
    grep -q "W A R N I N G - L E G A L  N O T I C E" /etc/banner || b_ok=false
  else
    b_ok=false
  fi

  if [[ -f /etc/motd ]]; then
    grep -q "W A R N I N G - L E G A L  N O T I C E" /etc/motd || b_ok=false
  else
    b_ok=false
  fi

  if [[ -f /etc/ssh/sshd_config ]]; then
    grep -Eiq '^\s*Banner\s+/etc/banner\s*$' /etc/ssh/sshd_config || b_ok=false
  else
    b_ok=false
  fi

  if $b_ok; then
    result_ok "4.7 - Banner (/etc/banner + /etc/motd + ssh)" "banner+motd contain legal notice and ssh Banner=/etc/banner"
  else
    result_fail "4.7 - Banner (/etc/banner + /etc/motd + ssh)" "Check /etc/banner, /etc/motd content, and sshd_config Banner /etc/banner"
  fi

  #####################################
  # 4.8 - Sysstat timer override every minute
  #####################################
  if rpm -q sysstat >/dev/null 2>&1; then
    if have_cmd systemctl && systemctl cat sysstat-collect.timer >/dev/null 2>&1; then
      ov="/etc/systemd/system/sysstat-collect.timer.d/override.conf"
      if [[ -f "$ov" ]]; then
        if grep -Eq '^\s*OnCalendar\s*=\s*$' "$ov" && grep -Eq '^\s*OnCalendar\s*=\s*\*:\*:00\s*$' "$ov"; then
          en="$(systemctl is-enabled sysstat-collect.timer 2>/dev/null || true)"
          ac="$(systemctl is-active sysstat-collect.timer 2>/dev/null || true)"
          if [[ "$en" == "enabled" ]] && [[ "$ac" == "active" ]]; then
            result_ok "4.8 - Sysstat timer (sysstat-collect.timer)" "override OK; enabled=$en active=$ac"
          else
            result_fail "4.8 - Sysstat timer (sysstat-collect.timer)" "override OK; enabled=$en active=$ac (expected enabled/active)"
          fi
        else
          result_fail "4.8 - Sysstat timer (sysstat-collect.timer)" "override missing OnCalendar reset and/or *:*:00"
        fi
      else
        result_fail "4.8 - Sysstat timer (sysstat-collect.timer)" "override file not found: $ov"
      fi
    else
      result_fail "4.8 - Sysstat timer (sysstat-collect.timer)" "unit not present (sysstat-collect.timer missing)"
    fi
  else
    result_fail "4.8 - Sysstat timer (sysstat-collect.timer)" "sysstat package not installed"
  fi

  #####################################
  # 4.9 - UTMP/BTMP via tmpfiles
  #####################################
  tf="/etc/tmpfiles.d/var.conf"
  tf_ok=true

  if [[ -f "$tf" ]]; then
    grep -Eq '^\s*f\s+/var/log/wtmp\s+0600\s+root\s+utmp\s+-\s*$' "$tf" || tf_ok=false
    grep -Eq '^\s*f\s+/var/log/btmp\s+0600\s+root\s+utmp\s+-\s*$' "$tf" || tf_ok=false
  else
    tf_ok=false
  fi

  if $tf_ok && have_cmd systemd-tmpfiles; then
    if ! run_timeout "$CMD_TIMEOUT" systemd-tmpfiles --create "$tf" >/dev/null 2>&1; then
      tf_ok=false
    fi
  else
    tf_ok=false
  fi

  if $tf_ok; then
    for f in /var/log/wtmp /var/log/btmp; do
      if [[ ! -f "$f" ]]; then tf_ok=false; fi
      m="$(file_mode "$f")"
      o="$(file_owner "$f")"
      g="$(file_group "$f")"
      [[ "$m" == "600" && "$o" == "root" && "$g" == "utmp" ]] || tf_ok=false
    done
  fi

  if $tf_ok; then
    result_ok "4.9 - UTMP/BTMP (tmpfiles var.conf)" "var.conf OK, tmpfiles applied, wtmp/btmp exist with 0600 root:utmp"
  else
    d1="$(grep -E '^\s*f\s+/var/log/(wtmp|btmp)\b' "$tf" 2>/dev/null | tr '\n' ';' || true)"
    mw="$(file_mode /var/log/wtmp)"; ow="$(file_owner /var/log/wtmp)"; gw="$(file_group /var/log/wtmp)"
    mb="$(file_mode /var/log/btmp)"; ob="$(file_owner /var/log/btmp)"; gb="$(file_group /var/log/btmp)"
    result_fail "4.9 - UTMP/BTMP (tmpfiles var.conf)" "var.conf='${d1:-missing}'; wtmp=${mw:-?} ${ow:-?}:${gw:-?}; btmp=${mb:-?} ${ob:-?}:${gb:-?}"
  fi

  #####################################
  # 5.1 - logrotate.conf (monthly/rotate 12/compress)
  #####################################
  lr_ok=true
  lr="/etc/logrotate.conf"
  if [[ -f "$lr" ]]; then
    lr_has_directive "$lr" "monthly" || lr_ok=false
    lr_has_directive "$lr" "rotate[[:space:]]+12" || lr_ok=false
    lr_has_directive "$lr" "compress" || lr_ok=false
  else
    lr_ok=false
  fi

  if $lr_ok; then
    result_ok "5.1 - Logrotate (/etc/logrotate.conf)" "monthly + rotate 12 + compress present"
  else
    result_fail "5.1 - Logrotate (/etc/logrotate.conf)" "Expected monthly/rotate 12/compress in /etc/logrotate.conf"
  fi

  #####################################
  # 5.2 - logrotate.d rules (btmp/wtmp/dnf)
  #####################################
  bfile="/etc/logrotate.d/btmp"
  b_ok=true
  if [[ -f "$bfile" ]]; then
    lr_rule_has_line "$bfile" '^[[:space:]]*/var/log/btmp[[:space:]]*\{' || b_ok=false
    lr_rule_has_line "$bfile" '^[[:space:]]*missingok[[:space:]]*$' || b_ok=false
    lr_rule_has_line "$bfile" '^[[:space:]]*monthly[[:space:]]*$' || b_ok=false
    lr_rule_has_line "$bfile" '^[[:space:]]*create[[:space:]]+0600[[:space:]]+root[[:space:]]+utmp[[:space:]]*$' || b_ok=false
    lr_rule_has_line "$bfile" '^[[:space:]]*rotate[[:space:]]+12[[:space:]]*$' || b_ok=false
  else
    b_ok=false
  fi
  $b_ok && result_ok "5.2 - Logrotate rule (btmp)" "rule OK" || result_fail "5.2 - Logrotate rule (btmp)" "Check $bfile content"

  wfile="/etc/logrotate.d/wtmp"
  w_ok=true
  if [[ -f "$wfile" ]]; then
    lr_rule_has_line "$wfile" '^[[:space:]]*/var/log/wtmp[[:space:]]*\{' || w_ok=false
    lr_rule_has_line "$wfile" '^[[:space:]]*missingok[[:space:]]*$' || w_ok=false
    lr_rule_has_line "$wfile" '^[[:space:]]*monthly[[:space:]]*$' || w_ok=false
    lr_rule_has_line "$wfile" '^[[:space:]]*create[[:space:]]+0600[[:space:]]+root[[:space:]]+utmp[[:space:]]*$' || w_ok=false
    lr_rule_has_line "$wfile" '^[[:space:]]*minsize[[:space:]]+1M[[:space:]]*$' || w_ok=false
    lr_rule_has_line "$wfile" '^[[:space:]]*rotate[[:space:]]+12[[:space:]]*$' || w_ok=false
  else
    w_ok=false
  fi
  $w_ok && result_ok "5.2 - Logrotate rule (wtmp)" "rule OK" || result_fail "5.2 - Logrotate rule (wtmp)" "Check $wfile content"

  dfile="/etc/logrotate.d/dnf"
  d_ok=true
  if [[ -f "$dfile" ]]; then
    lr_rule_has_line "$dfile" '^[[:space:]]*/var/log/hawkey\.log[[:space:]]*\{' || d_ok=false
    lr_rule_has_line "$dfile" '^[[:space:]]*missingok[[:space:]]*$' || d_ok=false
    lr_rule_has_line "$dfile" '^[[:space:]]*notifempty[[:space:]]*$' || d_ok=false
    lr_rule_has_line "$dfile" '^[[:space:]]*rotate[[:space:]]+12[[:space:]]*$' || d_ok=false
    lr_rule_has_line "$dfile" '^[[:space:]]*monthly[[:space:]]*$' || d_ok=false

    lr_rule_has_line "$dfile" '^[[:space:]]*/var/log/dnf\.log[[:space:]]*\{' || d_ok=false
    lr_rule_has_line "$dfile" '^[[:space:]]*rotate[[:space:]]+24[[:space:]]*$' || d_ok=false
    lr_rule_has_line "$dfile" '^[[:space:]]*compress[[:space:]]*$' || d_ok=false
    lr_rule_has_line "$dfile" '^[[:space:]]*delaycompress[[:space:]]*$' || d_ok=false
    lr_rule_has_line "$dfile" '^[[:space:]]*create[[:space:]]+0644[[:space:]]+root[[:space:]]+root[[:space:]]*$' || d_ok=false
  else
    d_ok=false
  fi
  $d_ok && result_ok "5.2 - Logrotate rule (dnf)" "rule OK" || result_fail "5.2 - Logrotate rule (dnf)" "Check $dfile content"

  #####################################
  # 5.2 - Validate logrotate dry-run
  #####################################
  if have_cmd logrotate && [[ -f /etc/logrotate.conf ]]; then
    if run_timeout "$CMD_TIMEOUT" logrotate -d /etc/logrotate.conf >/dev/null 2>&1; then
      result_ok "5.2 - Validate logrotate (dry-run)" "logrotate -d OK"
    else
      result_fail "5.2 - Validate logrotate (dry-run)" "logrotate -d FAILED (check syntax in /etc/logrotate.conf or /etc/logrotate.d/*)"
    fi
  else
    result_fail "5.2 - Validate logrotate (dry-run)" "logrotate command or /etc/logrotate.conf not found"
  fi

  #####################################
  # 5.3 - Zabbix agent RPM instalado (lab: instala via URL direta, sem repo file)
  #####################################
  if rpm -q zabbix-agent >/dev/null 2>&1; then
    result_ok "5.3 - Zabbix agent RPM instalado" "$(rpm -q zabbix-agent 2>/dev/null)"
  else
    result_fail "5.3 - Zabbix agent RPM instalado" "zabbix-agent não encontrado"
  fi

  #####################################
  # 5.4 - Zabbix agent config + service
  #####################################
  zcfg="/etc/zabbix/zabbix_agentd.conf"
  zsvc_ok=true

  if rpm -q zabbix-agent >/dev/null 2>&1; then
    : # ok
  else
    zsvc_ok=false
  fi

  if [[ -f "$zcfg" ]]; then
    : # ok
  else
    zsvc_ok=false
  fi

  if have_cmd systemctl; then
    zen="$(systemctl is-enabled zabbix-agent 2>/dev/null || true)"
    zac="$(systemctl is-active zabbix-agent 2>/dev/null || true)"
    [[ "$zen" == "enabled" ]] || zsvc_ok=false
    [[ "$zac" == "active" ]] || zsvc_ok=false
  else
    zen="N/A"; zac="N/A"
    zsvc_ok=false
  fi

  if $zsvc_ok; then
    result_ok "5.4 - Zabbix agent (conf + service)" "pkg=installed conf=present enabled=$zen active=$zac"
  else
    pkg="$(rpm -q zabbix-agent 2>/dev/null || echo "not-installed")"
    result_fail "5.4 - Zabbix agent (conf + service)" "pkg=$pkg conf=$([[ -f "$zcfg" ]] && echo present || echo missing) enabled=$zen active=$zac"
  fi

  
  echo "------------------------------------------------------------"
  echo "TOTAL: PASS=$PASS  FAIL=$FAIL"
  echo "------------------------------------------------------------"

} | tee "$REPORT_PATH"

[[ $FAIL -eq 0 ]] && exit 0 || exit 2
