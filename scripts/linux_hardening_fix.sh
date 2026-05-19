#!/usr/bin/env bash
# =============================================================================
# linux_hardening_fix.sh
# Linux Security Hardening Remediation Script
# Supports: RHEL 8/9/10, Ubuntu 22.04/24.04
#
# IMPORTANT: Run as root. Creates backups before every modification.
# Idempotent — safe to run multiple times.
#
# References:
#   - RHEL Security Hardening: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/security_hardening/index
#   - CIS Ubuntu Benchmark:    https://ubuntu.com/security/cis
#   - CIS Benchmarks:          https://www.cisecurity.org/benchmark/ubuntu_linux
# =============================================================================

set -uo pipefail

# --- Root check --------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# --- Configuration -----------------------------------------------------------
BACKUP_DIR="/root/hardening_backup_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/linux_hardening_fix.log"
DRY_RUN="${DRY_RUN:-0}"  # Set DRY_RUN=1 to preview without applying

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FIXED_COUNT=0
SKIP_COUNT=0
ERROR_COUNT=0

# --- Helpers -----------------------------------------------------------------
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
fixed()   { echo -e "${GREEN}[FIXED]${NC} $1"; log "[FIXED] $1"; ((FIXED_COUNT++)); }
skipped() { echo -e "${CYAN}[SKIP]${NC} $1"; log "[SKIP] $1"; ((SKIP_COUNT++)); }
error()   { echo -e "${RED}[ERROR]${NC} $1"; log "[ERROR] $1"; ((ERROR_COUNT++)); }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; log "[WARN] $1"; }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"; log "=== $1 ==="; }
info()    { echo -e "       ${CYAN}↳${NC} $1"; }

backup_file() {
    local src="$1"
    if [[ -f "$src" ]]; then
        local dst="${BACKUP_DIR}$(dirname "$src")"
        mkdir -p "$dst"
        cp -p "$src" "$dst/"
        log "Backup: $src → $dst/"
    fi
}

apply_sysctl() {
    local key="$1"; local val="$2"
    local current
    current=$(sysctl -n "$key" 2>/dev/null || echo "MISSING")
    if [[ "$current" == "$val" ]]; then
        skipped "sysctl $key already $val"
        return
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        warn "[DRY-RUN] Would set sysctl $key=$val (current: $current)"
        return
    fi
    echo "${key} = ${val}" >> /etc/sysctl.d/99-hardening.conf
    sysctl -w "${key}=${val}" &>/dev/null && fixed "sysctl $key=$val" || error "Failed to set sysctl $key"
}

set_lineinfile() {
    local file="$1"; local pattern="$2"; local line="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        current=$(grep -E "$pattern" "$file" | head -1)
        if [[ "$current" == "$line" ]]; then
            skipped "$file: '$line' already set"
            return 0
        fi
        [[ "$DRY_RUN" == "0" ]] && sed -i "s|${pattern}|${line}|g" "$file" && fixed "$file: set '$line'" || warn "[DRY-RUN] Would set '$line' in $file"
    else
        [[ "$DRY_RUN" == "0" ]] && echo "$line" >> "$file" && fixed "$file: appended '$line'" || warn "[DRY-RUN] Would append '$line' to $file"
    fi
}

# =============================================================================
# Init
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  Linux Security Hardening Fix Script               ${NC}"
echo -e "${BOLD}${CYAN}  $(date)                ${NC}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${NC}"

[[ "$DRY_RUN" == "1" ]] && warn "DRY-RUN MODE — no changes will be applied"

mkdir -p "$BACKUP_DIR"
log "Started. Backup dir: $BACKUP_DIR"
echo "Backups: $BACKUP_DIR"
echo "Log:     $LOG_FILE"

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
        rhel|centos|rocky|almalinux|ol) OS="rhel" ;;
        ubuntu) OS="ubuntu" ;;
    esac
fi

echo "OS: $OS_NAME $OS_VERSION (family: $OS)"
log "OS: $OS_NAME $OS_VERSION"

if [[ "$OS" == "unknown" ]]; then
    error "Unsupported OS: $OS_NAME — some fixes may not apply correctly"
fi

# =============================================================================
# 2. IPv6 Disable
# =============================================================================
section "2. IPv6 Disable"

# 2.1 sysctl (immediate effect, persists via /etc/sysctl.d/)
SYSCTL_HARDENING="/etc/sysctl.d/99-hardening.conf"
touch "$SYSCTL_HARDENING"

