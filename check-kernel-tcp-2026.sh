#!/usr/bin/env bash
#
# Kernel TCP checker: CVE-2026-98432 (IPv4 TCP handshake use-after-free, remote root)
#
# Usage:
#   sudo ./check-kernel-tcp-2026.sh              # check only — makes no changes; reports whether the
#                                                # running kernel has the fix, and if a reboot is pending
#   sudo ./check-kernel-tcp-2026.sh --mitigate   # stopgap: drop inbound IPv4 TCP with IP options,
#                                                # MPTCP and request migration off; survives reboot
#   sudo ./check-kernel-tcp-2026.sh --unmitigate # remove the stopgap again
#   sudo ./check-kernel-tcp-2026.sh --upgrade    # apt-upgrade the kernel only (no reboot)
#   sudo ./check-kernel-tcp-2026.sh --upgrade --proposed
#                                                # Ubuntu 22.04+: take the fixed kernel from -proposed
#                                                # before it reaches -updates (pocket removed afterwards)
#   Add -y to skip the confirmation prompt.
# Every mode re-runs the check afterwards.
#
# Linux 4.4 and newer are affected; the fix is upstream commit "ipv4: free inet_opt
# and ireq_opt after an RCU grace period" (stable 5.10.272, 5.15.223, 6.1.190,
# 6.6.159, 6.12.113, 6.18.56, 7.2.10, mainline 7.3). Only a new kernel plus a
# reboot (or a livepatch) fixes it.
#
# Last line of output is machine-readable, for collecting results across servers:
#   RESULT|<host>|<status>|<details>
# Exit codes: 0 = not vulnerable, 1 = vulnerable (or reboot pending), 2 = could not determine
#
set -u

CVE="CVE-2026-98432"
FIX_SUBJECT="free inet_opt and ireq_opt after an RCU grace period"
TAG="cve-2026-98432"
HELPER="/usr/local/sbin/${TAG}-mitigation"
UNIT="${TAG}-mitigation.service"
SYSCTL_FILE="/etc/sysctl.d/99-${TAG}.conf"
PROP_LIST="/etc/apt/sources.list.d/${TAG}-proposed.list"
PROP_PIN="/etc/apt/preferences.d/${TAG}-proposed"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
HOST=$(hostname -f 2>/dev/null || hostname)

ACTION="check"; ASSUME_YES="no"; PROPOSED="no"
for arg in "$@"; do
    case "$arg" in
        --mitigate)   ACTION="mitigate" ;;
        --unmitigate) ACTION="unmitigate" ;;
        --upgrade)    ACTION="upgrade" ;;
        --proposed)   PROPOSED="yes" ;;
        -y|--yes)     ASSUME_YES="yes" ;;
        -h|--help)    sed -n '2,27p' "$0"; exit 0 ;;
        *)            echo "Unknown option: $arg (see --help)"; exit 2 ;;
    esac
done
if [ "$PROPOSED" = "yes" ] && [ "$ACTION" != "upgrade" ]; then
    echo "--proposed only works with --upgrade"; exit 2
fi

if [ "$ACTION" != "check" ] && [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}--${ACTION} changes the system — run it with sudo.${NC}"
    exit 2
fi

echo -e "${BOLD}=== Kernel TCP (${CVE}) checker — ${HOST} — $(date '+%Y-%m-%d %H:%M') ===${NC}\n"

# a <= b, version-wise
ver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

