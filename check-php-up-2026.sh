#!/usr/bin/env bash
#
# PHP security checker for the 2026 critical rounds:
#   October  "PHP-UP": CVE-2026-109618 / CVE-2026-109619 (session upload-progress RCE)
#   November: CVE-2026-129289 (FPM request smuggling via FastCGI connection reuse),
#             CVE-2026-129474 (PHP 8.5 without php.ini), CVE-2026-115560 (session
#             serializer mismatch) and 15 more
#
# Usage:
#   sudo ./check-php-up-2026.sh              # check only — makes no changes; reports where each
#                                            # PHP came from and whether apt already has the fix
#   sudo ./check-php-up-2026.sh --mitigate   # stopgap ini settings for every web SAPI, restart PHP
#   sudo ./check-php-up-2026.sh --unmitigate # remove the stopgap again
#   sudo ./check-php-up-2026.sh --upgrade    # apt-upgrade installed PHP packages, restart PHP
#   Add -y to skip the confirmation prompt.
# Every mode re-runs the check afterwards.
#
# Fixed upstream on 2026-11-19 in PHP 8.2.36 / 8.3.37 / 8.4.28 / 8.5.13 (October's
# fixes came a month earlier in the previous releases), so every release up to the
# ones below is vulnerable. PHP <= 8.1 has no upstream fix; only distro/vendor
# backports (detected via the package changelog) count as patched.
#
# Last line of output is machine-readable, for collecting results across servers:
#   RESULT|<host>|<status>|<details>
# Exit codes: 0 = not vulnerable, 1 = vulnerable, 2 = could not determine
#
set -u

CVES="Oct + Nov 2026"
# Last releases without November's fixes; October's are one release earlier
LAST_VULN_8_2="${LAST_VULN_8_2:-8.2.35}"
LAST_VULN_8_3="${LAST_VULN_8_3:-8.3.36}"
LAST_VULN_8_4="${LAST_VULN_8_4:-8.4.27}"
LAST_VULN_8_5="${LAST_VULN_8_5:-8.5.12}"
# A backport's changelog names these: every November build (Sury, Ubuntu, our
# rebuilds) lists CVE-2026-129289; October-only builds list just 10961[89]
NOV_CVE_RE='CVE-2026-129289'
OCT_CVE_RE='CVE-2026-10961[89]'

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

echo -e "${BOLD}=== PHP security (${CVES}) checker — ${HOST} — $(date '+%Y-%m-%d %H:%M') ===${NC}\n"

# a <= b, version-wise
ver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

OS_NAME=$(. /etc/os-release 2>/dev/null; echo "${NAME:-Linux}" | awk '{print $1}')
OS_CODENAME=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
# Ondrej no longer publishes for 20.04 (since June 2025) or 18.04; these repos rebuild his fixes
case "$OS_CODENAME" in
    focal)  BP_REPO="php-focal-backports";  BP_RELEASE="Ubuntu 20.04"; BP_PHP="7.2–8.2"; BP_MM='^(7\.[2-4]|8\.[0-2])$' ;;
    bionic) BP_REPO="php-bionic-backports"; BP_RELEASE="Ubuntu 18.04"; BP_PHP="8.1";     BP_MM='^8\.1$' ;;
    *)      BP_REPO="" ;;