# Clear existing IPv6 entries to avoid duplicates (idempotent)
sed -i '/^net\.ipv6\.conf\.\(all\|default\)\.disable_ipv6/d' "$SYSCTL_HARDENING" 2>/dev/null || true

apply_sysctl "net.ipv6.conf.all.disable_ipv6"     "1"
apply_sysctl "net.ipv6.conf.default.disable_ipv6" "1"

# 2.2 GRUB persistence
if [[ "$OS" == "rhel" ]]; then
    if command -v grubby &>/dev/null; then
        if ! grep -q "ipv6.disable=1" /proc/cmdline 2>/dev/null; then
            [[ "$DRY_RUN" == "0" ]] && grubby --update-kernel=ALL --args="ipv6.disable=1" && fixed "GRUB: ipv6.disable=1 added (reboot required)" || warn "[DRY-RUN] Would run: grubby --update-kernel=ALL --args='ipv6.disable=1'"
        else
            skipped "GRUB: ipv6.disable=1 already in cmdline"
        fi
    fi
elif [[ "$OS" == "ubuntu" ]]; then
    GRUB_DEFAULT="/etc/default/grub"
    if [[ -f "$GRUB_DEFAULT" ]]; then
        if ! grep -q "ipv6.disable=1" "$GRUB_DEFAULT"; then
            backup_file "$GRUB_DEFAULT"
            if [[ "$DRY_RUN" == "0" ]]; then
                sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 ipv6.disable=1"/' "$GRUB_DEFAULT"
                update-grub 2>/dev/null && fixed "GRUB: ipv6.disable=1 added to Ubuntu grub (reboot required)"
            else
                warn "[DRY-RUN] Would add ipv6.disable=1 to /etc/default/grub"
            fi
        else
            skipped "GRUB: ipv6.disable=1 already in /etc/default/grub"
        fi
    fi
fi

# =============================================================================
# 3. SSH Hardening
# =============================================================================
section "3. SSH Hardening"

SSHD_CONFIG="/etc/ssh/sshd_config"

if [[ ! -f "$SSHD_CONFIG" ]]; then
    error "SSH config not found: $SSHD_CONFIG — skipping SSH hardening"
