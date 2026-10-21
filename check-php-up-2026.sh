#!/usr/bin/env bash
#
# "PHP-UP" checker: CVE-2026-109618 / CVE-2026-109619 (PHP session upload-progress RCE)
# Read-only: makes no changes to the system.
#
# Upstream fix is the PHP security release of 2026-10-21 14:00 UTC. Every branch
# release up to and including the 2026-09-24 releases below is treated as vulnerable.
# Once php.net publishes the fixed versions, confirm they are the next patch release
# on each branch (override with LAST_VULN_8_x=... env vars if not).
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

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
HOST=$(hostname -f 2>/dev/null || hostname)

echo -e "${BOLD}=== PHP-UP (${CVES}) checker — ${HOST} — $(date '+%Y-%m-%d %H:%M') ===${NC}\n"

# a <= b, version-wise
ver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

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
    echo "  → Upgrade PHP as soon as the 2026-10-21 release lands, e.g. (Ondrej PPA):"
    echo "      sudo apt update && sudo apt install --only-upgrade 'php*' && sudo systemctl restart 'php*-fpm'"
    echo "  → Stopgap until then: session.upload_progress.enabled = Off in the FPM php.ini, then restart FPM."
    echo "    This only blocks the upload-progress path; the multipart-parser path may remain."
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
    RC=0
fi
echo
echo "Authoritative status: https://www.php.net/archive/2026.php"
echo "RESULT|${HOST}|${STATUS}|serving=${SERVING:-none} ${DETAILS% }"
exit $RC
