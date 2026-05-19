#!/usr/bin/env bash
# =============================================================================
# linux_hardening_check.sh
# Linux Security Hardening Audit Script
# Supports: RHEL 8/9/10, Ubuntu 22.04/24.04
#
# References:
#   - RHEL Security Hardening: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/security_hardening/index
#   - CIS Ubuntu Benchmark:    https://ubuntu.com/security/cis
#   - CIS Benchmarks:          https://www.cisecurity.org/benchmark/ubuntu_linux
# =============================================================================

set -uo pipefail

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Counters ----------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# --- Output helpers ----------------------------------------------------------
pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS_COUNT++)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL_COUNT++)); }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARN_COUNT++)); }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"; }
info()    { echo -e "       ${CYAN}↳${NC} $1"; }

# =============================================================================
# 1. OS Detection
# =============================================================================
section "1. OS Detection"

OS="unknown"
OS_VERSION="unknown"
OS_NAME="unknown"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="${NAME:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    case "${ID:-}" in
        rhel|centos|rocky|almalinux|ol)
            OS="rhel"
            ;;
        ubuntu)
            OS="ubuntu"
            ;;
        *)
            OS="unknown"
            ;;
    esac
fi

if [[ "$OS" == "unknown" ]]; then
    warn "Unrecognized OS: $OS_NAME $OS_VERSION — some checks may not apply"
else
    pass "OS detected: $OS_NAME $OS_VERSION"
fi

info "OS family: $OS | Version: $OS_VERSION"

# =============================================================================
# 2. IPv6
# =============================================================================
section "2. IPv6 Disable"

# 2.1 sysctl runtime check
val_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
val_def=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo "0")

if [[ "$val_all" == "1" && "$val_def" == "1" ]]; then
    pass "IPv6 disabled via sysctl (all=$val_all, default=$val_def)"
else
    fail "IPv6 NOT disabled via sysctl (net.ipv6.conf.all=$val_all, net.ipv6.conf.default=$val_def)"
    info "Fix: add net.ipv6.conf.all.disable_ipv6=1 to /etc/sysctl.d/99-hardening.conf"
fi

# 2.2 Kernel cmdline (GRUB method)
if grep -q "ipv6.disable=1" /proc/cmdline 2>/dev/null; then
    pass "IPv6 disabled in kernel cmdline (GRUB)"
else
    warn "IPv6 not disabled in kernel cmdline — sysctl method active, reboot may re-enable"
    info "For persistent disable: grubby --update-kernel=ALL --args='ipv6.disable=1' (RHEL) or update GRUB_CMDLINE_LINUX in /etc/default/grub (Ubuntu)"
fi

# 2.3 Active IPv6 addresses
active_ipv6=$(ip -6 addr show 2>/dev/null | grep -v "^$" | grep -v "lo" | wc -l)
if [[ "$active_ipv6" -eq 0 ]]; then
    pass "No active IPv6 addresses on network interfaces"
else
    warn "Active IPv6 addresses found ($active_ipv6 entries) — check if intentional"
fi

# =============================================================================
# 3. SSH Hardening
# =============================================================================
section "3. SSH Hardening"

SSHD_CONFIG="/etc/ssh/sshd_config"

if [[ ! -f "$SSHD_CONFIG" ]]; then
    fail "SSH config not found: $SSHD_CONFIG"