else
    backup_file "$SSHD_CONFIG"

    ssh_changed=false

    apply_ssh_param() {
        local key="$1"; local value="$2"
        local current
        current=$(sshd -T 2>/dev/null | grep -i "^${key} " | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
        local val_lower
        val_lower=$(echo "$value" | tr '[:upper:]' '[:lower:]')

        if [[ "$current" == "$val_lower" ]]; then
            skipped "SSH $key already $value"
            return
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
            warn "[DRY-RUN] SSH $key: would set to $value (current: $current)"
            return
        fi

        if grep -qiE "^\s*#?\s*${key}\b" "$SSHD_CONFIG"; then
            sed -i "s|^\s*#\?\s*${key}\b.*|${key} ${value}|gI" "$SSHD_CONFIG"
        else
            echo "${key} ${value}" >> "$SSHD_CONFIG"
        fi
        fixed "SSH $key set to $value"
        ssh_changed=true
    }

    apply_ssh_param "PermitRootLogin"          "no"
    apply_ssh_param "PermitEmptyPasswords"     "no"
    apply_ssh_param "X11Forwarding"            "no"
    apply_ssh_param "IgnoreRhosts"             "yes"
    apply_ssh_param "HostbasedAuthentication"  "no"
    apply_ssh_param "UseDNS"                   "no"
    apply_ssh_param "MaxAuthTries"             "4"
    apply_ssh_param "AllowAgentForwarding"     "no"

    # ClientAliveInterval — set only if currently 0 or unset (timeout is important)
    current_cai=$(sshd -T 2>/dev/null | grep -i "^clientaliveinterval " | awk '{print $2}')
    if [[ "${current_cai:-0}" == "0" ]]; then
        apply_ssh_param "ClientAliveInterval"   "300"
        apply_ssh_param "ClientAliveCountMax"   "3"
    else
        skipped "SSH ClientAliveInterval already $current_cai"
    fi

    if [[ "$ssh_changed" == "true" && "$DRY_RUN" == "0" ]]; then
        if sshd -t 2>/dev/null; then
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
            fixed "sshd restarted after config changes"
        else
            error "sshd -t validation failed — sshd NOT restarted. Fix config manually."
        fi
    fi
fi

# =============================================================================
# 4. PAM Configuration
# =============================================================================
section "4. PAM Configuration"

# 4.1 faillock (RHEL — via faillock.conf)
if [[ "$OS" == "rhel" ]]; then
    FAILLOCK_CONF="/etc/security/faillock.conf"
    if [[ -f "$FAILLOCK_CONF" ]]; then
        backup_file "$FAILLOCK_CONF"
        for pair in "deny = 4" "unlock_time = 1800"; do
            key=$(echo "$pair" | awk '{print $1}')
            current=$(grep -E "^\s*${key}\s*=" "$FAILLOCK_CONF" | awk -F= '{print $2}' | tr -d ' ')
            expected=$(echo "$pair" | awk '{print $3}')
            if [[ "$current" == "$expected" ]]; then
                skipped "faillock.conf $pair already set"
            elif [[ -n "$current" ]]; then
                [[ "$DRY_RUN" == "0" ]] && sed -i "s|^\s*#\?\s*${key}\s*=.*|${pair}|" "$FAILLOCK_CONF" && fixed "faillock.conf: $pair" || warn "[DRY-RUN] Would set $pair"
            else
                [[ "$DRY_RUN" == "0" ]] && echo "$pair" >> "$FAILLOCK_CONF" && fixed "faillock.conf: appended $pair" || warn "[DRY-RUN] Would append $pair"
            fi
        done
    else
        warn "faillock.conf not found — PAM faillock may need manual configuration"
    fi

elif [[ "$OS" == "ubuntu" ]]; then
    # Ubuntu: configure pam_faillock in /etc/pam.d/common-auth
    COMMON_AUTH="/etc/pam.d/common-auth"
    backup_file "$COMMON_AUTH"
    if ! grep -q "pam_faillock" "$COMMON_AUTH" 2>/dev/null; then
        if [[ "$DRY_RUN" == "0" ]]; then
            # Insert before the first auth line
            sed -i '1s|^|auth required pam_faillock.so preauth\nauth [success=1 default=ignore] pam_unix.so nullok\nauth [default=die] pam_faillock.so authfail deny=4 unlock_time=1800\nauth sufficient pam_faillock.so authsucc\n|' "$COMMON_AUTH"
            fixed "Ubuntu: pam_faillock added to common-auth"
        else
            warn "[DRY-RUN] Would add pam_faillock to /etc/pam.d/common-auth"
        fi
    else
        skipped "pam_faillock already in /etc/pam.d/common-auth"
    fi

    # Ubuntu: faillock.conf
    FAILLOCK_CONF="/etc/security/faillock.conf"
    if [[ -f "$FAILLOCK_CONF" ]]; then
        backup_file "$FAILLOCK_CONF"
        for pair in "deny = 4" "unlock_time = 1800"; do
            key=$(echo "$pair" | awk '{print $1}')
            current=$(grep -E "^\s*${key}\s*=" "$FAILLOCK_CONF" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
            expected=$(echo "$pair" | awk '{print $3}')
            if [[ "$current" == "$expected" ]]; then
                skipped "faillock.conf $pair already set"
            elif [[ -n "$current" ]]; then
                [[ "$DRY_RUN" == "0" ]] && sed -i "s|^\s*#\?\s*${key}\s*=.*|${pair}|" "$FAILLOCK_CONF" && fixed "faillock.conf: $pair" || warn "[DRY-RUN] Would set $pair"
            else
                [[ "$DRY_RUN" == "0" ]] && echo "$pair" >> "$FAILLOCK_CONF" && fixed "faillock.conf: appended $pair" || warn "[DRY-RUN] Would append $pair"
            fi
        done
    fi
fi

# 4.2 pwhistory
PWHISTORY_CONF="/etc/security/pwhistory.conf"
if [[ -f "$PWHISTORY_CONF" ]]; then
    backup_file "$PWHISTORY_CONF"
    current_remember=$(grep -E "^\s*remember\s*=" "$PWHISTORY_CONF" | awk -F= '{print $2}' | tr -d ' ')
    if [[ "${current_remember:-0}" -ge 5 ]]; then
        skipped "pwhistory remember=$current_remember already >= 5"
    else
        [[ "$DRY_RUN" == "0" ]] && sed -i "s|^\s*#\?\s*remember\s*=.*|remember = 5|" "$PWHISTORY_CONF" && fixed "pwhistory: remember = 5" || warn "[DRY-RUN] Would set remember = 5"
    fi
else
    # For Ubuntu, configure in common-password
    if [[ "$OS" == "ubuntu" ]]; then
        COMMON_PASS="/etc/pam.d/common-password"
        if ! grep -q "pam_pwhistory" "$COMMON_PASS" 2>/dev/null; then
            backup_file "$COMMON_PASS"
            [[ "$DRY_RUN" == "0" ]] && echo "password required pam_pwhistory.so remember=5 use_authtok" >> "$COMMON_PASS" && fixed "Ubuntu: pam_pwhistory added to common-password" || warn "[DRY-RUN] Would add pam_pwhistory to common-password"
        else
            skipped "pam_pwhistory already in /etc/pam.d/common-password"
        fi
    fi
fi

# 4.3 pwquality
PWQUALITY_CONF="/etc/security/pwquality.conf"
if [[ -f "$PWQUALITY_CONF" ]]; then
    backup_file "$PWQUALITY_CONF"

    apply_pwq() {
        local key="$1"; local val="$2"
        local current
        current=$(grep -E "^\s*${key}\s*=" "$PWQUALITY_CONF" | awk -F= '{print $2}' | tr -d ' ')
        if [[ "$current" == "$val" ]]; then
            skipped "pwquality $key=$val already set"
        elif grep -qE "^\s*#?\s*${key}\s*=" "$PWQUALITY_CONF"; then
            [[ "$DRY_RUN" == "0" ]] && sed -i "s|^\s*#\?\s*${key}\s*=.*|${key} = ${val}|" "$PWQUALITY_CONF" && fixed "pwquality: $key = $val" || warn "[DRY-RUN] Would set $key = $val"
        else
            [[ "$DRY_RUN" == "0" ]] && echo "${key} = ${val}" >> "$PWQUALITY_CONF" && fixed "pwquality: appended $key = $val" || warn "[DRY-RUN] Would append $key = $val"
        fi
    }

    apply_pwq "minlen"          "12"
    apply_pwq "dcredit"         "-1"
    apply_pwq "ucredit"         "-1"
    apply_pwq "lcredit"         "-1"
    apply_pwq "ocredit"         "-1"
    apply_pwq "minclass"        "1"
    apply_pwq "maxrepeat"       "3"
    apply_pwq "maxclassrepeat"  "0"
else
    warn "pwquality.conf not found: $PWQUALITY_CONF"
    warn "Install: libpam-pwquality (Ubuntu) or libpwquality (RHEL)"
fi

# Ubuntu: ensure pwquality is in pam.d/common-password
if [[ "$OS" == "ubuntu" ]]; then
    COMMON_PASS="/etc/pam.d/common-password"
    if ! grep -q "pam_pwquality" "$COMMON_PASS" 2>/dev/null; then
        backup_file "$COMMON_PASS"
        if [[ "$DRY_RUN" == "0" ]]; then
            sed -i 's|password\s*\[success=.*\] pam_unix.so|password required pam_pwquality.so retry=3\n&|' "$COMMON_PASS"
            fixed "Ubuntu: pam_pwquality added to common-password"
        else
            warn "[DRY-RUN] Would add pam_pwquality to /etc/pam.d/common-password"
        fi
    else
        skipped "pam_pwquality already in /etc/pam.d/common-password"
    fi
fi

# =============================================================================
# 5. login.defs
# =============================================================================
section "5. /etc/login.defs"

LOGIN_DEFS="/etc/login.defs"
if [[ -f "$LOGIN_DEFS" ]]; then
    backup_file "$LOGIN_DEFS"

    apply_logindefs() {
        local key="$1"; local val="$2"
        if grep -qE "^\s*${key}\s+" "$LOGIN_DEFS"; then
            current=$(grep -E "^\s*${key}\s+" "$LOGIN_DEFS" | awk '{print $2}')
            if [[ "$current" == "$val" ]]; then
                skipped "login.defs $key already $val"
            else
                [[ "$DRY_RUN" == "0" ]] && sed -i "s|^\s*${key}\s\+.*|${key}   ${val}|" "$LOGIN_DEFS" && fixed "login.defs: $key = $val" || warn "[DRY-RUN] Would set $key=$val"
            fi
        else
            [[ "$DRY_RUN" == "0" ]] && echo "${key}   ${val}" >> "$LOGIN_DEFS" && fixed "login.defs: appended $key = $val" || warn "[DRY-RUN] Would append $key=$val"
        fi
    }

    apply_logindefs "PASS_MAX_DAYS"  "90"
    apply_logindefs "PASS_MIN_DAYS"  "7"
    apply_logindefs "PASS_WARN_AGE"  "14"
    apply_logindefs "PASS_MIN_LEN"   "12"
    apply_logindefs "LOGIN_RETRIES"  "3"
    apply_logindefs "LOGIN_TIMEOUT"  "60"

    # Password hashing algorithm
    if [[ "$OS" == "rhel" ]]; then
        # RHEL 9+ supports yescrypt, RHEL 8 uses SHA512
        rhel_major=$(echo "$OS_VERSION" | cut -d. -f1)
        if [[ "${rhel_major:-8}" -ge 9 ]]; then
            apply_logindefs "ENCRYPT_METHOD" "yescrypt"
        else
            apply_logindefs "ENCRYPT_METHOD" "SHA512"
        fi
    elif [[ "$OS" == "ubuntu" ]]; then
        apply_logindefs "ENCRYPT_METHOD" "yescrypt"
    fi
fi

# =============================================================================
# 6. cron.allow / at.allow
# =============================================================================
section "6. cron.allow / at.allow"

# cron.allow
if [[ ! -f /etc/cron.allow ]]; then
    if [[ "$DRY_RUN" == "0" ]]; then
        echo "root" > /etc/cron.allow
        chmod 0600 /etc/cron.allow
        chown root:root /etc/cron.allow
        fixed "Created /etc/cron.allow with 'root'"
    else
        warn "[DRY-RUN] Would create /etc/cron.allow"
    fi
else
    skipped "/etc/cron.allow already exists"
    # Ensure permissions
    if [[ "$(stat -c '%a' /etc/cron.allow)" != "600" ]]; then
        [[ "$DRY_RUN" == "0" ]] && chmod 0600 /etc/cron.allow && chown root:root /etc/cron.allow && fixed "/etc/cron.allow permissions fixed: 0600 root:root" || warn "[DRY-RUN] Would fix cron.allow perms"
    fi
fi

# Remove cron.deny (cron.allow takes precedence; deny is redundant)
if [[ -f /etc/cron.deny ]]; then
    warn "/etc/cron.deny exists — keeping but recommend removing when cron.allow is in use"
    info "To remove: rm -f /etc/cron.deny"
fi

# at.allow
if [[ ! -f /etc/at.allow ]]; then
    if [[ "$DRY_RUN" == "0" ]]; then
        echo "root" > /etc/at.allow
        chmod 0600 /etc/at.allow
        chown root:root /etc/at.allow
        fixed "Created /etc/at.allow with 'root'"
    else
        warn "[DRY-RUN] Would create /etc/at.allow"
    fi
else
    skipped "/etc/at.allow already exists"
    if [[ "$(stat -c '%a' /etc/at.allow)" != "600" ]]; then
        [[ "$DRY_RUN" == "0" ]] && chmod 0600 /etc/at.allow && chown root:root /etc/at.allow && fixed "/etc/at.allow permissions fixed" || warn "[DRY-RUN] Would fix at.allow perms"
    fi
fi

# /etc/crontab permissions
if [[ -f /etc/crontab ]]; then
    if [[ "$(stat -c '%a:%U:%G' /etc/crontab)" != "600:root:root" ]]; then
        [[ "$DRY_RUN" == "0" ]] && chmod 0600 /etc/crontab && chown root:root /etc/crontab && fixed "/etc/crontab: 0600 root:root" || warn "[DRY-RUN] Would fix /etc/crontab perms"
    else
        skipped "/etc/crontab permissions already correct"
    fi
fi

# Cron directories
for cron_dir in /etc/cron.d /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.hourly; do
    if [[ -d "$cron_dir" ]]; then
        current_perms=$(stat -c '%a:%U:%G' "$cron_dir" 2>/dev/null)
        if [[ "$current_perms" != "700:root:root" ]]; then
            [[ "$DRY_RUN" == "0" ]] && chmod 0700 "$cron_dir" && chown root:root "$cron_dir" && fixed "$cron_dir: 0700 root:root" || warn "[DRY-RUN] Would fix $cron_dir perms"
        else
            skipped "$cron_dir permissions already correct"
        fi
    fi
done

# /var/spool/cron
if [[ -d /var/spool/cron ]]; then
    if [[ "$(stat -c '%a:%U:%G' /var/spool/cron)" != "700:root:root" ]]; then
        [[ "$DRY_RUN" == "0" ]] && chmod 0700 /var/spool/cron && chown root:root /var/spool/cron && fixed "/var/spool/cron: 0700 root:root" || warn "[DRY-RUN] Would fix /var/spool/cron"
    else
        skipped "/var/spool/cron permissions already correct"
    fi
fi

# =============================================================================
# 7. Sysctl Kernel Hardening
# =============================================================================
section "7. Sysctl Kernel Hardening"

# Rebuild 99-hardening.conf cleanly (remove stale entries first)
SYSCTL_CONF="/etc/sysctl.d/99-hardening.conf"

if [[ "$DRY_RUN" == "0" ]]; then
    # Write complete file (idempotent — overwrites every run)
    cat > "$SYSCTL_CONF" << 'EOF'
# ============================================================
# Linux Security Hardening — sysctl parameters
# Generated by linux_hardening_fix.sh
# References: RHEL Security Guide, CIS Benchmarks
# ============================================================

# ASLR — full randomization of address space layout
kernel.randomize_va_space = 2

# Kernel pointer and dmesg restrictions
kernel.kptr_restrict = 1
kernel.dmesg_restrict = 1
kernel.core_uses_pid = 1

# Disable IP forwarding (not a router)
net.ipv4.ip_forward = 0

# Anti-spoofing — reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Ignore ICMP broadcast (amplification prevention)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Reject source-routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Disable ICMP redirects (prevent MITM routing attacks)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Log suspicious (martian) packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# IPv6 disable (complements GRUB method — immediate effect)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# SUID core dumps restriction
fs.suid_dumpable = 0

# TCP timestamps (disable to prevent fingerprinting — optional)
# net.ipv4.tcp_timestamps = 0
EOF
    sysctl -p "$SYSCTL_CONF" &>/dev/null && fixed "Sysctl hardening conf written and loaded: $SYSCTL_CONF" || error "Failed to load sysctl conf — check $SYSCTL_CONF"
else
    warn "[DRY-RUN] Would write and load $SYSCTL_CONF"
fi

# =============================================================================
# 8. auditd
# =============================================================================
section "8. auditd"

# Install if missing
if ! command -v auditctl &>/dev/null; then
    if [[ "$DRY_RUN" == "0" ]]; then
        if [[ "$OS" == "rhel" ]]; then
            dnf install -y audit &>/dev/null && fixed "audit package installed" || error "Failed to install audit"
        elif [[ "$OS" == "ubuntu" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y auditd &>/dev/null && fixed "auditd package installed" || error "Failed to install auditd"
        fi
    else
        warn "[DRY-RUN] Would install auditd"
    fi
fi

# Deploy audit rules
AUDIT_RULES_DIR="/etc/audit/rules.d"
AUDIT_RULES_FILE="${AUDIT_RULES_DIR}/99-hardening.rules"

if [[ -d "$AUDIT_RULES_DIR" ]]; then
    if [[ "$DRY_RUN" == "0" ]]; then
        cat > "$AUDIT_RULES_FILE" << 'EOF'
# ============================================================
# Linux Security Hardening — auditd rules
# Generated by linux_hardening_fix.sh
# References: RHEL Auditd Guide, CIS Benchmarks
# ============================================================

# Delete existing rules
-D

# Buffer size (increase if audit events are lost)
-b 8192

# Failure mode: 1=printk, 2=panic
-f 1

# ---- Identity & Authentication files ----
-w /etc/passwd       -p wa -k identity_change
-w /etc/shadow       -p wa -k identity_change
-w /etc/gshadow      -p wa -k identity_change
-w /etc/group        -p wa -k identity_change
-w /etc/security/opasswd -p wa -k identity_change

# ---- Privilege escalation ----
-w /etc/sudoers      -p wa -k privilege_escalation
-w /etc/sudoers.d/   -p wa -k privilege_escalation

# ---- SSH configuration ----
-w /etc/ssh/sshd_config -p wa -k sshd_config_change

# ---- PAM configuration ----
-w /etc/pam.d/       -p wa -k pam_config_change
-w /etc/security/    -p wa -k security_config_change

# ---- Cron configuration ----
-w /etc/cron.allow   -p wa -k cron_config_change
-w /etc/cron.deny    -p wa -k cron_config_change
-w /etc/at.allow     -p wa -k cron_config_change
-w /etc/at.deny      -p wa -k cron_config_change
-w /etc/crontab      -p wa -k cron_config_change
-w /etc/cron.d/      -p wa -k cron_config_change

# ---- Kernel module loading ----
-w /usr/sbin/insmod  -p x -k modules
-w /usr/sbin/rmmod   -p x -k modules
-w /usr/sbin/modprobe -p x -k modules
-w /sbin/insmod      -p x -k modules
-w /sbin/rmmod       -p x -k modules
-w /sbin/modprobe    -p x -k modules

# ---- login.defs ----
-w /etc/login.defs   -p wa -k login_config_change

# ---- Immutable (must be last) — prevents rule changes without reboot ----
# Uncomment after confirming rules are correct:
# -e 2
EOF
        fixed "auditd rules deployed: $AUDIT_RULES_FILE"

        # Load rules
        if command -v augenrules &>/dev/null; then
            augenrules --load &>/dev/null && fixed "auditd rules loaded via augenrules" || error "augenrules --load failed"
        elif command -v auditctl &>/dev/null; then
            auditctl -R "$AUDIT_RULES_FILE" &>/dev/null && fixed "auditd rules loaded via auditctl" || error "auditctl -R failed"
        fi
    else
        warn "[DRY-RUN] Would write $AUDIT_RULES_FILE and load rules"
    fi
else
    warn "Audit rules directory not found: $AUDIT_RULES_DIR — auditd may not be installed"
fi

# Enable and start auditd
if command -v auditctl &>/dev/null; then
    if ! systemctl is-enabled auditd &>/dev/null; then
        [[ "$DRY_RUN" == "0" ]] && systemctl enable auditd &>/dev/null && fixed "auditd enabled at boot" || warn "[DRY-RUN] Would enable auditd"
    else
        skipped "auditd already enabled"
    fi

    if ! systemctl is-active auditd &>/dev/null; then
        [[ "$DRY_RUN" == "0" ]] && service auditd start &>/dev/null && fixed "auditd started" || warn "[DRY-RUN] Would start auditd"
    else
        skipped "auditd already running"
    fi
fi

# =============================================================================
# 9. Core Dump Restrictions
# =============================================================================
section "9. Core Dump Restrictions"

LIMITS_CONF="/etc/security/limits.conf"
if [[ -f "$LIMITS_CONF" ]]; then
    if ! grep -qE '^\*\s+hard\s+core\s+0' "$LIMITS_CONF"; then
        backup_file "$LIMITS_CONF"
        if [[ "$DRY_RUN" == "0" ]]; then
            echo "* hard core 0" >> "$LIMITS_CONF"
            echo "* soft core 0" >> "$LIMITS_CONF"
            fixed "limits.conf: core dumps disabled"
        else
            warn "[DRY-RUN] Would add '* hard core 0' to limits.conf"
        fi
    else
        skipped "limits.conf: core 0 already set"
    fi
fi

# systemd coredump.conf
COREDUMP_CONF="/etc/systemd/coredump.conf"
if [[ -f "$COREDUMP_CONF" ]]; then
    backup_file "$COREDUMP_CONF"
    if ! grep -qE "^\s*Storage\s*=\s*none" "$COREDUMP_CONF"; then
        if [[ "$DRY_RUN" == "0" ]]; then
            if grep -qE "^\s*Storage\s*=" "$COREDUMP_CONF"; then
                sed -i 's|^\s*Storage\s*=.*|Storage=none|' "$COREDUMP_CONF"
            else
                sed -i '/^\[Coredump\]/a Storage=none' "$COREDUMP_CONF"
            fi
            fixed "systemd-coredump: Storage=none"
        else
            warn "[DRY-RUN] Would set Storage=none in coredump.conf"
        fi
    else
        skipped "systemd-coredump Storage=none already set"
    fi
fi

# =============================================================================
# 10. UTMP / BTMP Permissions
# =============================================================================
section "10. UTMP / BTMP Permissions"

fix_file_perm() {
    local path="$1"; local mode="$2"; local owner="$3"; local desc="$4"
    [[ ! -e "$path" ]] && { warn "$desc: not found ($path)"; return; }
    local current_mode current_owner
    current_mode=$(stat -c '%a' "$path" 2>/dev/null)
    current_owner=$(stat -c '%U:%G' "$path" 2>/dev/null)
    if [[ "$current_mode" == "$mode" && "$current_owner" == "$owner" ]]; then
        skipped "$desc already $mode $owner"
    else
        [[ "$DRY_RUN" == "0" ]] && chmod "$mode" "$path" && chown "$owner" "$path" && fixed "$desc: $mode $owner" || warn "[DRY-RUN] Would fix $desc to $mode $owner"
    fi
}

fix_file_perm "/var/log/wtmp"    "0600" "root:utmp"  "/var/log/wtmp"
fix_file_perm "/var/log/btmp"    "0600" "root:utmp"  "/var/log/btmp"
fix_file_perm "/var/log/lastlog" "0640" "root:root"  "/var/log/lastlog"

# =============================================================================
# 11. Binary Permissions
# =============================================================================
section "11. Binary Permissions"

fix_bin_perm() {
    local bin="$1"; local mode="$2"; local desc="$3"
    [[ ! -f "$bin" ]] && return
    current=$(stat -c '%a' "$bin" 2>/dev/null)
    if [[ "$current" == "$mode" ]]; then
        skipped "$desc already $mode"
    else
        [[ "$DRY_RUN" == "0" ]] && chmod "$mode" "$bin" && chown root:root "$bin" && fixed "$desc: $mode" || warn "[DRY-RUN] Would set $bin to $mode"
    fi
}

fix_bin_perm "/usr/bin/last"      "0700" "/usr/bin/last (restrict to root)"
fix_bin_perm "/usr/sbin/ifconfig" "0700" "/usr/sbin/ifconfig (restrict to root)"

# =============================================================================
# 12. /etc/hosts.equiv and .rhosts
# =============================================================================
section "12. /etc/hosts.equiv and .rhosts"

if [[ -f /etc/hosts.equiv ]]; then
    if [[ -s /etc/hosts.equiv ]]; then
        warn "/etc/hosts.equiv has content — review before removing"
        info "To secure: truncate /etc/hosts.equiv or run: echo '' > /etc/hosts.equiv"
    else
        skipped "/etc/hosts.equiv exists but is empty"
    fi
fi

# Check .rhosts in home dirs — warn only (user decision to remove)
found_rhosts=0
while IFS=: read -r _ _ _ _ _ homedir _; do
    if [[ -f "${homedir}/.rhosts" ]]; then
        warn ".rhosts found: ${homedir}/.rhosts — remove manually"
        ((found_rhosts++))
    fi
done < /etc/passwd
[[ "$found_rhosts" -eq 0 ]] && skipped "No .rhosts files found"

# =============================================================================
# 13. Shell Idle Timeout (TMOUT)
# =============================================================================
section "13. Shell Idle Timeout"

TMOUT_FILE="/etc/profile.d/04-autologout.sh"
if [[ -f "$TMOUT_FILE" ]]; then
    if grep -qE "TMOUT" "$TMOUT_FILE"; then
        skipped "TMOUT already configured in $TMOUT_FILE"
    else
        backup_file "$TMOUT_FILE"
        [[ "$DRY_RUN" == "0" ]] && echo "readonly TMOUT=600; export TMOUT" >> "$TMOUT_FILE" && fixed "TMOUT=600 added to $TMOUT_FILE" || warn "[DRY-RUN] Would add TMOUT to $TMOUT_FILE"
    fi
else
    if [[ "$DRY_RUN" == "0" ]]; then
        cat > "$TMOUT_FILE" << 'EOF'
# Auto-logout after 600 seconds of inactivity
readonly TMOUT=600
export TMOUT
EOF
        chmod 0644 "$TMOUT_FILE"
        fixed "Created $TMOUT_FILE with TMOUT=600"
    else
        warn "[DRY-RUN] Would create $TMOUT_FILE"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((FIXED_COUNT + SKIP_COUNT + ERROR_COUNT))

echo ""
echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
echo -e "${BOLD}  HARDENING FIX SUMMARY${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
echo -e "  Total actions : $TOTAL"
echo -e "  ${GREEN}FIXED${NC}         : $FIXED_COUNT"
echo -e "  ${CYAN}SKIPPED${NC}       : $SKIP_COUNT (already compliant)"
echo -e "  ${RED}ERRORS${NC}        : $ERROR_COUNT"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
echo "  Backup dir : $BACKUP_DIR"
echo "  Log file   : $LOG_FILE"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"

if [[ "$ERROR_COUNT" -eq 0 ]]; then
    echo -e "\n${GREEN}${BOLD}Hardening applied. Run linux_hardening_check.sh to verify.${NC}"
    echo -e "${YELLOW}NOTE: Some changes require a reboot (IPv6 GRUB, sysctl may need reboot on some systems).${NC}\n"
    log "Completed: FIXED=$FIXED_COUNT SKIP=$SKIP_COUNT ERRORS=$ERROR_COUNT"
    exit 0
else
    echo -e "\n${RED}${BOLD}$ERROR_COUNT error(s) occurred. Review $LOG_FILE.${NC}\n"
    log "Completed with errors: FIXED=$FIXED_COUNT SKIP=$SKIP_COUNT ERRORS=$ERROR_COUNT"
    exit 1
fi