# shellcheck disable=SC1091
OS_ID=$(. /etc/os-release 2>/dev/null; echo "${ID:-linux}")
OS_LIKE=$(. /etc/os-release 2>/dev/null; echo "${ID_LIKE:-}")
OS_PRETTY=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
OS_CODENAME=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
KREL=${KREL:-$(uname -r)}        # KREL overrides the running kernel, for testing
KVER=$(echo "$KREL" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?')

# Fixed kernel builds by release/source package, from the Ubuntu CVE tracker
# (2026-11-05: in -proposed) and Debian's DSA/DLA. Anything >= these is fixed.
known_fixed_build() {
    case "$1/$2" in
        jammy/linux)            echo "5.15.0-203.213" ;;
        noble/linux)            echo "6.8.0-149.149" ;;
        resolute/linux)         echo "7.0.0-43.43" ;;
        stonking/linux)         echo "7.3.0-10.10" ;;
        focal/linux-hwe-5.15)   echo "5.15.0-203.213~20.04.1" ;;
        jammy/linux-hwe-6.8)    echo "6.8.0-149.149~22.04.1" ;;
        noble/linux-hwe-7.0)    echo "7.0.0-43.43~24.04.1" ;;
        jammy/linux-lowlatency) echo "5.15.0-198.208" ;;
        noble/linux-lowlatency) echo "6.8.0-149.149.1" ;;
        jammy/linux-kvm)        echo "5.15.0-1112.117" ;;
        jammy/linux-aws)        echo "5.15.0-1120.127" ;;
        noble/linux-aws)        echo "6.8.0-1069.74" ;;
        resolute/linux-aws)     echo "7.0.0-1017.18" ;;
        stonking/linux-aws)     echo "7.3.0-1004.4" ;;
        focal/linux-aws-5.15)   echo "5.15.0-1120.127~20.04.1" ;;
        jammy/linux-aws-6.8)    echo "6.8.0-1069.74~22.04.1" ;;
        noble/linux-aws-7.0)    echo "7.0.0-1017.18~24.04.1" ;;
        jammy/linux-azure)      echo "5.15.0-1126.135" ;;
        noble/linux-azure)      echo "6.8.0-1073.82" ;;
        resolute/linux-azure)   echo "7.0.0-1020.21" ;;
        stonking/linux-azure)   echo "7.3.0-1004.4" ;;
        focal/linux-azure-5.15) echo "5.15.0-1126.135~20.04.1" ;;
        jammy/linux-azure-6.8)  echo "6.8.0-1073.82~22.04.1" ;;
        noble/linux-azure-7.0)  echo "7.0.0-1020.21~24.04.1" ;;
        jammy/linux-gcp)        echo "5.15.0-1121.131" ;;
        noble/linux-gcp)        echo "6.8.0-1073.81" ;;
        resolute/linux-gcp)     echo "7.0.0-1017.19" ;;
        stonking/linux-gcp)     echo "7.3.0-1004.4" ;;
        focal/linux-gcp-5.15)   echo "5.15.0-1121.131~20.04.1" ;;
        jammy/linux-gcp-6.8)    echo "6.8.0-1073.81~22.04.1" ;;
        noble/linux-gcp-7.0)    echo "7.0.0-1017.19~24.04.1" ;;
        jammy/linux-oracle)     echo "5.15.0-1117.123" ;;
        noble/linux-oracle)     echo "6.8.0-1067.71" ;;
        resolute/linux-oracle)  echo "7.0.0-1016.18" ;;
        focal/linux-oracle-5.15) echo "5.15.0-1117.123~20.04.1" ;;
        noble/linux-oracle-7.0) echo "7.0.0-1016.18~24.04.1" ;;
        bookworm/6.1)           echo "6.1.190-1" ;;            # DLA-4841-1
        bookworm/6.12)          echo "6.12.113-1~deb12u1" ;;   # DLA-4850-1
        trixie/6.12)            echo "6.12.113-1" ;;           # DSA-6568-1
    esac
}

# Upstream stable releases carrying the fix, for kernels not from a distro package
upstream_fixed() {
    local v="$1"
    case "$(echo "$v" | cut -d. -f1,2)" in
        5.10) ver_le 5.10.272 "$v" ;;
        5.15) ver_le 5.15.223 "$v" ;;
        6.1)  ver_le 6.1.190 "$v" ;;
        6.6)  ver_le 6.6.159 "$v" ;;
        6.12) ver_le 6.12.113 "$v" ;;
        6.18) ver_le 6.18.56 "$v" ;;
        7.2)  ver_le 7.2.10 "$v" ;;
        *)    ver_le 7.3 "$v" ;;      # 7.3+ fixed; other old branches never got it
    esac
}