else
    sshd_t_output=$(sshd -T 2>/dev/null || echo "")

    check_ssh_param() {
        local param="$1"
        local expected="$2"
        local desc="$3"
        local actual
        actual=$(echo "$sshd_t_output" | grep -i "^${param} " | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
        expected_lower=$(echo "$expected" | tr '[:upper:]' '[:lower:]')
        if [[ "$actual" == "$expected_lower" ]]; then
            pass "SSH $desc: $actual"
        elif [[ -z "$actual" ]]; then
            warn "SSH $desc: not found in sshd -T output"
        else
            fail "SSH $desc: got '$actual', expected '$expected_lower'"
        fi
    }

    check_ssh_param "PermitRootLogin"        "no"   "PermitRootLogin disabled"
    check_ssh_param "PermitEmptyPasswords"   "no"   "PermitEmptyPasswords disabled"
    check_ssh_param "X11Forwarding"          "no"   "X11Forwarding disabled"
    check_ssh_param "IgnoreRhosts"           "yes"  "IgnoreRhosts enabled"
    check_ssh_param "HostbasedAuthentication" "no"  "HostbasedAuthentication disabled"
    check_ssh_param "UseDNS"                 "no"   "UseDNS disabled"

    # MaxAuthTries <= 4
    max_auth=$(echo "$sshd_t_output" | grep -i "^maxauthtries " | awk '{print $2}')
    if [[ -n "$max_auth" ]] && [[ "$max_auth" -le 4 ]]; then
        pass "SSH MaxAuthTries: $max_auth (<= 4)"
    elif [[ -n "$max_auth" ]]; then
        fail "SSH MaxAuthTries: $max_auth (should be <= 4)"
    else
        warn "SSH MaxAuthTries: not found"
    fi

    # ClientAliveInterval (any non-zero is good for timeout)
    client_alive=$(echo "$sshd_t_output" | grep -i "^clientaliveinterval " | awk '{print $2}')
    if [[ -n "$client_alive" ]]; then
        pass "SSH ClientAliveInterval: $client_alive"
    else
        warn "SSH ClientAliveInterval: not configured"
    fi

    # Banner
    banner_val=$(echo "$sshd_t_output" | grep -i "^banner " | awk '{print $2}')
    if [[ -n "$banner_val" && "$banner_val" != "none" ]]; then
        pass "SSH Banner configured: $banner_val"
    else
        warn "SSH Banner not configured"
    fi

    # Port check
    ports=$(echo "$sshd_t_output" | grep -i "^port " | awk '{print $2}')
    if [[ -n "$ports" ]]; then
        pass "SSH listening on port(s): $(echo "$ports" | tr '\n' ' ')"
    fi
fi

# =============================================================================
# 4. PAM
# =============================================================================
section "4. PAM Configuration"

# 4.1 faillock
if [[ "$OS" == "rhel" ]]; then
    FAILLOCK_CONF="/etc/security/faillock.conf"
    if [[ -f "$FAILLOCK_CONF" ]]; then
        deny_val=$(grep -E '^\s*deny\s*=' "$FAILLOCK_CONF" | awk -F= '{print $2}' | tr -d ' ')
        unlock_val=$(grep -E '^\s*unlock_time\s*=' "$FAILLOCK_CONF" | awk -F= '{print $2}' | tr -d ' ')

        if [[ -n "$deny_val" ]] && [[ "$deny_val" -le 5 ]]; then
            pass "PAM faillock deny=$deny_val (<= 5)"
        elif [[ -n "$deny_val" ]]; then
            fail "PAM faillock deny=$deny_val (should be <= 5)"
        else
            fail "PAM faillock deny: not configured in $FAILLOCK_CONF"
        fi

        if [[ -n "$unlock_val" ]] && [[ "$unlock_val" -ge 900 ]]; then
            pass "PAM faillock unlock_time=${unlock_val}s (>= 900)"
        elif [[ -n "$unlock_val" ]]; then
            warn "PAM faillock unlock_time=${unlock_val}s (recommend >= 900)"
        else
            fail "PAM faillock unlock_time: not configured"
        fi
    else
        fail "PAM faillock.conf not found: $FAILLOCK_CONF"
    fi
elif [[ "$OS" == "ubuntu" ]]; then
    if grep -qE 'pam_faillock|pam_tally2' /etc/pam.d/common-auth 2>/dev/null; then
        deny_val=$(grep -E 'pam_faillock|pam_tally2' /etc/pam.d/common-auth | grep -oE 'deny=[0-9]+' | awk -F= '{print $2}')
        if [[ -n "$deny_val" ]] && [[ "$deny_val" -le 5 ]]; then
            pass "PAM account lockout deny=$deny_val configured in common-auth"
        else
            warn "PAM account lockout: found but deny not <= 5 (got: $deny_val)"
        fi
    else
        fail "PAM account lockout (pam_faillock) not configured in /etc/pam.d/common-auth"
        info "Add: auth required pam_faillock.so preauth deny=4 unlock_time=1800"
    fi
fi

# 4.2 pwhistory (password reuse prevention)
PWHISTORY_CONF="/etc/security/pwhistory.conf"
if [[ -f "$PWHISTORY_CONF" ]]; then
    remember_val=$(grep -E '^\s*remember\s*=' "$PWHISTORY_CONF" | awk -F= '{print $2}' | tr -d ' ')
    if [[ -n "$remember_val" ]] && [[ "$remember_val" -ge 5 ]]; then
        pass "PAM pwhistory remember=$remember_val (>= 5)"
    elif [[ -n "$remember_val" ]]; then
        warn "PAM pwhistory remember=$remember_val (recommend >= 5)"
    else
        fail "PAM pwhistory remember: not configured"
    fi
else
    # Check in pam.d for both distros
    if grep -qE 'pam_pwhistory' /etc/pam.d/common-password 2>/dev/null || \
       grep -qE 'pam_pwhistory' /etc/pam.d/system-auth 2>/dev/null || \
       grep -qE 'pam_pwhistory' /etc/pam.d/password-auth 2>/dev/null; then
        pass "PAM pwhistory configured in pam.d"
    else
        warn "PAM pwhistory not configured — password reuse not restricted"
    fi
fi

# 4.3 pwquality
PWQUALITY_CONF="/etc/security/pwquality.conf"
if [[ -f "$PWQUALITY_CONF" ]]; then
    check_pwq() {
        local key="$1"; local op="$2"; local threshold="$3"; local desc="$4"
        local val
        val=$(grep -E "^\s*${key}\s*=" "$PWQUALITY_CONF" | tail -1 | awk -F= '{print $2}' | tr -d ' ')
        if [[ -z "$val" ]]; then
            warn "pwquality $key: not set in $PWQUALITY_CONF"
            return
        fi
        case "$op" in
            ge) [[ "$val" -ge "$threshold" ]] && pass "pwquality $desc: $val" || fail "pwquality $desc: $val (should be >= $threshold)" ;;
            le) [[ "$val" -le "$threshold" ]] && pass "pwquality $desc: $val" || fail "pwquality $desc: $val (should be <= $threshold)" ;;
            eq) [[ "$val" == "$threshold" ]] && pass "pwquality $desc: $val" || fail "pwquality $desc: $val (should be $threshold)" ;;
        esac
    }
    check_pwq "minlen"         "ge" "12"  "minlen (>= 12)"
    check_pwq "dcredit"        "le" "-1"  "dcredit (require digit)"
    check_pwq "ucredit"        "le" "-1"  "ucredit (require uppercase)"
    check_pwq "lcredit"        "le" "-1"  "lcredit (require lowercase)"
    check_pwq "ocredit"        "le" "-1"  "ocredit (require special char)"
    check_pwq "maxrepeat"      "le" "3"   "maxrepeat (<= 3)"