esac
BP_INSTALL=${BP_REPO:+"curl -fsSL https://raw.githubusercontent.com/wmfairuz/$BP_REPO/main/install.sh | sudo bash"}

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
        *+pbb[0-9]*)               echo "pbb-repo" ;; # wmfairuz/php-bionic-backports rebuilds
        *+php7.[0-9]*~*)           echo "Niek/php7" ;;
        *deb.sury.org*|*+0~[0-9]*|*debsuryorg*) echo "Ondrej" ;;   # PPA (Ubuntu) / packages.sury.org (Debian)
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
# Builds that keep an old upstream version but carry November's fixes —
# confirmed from their changelogs on 2026-11-21. Anything >= these (same
# branch/source) is fixed.
known_fixed_build() {
    local src="$2"
    case "$src" in pfb-repo|pbb-repo) src="Ondrej" ;; esac   # rebuilds of Ondrej's sources
    case "$1/$src" in
        8.1/Ubuntu) echo "8.1.2-1ubuntu2.29" ;;        # 22.04 jammy-security
        8.3/Ubuntu) echo "8.3.6-0ubuntu0.24.04.14" ;;  # 24.04 noble-security
        8.5/Ubuntu) echo "8.5.4-0ubuntu1.6" ;;         # 26.04 resolute-security
        8.1/Ondrej) echo "8.1.34-13" ;;                # backport from 8.2.36
        8.0/Ondrej) echo "1:8.0.30-30" ;;              # backport from 8.2.36
        7.4/Ondrej) echo "1:7.4.33-36" ;;              # backport from 8.2.36
        7.3/Ondrej) echo "7.3.33-40" ;;                # backport from 8.2.36
        7.2/Ondrej) echo "7.2.34-69" ;;                # backport from 8.2.36
        7.1/Ondrej) echo "7.1.33-84" ;;                # backport from 8.2.36
        7.0/Ondrej) echo "7.0.33-96" ;;                # backport from 8.2.36
        5.6/Ondrej) echo "5.6.40-108" ;;               # backport from 8.2.36
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
        elif echo "$out" | grep -qE "$NOV_CVE_RE"; then CL_CACHE[$mm]="yes"
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
    echo -e "${BOLD}--- Applying stopgap: upload progress off, exception args hidden ---${NC}"
    local dirs d bin
    dirs=$(ini_scan_dirs)
    if [ -z "$dirs" ]; then
        echo -e "  ${RED}No web SAPI ini scan dir found — set it in php.ini by hand.${NC}"
        return
    fi
    echo "  Will write ${DROPIN} into:"; echo "$dirs" | sed 's/^/    /'
    confirm "  Proceed?" || { echo "  Skipped."; echo; return; }
    for d in $dirs; do
        # Per the php.net advisories (CVE-2026-109619 in October, the November round).
        # fatal_error_backtraces only exists on PHP 8.5+; older versions silently ignore it.
        printf '%s\n' \
            "; PHP security stopgap (${CVES}) — remove once PHP is patched:" \
            ";   sudo $(readlink -f "$0") --unmitigate" \
            "session.upload_progress.enabled = Off" \
            "zend.exception_ignore_args = On" \
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
    echo -e "  ${YELLOW}Note: this only reduces exposure (CVE-2026-109619, CVE-2026-115560 and others);"
    echo -e "  the rest stay open until PHP is upgraded. Web-server and FPM-pool stopgaps (FastCGI"
    echo -e "  connection reuse, catch_workers_output) are listed under 'November risk factors' —"
    echo -e "  change those by hand. Upload progress bars stop updating while this is on.${NC}\n"
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
    # Ondrej renamed his PPA's Label; apt refuses to refresh it (leaving a stale
    # index whose files 404) until that change is accepted. Accept Label only.
    local upd_err
    upd_err=$(apt-get update -qq -o Acquire::AllowReleaseInfoChange::Label=true 2>&1 >/dev/null) \
        || echo -e "  ${YELLOW}apt-get update reported errors — continuing:${NC}"
    [ -n "$upd_err" ] && echo "$upd_err" | grep -E '^(E|W):' | sed -n '1,5s/^/    /p'
    local installed upgradable
    installed=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'php*' 'lsphp*' 2>/dev/null | awk '$1=="ii"{print $2}')
    upgradable=$(apt list --upgradable 2>/dev/null | cut -d/ -f1 | grep -xF -f <(echo "$installed"))
    if [ -z "$upgradable" ] && [ -n "$BP_INSTALL" ]; then
        echo -e "  ${YELLOW}No PHP updates available — and none will come from Ondrej's PPA on $BP_RELEASE.${NC}"
        echo "  Get the patched PHP $BP_PHP packages (one command, asks before changing anything):"
        echo "    $BP_INSTALL"
        echo
        return
    fi
    if [ -z "$upgradable" ]; then
        echo -e "  ${YELLOW}No PHP updates available from your apt sources yet.${NC}"
        echo "  Upstream fixed 8.2.36 / 8.3.37 / 8.4.28 / 8.5.13 on 2026-11-19; distro and Ondrej"
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
       /opt/cpanel/ea-php*/root/usr/bin/php /opt/cpanel/ea-php*/root/usr/bin/php-cgi \
       /opt/cpanel/ea-php*/root/usr/sbin/php-fpm \
       /opt/plesk/php/*/bin/php /opt/plesk/php/*/sbin/php-fpm \
       /opt/remi/php*/root/usr/bin/php /opt/remi/php*/root/usr/sbin/php-fpm 2>/dev/null
)