# The package that holds kernel <release>'s files and its changelog: "<pkg> <source> <version>"
kernel_pkg() {
    local r="$1" p
    if command -v dpkg-query >/dev/null 2>&1; then
        # linux-image-*-generic comes from linux-signed, whose changelog has no fixes in it
        for p in "linux-modules-$r" "linux-image-unsigned-$r" "linux-image-$r"; do
            dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${source:Package} ${Version}\n' "$p" 2>/dev/null \
                | awk '$1 ~ /^[ih]i/ {print $2, $3, $4; f=1} END {exit !f}' && return 0
        done
    elif command -v rpm >/dev/null 2>&1; then
        p=$(rpm -qf "/lib/modules/$r" --qf '%{NAME} %{SOURCERPM} %{VERSION}-%{RELEASE}\n' 2>/dev/null | head -1)
        [ -n "$p" ] && [[ "$p" != *"not owned"* ]] && { echo "$p"; return 0; }
    fi
    return 1
}

# known_fixed_build key: Ubuntu tracks kernels by source package, Debian by branch
fix_key() {
    if [ "$OS_ID" = "debian" ]; then echo "$2" | cut -d. -f1,2; else echo "$1"; fi
}

# Does this kernel package carry the fix? Sets KFIXED (yes/no/unknown) and KWHY.
kernel_fixed() {
    local pkg="$1" src="$2" ver="$3" r="$4" cl key known
    KFIXED="unknown"; KWHY=""
    if command -v dpkg-query >/dev/null 2>&1; then
        cl="/usr/share/doc/$pkg/changelog.Debian.gz"
        if [ -f "$cl" ] && zgrep -qE "$CVE|$FIX_SUBJECT" "$cl" 2>/dev/null; then
            KFIXED="yes"; KWHY="changelog has the fix"; return
        fi
    elif rpm -q --changelog "$pkg-$ver" 2>/dev/null | grep -qE "$CVE|$FIX_SUBJECT"; then
        KFIXED="yes"; KWHY="changelog has the fix"; return
    fi
    key=$(fix_key "$src" "$r")
    known=$(known_fixed_build "$OS_CODENAME" "$key")
    if [ -n "$known" ]; then
        if dpkg --compare-versions "$ver" ge "$known" 2>/dev/null; then
            KFIXED="yes"; KWHY=">= fixed build $known"
        else
            KFIXED="no"; KWHY="fixed in $known"
        fi
        return
    fi
    KFIXED="no"; KWHY="no fixed build known for $OS_CODENAME/$key"
}

# Mitigation state: rule (iptables/nft), sysctls, persistence
mitigation_state() {
    RULE_ON="no"; RULE_HOW=""
    if command -v iptables >/dev/null 2>&1 && iptables -t raw -S PREROUTING 2>/dev/null | grep -q "$TAG"; then
        RULE_ON="yes"; RULE_HOW="iptables raw"
    elif command -v nft >/dev/null 2>&1 && nft list tables 2>/dev/null | grep -q "cve_2026_98432"; then
        RULE_ON="yes"; RULE_HOW="nft table cve_2026_98432"
    fi
    MPTCP=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "n/a")
    MIGRATE=$(sysctl -n net.ipv4.tcp_migrate_req 2>/dev/null || echo "n/a")
    PERSIST="no"
    systemctl is-enabled --quiet "$UNIT" 2>/dev/null && PERSIST="yes"
}

confirm() {
    [ "$ASSUME_YES" = "yes" ] && return 0
    read -r -p "$1 [y/N] " ans < /dev/tty
    [[ "$ans" =~ ^[Yy]$ ]]
}

SELF=$(readlink -f "$0")

