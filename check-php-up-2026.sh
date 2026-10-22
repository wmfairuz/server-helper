#!/usr/bin/env bash
#
# "PHP-UP" checker: CVE-2026-109618 / CVE-2026-109619 (PHP session upload-progress RCE)
#
# Usage:
#   sudo ./check-php-up-2026.sh              # check only — makes no changes; reports where each
#                                            # PHP came from and whether apt already has the fix
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

OS_NAME=$(. /etc/os-release 2>/dev/null; echo "${NAME:-Linux}" | awk '{print $1}')
OS_CODENAME=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
# Ondrej stopped publishing for 20.04 in June 2025; this repo rebuilds his fixes
PFB_INSTALL="curl -fsSL https://raw.githubusercontent.com/wmfairuz/php-focal-backports/main/install.sh | sudo bash"

# Where a PHP build came from: path for panels/vendors, package version for apt
php_source() {
    local bin="$1" pkg="$2" pv="$3"
    case "$bin" in
        /opt/cpanel/*)     echo "cPanel"; return ;;
        /opt/plesk/*)      echo "Plesk"; return ;;
        /opt/remi/*)       echo "Remi"; return ;;
        /usr/local/lsws/*) echo "LiteSpeed"; return ;;
    esac
    [ -z "$pkg" ] && { echo "custom"; return; }
    case "$pv" in
        *+pfb[0-9]*)               echo "pfb-repo" ;; # wmfairuz/php-focal-backports rebuilds
        *+php7.[0-9]*~*)           echo "Niek/php7" ;;
        *deb.sury.org*|*+0~[0-9]*) echo "Ondrej" ;;   # PPA (Ubuntu) / packages.sury.org (Debian)
        *ubuntu*)                  echo "Ubuntu" ;;
        *)                         echo "$OS_NAME" ;;
    esac
}

# Hours since the last `apt update`. The list files carry the repo's own
# timestamps, so use apt's cache, which every update rebuilds.
apt_update_age() {
    local newest
    newest=$(stat -c %Y /var/cache/apt/pkgcache.bin /var/lib/apt/periodic/update-success-stamp \
                2>/dev/null | sort -n | tail -1)
    # No cache (e.g. Docker images): fall back to when list files were last rewritten
    [ -z "$newest" ] && newest=$(stat -c %Z /var/lib/apt/lists/*_InRelease 2>/dev/null | sort -n | tail -1)
    [ -n "$newest" ] && echo $(( ($(date +%s) - newest) / 3600 ))
}

# Does the apt candidate of php<MM>-common name the CVEs in its changelog?
# Builds that keep an old upstream version but carry the fix — confirmed from
# their changelogs on 2026-10-21. Anything >= these (same branch/source) is fixed.
known_fixed_build() {
    case "$1/$2" in
        8.1/Ubuntu) echo "8.1.2-1ubuntu2.28" ;;        # 22.04 jammy-security
        8.3/Ubuntu) echo "8.3.6-0ubuntu0.24.04.13" ;;  # 24.04 noble-security
        8.5/Ubuntu) echo "8.5.4-0ubuntu1.5" ;;         # 26.04 resolute-security
        8.1/Ondrej) echo "8.1.34-9" ;;                 # backport from 8.2.35
        8.0/Ondrej) echo "1:8.0.30-25" ;;              # backport from 8.2.35
        7.4/Ondrej) echo "1:7.4.33-31" ;;              # backport from 8.2.35
        7.3/Ondrej) echo "7.3.33-35" ;;                # backport from 8.2.35
        7.2/Ondrej) echo "7.2.34-66" ;;                # backport from 8.2.35
        7.1/Ondrej) echo "7.1.33-80" ;;                # backport from 8.2.35
        7.0/Ondrej) echo "7.0.33-92" ;;                # backport from 8.2.35
        5.6/Ondrej) echo "5.6.40-104" ;;               # backport from 8.2.35
    esac
}

# Sets FIXED to yes / no / unknown (no network, or a repo without changelogs
# such as a PPA). Not called in $(...) so the cache survives.
declare -A CL_CACHE=()
candidate_has_fix() {
    local mm="$1" out
    if [ -z "${CL_CACHE[$mm]:-}" ]; then
        # A failed fetch prints "Err: ... 404" on stdout, so trust the exit code;
        # changelogs.ubuntu.com often lags new security uploads by hours.
        if ! out=$(timeout 25 apt-get changelog "php${mm}-common" 2>/dev/null); then
            CL_CACHE[$mm]="unknown"
        elif echo "$out" | grep -qE 'CVE-2026-10961[89]'; then CL_CACHE[$mm]="yes"
        else CL_CACHE[$mm]="no"
        fi
    fi
    FIXED="${CL_CACHE[$mm]}"
}

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
    if [ -z "$upgradable" ] && [ "$OS_CODENAME" = "focal" ]; then
        echo -e "  ${YELLOW}No PHP updates available — and none will come from Ondrej's PPA on Ubuntu 20.04.${NC}"
        echo "  Get the patched packages (one command, asks before changing anything):"
        echo "    $PFB_INSTALL"
        echo
        return
    fi
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
declare -A TODO_UPGRADE=() TODO_MAYBE=() TODO_WAIT=() TODO_MANUAL=()
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

    if [ -n "$LAST" ] && ! ver_le "$VER" "$LAST"; then
        STATE="PATCHED (upstream fix)"; COLOR="$GREEN"
    elif [ "$BACKPORT" = "yes" ]; then
        STATE="PATCHED (distro backport)"; COLOR="$GREEN"
    elif [ -n "$LAST" ]; then
        STATE="VULNERABLE (<= $LAST)"; COLOR="$RED"; ANY_VULN="yes"
    elif ver_le "$MM" "8.1"; then
        STATE="VULNERABLE — EOL branch, no upstream fix"; COLOR="$RED"; ANY_VULN="yes"
    else
        STATE="UNKNOWN branch ($MM) — check manually"; COLOR="$YELLOW"; ANY_UNKNOWN="yes"
    fi

    PKG=$(dpkg -S "$bin" 2>/dev/null | grep -v '^diversion' | head -1 | cut -d: -f1)
    PKGVER=""
    [ -n "$PKG" ] && PKGVER=$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null)
    SRC=$(php_source "$bin" "$PKG" "$PKGVER")

    printf "  %-32s %-8s %-10s upload_progress=%-4s " "$bin" "$VER" "$SRC" "${UP:-?}"
    echo -e "${COLOR}${STATE}${NC}"
    DETAILS+="${VER}:${STATE%% *}:${SRC}:up=${UP:-?} "

    # Vulnerable: can it be fixed right now? (reads apt's local lists — no network)
    case "$STATE" in VULNERABLE*) ;; *) continue ;; esac
    LABEL="php${MM} (${SRC})"
    CAND=""
    [ -n "$PKG" ] && CAND=$(apt-cache policy "$PKG" 2>/dev/null | awk '/Candidate:/{print $2}')
    if [ -z "$PKG" ] || [ -z "$CAND" ]; then
        case "$SRC" in
            cPanel) HOW="update ea-php${MM//./} via WHM → EasyApache 4" ;;
            Plesk)  HOW="update via Plesk → Tools & Settings → Updates" ;;
            Remi)   HOW="sudo dnf upgrade 'php*'" ;;
            *)      HOW="not from a package — rebuild / pull a newer image" ;;
        esac
        echo -e "      ${YELLOW}↳ not apt-managed: ${HOW}${NC}"
        TODO_MANUAL[$LABEL]="$HOW"
    elif [ "$CAND" != "(none)" ] && dpkg --compare-versions "$CAND" gt "$PKGVER"; then
        CUP=$(echo "$CAND" | sed 's/^[0-9]*://' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
        if [ -n "$LAST" ] && ! ver_le "$CUP" "$LAST"; then
            FIXED="yes"                         # newer upstream release, e.g. 8.3.36
        else
            KNOWN=$(known_fixed_build "$MM" "$SRC")   # same/old upstream: only a backport helps
            if [ -n "$KNOWN" ]; then
                dpkg --compare-versions "$CAND" ge "$KNOWN" && FIXED="yes" || FIXED="no"
            else
                candidate_has_fix "$MM"
            fi
        fi
        case "$FIXED" in
            yes)
                echo -e "      ${GREEN}↳ fix available in apt: ${CAND}${NC}"
                TODO_UPGRADE[$LABEL]="$CAND" ;;
            no)
                echo -e "      ${YELLOW}↳ update ${CAND} is in apt but does NOT contain the fix yet${NC}"
                TODO_WAIT[$LABEL]=1 ;;
            *)
                echo -e "      ${YELLOW}↳ update available in apt: ${CAND} — can't confirm it has the fix; upgrade, then re-check${NC}"
                TODO_MAYBE[$LABEL]="$CAND" ;;
        esac
    else
        echo -e "      ${YELLOW}↳ no fix in apt yet${NC}"
        TODO_WAIT[$LABEL]=1
    fi
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
SELF=$(readlink -f "$0")
NEXT="none"
if [ "$ANY_VULN" = "yes" ]; then
    if [ -n "$SERVING" ]; then
        STATUS="VULNERABLE"
        echo -e "${RED}A vulnerable PHP build is installed and PHP is served over HTTP (${SERVING% }).${NC}"
    else
        STATUS="VULNERABLE-CLI-ONLY"
        echo -e "${YELLOW}Vulnerable PHP build present, but nothing serves PHP over HTTP. Practical risk: LOW.${NC}"
    fi
    echo
    if [ ${#TODO_UPGRADE[@]} -gt 0 ]; then
        NEXT="upgrade-now"
        echo -e "  ${GREEN}•  Fix is in apt now${NC} for: ${!TODO_UPGRADE[*]}"
        echo "       sudo $SELF --upgrade"
    fi
    if [ ${#TODO_MAYBE[@]} -gt 0 ]; then
        [ "$NEXT" = "none" ] && NEXT="upgrade-maybe"
        echo -e "  ${YELLOW}•  Update in apt that may contain the fix${NC} for: ${!TODO_MAYBE[*]}"
        echo "       sudo $SELF --upgrade   # the check afterwards says for sure"
    fi
    if [ ${#TODO_WAIT[@]} -gt 0 ]; then
        [ "$NEXT" = "none" ] && NEXT="wait"
        echo -e "  ${YELLOW}•  No fix in apt yet${NC} for: ${!TODO_WAIT[*]}"
        AGE=$(apt_update_age)
        if [ "$OS_CODENAME" = "focal" ]; then
            echo "       Ubuntu 20.04: Ondrej's PPA no longer publishes here, so waiting won't help."
            echo "       Get the patched packages (one command, asks before changing anything):"
            echo "         $PFB_INSTALL"
        elif [ -z "$AGE" ] || [ "$AGE" -ge 1 ]; then
            echo "       apt was last updated ${AGE:-?}h ago — refresh first, then re-run this check:"
            echo "         sudo apt update"
        else
            echo "       apt was updated <1h ago. Wait for the package to be published, then:"
            echo "         sudo apt update   # and re-run this check"
        fi
    fi
    if [ ${#TODO_MANUAL[@]} -gt 0 ]; then
        [ "$NEXT" = "none" ] && NEXT="manual"
        echo -e "  ${YELLOW}•  Not apt-managed${NC} — update these yourself:"
        for k in "${!TODO_MANUAL[@]}"; do echo "       $k: ${TODO_MANUAL[$k]}"; done
    fi
    if [ -n "$SERVING" ]; then
        if [ -n "$OVR" ] && echo "$OVR" | grep -q "$DROPIN"; then
            echo -e "  •  Stopgap ${GREEN}already applied${NC} (${DROPIN}) — keep it until the verdict says PATCHED."
        else
            echo "  •  Until upgraded, apply the stopgap (partial protection, CVE-2026-109619 only):"
            echo "       sudo $SELF --mitigate"
        fi
    fi
    RC=1
elif [ "$ANY_UNKNOWN" = "yes" ]; then
    STATUS="UNKNOWN"
    echo -e "${YELLOW}Could not classify every PHP build — review the list above.${NC}"
    RC=2
else
    STATUS="PATCHED"
    echo -e "${GREEN}All PHP builds are past the last vulnerable release (or carry a backport).${NC}"
    if [ -n "$OVR" ] && echo "$OVR" | grep -q "$DROPIN"; then
        echo "  → Stopgap no longer needed: sudo $SELF --unmitigate"
    fi
    RC=0
fi
echo
echo "Authoritative status: https://www.php.net/archive/2026.php"
echo "RESULT|${HOST}|${STATUS}|next=${NEXT} serving=${SERVING:-none} ${DETAILS% }"
exit $RC
