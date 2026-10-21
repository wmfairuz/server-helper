#!/usr/bin/env bash
#
# "PHP-UP" checker: CVE-2026-109618 / CVE-2026-109619 (PHP session upload-progress RCE)
#
# Usage:
#   sudo ./check-php-up-2026.sh              # check only — makes no changes
#   sudo ./check-php-up-2026.sh --mitigate   # stopgap: session.upload_progress.enabled=Off, reload PHP
#   sudo ./check-php-up-2026.sh --unmitigate # remove the stopgap again
#   sudo ./check-php-up-2026.sh --upgrade    # apt-upgrade installed PHP packages, restart PHP
#   Add -y to skip the confirmation prompt.
# Every mode re-runs the check afterwards.
#
# Fixed upstream on 2026-10-21 in PHP 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12, so every
# release up to the ones below is vulnerable. PHP <= 8.1 has no upstream fix; only
# distro/vendor backports (detected via the package changelog) count as patched.
#
# Last line of output is machine-readable, for collecting results across servers:
#   RESULT|<host>|<status>|<details>
# Exit codes: 0 = not vulnerable, 1 = vulnerable, 2 = could not determine
#
set -u

CVES="CVE-2026-109618 CVE-2026-109619"
LAST_VULN_8_2="${LAST_VULN_8_2:-8.2.34}"
LAST_VULN_8_3="${LAST_VULN_8_3:-8.3.35}"
LAST_VULN_8_4="${LAST_VULN_8_4:-8.4.26}"
LAST_VULN_8_5="${LAST_VULN_8_5:-8.5.11}"

DROPIN="99-php-up-mitigation.ini"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
HOST=$(hostname -f 2>/dev/null || hostname)

ACTION="check"; ASSUME_YES="no"
for arg in "$@"; do
    case "$arg" in
        --mitigate)   ACTION="mitigate" ;;
        --unmitigate) ACTION="unmitigate" ;;
        --upgrade)    ACTION="upgrade" ;;
        -y|--yes)     ASSUME_YES="yes" ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *)            echo "Unknown option: $arg (see --help)"; exit 2 ;;
    esac
done

if [ "$ACTION" != "check" ] && [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}--${ACTION} changes the system — run it with sudo.${NC}"
    exit 2
fi

echo -e "${BOLD}=== PHP-UP (${CVES}) checker — ${HOST} — $(date '+%Y-%m-%d %H:%M') ===${NC}\n"

# a <= b, version-wise
ver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

confirm() {
    [ "$ASSUME_YES" = "yes" ] && return 0
    read -r -p "$1 [y/N] " ans < /dev/tty
    [[ "$ans" =~ ^[Yy]$ ]]
}

# Reload (ini change) or restart (new binary) everything that serves PHP
bounce_php() {
    local how="$1" units u
    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "  ${YELLOW}systemctl not found — ${how} PHP-FPM / the web server yourself.${NC}"
        return
    fi
    units=$(systemctl list-units --type=service --state=running --plain --no-legend \
                'php*-fpm*' 'lsws*' 2>/dev/null | awk '{print $1}')
    ls /etc/apache2/mods-enabled/php*.load >/dev/null 2>&1 && units+=$'\napache2.service'
    ls /etc/httpd/conf.modules.d/*php*.conf >/dev/null 2>&1 && units+=$'\nhttpd.service'
    for u in $units; do
        if systemctl "$how" "$u" 2>/dev/null; then
            echo -e "  ${GREEN}${how}ed ${u}${NC}"
        else
            echo -e "  ${RED}failed to ${how} ${u} — check: systemctl status ${u}${NC}"
        fi
    done
    if [ -z "$units" ]; then
        echo "  No running PHP-FPM / LiteSpeed / Apache-mod_php systemd service to ${how}."
        for p in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$p"; echo; done 2>/dev/null \
            | grep -q -e 'php-fpm: master' -e lsphp \
            && echo -e "  ${RED}But PHP is running outside systemd — ${how} it yourself or the change won't apply.${NC}"
    fi
}

# ini scan dirs of every web-facing SAPI (skips CLI-only dirs)
ini_scan_dirs() {
    local bin dir
    for bin in "${BINS[@]}"; do
        dir=$("$bin" -i 2>/dev/null | grep -m1 'Scan this dir for additional .ini files' | awk '{print $NF}')
        [ -d "$dir" ] || continue
        [[ "$dir" == */cli/* || "$dir" == */cli ]] && continue
        echo "$dir"
    done | sort -u
}