# ── Actions ───────────────────────────────────────────────────────────
do_mitigate() {
    echo -e "${BOLD}--- Applying stopgap ---${NC}"
    echo "  • Drop inbound IPv4 TCP packets that carry IP options (normal traffic never does;"
    echo "    the bug needs them). Covers the host and its Docker containers. Survives reboot."
    echo "  • net.mptcp.enabled=0 and net.ipv4.tcp_migrate_req=0 where the kernel has them."
    echo "  Lowers the risk a lot but is not a fix: the kernel still needs upgrading."
    confirm "  Proceed?" || { echo "  Skipped."; echo; return; }

    cat > "$HELPER" <<'EOF'
#!/bin/sh
# CVE-2026-98432 stopgap: drop inbound IPv4 TCP packets carrying IP options.
# Installed by check-kernel-tcp-2026.sh --mitigate; removed by --unmitigate.
RULE='-p tcp -m u32 --u32 0>>24&0xF=6:15 -m comment --comment cve-2026-98432 -j DROP'
case "$1" in
    start)
        if command -v iptables >/dev/null 2>&1 && iptables -t raw -L PREROUTING >/dev/null 2>&1; then
            iptables -t raw -C PREROUTING $RULE 2>/dev/null || iptables -t raw -I PREROUTING $RULE && exit 0
        fi
        # No iptables or no u32 match (some cloud kernels): nftables matches the header natively
        nft list table ip cve_2026_98432 >/dev/null 2>&1 && exit 0
        nft -f - <<'NFT'
table ip cve_2026_98432 {
    chain prerouting {
        type filter hook prerouting priority -300; policy accept;
        ip protocol tcp ip hdrlength > 5 counter drop
    }
}
NFT
        ;;
    stop)
        if command -v iptables >/dev/null 2>&1; then
            while iptables -t raw -D PREROUTING $RULE 2>/dev/null; do :; done
        fi
        command -v nft >/dev/null 2>&1 && nft delete table ip cve_2026_98432 2>/dev/null
        exit 0
        ;;
    *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
EOF
    chmod 0755 "$HELPER"
    if "$HELPER" start; then
        echo -e "  ${GREEN}✓${NC} drop rule active"
    else
        echo -e "  ${RED}✗ could not add the drop rule (no working iptables u32 or nft) — see the errors above${NC}"
    fi

    if [ -d /run/systemd/system ]; then
        cat > "/etc/systemd/system/$UNIT" <<EOF
[Unit]
Description=CVE-2026-98432 stopgap: drop inbound IPv4 TCP packets carrying IP options
After=network-pre.target netfilter-persistent.service ufw.service firewalld.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$HELPER start
ExecStop=$HELPER stop

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --quiet "$UNIT" && systemctl start "$UNIT" \
            && echo -e "  ${GREEN}✓${NC} $UNIT enabled (re-applies the rule at boot)"
    else
        echo -e "  ${YELLOW}! no systemd — the rule is lost on reboot; re-run --mitigate after booting${NC}"
    fi

    : > "$SYSCTL_FILE"
    for key in net.mptcp.enabled net.ipv4.tcp_migrate_req; do
        if sysctl -n "$key" >/dev/null 2>&1; then
            echo "$key = 0" >> "$SYSCTL_FILE"
            sysctl -q -w "$key=0" >/dev/null 2>&1
            if [ "$(sysctl -n "$key" 2>/dev/null)" = "0" ]; then
                echo -e "  ${GREEN}✓${NC} $key=0"
            else
                echo -e "  ${YELLOW}! could not set $key=0 now (read-only /proc/sys?); applied at next boot${NC}"
            fi
        fi
    done
    if [ -s "$SYSCTL_FILE" ]; then
        sed -i "1i # $CVE stopgap, added by check-kernel-tcp-2026.sh --mitigate" "$SYSCTL_FILE"
    else
        rm -f "$SYSCTL_FILE"
        echo "  • this kernel has no MPTCP / request migration settings — nothing to switch off"
    fi
    if command -v ss >/dev/null 2>&1 && [ -n "$(ss -H -lMn 2>/dev/null)" ]; then
        echo -e "  ${YELLOW}! MPTCP listeners keep running until restarted (often Go 1.24+ services):${NC}"
        ss -H -lMnp 2>/dev/null | awk '{print "      " $4, $NF}' | head -10
    fi
    echo
}