declare -A SEEN=()
BINS=()
for b in $CANDIDATES; do
    [ -x "$b" ] || continue
    real=$(readlink -f "$b" 2>/dev/null || echo "$b")
    # cPanel's /usr/local/bin/php only dispatches to an ea-php build listed anyway
    [ -d /opt/cpanel ] && [[ "$real" == /usr/local/bin/* ]] && continue
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
# cPanel CGI/suPHP handlers start PHP per request, so there is no PHP process
# to find — a running Apache is what serves it
if [ -d /opt/cpanel ] && echo "$PROCS" | grep -qE '(^|/)(httpd|apache2)( |$)'; then
    SERVING+="cpanel-httpd "
    echo "    httpd (cPanel: CGI/suPHP handlers run PHP per request)"
fi
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

    # Backport? The package changelog names the CVEs: Debian/Ubuntu (Ubuntu,
    # Ondrej, pfb-repo, pbb-repo) or RPM (cPanel ea-php, CentOS/RHEL, Remi, CloudLinux).
    # BACKPORT = nov (has November's fixes), oct (October's only) or no
    BACKPORT="no"; CLTXT=""
    CL="/usr/share/doc/php${MM}-common/changelog.Debian.gz"
    if [ -f "$CL" ]; then
        CLTXT=$(zcat "$CL" 2>/dev/null)
    elif command -v rpm >/dev/null 2>&1 && owner=$(rpm -qf "$bin" 2>/dev/null); then
        CLTXT=$(rpm -q --changelog "$owner" 2>/dev/null)
    fi
    if grep -qE "$NOV_CVE_RE" <<<"$CLTXT"; then BACKPORT="nov"
    elif grep -qE "$OCT_CVE_RE" <<<"$CLTXT"; then BACKPORT="oct"
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
    elif [ "$BACKPORT" = "nov" ]; then
        STATE="PATCHED (distro backport)"; COLOR="$GREEN"
    elif [ "$BACKPORT" = "oct" ] || { [ -n "$LAST" ] && [ "$VER" = "$LAST" ]; }; then
        # e.g. 8.2.35, or Ondrej's 8.1.34-9: has October's fix, not November's
        STATE="VULNERABLE — October fix only, November's missing"; COLOR="$RED"; ANY_VULN="yes"
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
            FIXED="yes"                         # newer upstream release, e.g. 8.3.37
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

# ── 5. November risk factors: setups that make the new bugs easy to hit ─
echo -e "${BOLD}--- November risk factors ---${NC}"
RISKS=""
# CVE-2026-129289: one request can run code when the web server reuses FastCGI
# connections. Both settings are off by default.
KEEPCONN=$(grep -rsnE '^[^#]*fastcgi_keep_conn[[:space:]]+on' \
        /etc/nginx /usr/local/nginx/conf /usr/local/openresty/nginx/conf 2>/dev/null)
REUSE=$(grep -rsniE '^[^#]*enablereuse=on' /etc/apache2 /etc/httpd /usr/local/apache/conf 2>/dev/null)
if [ -n "$KEEPCONN$REUSE" ]; then
    RISKS+="fcgi-reuse "
    echo -e "  ${RED}FastCGI connection reuse is ON (CVE-2026-129289: single-request RCE):${NC}"
    echo "$KEEPCONN$REUSE" | sed '/^$/d; s/^/    /'
    echo "    → set 'fastcgi_keep_conn off;' (nginx) / remove 'enablereuse=on' (Apache), reload the web server"
fi
# CVE-2026-129474: PHP 8.5 with no php.ini at all (official Docker images ship without one)
NOINI=""
for bin in "${BINS[@]}"; do
    "$bin" -v 2>/dev/null | head -1 | grep -qE '^PHP 8\.5\.' || continue
    "$bin" -i 2>/dev/null | grep -m1 'Loaded Configuration File' | grep -q '(none)' && NOINI+="$bin "
done
if [ -n "$NOINI" ]; then
    RISKS+="no-php-ini "
    echo -e "  ${RED}PHP 8.5 running without a php.ini (CVE-2026-129474):${NC} ${NOINI% }"
    echo "    → install php.ini-production as php.ini (Docker: cp \"\$PHP_INI_DIR/php.ini-production\" \"\$PHP_INI_DIR/php.ini\")"
fi
# php.net's stopgap: catch_workers_output=no (the official php-fpm images turn it on)
CATCHOUT=$(grep -rsnE '^[[:space:]]*catch_workers_output[[:space:]]*=[[:space:]]*(yes|on|true|1)' \
        /etc/php/*/fpm /etc/php-fpm.conf /etc/php-fpm.d /usr/local/etc/php-fpm.conf /usr/local/etc/php-fpm.d \
        /opt/cpanel/ea-php*/root/etc/php-fpm.d /etc/opt/remi/php*/php-fpm.d 2>/dev/null)
if [ -n "$CATCHOUT" ]; then
    RISKS+="catch-workers-output "
    echo -e "  ${YELLOW}catch_workers_output is on in these FPM pools:${NC}"
    echo "$CATCHOUT" | sed 's/^/    /'
    echo "    → until patched, set 'catch_workers_output = no' and restart PHP-FPM"
fi
# CVE-2026-115560: apps sharing one session store with different serializers
SERIAL=$(grep -rsnE 'session\.serialize_handler' \
        /etc/php /etc/php-fpm.d /etc/opt/remi /opt/cpanel/ea-php*/root/etc /usr/local/etc 2>/dev/null \
        | grep -vE ':\s*;' | grep -viE '=\s*php\s*$')
if [ -n "$SERIAL" ]; then
    RISKS+="mixed-serializers "
    echo -e "  ${YELLOW}session.serialize_handler is changed here (CVE-2026-115560 if apps share a session store):${NC}"
    echo "$SERIAL" | sed 's/^/    /'
    echo "    → give each app its own session.save_path, or one serializer everywhere"
fi
[ -z "$RISKS" ] && echo "  None found: no FastCGI reuse, no 8.5 without php.ini, no catch_workers_output, no serializer changes."
echo

# ── 6. Verdict ────────────────────────────────────────────────────────
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
        if [ -n "$BP_INSTALL" ]; then
            # Only point at the backports repo for the PHP versions it actually builds
            BP_YES=""; BP_NO=""
            for k in "${!TODO_WAIT[@]}"; do
                mm=${k#php}; mm=${mm%% *}
                if [[ "$mm" =~ $BP_MM ]]; then BP_YES+="$k "; else BP_NO+="$k "; fi
            done
            echo "       $BP_RELEASE: Ondrej's PPA no longer publishes here, so waiting won't help."
            if [ -n "$BP_YES" ]; then
                echo "       Get the patched PHP $BP_PHP packages for ${BP_YES% } (one command, asks first):"
                echo "         $BP_INSTALL"
            fi
            if [ -n "$BP_NO" ]; then
                echo "       ${BP_NO% }: not built by $BP_REPO (PHP $BP_PHP only). Move these sites"
                echo "       to PHP $BP_PHP from there, or the server to a newer Ubuntu."
            fi
        elif [ -z "$AGE" ] || [ "$AGE" -ge 1 ]; then
            echo "       apt was last updated ${AGE:-?}h ago — refresh first, then re-run this check:"
            echo "         sudo apt-get update -o Acquire::AllowReleaseInfoChange::Label=true"
        else
            echo "       apt was updated <1h ago. Wait for the package to be published, then:"
            echo "         sudo apt-get update -o Acquire::AllowReleaseInfoChange::Label=true   # then re-run this check"
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
            echo "  •  Until upgraded, apply the stopgap (partial protection only):"
            echo "       sudo $SELF --mitigate"
        fi
        [ -n "$RISKS" ] && echo -e "  ${RED}•  Fix the November risk factors above first${NC} (${RISKS% }) — they make these bugs easy to hit."
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
echo "RESULT|${HOST}|${STATUS}|next=${NEXT} serving=$(echo ${SERVING:-none} | tr " " ,) risks=$(echo ${RISKS:-none} | tr ' ' ,) ${DETAILS% }"
exit $RC