else
    fail "pwquality.conf not found: $PWQUALITY_CONF"
    info "Install libpwquality and configure /etc/security/pwquality.conf"
fi

# =============================================================================
# 5. login.defs
# =============================================================================
section "5. /etc/login.defs"

LOGIN_DEFS="/etc/login.defs"
if [[ ! -f "$LOGIN_DEFS" ]]; then
    fail "/etc/login.defs not found"
else
    check_logindefs() {
        local key="$1"; local op="$2"; local threshold="$3"; local desc="$4"
        local val
        val=$(grep -E "^\s*${key}\s+" "$LOGIN_DEFS" | awk '{print $2}')
        if [[ -z "$val" ]]; then
            warn "login.defs $key: not set"
            return
        fi
        case "$op" in
            le) [[ "$val" -le "$threshold" ]] && pass "login.defs $desc: $val" || fail "login.defs $desc: $val (should be <= $threshold)" ;;
            ge) [[ "$val" -ge "$threshold" ]] && pass "login.defs $desc: $val" || fail "login.defs $desc: $val (should be >= $threshold)" ;;
        esac
    }
    check_logindefs "PASS_MAX_DAYS"  "le" "90"   "PASS_MAX_DAYS (<= 90)"
    check_logindefs "PASS_MIN_DAYS"  "ge" "1"    "PASS_MIN_DAYS (>= 1)"
    check_logindefs "PASS_WARN_AGE"  "ge" "7"    "PASS_WARN_AGE (>= 7)"
    check_logindefs "PASS_MIN_LEN"   "ge" "12"   "PASS_MIN_LEN (>= 12)"
    check_logindefs "LOGIN_RETRIES"  "le" "3"    "LOGIN_RETRIES (<= 3)"
    check_logindefs "LOGIN_TIMEOUT"  "le" "60"   "LOGIN_TIMEOUT (<= 60s)"