do_unmitigate() {
    echo -e "${BOLD}--- Removing stopgap ---${NC}"
    confirm "  Remove the drop rule, its boot service and the sysctl file?" || { echo "  Skipped."; echo; return; }
    if [ -f "/etc/systemd/system/$UNIT" ]; then
        systemctl disable --now --quiet "$UNIT" 2>/dev/null
        rm -f "/etc/systemd/system/$UNIT"
        systemctl daemon-reload
        echo -e "  ${GREEN}✓${NC} $UNIT removed"
    fi
    if [ -x "$HELPER" ]; then
        "$HELPER" stop
        rm -f "$HELPER"
    fi
    echo -e "  ${GREEN}✓${NC} drop rule removed"
    if [ -f "$SYSCTL_FILE" ]; then
        # Back to the kernel defaults (MPTCP on; migration was already off by default)
        grep -q '^net.mptcp.enabled' "$SYSCTL_FILE" && sysctl -q -w net.mptcp.enabled=1 >/dev/null 2>&1 \
            && echo -e "  ${GREEN}✓${NC} net.mptcp.enabled=1 (the default) again"
        rm -f "$SYSCTL_FILE"
        echo -e "  ${GREEN}✓${NC} $SYSCTL_FILE removed"
    fi
    echo
}

do_upgrade() {
    echo -e "${BOLD}--- Upgrading the kernel ---${NC}"
    if ! command -v apt-get >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1; then
            echo "  Not apt-based. Upgrade with: sudo dnf update kernel && sudo reboot"
        else
            echo "  Not apt-based. Upgrade with: sudo yum update kernel && sudo reboot"
        fi
        echo; return
    fi
    # The metapackages that pull in new kernels: Ubuntu's linux-meta* (linux-generic,
    # linux-image-aws, linux-generic-hwe-20.04, …) and Debian's linux-image-<arch>
    local metas
    metas=$(dpkg-query -W -f='${source:Package}\t${binary:Package}\t${db:Status-Abbrev}\n' 2>/dev/null \
            | awk '$3 ~ /^ii/ && ($1 ~ /^linux-meta/ || $2 ~ /^linux-(image|headers)-(cloud-|rt-)?(amd64|arm64)$/) {print $2}' \
            | sort -u | tr '\n' ' ')
    if [ -z "$metas" ]; then
        echo -e "  ${YELLOW}No kernel metapackage installed (e.g. linux-generic), so apt never moves to a new kernel.${NC}"
        echo "  Install the one for your flavour, e.g.: sudo apt install linux-generic"
        echo; return
    fi

    local target=()
    if [ "$PROPOSED" = "yes" ]; then
        if [ "$OS_ID" != "ubuntu" ]; then
            echo "  --proposed is for Ubuntu only."; echo; return
        fi
        case "$(dpkg --print-architecture)" in
            amd64|i386) mirror="http://archive.ubuntu.com/ubuntu" ;;
            *)          mirror="http://ports.ubuntu.com/ubuntu-ports" ;;
        esac
        # Removed on exit, however the script ends
        trap 'rm -f "$PROP_LIST" "$PROP_PIN"' EXIT
        echo "deb $mirror ${OS_CODENAME}-proposed main restricted" > "$PROP_LIST"
        # 22.04's -proposed isn't marked opt-in: keep everything else from coming from it
        printf 'Package: *\nPin: release a=%s-proposed\nPin-Priority: 100\n' "$OS_CODENAME" > "$PROP_PIN"
        target=(-t "${OS_CODENAME}-proposed")
        echo "  Temporarily added ${OS_CODENAME}-proposed (pinned low; removed again when done)."
    fi

    upd_err=$(apt-get update -qq -o Acquire::AllowReleaseInfoChange::Label=true 2>&1 >/dev/null) \
        || echo -e "  ${YELLOW}apt-get update reported errors — continuing:${NC}"
    [ -n "${upd_err:-}" ] && echo "$upd_err" | grep -E '^(E|W):' | sed -n '1,5s/^/    /p'

    # shellcheck disable=SC2086
    plan=$(apt-get -s install --only-upgrade ${target[@]+"${target[@]}"} $metas 2>&1)
    new=$(echo "$plan" | awk '/^Inst linux-(modules|image-unsigned|image)-[0-9]/ {gsub(/[()\[\]]/,""); print $2, $3}' \
          | sort -u)
    if echo "$plan" | grep -q '^Remv '; then
        echo -e "  ${RED}apt would remove packages — not continuing:${NC}"
        echo "$plan" | awk '/^Remv /{print "      " $2}'
        echo; return
    fi
    if [ -z "$new" ]; then
        echo -e "  ${YELLOW}No newer kernel in apt.${NC}"
        if [ "$OS_ID" = "ubuntu" ] && [ "$PROPOSED" = "no" ]; then
            case "$OS_CODENAME" in
                xenial|bionic|focal)
                    echo "  Ubuntu's fix for this release comes through Ubuntu Pro (ESM) only, and is not out yet."
                    pro status 2>/dev/null | grep -E '^esm-infra' | sed 's/^/    /' \
                        || echo "    Ubuntu Pro isn't attached: sudo pro attach <token>  (free for 5 machines)" ;;
                *)
                    echo "  The fix may still be in -proposed only. To take it now:"
                    echo "    sudo $SELF --upgrade --proposed" ;;
            esac
        fi
        echo; return
    fi
    echo "  Will install (current kernel stays installed as a fallback in the boot menu):"
    echo "$new" | while read -r p v; do
        src=$(apt-cache show --no-all-versions "$p=$v" 2>/dev/null | awk '/^Source:/{print $2; exit}')
        known=$(known_fixed_build "$OS_CODENAME" "$(fix_key "${src:-linux}" "${p#linux-*-}")")
        if [ -n "$known" ] && dpkg --compare-versions "$v" ge "$known"; then
            echo -e "      $p $v  ${GREEN}— has the fix${NC}"
        elif [ -n "$known" ]; then
            echo -e "      $p $v  ${YELLOW}— older than the fixed $known${NC}"
        else
            echo -e "      $p $v  ${YELLOW}— can't confirm the fix; the check afterwards says for sure${NC}"
        fi
    done
    if [ "$PROPOSED" = "yes" ]; then
        extra=$(echo "$plan" | awk '/^Inst / && /-proposed/ && $2 !~ /^linux-/ {print $2}' | paste -sd' ' -)
        [ -n "$extra" ] && echo -e "  ${YELLOW}! also from -proposed (needed by the new kernel): ${extra}${NC}"
    fi
    confirm "  Install it? (no reboot yet)" || { echo "  Skipped."; echo; return; }
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --only-upgrade ${target[@]+"${target[@]}"} \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $metas \
        && echo -e "  ${GREEN}✓${NC} kernel installed — reboot to run it: sudo reboot" \
        || echo -e "  ${RED}✗ apt-get install failed — see above${NC}"
    echo
}

case "$ACTION" in
    mitigate)   do_mitigate ;;
    unmitigate) do_unmitigate ;;
    upgrade)    do_upgrade ;;
