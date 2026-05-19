# Linux Security Hardening Scripts

Bash-based security audit and remediation for **RHEL 8/9/10** and **Ubuntu 22.04/24.04**.

## Files

| File | Purpose |
|------|---------|
| `scripts/linux_hardening_check.sh` | Audit — checks each control, outputs PASS/FAIL/WARN |
| `scripts/linux_hardening_fix.sh` | Remediation — applies fixes, backs up modified files |

---

## Quick Start

```bash
# Audit (read-only, no changes)
chmod +x scripts/linux_hardening_check.sh
sudo bash scripts/linux_hardening_check.sh

# Preview fixes without applying (dry run)
sudo DRY_RUN=1 bash scripts/linux_hardening_fix.sh

# Apply all fixes
chmod +x scripts/linux_hardening_fix.sh
sudo bash scripts/linux_hardening_fix.sh

# Verify after fix
sudo bash scripts/linux_hardening_check.sh
```

> **Note:** Fix script must run as root. Check script must run as root for full access to `/etc/shadow` and audit rules.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DRY_RUN` | `0` | Set `1` to preview without applying changes |

---

## Checks and Fixes — Detailed Reference

### Section 1 — OS Detection

**What it checks:** Identifies OS family (RHEL or Ubuntu) and version from `/etc/os-release`.

**Purpose:** Several controls have different paths or mechanisms between RHEL and Ubuntu. OS detection gates the correct fix path.

**Supported IDs:** `rhel`, `centos`, `rocky`, `almalinux`, `ol` → RHEL family. `ubuntu` → Ubuntu family.

---

### Section 2 — IPv6 Disable

| Control | Check | Fix |
|---------|-------|-----|
| sysctl runtime | `net.ipv6.conf.all.disable_ipv6 = 1` | Writes `/etc/sysctl.d/99-hardening.conf`, runs `sysctl -p` |
| Kernel cmdline | `ipv6.disable=1` in `/proc/cmdline` | RHEL: `grubby --update-kernel=ALL --args="ipv6.disable=1"` / Ubuntu: edits `/etc/default/grub` + `update-grub` |
| Active interfaces | No IPv6 addresses on non-loopback | Informational only |

**Why:** IPv6 expands attack surface if not used. Disabling via both sysctl (immediate) and GRUB (persistent across reboots) is required for full hardening.

**References:** [RHEL Security Hardening § Disabling IPv6](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/security_hardening/index), [CIS Ubuntu Benchmark 3.3.3](https://www.cisecurity.org/benchmark/ubuntu_linux)

---

### Section 3 — SSH Hardening

All checks read live config via `sshd -T` (reflects active parsed config including includes).

| Parameter | Secure Value | Reason |
|-----------|-------------|--------|
| `PermitRootLogin` | `no` | Prevent direct root SSH — use sudo |
| `PermitEmptyPasswords` | `no` | Disallow password-less accounts via SSH |
| `X11Forwarding` | `no` | X11 forwarding is rarely needed; increases attack surface |
| `IgnoreRhosts` | `yes` | Ignore `.rhosts` / `.shosts` — legacy trust mechanism |
| `HostbasedAuthentication` | `no` | Disable host-based auth (trusts hostnames, easily spoofed) |
| `UseDNS` | `no` | Skip reverse DNS on connect — avoids delays and DNS-based controls |
| `MaxAuthTries` | `4` | Limits brute-force attempts per connection |
| `AllowAgentForwarding` | `no` | Prevent key agent forwarding (pivot risk) |
| `ClientAliveInterval` | `300` | Disconnect idle sessions after 5 min |
| `ClientAliveCountMax` | `3` | Max missed keepalives before disconnect |
| `Banner` | `/etc/banner` | Legal warning before login |

**Fix behavior:** `sed -i` replaces existing matching line (commented or not). Appends if missing. Validates with `sshd -t` before restarting.

**References:** [SSH Hardening 2025](https://www.onlinehashcrack.com/guides/tutorials/howto-harden-ssh-daemon-2025-best-settings.php), [RHEL § Securing SSH](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/security_hardening/index#securing-openssl_security-hardening)

---

### Section 4 — PAM

#### 4.1 faillock (Account Lockout)

| Setting | Value | Meaning |
|---------|-------|---------|
| `deny` | `4` | Lock account after 4 consecutive failures |
| `unlock_time` | `1800` | Locked for 30 minutes before auto-unlock |

**RHEL:** Configured in `/etc/security/faillock.conf`.

**Ubuntu:** Added to `/etc/pam.d/common-auth` via `pam_faillock` module. Also populates `faillock.conf` if present.

#### 4.2 pwhistory (Password Reuse Prevention)

| Setting | Value | Meaning |
|---------|-------|---------|
| `remember` | `5` | Remember last 5 passwords; reject reuse |

**RHEL:** `/etc/security/pwhistory.conf`

**Ubuntu:** `/etc/pam.d/common-password` line: `password required pam_pwhistory.so remember=5 use_authtok`

#### 4.3 pwquality (Password Complexity)

| Setting | Value | Meaning |
|---------|-------|---------|
| `minlen` | `12` | Minimum 12 characters |
| `dcredit` | `-1` | Must contain at least 1 digit |
| `ucredit` | `-1` | Must contain at least 1 uppercase |
| `lcredit` | `-1` | Must contain at least 1 lowercase |
| `ocredit` | `-1` | Must contain at least 1 special character |
| `minclass` | `1` | Minimum 1 character class present |
| `maxrepeat` | `3` | Max 3 consecutive same characters |
| `maxclassrepeat` | `0` | No limit on class repeats (covered by maxrepeat) |

File: `/etc/security/pwquality.conf` (same path on RHEL and Ubuntu).

**References:** [pam_pwquality man page](https://linux.die.net/man/8/pam_pwquality), [Red Hat PAM guide](https://www.redhat.com/en/blog/linux-security-pam)

---

### Section 5 — /etc/login.defs

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `PASS_MAX_DAYS` | `90` | Force password change every 90 days |
| `PASS_MIN_DAYS` | `7` | Minimum 7 days between changes |
| `PASS_WARN_AGE` | `14` | Warn 14 days before expiry |
| `PASS_MIN_LEN` | `12` | Min 12 characters (backup to pwquality) |
| `LOGIN_RETRIES` | `3` | Max login attempts at console |
| `LOGIN_TIMEOUT` | `60` | Timeout login prompt after 60s |

> **Note:** `PASS_MIN_LEN` in login.defs only applies when `pam_pwquality` is NOT in use (RHEL 8+). pwquality `minlen` takes precedence. Both are set for defense-in-depth.

> **Note:** These settings apply to new accounts only. Existing accounts need `chage` to update.

---

### Section 6 — Password Hashing Algorithm

| OS | Recommended | Why |
|----|------------|-----|
| RHEL 8 | `SHA512` | yescrypt not available |
| RHEL 9+ | `yescrypt` | Memory-hard, RHEL 9 default, resists GPU cracking |
| Ubuntu 22.04+ | `yescrypt` | Ubuntu default since 22.04 |

**Check:** `grep ENCRYPT_METHOD /etc/login.defs`

**Shadow check:** Reads first non-system hash from `/etc/shadow` and identifies algorithm by `$id$` prefix:
- `$6$` = SHA-512
- `$y$` = yescrypt
- `$5$` = SHA-256 (warn)
- `$1$` = MD5 (fail — insecure)

---

### Section 7 — cron.allow / at.allow

**Security model:** When `/etc/cron.allow` exists, **only** listed users can use cron. When it doesn't exist, `/etc/cron.deny` is consulted instead. Explicit allow list (`cron.allow`) is more secure than deny list.

| Control | Target | Mode | Owner |
|---------|--------|------|-------|
| `/etc/cron.allow` | `root` (initial) | `0600` | `root:root` |
| `/etc/at.allow` | `root` (initial) | `0600` | `root:root` |
| `/etc/crontab` | — | `0600` | `root:root` |
| `/etc/cron.d/` | — | `0700` | `root:root` |
| `/etc/cron.daily/` | — | `0700` | `root:root` |
| `/etc/cron.weekly/` | — | `0700` | `root:root` |
| `/etc/cron.monthly/` | — | `0700` | `root:root` |
| `/etc/cron.hourly/` | — | `0700` | `root:root` |
| `/var/spool/cron/` | — | `0700` | `root:root` |

**Adding users:** Edit `/etc/cron.allow` and `/etc/at.allow` — one username per line.

**References:** [SUSE cron restriction docs](https://documentation.suse.com/sles/15-SP7/html/SLES-all/cha-sec-cron-at.html), [CIS Benchmark § Cron](https://www.cisecurity.org/benchmark/ubuntu_linux)

---

### Section 8 — Sysctl Kernel Hardening

Written to `/etc/sysctl.d/99-hardening.conf` and loaded via `sysctl -p`.

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `kernel.randomize_va_space` | `2` | Full ASLR — randomize stack, heap, mmap |
| `kernel.kptr_restrict` | `1` | Hide kernel pointers from `/proc/kallsyms` |
| `kernel.dmesg_restrict` | `1` | Restrict dmesg to root |
| `kernel.core_uses_pid` | `1` | Include PID in core dump filename |
| `net.ipv4.ip_forward` | `0` | Disable IP forwarding (not a router) |
| `net.ipv4.conf.all.rp_filter` | `1` | Reverse path filter — drop spoofed packets |
| `net.ipv4.conf.default.rp_filter` | `1` | Same for new interfaces |
| `net.ipv4.icmp_echo_ignore_broadcasts` | `1` | No ICMP amplification via broadcasts |
| `net.ipv4.tcp_syncookies` | `1` | SYN flood protection |
| `net.ipv4.conf.all.accept_source_route` | `0` | Reject source-routed packets |
| `net.ipv4.conf.all.accept_redirects` | `0` | No ICMP redirect acceptance (MITM prevention) |
| `net.ipv4.conf.all.send_redirects` | `0` | No ICMP redirect sending |
| `net.ipv4.conf.all.secure_redirects` | `0` | Reject even "secure" redirects |
| `net.ipv4.conf.all.log_martians` | `1` | Log packets with impossible source addresses |
| `net.ipv6.conf.all.disable_ipv6` | `1` | IPv6 off (also set via GRUB) |
| `fs.suid_dumpable` | `0` | SUID processes cannot dump core |

**References:** [Linux sysctl hardening](https://linux-audit.com/system-hardening/linux-hardening-with-sysctl/), [SUSE Network Security](https://documentation.suse.com/sles/15-SP7/html/SLES-all/cha-sec-sysctl.html)

---

### Section 9 — auditd

**Purpose:** Audit daemon records security-relevant system events to `/var/log/audit/audit.log`. Required by CIS Level 2 and common compliance frameworks (PCI-DSS, SOC2, ISO 27001).

**Rules deployed** to `/etc/audit/rules.d/99-hardening.rules`:

| Watch path | Permission | Key | Why |
|-----------|-----------|-----|-----|
| `/etc/passwd`, `/etc/shadow`, `/etc/gshadow`, `/etc/group` | `wa` | `identity_change` | Account modifications |
| `/etc/security/opasswd` | `wa` | `identity_change` | Password history file |
| `/etc/sudoers`, `/etc/sudoers.d/` | `wa` | `privilege_escalation` | Sudo changes |
| `/etc/ssh/sshd_config` | `wa` | `sshd_config_change` | SSH config changes |
| `/etc/pam.d/` | `wa` | `pam_config_change` | PAM changes |
| `/etc/security/` | `wa` | `security_config_change` | Security policy changes |
| `/etc/cron.allow`, `/etc/at.allow`, etc. | `wa` | `cron_config_change` | Cron access control changes |
| `/etc/crontab`, `/etc/cron.d/` | `wa` | `cron_config_change` | Cron job changes |
| `/sbin/insmod`, `/sbin/rmmod`, `/sbin/modprobe` | `x` | `modules` | Kernel module loading |
| `/etc/login.defs` | `wa` | `login_config_change` | Login policy changes |

**Load method:** `augenrules --load` (preferred, merges all rule files) or `auditctl -R`.

**Query logs:**
```bash
ausearch -k identity_change     # identity changes
ausearch -k privilege_escalation # sudo changes
ausearch -k modules              # kernel module loading
ausearch -ts today               # today's events
```

**References:** [Red Hat auditd guide](https://www.redhat.com/en/blog/configure-linux-auditing-auditd), [Oracle Linux auditd](https://docs.oracle.com/en/learn/ol-auditd/)

---

### Section 10 — Core Dump Restrictions

| Control | File | Setting |
|---------|------|---------|
| Hard limit | `/etc/security/limits.conf` | `* hard core 0` |
| Soft limit | `/etc/security/limits.conf` | `* soft core 0` |
| SUID dumps | `/etc/sysctl.d/99-hardening.conf` | `fs.suid_dumpable = 0` |
| systemd | `/etc/systemd/coredump.conf` | `Storage=none` |

**Why:** Core dumps can contain sensitive memory contents (passwords, keys, session tokens). Disabling prevents exfiltration via crash artifacts.

---

### Section 11 — UTMP / BTMP Permissions

| File | Mode | Owner | Purpose |
|------|------|-------|---------|
| `/var/log/wtmp` | `0600` | `root:utmp` | Login/logout history |
| `/var/log/btmp` | `0600` | `root:utmp` | Failed login attempts |
| `/var/log/lastlog` | `0640` | `root:root` | Last login per user |

**Why:** World-readable login logs leak information about who logs in, from where, and when.

---

### Section 12 — Binary Permissions

| Binary | Mode | Why |
|--------|------|-----|
| `/usr/bin/last` | `0700` | Shows login history — restrict to root |
| `/usr/sbin/ifconfig` | `0700` | Shows network configuration — restrict to root |

---

### Section 13 — /etc/hosts.equiv and .rhosts

**Why:** `.rhosts` and `hosts.equiv` implement legacy rsh/rlogin trust that bypasses password authentication. Any non-empty `hosts.equiv` or any `.rhosts` file is a security risk.

**Check:** Script scans all home directories from `/etc/passwd`.

---

### Section 14 — Firewall Status

**RHEL:** Checks `firewalld` active status. Warns if inactive (does not enable — firewall management is environment-specific for DB servers).

**Ubuntu:** Checks `ufw status`. Warns if inactive.

> The existing playbook intentionally disables firewalld on DB servers (managed by network infrastructure). The scripts warn but do not force-enable.

---

### Section 15 — SELinux / AppArmor

**RHEL:** `getenforce` — checks for Enforcing / Permissive / Disabled. Warns if not Enforcing.

**Ubuntu:** `aa-status --enabled` — checks AppArmor state.

> Scripts warn if disabled but do NOT force-enable (risk of breaking services). Playbooks for new builds enforce the setting.

---

### Section 16 — Shell Idle Timeout

**Check:** Scans `/etc/profile`, `/etc/profile.d/*.sh`, `/etc/bashrc` for `TMOUT`.

**Fix:** Writes `readonly TMOUT=600; export TMOUT` to `/etc/profile.d/04-autologout.sh`.

**Value:** 600 seconds (10 minutes). Set to `900` (15 min) for less aggressive timeout if needed.

---

## Backup and Logging

### Backups

Fix script creates `/root/hardening_backup_YYYYMMDD_HHMMSS/` with a copy of every file before modification. Directory mirrors source paths:

```
/root/hardening_backup_20260518_143022/
├── etc/
│   ├── ssh/sshd_config
│   ├── login.defs
│   ├── security/
│   │   ├── faillock.conf
│   │   ├── pwquality.conf
│   │   └── limits.conf
│   └── ...
```

### Log File

All actions logged to `/var/log/linux_hardening_fix.log` with timestamps:

```
[2026-05-18 14:30:22] === 3. SSH Hardening ===
[2026-05-18 14:30:22] [FIXED] SSH PermitRootLogin set to no
[2026-05-18 14:30:22] [SKIP] SSH UseDNS already no
[2026-05-18 14:30:23] [FIXED] sshd restarted after config changes
```

---

## What the Scripts Do NOT Change

| Item | Reason |
|------|--------|
| SELinux enforcement | Risk of breaking services; must be validated per host |
| Firewall rules | Environment-specific; DB servers use network firewall |
| Firewall enable/disable | Existing playbook intentionally disables on DB servers |
| IPv6 GRUB on Ubuntu | `update-grub` runs but fix only adds to cmdline — does not replace existing entries |
| `.rhosts` removal | User decision; script warns but does not delete |
| `cron.deny` removal | Script warns; user decides whether to remove |
| Kernel module blacklisting | System-specific; USB/removable media control is separate |
| `/tmp` noexec mounting | Requires fstab change and remount; out of scope for in-place fix |

---

## Next Steps: Ansible Playbook

Once scripts are validated on RHEL and Ubuntu VMs, controls will be migrated to Ansible roles:

- `roles/hardening_ubuntu/` — Ubuntu equivalent of `roles/hardening_security/`
- `playbooks/00_ubuntu_guide.yml` — Ubuntu baseline + hardening playbook

See [`playbooks/00_ubuntu_guide.yml`](../playbooks/00_ubuntu_guide.yml) for the current Ubuntu playbook.

---

## References

| Source | URL |
|--------|-----|
| RHEL 9 Security Hardening | https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/security_hardening/index |
| RHEL 8 Security Hardening | https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html-single/security_hardening/index |
| Ubuntu CIS Benchmarks | https://ubuntu.com/security/cis |
| Ubuntu 24.04 CIS Hardening | https://ubuntu.com/blog/hardening-automation-for-cis-benchmarks-now-available-for-ubuntu-24-04-lts |
| CIS Linux Benchmarks | https://www.cisecurity.org/benchmark/ubuntu_linux |
| pam_pwquality | https://linux.die.net/man/8/pam_pwquality |
| Red Hat PAM guide | https://www.redhat.com/en/blog/linux-security-pam |
| Linux sysctl hardening | https://linux-audit.com/system-hardening/linux-hardening-with-sysctl/ |
| auditd configuration | https://www.redhat.com/en/blog/configure-linux-auditing-auditd |
| Oracle Linux auditd | https://docs.oracle.com/en/learn/ol-auditd/ |
| SSH hardening 2025 | https://www.onlinehashcrack.com/guides/tutorials/howto-harden-ssh-daemon-2025-best-settings.php |
| SUSE cron security | https://documentation.suse.com/sles/15-SP7/html/SLES-all/cha-sec-cron-at.html |
| login.defs man page | https://man7.org/linux/man-pages/man5/login.defs.5.html |