do_mitigate() {
    echo -e "${BOLD}--- Applying stopgap: session.upload_progress.enabled = Off ---${NC}"
    local dirs d bin
    dirs=$(ini_scan_dirs)
    if [ -z "$dirs" ]; then
        echo -e "  ${RED}No web SAPI ini scan dir found — set it in php.ini by hand.${NC}"
        return
    fi
    echo "  Will write ${DROPIN} into:"; echo "$dirs" | sed 's/^/    /'
    confirm "  Proceed?" || { echo "  Skipped."; echo; return; }
    for d in $dirs; do
        # Per the php.net advisory (CVE-2026-109619). fatal_error_backtraces only exists
        # on PHP 8.5+; older versions silently ignore it.
        printf '%s\n' \
            "; PHP-UP stopgap (${CVES}) — remove once PHP is patched:" \
            ";   sudo $(readlink -f "$0") --unmitigate" \
            "session.upload_progress.enabled = Off" \
            "fatal_error_backtraces = Off" > "$d/$DROPIN"
        echo -e "  ${GREEN}wrote $d/$DROPIN${NC}"
    done
    for bin in "${BINS[@]}"; do
        case "$bin" in *php-fpm*)
            "$bin" -t >/dev/null 2>&1 || { echo -e "  ${RED}$bin -t failed — not reloading.${NC}"; return; } ;;
        esac
    done
    # Advisory says restart every worker — a reload is not enough
    bounce_php restart
    echo -e "  ${YELLOW}Note: this only reduces exposure to CVE-2026-109619. CVE-2026-109618 stays open"
    echo -e "  until PHP is upgraded (php.net's other stopgaps — memory_limit=-1, low post_max_size —"
    echo -e "  can break apps, so they are not applied here).${NC}\n"
}

do_unmitigate() {
    echo -e "${BOLD}--- Removing stopgap ---${NC}"
    local files
    files=$(ls /etc/php/*/*/conf.d/$DROPIN /usr/local/etc/php/conf.d/$DROPIN \
               /usr/local/lsws/lsphp*/etc/php/*/mods-available/$DROPIN \
               /opt/cpanel/ea-php*/root/etc/php.d/$DROPIN /opt/plesk/php/*/etc/php.d/$DROPIN \
               /etc/opt/remi/php*/php.d/$DROPIN 2>/dev/null)
    [ -z "$files" ] && { echo -e "  No ${DROPIN} found — nothing to remove.\n"; return; }
    echo "$files" | sed 's/^/    /'
    confirm "  Remove these?" || { echo "  Skipped."; echo; return; }
    rm -f $files
    bounce_php restart
    echo
}

do_upgrade() {
    echo -e "${BOLD}--- Upgrading PHP packages ---${NC}"
    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "  ${RED}apt-get not found — --upgrade supports Debian/Ubuntu only. Upgrade via your panel/vendor.${NC}\n"
        return
    fi
    echo "  apt-get update ..."
    apt-get update -qq >/dev/null 2>&1 || echo -e "  ${YELLOW}apt-get update reported errors — continuing.${NC}"
    local installed upgradable
    installed=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'php*' 'lsphp*' 2>/dev/null | awk '$1=="ii"{print $2}')
    upgradable=$(apt list --upgradable 2>/dev/null | cut -d/ -f1 | grep -xF -f <(echo "$installed"))
    if [ -z "$upgradable" ]; then
        echo -e "  ${YELLOW}No PHP updates available from your apt sources yet.${NC}"
        echo "  Upstream fixed 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 on 2026-10-21; distro and Ondrej"
        echo "  builds can lag by hours. Re-run --upgrade later."
        echo "  Until then consider: sudo $(readlink -f "$0") --mitigate"
        echo
        return
    fi
    echo "  Upgradable PHP packages:"
    apt list --upgradable 2>/dev/null | grep -F -f <(echo "$upgradable" | sed 's|$|/|') | sed 's/^/    /'
    confirm "  Upgrade these and restart PHP?" || { echo "  Skipped."; echo; return; }
    # keep existing config files (php.ini, pool.d) untouched
    DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
        -o Dpkg::Options::=--force-confold $upgradable \
        || { echo -e "  ${RED}apt-get install failed — see output above.${NC}"; return; }
    bounce_php restart
    echo
}