esac

# ── 1. Running kernel ─────────────────────────────────────────────────
echo -e "${BOLD}--- Running kernel ---${NC}"
echo "  $OS_PRETTY, kernel $KREL"
INCONTAINER="no"
if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    INCONTAINER="yes"
elif virt=$(systemd-detect-virt -c 2>/dev/null) && [ "$virt" != "none" ]; then
    INCONTAINER="yes"
fi
[ "$INCONTAINER" = "yes" ] && echo -e "  ${YELLOW}Inside a container: this is the host's kernel — run the check on the host.${NC}"

STATE=""; LIVE=""
if command -v canonical-livepatch >/dev/null 2>&1 \
   && canonical-livepatch status --verbose 2>/dev/null | grep -q "$CVE"; then
    LIVE="Livepatch"
elif command -v kcarectl >/dev/null 2>&1 && kcarectl --patch-info 2>/dev/null | grep -q "$CVE"; then
    LIVE="KernelCare"
fi

RUN_FIXED="unknown"
if KP=$(kernel_pkg "$KREL"); then
    read -r KPKG KSRC KPV <<<"$KP"
    KSRC=${KSRC%%-[0-9]*.src.rpm}   # rpm: kernel-4.18.0-….src.rpm → kernel
    kernel_fixed "$KPKG" "$KSRC" "$KPV" "$KREL"
    RUN_FIXED="$KFIXED"
    echo "  package $KPKG $KPV (source: $KSRC) — $KWHY"
else
    KPV=""
    echo "  not from a distro package — comparing with upstream releases"
fi