fi

# =============================================================================
# 6. Password Hashing Algorithm
# =============================================================================
section "6. Password Hashing Algorithm"

if [[ -f "$LOGIN_DEFS" ]]; then
    encrypt_method=$(grep -E "^\s*ENCRYPT_METHOD\s+" "$LOGIN_DEFS" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
    if [[ "$encrypt_method" == "sha512" || "$encrypt_method" == "yescrypt" ]]; then
        pass "Password hashing: $encrypt_method (strong)"
    elif [[ -n "$encrypt_method" ]]; then
        fail "Password hashing: $encrypt_method (weak — use SHA512 or yescrypt)"
    else
        warn "ENCRYPT_METHOD not set in /etc/login.defs"
    fi
fi

# Check /etc/shadow for actual algorithm in use (first regular user)
shadow_hash=$(awk -F: '$2 ~ /^\$/ {print $2; exit}' /etc/shadow 2>/dev/null | cut -d'$' -f2)
case "$shadow_hash" in
    "6")   pass "Shadow: existing hashes use SHA-512 (\$6\$)" ;;
    "y")   pass "Shadow: existing hashes use yescrypt (\$y\$)" ;;
    "5")   warn "Shadow: existing hashes use SHA-256 (\$5\$) — weaker than SHA-512" ;;
    "1")   fail "Shadow: existing hashes use MD5 (\$1\$) — insecure, rehash required" ;;
    "2b")  warn "Shadow: existing hashes use bcrypt (\$2b\$)" ;;
    "")    info "No shadow hash found to check" ;;
    *)     warn "Shadow: unknown hash type: \$$shadow_hash\$" ;;
esac

# =============================================================================
# 7. cron.allow / at.allow / Cron Permissions
# =============================================================================
section "7. cron.allow / at.allow / Cron Permissions"

# cron.allow
if [[ -f /etc/cron.allow ]]; then
    cron_allow_perms=$(stat -c "%a" /etc/cron.allow 2>/dev/null)
    cron_allow_owner=$(stat -c "%U:%G" /etc/cron.allow 2>/dev/null)
    pass "cron.allow exists"
    if [[ "$cron_allow_perms" == "600" ]]; then
        pass "cron.allow permissions: $cron_allow_perms (0600)"
    else
        fail "cron.allow permissions: $cron_allow_perms (should be 0600)"
    fi
    if [[ "$cron_allow_owner" == "root:root" ]]; then
        pass "cron.allow owner: root:root"
    else
        fail "cron.allow owner: $cron_allow_owner (should be root:root)"
    fi
else
    fail "cron.allow not found — all users can use cron by default"
    info "Create /etc/cron.allow with 'root' and authorized users only"