# ── 1. Find every PHP binary (CLI, FPM, LiteSpeed, cPanel/Plesk/Remi) ──
CANDIDATES=$(
    command -v php 2>/dev/null
    ls /usr/bin/php[0-9]* /usr/sbin/php-fpm* /usr/bin/php-cgi* \
       /usr/local/bin/php /usr/local/sbin/php-fpm \
       /usr/local/lsws/lsphp*/bin/lsphp /usr/local/lsws/lsphp*/bin/php \
       /opt/cpanel/ea-php*/root/usr/bin/php /opt/cpanel/ea-php*/root/usr/sbin/php-fpm \
       /opt/plesk/php/*/bin/php /opt/plesk/php/*/sbin/php-fpm \
       /opt/remi/php*/root/usr/bin/php /opt/remi/php*/root/usr/sbin/php-fpm 2>/dev/null
)

declare -A SEEN=()
BINS=()
for b in $CANDIDATES; do
    [ -x "$b" ] || continue
    real=$(readlink -f "$b" 2>/dev/null || echo "$b")
    [ -n "${SEEN[$real]:-}" ] && continue
    SEEN[$real]=1
    BINS+=("$real")
done

if [ ${#BINS[@]} -eq 0 ]; then
    echo -e "${GREEN}No PHP binaries found — not affected.${NC}"
    echo "RESULT|${HOST}|NO-PHP|-"
    exit 0
fi

case "$ACTION" in
    mitigate)   do_mitigate ;;
    unmitigate) do_unmitigate ;;
    upgrade)    do_upgrade ;;
esac