if [ -n "$LIVE" ]; then
    STATE="PATCHED-LIVE"
    echo -e "  ${GREEN}PATCHED (live, by $LIVE)${NC} — the fix is applied to the running kernel"
elif [ -n "$KVER" ] && ! ver_le 4.4 "$KVER"; then
    STATE="NOT-AFFECTED"
    echo -e "  ${GREEN}NOT AFFECTED${NC} — the bug came in with Linux 4.4"
elif [ "$RUN_FIXED" = "yes" ]; then
    STATE="PATCHED"
    echo -e "  ${GREEN}PATCHED${NC}"
elif [ -z "$KPV" ] && [ -n "$KVER" ] && upstream_fixed "$KVER"; then
    STATE="PATCHED"
    echo -e "  ${GREEN}PATCHED${NC} (upstream $KVER has the fix)"
elif [ -z "$KPV" ] && [ -z "$KVER" ]; then
    STATE="UNKNOWN"
    echo -e "  ${YELLOW}UNKNOWN — could not read the kernel version${NC}"
else
    STATE="VULNERABLE"
    echo -e "  ${RED}VULNERABLE${NC}"
fi

# ── 2. Installed kernels (is a fixed one waiting for a reboot?) ───────
echo -e "\n${BOLD}--- Installed kernels ---${NC}"
PENDING=""
if command -v dpkg-query >/dev/null 2>&1; then
    while read -r r; do
        [ "$r" = "$KREL" ] && continue
        KP=$(kernel_pkg "$r") || continue
        read -r p s v <<<"$KP"
        kernel_fixed "$p" "$s" "$v" "$r"
        if [ "$KFIXED" = "yes" ]; then
            echo -e "  $r  $v  ${GREEN}fixed${NC}"
            if [ -z "$PENDING" ] || dpkg --compare-versions "$v" gt "${PENDING#* }"; then PENDING="$r $v"; fi
        else
            echo -e "  $r  $v  ${YELLOW}not fixed${NC}"
        fi
    done < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-modules-[0-9]*' 'linux-image-[0-9]*' 2>/dev/null \
             | awk '$1 ~ /^ii/ {print $2}' | sed -E 's/^linux-(modules|image)-//' | sort -uV)
elif command -v rpm >/dev/null 2>&1; then
    rpm -q kernel kernel-core 2>/dev/null | grep -v 'not installed' | sed 's/^/  /'
fi
[ -z "$(ls /lib/modules 2>/dev/null | grep -vxF "$KREL")" ] && echo "  (no other kernel installed)"
REBOOT_REQ="no"
[ -f /var/run/reboot-required ] && REBOOT_REQ="yes"
[ "$REBOOT_REQ" = "yes" ] && echo -e "  ${YELLOW}/var/run/reboot-required is set${NC}"

# ── 3. Exposure ───────────────────────────────────────────────────────
echo -e "\n${BOLD}--- Exposure ---${NC}"
LISTEN=""
if command -v ss >/dev/null 2>&1; then
    LISTEN=$(ss -H -ltn 2>/dev/null | awk '{print $4}' \
             | grep -vE '^(127\.|\[::1\]|::1|\[::ffff:127\.)' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un | paste -sd' ' -)
    echo "  TCP ports listening beyond localhost: ${LISTEN:-none}"
    MPL=$(ss -H -lMn 2>/dev/null | awk '{print $4}' | paste -sd' ' -)
    [ -n "$MPL" ] && echo -e "  ${YELLOW}MPTCP listeners (the demonstrated exploit used one): $MPL${NC}"
fi
mitigation_state
echo "  net.mptcp.enabled=$MPTCP  net.ipv4.tcp_migrate_req=$MIGRATE"
if [ "$(id -u)" -ne 0 ]; then
    echo -e "  ${YELLOW}Not root: can't read the firewall — run with sudo to see the stopgap state${NC}"
    RULE_ON="unknown"
elif [ "$RULE_ON" = "yes" ]; then
    echo -e "  Stopgap: ${GREEN}drop rule active${NC} ($RULE_HOW)$( [ "$PERSIST" = yes ] && echo ", re-applied at boot by $UNIT")"
else
    echo "  Stopgap: not applied"