fi

# cron.deny (should not exist if cron.allow is present)
if [[ -f /etc/cron.deny ]]; then
    warn "cron.deny exists — when cron.allow is used, cron.deny is redundant and potentially misleading"
    info "Remove /etc/cron.deny when /etc/cron.allow is in use"
fi

# at.allow
if [[ -f /etc/at.allow ]]; then
    at_allow_perms=$(stat -c "%a" /etc/at.allow 2>/dev/null)
    at_allow_owner=$(stat -c "%U:%G" /etc/at.allow 2>/dev/null)
    pass "at.allow exists"
    if [[ "$at_allow_perms" == "600" ]]; then
        pass "at.allow permissions: $at_allow_perms (0600)"
    else
        fail "at.allow permissions: $at_allow_perms (should be 0600)"
    fi
    if [[ "$at_allow_owner" == "root:root" ]]; then
        pass "at.allow owner: root:root"
    else
        fail "at.allow owner: $at_allow_owner (should be root:root)"
    fi
else
    fail "at.allow not found"
fi

# at.deny
if [[ -f /etc/at.deny ]]; then
    warn "at.deny exists — when at.allow is used, at.deny is redundant"
fi

# /etc/crontab permissions
if [[ -f /etc/crontab ]]; then
    crontab_perms=$(stat -c "%a" /etc/crontab 2>/dev/null)
    crontab_owner=$(stat -c "%U:%G" /etc/crontab 2>/dev/null)
    if [[ "$crontab_perms" == "600" && "$crontab_owner" == "root:root" ]]; then
        pass "/etc/crontab: 0600 root:root"
    else
        fail "/etc/crontab: $crontab_perms $crontab_owner (should be 0600 root:root)"
    fi
fi

# Cron directories
for cron_dir in /etc/cron.d /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.hourly; do
    if [[ -d "$cron_dir" ]]; then
        dir_perms=$(stat -c "%a" "$cron_dir" 2>/dev/null)
        dir_owner=$(stat -c "%U:%G" "$cron_dir" 2>/dev/null)
        if [[ "$dir_perms" == "700" && "$dir_owner" == "root:root" ]]; then
            pass "$cron_dir: 0700 root:root"
        else
            fail "$cron_dir: $dir_perms $dir_owner (should be 0700 root:root)"
        fi
    fi
done

# /var/spool/cron permissions
if [[ -d /var/spool/cron ]]; then
    spool_perms=$(stat -c "%a" /var/spool/cron 2>/dev/null)
    spool_owner=$(stat -c "%U:%G" /var/spool/cron 2>/dev/null)
    if [[ "$spool_perms" == "700" && "$spool_owner" == "root:root" ]]; then
        pass "/var/spool/cron: 0700 root:root"
    else
        fail "/var/spool/cron: $spool_perms $spool_owner (should be 0700 root:root)"
    fi
fi

# =============================================================================
# 8. Sysctl Kernel Hardening
# =============================================================================
section "8. Sysctl Kernel Hardening"

check_sysctl() {
    local param="$1"; local expected="$2"; local desc="$3"
    local actual
    actual=$(sysctl -n "$param" 2>/dev/null || echo "NOT_FOUND")
    if [[ "$actual" == "NOT_FOUND" ]]; then
        warn "sysctl $param: not found (kernel may not support)"
    elif [[ "$actual" == "$expected" ]]; then
        pass "sysctl $desc: $actual"
    else
        fail "sysctl $desc: $actual (expected $expected)"
    fi
}