# ── 2. What is actually serving PHP over HTTP? ─────────────────────────
echo -e "${BOLD}--- Web-facing PHP processes ---${NC}"
SERVING=""
# Read /proc directly — minimal images/containers may lack pgrep
PROCS=$(for p in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$p"; echo; done 2>/dev/null)
FPM_PROCS=$(echo "$PROCS" | grep 'php-fpm: master')
LS_PROCS=$(echo "$PROCS" | grep -m3 'lsphp')
MODPHP=$(ls /etc/apache2/mods-enabled/php*.load /etc/httpd/conf.modules.d/*php*.conf 2>/dev/null)
[ -n "$FPM_PROCS" ] && SERVING+="fpm " && echo "$FPM_PROCS" | sed 's/^/    /'
[ -n "$LS_PROCS" ]  && SERVING+="lsphp " && echo "$LS_PROCS" | sed 's/^/    /'
[ -n "$MODPHP" ]    && SERVING+="mod_php " && echo "$MODPHP" | sed 's/^/    mod_php: /'
[ -z "$SERVING" ] && echo -e "  ${YELLOW}No running php-fpm / lsphp / mod_php found (CLI-only box?)${NC}"
echo

# ── 3. Per-binary version + patch state ────────────────────────────────
echo -e "${BOLD}--- PHP builds ---${NC}"
ANY_VULN="no"; ANY_UNKNOWN="no"; DETAILS=""
for bin in "${BINS[@]}"; do
    VER=$("$bin" -v 2>/dev/null | head -1 | grep -oE 'PHP [0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}')
    if [ -z "$VER" ]; then
        echo -e "  ${YELLOW}$bin — could not read version${NC}"
        continue
    fi
    MM=$(echo "$VER" | cut -d. -f1,2)
    UP=$("$bin" -i 2>/dev/null | grep -m1 '^session.upload_progress.enabled' | awk '{print $NF}')

    # Distro backport? (Ubuntu/Debian/Ondrej changelog mentions the CVE)
    BACKPORT="no"
    CL="/usr/share/doc/php${MM}-common/changelog.Debian.gz"
    if [ -f "$CL" ] && zgrep -qE 'CVE-2026-10961[89]' "$CL" 2>/dev/null; then
        BACKPORT="yes"
    fi

    case "$MM" in
        8.2) LAST="$LAST_VULN_8_2" ;;
        8.3) LAST="$LAST_VULN_8_3" ;;
        8.4) LAST="$LAST_VULN_8_4" ;;
        8.5) LAST="$LAST_VULN_8_5" ;;
        *)   LAST="" ;;
    esac

    if [ "$BACKPORT" = "yes" ]; then
        STATE="PATCHED (distro backport)"; COLOR="$GREEN"
    elif [ -n "$LAST" ]; then
        if ver_le "$VER" "$LAST"; then
            STATE="VULNERABLE (<= $LAST)"; COLOR="$RED"; ANY_VULN="yes"
        else
            STATE="patched (> $LAST)"; COLOR="$GREEN"
        fi
    elif ver_le "$MM" "8.1"; then
        STATE="VULNERABLE — EOL branch, no upstream fix"; COLOR="$RED"; ANY_VULN="yes"
    else
        STATE="UNKNOWN branch ($MM) — check manually"; COLOR="$YELLOW"; ANY_UNKNOWN="yes"
    fi

    printf "  %-45s %-8s upload_progress=%-4s " "$bin" "$VER" "${UP:-?}"
    echo -e "${COLOR}${STATE}${NC}"
    DETAILS+="${VER}:${STATE%% *}:up=${UP:-?} "
done
echo

# ── 4. upload_progress overrides (pool / .user.ini / .htaccess) ────────
echo -e "${BOLD}--- session.upload_progress overrides ---${NC}"
OVR=$(grep -rsnE 'session\.upload_progress\.enabled' \
        /etc/php /etc/php-fpm.d /etc/opt/remi /opt/cpanel/ea-php*/root/etc \
        /usr/local/lsws/lsphp*/etc 2>/dev/null | grep -vE ':\s*;')
WEBOVR=$(find /var/www /home /srv -maxdepth 5 \( -name .user.ini -o -name .htaccess \) \
        -exec grep -lsE 'session\.upload_progress\.enabled' {} + 2>/dev/null | head -20)
[ -n "$OVR" ]    && echo "$OVR" | sed 's/^/    /'
[ -n "$WEBOVR" ] && echo "$WEBOVR" | sed 's/^/    web override: /'
[ -z "$OVR$WEBOVR" ] && echo "  None — every build uses its php.ini default (shown above)."
echo

# ── 5. Verdict ────────────────────────────────────────────────────────
echo -e "${BOLD}=== VERDICT ===${NC}"
if [ "$ANY_VULN" = "yes" ] && [ -n "$SERVING" ]; then
    STATUS="VULNERABLE"
    echo -e "${RED}A vulnerable PHP build is installed and PHP is served over HTTP (${SERVING% }).${NC}"
    echo "  → Upgrade to 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 (or a distro backport) as soon as your apt sources have it:"
    echo "      sudo $(readlink -f "$0") --upgrade"
    if [ -n "$OVR" ] && echo "$OVR" | grep -q "$DROPIN"; then
        echo -e "  → Stopgap ${GREEN}already applied${NC} (${DROPIN}); it only blocks the upload-progress path."
    else
        echo "  → Stopgap until then (only blocks the upload-progress path; multipart path may remain):"
        echo "      sudo $(readlink -f "$0") --mitigate"
    fi
    RC=1
elif [ "$ANY_VULN" = "yes" ]; then
    STATUS="VULNERABLE-CLI-ONLY"
    echo -e "${YELLOW}Vulnerable PHP build present, but nothing serves PHP over HTTP. Practical risk: LOW.${NC}"
    echo "  → Upgrade anyway; re-check if a web server is added later."
    RC=1
elif [ "$ANY_UNKNOWN" = "yes" ]; then
    STATUS="UNKNOWN"
    echo -e "${YELLOW}Could not classify every PHP build — review the list above.${NC}"
    RC=2
else
    STATUS="PATCHED"
    echo -e "${GREEN}All PHP builds are past the last vulnerable release (or carry a backport).${NC}"
    if [ -n "$OVR" ] && echo "$OVR" | grep -q "$DROPIN"; then
        echo "  → Stopgap no longer needed: sudo $(readlink -f "$0") --unmitigate"
    fi
    RC=0
fi
echo
echo "Authoritative status: https://www.php.net/archive/2026.php"
echo "RESULT|${HOST}|${STATUS}|serving=${SERVING:-none} ${DETAILS% }"
exit $RC