fi
command -v docker >/dev/null 2>&1 && echo "  Docker installed: containers share this kernel, and the host rule covers them"

# ── Verdict ───────────────────────────────────────────────────────────
echo -e "\n${BOLD}=== VERDICT ===${NC}"
NEXT="none"
case "$STATE" in
    PATCHED|PATCHED-LIVE|NOT-AFFECTED)
        RC=0
        if [ "$STATE" = "NOT-AFFECTED" ]; then
            echo -e "${GREEN}Kernel $KVER predates the bug — not affected.${NC}"
        else
            echo -e "${GREEN}The running kernel has the fix.${NC}"
            [ "$STATE" = "PATCHED-LIVE" ] && echo "  It is a live patch: still install the fixed kernel at the next reboot window."
        fi
        if [ "$RULE_ON" = "yes" ] || [ -f "$SYSCTL_FILE" ]; then
            echo "  → Stopgap no longer needed: sudo $SELF --unmitigate"
        fi ;;
    VULNERABLE)
        RC=1
        if [ -n "$PENDING" ]; then
            STATE="REBOOT-NEEDED"; NEXT="reboot"
            echo -e "${YELLOW}A fixed kernel is installed (${PENDING% *}) but not running yet.${NC}"
            echo "  •  Reboot in a maintenance window: sudo reboot"
            echo "     then re-run this check; it should print PATCHED."
        else
            echo -e "${RED}The running kernel is vulnerable and no fixed kernel is installed.${NC}"
            if [ -z "$LISTEN" ]; then
                echo -e "  ${YELLOW}Nothing listens beyond localhost, so practical risk is LOW.${NC}"
            fi
            NEXT="upgrade"
            if [ "$OS_ID" = "ubuntu" ]; then
                case "$OS_CODENAME" in
                    xenial|bionic|focal)
                        NEXT="mitigate-wait-esm"
                        echo "  •  Ubuntu's fix for $OS_PRETTY comes through Ubuntu Pro (ESM) only, and is not out yet."
                        known=$(known_fixed_build "$OS_CODENAME" "${KSRC:-}")
                        [ -n "$known" ] && echo "     (A fix for this ${KSRC} kernel is in testing: $known.)"
                        echo "     Attach Ubuntu Pro if it isn't (free for 5 machines): sudo pro attach <token>"
                        echo "     Then: sudo $SELF --upgrade   once Ubuntu releases it" ;;
                    *)
                        echo "  •  Get the fixed kernel, then reboot:"
                        echo "       sudo $SELF --upgrade              # from -updates, once released"
                        echo "       sudo $SELF --upgrade --proposed   # now, from -proposed (still in testing)" ;;
                esac
            elif [ "$OS_ID" = "debian" ] || [[ "$OS_LIKE" == *debian* ]]; then
                echo "  •  Get the fixed kernel, then reboot: sudo $SELF --upgrade"
            else
                echo "  •  Update the kernel with your package manager (dnf/yum update kernel), then reboot."
            fi
        fi
        if [ "$RULE_ON" = "yes" ]; then
            echo -e "  •  Stopgap ${GREEN}already applied${NC} — keep it until the verdict says PATCHED."
            [ "$STATE" = "VULNERABLE" ] && STATE="VULNERABLE-MITIGATED"
        elif [ "$RULE_ON" = "no" ]; then
            echo "  •  Until then, apply the stopgap (drops IPv4 TCP with IP options; no reboot, no downtime):"
            echo "       sudo $SELF --mitigate"
        fi ;;
    *)
        RC=2
        echo -e "${YELLOW}Could not tell whether this kernel has the fix — check your vendor's advisory for ${CVE}.${NC}" ;;
esac
[ "$INCONTAINER" = "yes" ] && echo -e "  ${YELLOW}(Inside a container — the verdict is about the host's kernel.)${NC}"
echo
echo "Authoritative status: https://ubuntu.com/security/${CVE}"
echo "RESULT|${HOST}|${STATE}|next=${NEXT} kernel=${KREL} pkg=${KPV:-none} pending=${PENDING% *} mitigation=${RULE_ON} mptcp=${MPTCP} listen=${LISTEN// /,}"
exit $RC