check_sysctl "kernel.randomize_va_space"               "2"  "kernel.randomize_va_space (ASLR full)"
check_sysctl "net.ipv4.ip_forward"                     "0"  "net.ipv4.ip_forward (disabled)"
check_sysctl "net.ipv4.conf.all.rp_filter"             "1"  "net.ipv4.conf.all.rp_filter (anti-spoof)"
check_sysctl "net.ipv4.conf.default.rp_filter"         "1"  "net.ipv4.conf.default.rp_filter"
check_sysctl "net.ipv4.icmp_echo_ignore_broadcasts"    "1"  "net.ipv4.icmp_echo_ignore_broadcasts"
check_sysctl "net.ipv4.tcp_syncookies"                 "1"  "net.ipv4.tcp_syncookies (SYN flood protection)"
check_sysctl "net.ipv4.conf.all.accept_source_route"   "0"  "net.ipv4.conf.all.accept_source_route (disabled)"
check_sysctl "net.ipv4.conf.default.accept_source_route" "0" "net.ipv4.conf.default.accept_source_route"
check_sysctl "net.ipv4.conf.all.accept_redirects"      "0"  "net.ipv4.conf.all.accept_redirects (disabled)"
check_sysctl "net.ipv4.conf.default.accept_redirects"  "0"  "net.ipv4.conf.default.accept_redirects"
check_sysctl "net.ipv4.conf.all.send_redirects"        "0"  "net.ipv4.conf.all.send_redirects (disabled)"
check_sysctl "net.ipv4.conf.all.log_martians"          "1"  "net.ipv4.conf.all.log_martians"
check_sysctl "net.ipv4.conf.default.log_martians"      "1"  "net.ipv4.conf.default.log_martians"
check_sysctl "fs.suid_dumpable"                        "0"  "fs.suid_dumpable (SUID core dumps disabled)"
check_sysctl "kernel.kptr_restrict"                    "1"  "kernel.kptr_restrict (kernel pointers restricted)"
check_sysctl "kernel.dmesg_restrict"                   "1"  "kernel.dmesg_restrict (dmesg restricted)"
check_sysctl "kernel.core_uses_pid"                    "1"  "kernel.core_uses_pid"

# =============================================================================
# 9. auditd
# =============================================================================
section "9. auditd"

if command -v auditctl &>/dev/null; then
    pass "auditd installed"

    if systemctl is-enabled auditd &>/dev/null; then
        pass "auditd enabled at boot"
    else
        fail "auditd NOT enabled at boot"
        info "Fix: systemctl enable auditd"
    fi

    if systemctl is-active auditd &>/dev/null; then
        pass "auditd is running"
    else
        fail "auditd is NOT running"
        info "Fix: service auditd start"
    fi

    # Check key audit rules
    check_audit_rule() {
        local key_path="$1"; local desc="$2"
        if auditctl -l 2>/dev/null | grep -q "$key_path"; then
            pass "auditd watching: $desc"
        else
            fail "auditd NOT watching: $desc ($key_path)"
            info "Add audit rule for $key_path to /etc/audit/rules.d/hardening.rules"
        fi
    }

    check_audit_rule "/etc/passwd"        "/etc/passwd (identity changes)"
    check_audit_rule "/etc/shadow"        "/etc/shadow (identity changes)"
    check_audit_rule "/etc/sudoers"       "/etc/sudoers (privilege escalation)"
    check_audit_rule "/etc/ssh/sshd_config" "SSH config changes"
    check_audit_rule "insmod\|rmmod\|modprobe" "kernel module loading"

else
    fail "auditd not installed"
    info "RHEL: dnf install audit | Ubuntu: apt install auditd"
fi

# =============================================================================
# 10. Core Dump Restrictions
# =============================================================================
section "10. Core Dump Restrictions"

# sysctl fs.suid_dumpable (already checked in section 8)
# limits.conf
if grep -E '^\*\s+hard\s+core\s+0' /etc/security/limits.conf &>/dev/null; then
    pass "limits.conf: * hard core 0"
elif grep -rE '^\*\s+hard\s+core\s+0' /etc/security/limits.d/ &>/dev/null 2>&1; then
    pass "limits.d: * hard core 0"
else
    fail "Core dumps not restricted in /etc/security/limits.conf"
    info "Add: * hard core 0 to /etc/security/limits.conf"
fi

# systemd coredump (if systemd-coredump is present)
if command -v coredumpctl &>/dev/null; then
    coredump_storage=$(grep -E "^\s*Storage\s*=" /etc/systemd/coredump.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
    if [[ "$coredump_storage" == "none" ]]; then
        pass "systemd-coredump Storage=none"
    else
        warn "systemd-coredump Storage not set to 'none' (current: ${coredump_storage:-default})"
        info "Set Storage=none in /etc/systemd/coredump.conf"
    fi
fi

# =============================================================================
# 11. UTMP / BTMP Permissions
# =============================================================================
section "11. UTMP / BTMP Permissions"

check_file_perm() {
    local path="$1"; local expected_mode="$2"; local expected_owner="$3"; local desc="$4"
    if [[ ! -e "$path" ]]; then
        warn "$desc: file not found ($path)"
        return
    fi
    local actual_mode actual_owner
    actual_mode=$(stat -c "%a" "$path" 2>/dev/null)
    actual_owner=$(stat -c "%U:%G" "$path" 2>/dev/null)
    if [[ "$actual_mode" == "$expected_mode" && "$actual_owner" == "$expected_owner" ]]; then
        pass "$desc: $actual_mode $actual_owner"
    else
        fail "$desc: $actual_mode $actual_owner (expected $expected_mode $expected_owner)"
    fi
}

check_file_perm "/var/log/wtmp"   "600" "root:utmp"  "/var/log/wtmp"
check_file_perm "/var/log/btmp"   "600" "root:utmp"  "/var/log/btmp"
check_file_perm "/var/log/lastlog" "640" "root:root" "/var/log/lastlog"

# =============================================================================
# 12. Binary Permissions
# =============================================================================
section "12. Binary Permissions"

check_bin_perm() {
    local bin="$1"; local expected_mode="$2"; local desc="$3"
    if [[ ! -f "$bin" ]]; then
        info "$desc: not found ($bin) — skipping"
        return
    fi
    local actual_mode
    actual_mode=$(stat -c "%a" "$bin" 2>/dev/null)
    if [[ "$actual_mode" == "$expected_mode" ]]; then
        pass "$desc: $actual_mode"
    else
        warn "$desc: $actual_mode (expected $expected_mode)"
    fi
}

check_bin_perm "/usr/bin/last"         "700" "/usr/bin/last (0700 root only)"
check_bin_perm "/usr/sbin/ifconfig"    "700" "/usr/sbin/ifconfig (0700 root only)"
check_bin_perm "/usr/bin/w"            "755" "/usr/bin/w"
check_bin_perm "/bin/su"               "4755" "/bin/su (setuid root)"

# =============================================================================
# 13. /etc/hosts.equiv and .rhosts
# =============================================================================
section "13. /etc/hosts.equiv and .rhosts"

if [[ -f /etc/hosts.equiv ]]; then
    if [[ ! -s /etc/hosts.equiv ]]; then
        pass "/etc/hosts.equiv exists but is empty"
    else
        fail "/etc/hosts.equiv has content — rsh trust relationships are insecure"
        info "Remove content from /etc/hosts.equiv or delete the file"
    fi
else
    pass "/etc/hosts.equiv does not exist"
fi

# Check for .rhosts in home directories
found_rhosts=0
while IFS=: read -r _ _ _ _ _ homedir _; do
    if [[ -f "${homedir}/.rhosts" ]]; then
        fail ".rhosts found: ${homedir}/.rhosts — insecure"
        ((found_rhosts++))
    fi
done < /etc/passwd
[[ "$found_rhosts" -eq 0 ]] && pass "No .rhosts files found in user home directories"

# =============================================================================
# 14. Firewall Status
# =============================================================================
section "14. Firewall Status"

if [[ "$OS" == "rhel" ]]; then
    if systemctl is-active firewalld &>/dev/null; then
        pass "firewalld is active"
        firewall-cmd --list-all 2>/dev/null | grep -E "services:|ports:" | while IFS= read -r line; do
            info "$line"
        done
    elif command -v iptables &>/dev/null && iptables -L 2>/dev/null | grep -qv "Chain.*ACCEPT"; then
        pass "iptables rules are configured"
    else
        warn "firewalld is inactive — verify iptables/nftables rules or this is intentional"
        info "For DB servers: firewall may be managed by network infrastructure"
    fi
elif [[ "$OS" == "ubuntu" ]]; then
    if command -v ufw &>/dev/null; then
        ufw_status=$(ufw status 2>/dev/null | head -1)
        if echo "$ufw_status" | grep -qi "active"; then
            pass "UFW is active"
        else
            warn "UFW is inactive — verify if intentional"
            info "Enable: ufw enable && ufw default deny incoming && ufw allow 22/tcp"
        fi
    else
        warn "UFW not installed"
    fi
fi

# =============================================================================
# 15. SELinux / AppArmor
# =============================================================================
section "15. SELinux / AppArmor"

if [[ "$OS" == "rhel" ]]; then
    if command -v getenforce &>/dev/null; then
        selinux_mode=$(getenforce 2>/dev/null)
        case "$selinux_mode" in
            "Enforcing")  pass "SELinux: Enforcing" ;;
            "Permissive") warn "SELinux: Permissive — not enforcing" ;;
            "Disabled")   warn "SELinux: Disabled — host is vulnerable to container escapes and privilege escalation if not compensated" ;;
        esac
    else
        warn "SELinux: getenforce not found"
    fi
elif [[ "$OS" == "ubuntu" ]]; then
    if command -v aa-status &>/dev/null || command -v apparmor_status &>/dev/null; then
        aa_cmd=$(command -v aa-status 2>/dev/null || command -v apparmor_status)
        if $aa_cmd --enabled 2>/dev/null; then
            pass "AppArmor is enabled"
        else
            warn "AppArmor is not enforcing"
        fi
    else
        warn "AppArmor status tools not found"
    fi
fi

# =============================================================================
# 16. Shell Timeout / TMOUT
# =============================================================================
section "16. Shell Idle Timeout"

tmout_set=false
for f in /etc/profile /etc/profile.d/*.sh /etc/bashrc; do
    if [[ -f "$f" ]] && grep -qE "^\s*(export\s+)?TMOUT\s*=" "$f" 2>/dev/null; then
        tmout_val=$(grep -E "^\s*(export\s+)?TMOUT\s*=" "$f" | tail -1 | grep -oE '[0-9]+')
        if [[ -n "$tmout_val" ]] && [[ "$tmout_val" -le 900 ]]; then
            pass "TMOUT set to ${tmout_val}s in $f"
        else
            warn "TMOUT set to ${tmout_val:-?}s in $f (recommend <= 900)"
        fi
        tmout_set=true
        break
    fi
done
$tmout_set || fail "TMOUT not set in any profile.d script — idle sessions will not time out"

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))

echo ""
echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
echo -e "${BOLD}  HARDENING CHECK SUMMARY${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
echo -e "  Total checks : $TOTAL"
echo -e "  ${GREEN}PASS${NC}          : $PASS_COUNT"
echo -e "  ${RED}FAIL${NC}          : $FAIL_COUNT"
echo -e "  ${YELLOW}WARN${NC}          : $WARN_COUNT"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"

if [[ "$FAIL_COUNT" -eq 0 && "$WARN_COUNT" -eq 0 ]]; then
    echo -e "\n${GREEN}${BOLD}All checks passed. System is hardened.${NC}\n"
    exit 0
elif [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo -e "\n${YELLOW}${BOLD}No failures. Review warnings above.${NC}\n"
    exit 0
else
    echo -e "\n${RED}${BOLD}$FAIL_COUNT failure(s) found. Run linux_hardening_fix.sh to remediate.${NC}\n"
    exit 1
fi
