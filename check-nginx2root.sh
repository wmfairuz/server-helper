#!/usr/bin/env bash
#
# "nginx2root" checker: CVE-2026-123007 (HTTP/2 flow-control overflow, unauthenticated RCE)
# plus CVE-2026-123633 / CVE-2026-123634 / CVE-2026-121810 / CVE-2026-113425
#
# Usage:
#   sudo ./check-nginx2root.sh              # check only — makes no changes; finds every nginx,
#                                           # where it came from, what is exposed, and whether
#                                           # apt/yum already has the fix
#   sudo ./check-nginx2root.sh --mitigate   # stopgap: turn HTTP/2 and HTTP/3 off in every vhost
#                                           # (marked, reversible), block the SCTP module, nginx -t, reload
#   sudo ./check-nginx2root.sh --unmitigate # put the vhost lines back and unblock SCTP
#   sudo ./check-nginx2root.sh --upgrade    # only-upgrade installed nginx packages (configs kept),
#                                           # nginx -t, then reload (restart if the binary changed)
#   Add -y to skip the confirmation prompt.
# Every mode re-runs the check afterwards.
#
# Fixed upstream on 2026-11-18 in nginx 1.30.7 (stable) and 1.31.9 (mainline). Every
# other release from 1.9.5 on has the HTTP/2 bug. 1.29.x and older have no upstream
# fix, so only a distro backport (found via the package changelog) counts as patched.
#
# Last line of output is machine-readable, for collecting results across servers:
#   RESULT|<host>|<status>|<details>
# Exit codes: 0 = not vulnerable, 1 = vulnerable, 2 = could not determine
#
set -u

FIX_1_30="${FIX_1_30:-1.30.7}"
FIX_1_31="${FIX_1_31:-1.31.9}"
# No OpenResty release with the fix was out on 2026-11-19. Set this to its first
# fixed version once one ships, e.g. OPENRESTY_FIXED=1.29.2.6 ./check-nginx2root.sh
OPENRESTY_FIXED="${OPENRESTY_FIXED:-}"

MARK="nginx2root-mitigation"
# Lines --mitigate changes: listen ... http2 / listen ... quic / http2 on; / http3 on;
MIT_RE='(^|[;{])[[:space:]]*(listen[[:space:]][^#;]*[[:space:]](http2|quic)([[:space:]]|;)|http[23][[:space:]]+on[[:space:]]*;)'
SCTP_CONF="/etc/modprobe.d/nginx2root-sctp.conf"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
HOST=$(hostname -f 2>/dev/null || hostname)

ACTION="check"; ASSUME_YES="no"
for arg in "$@"; do
    case "$arg" in
        --mitigate)   ACTION="mitigate" ;;
        --unmitigate) ACTION="unmitigate" ;;
        --upgrade)    ACTION="upgrade" ;;
        -y|--yes)     ASSUME_YES="yes" ;;
        -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
        *)            echo "Unknown option: $arg (see --help)"; exit 2 ;;
    esac
done

IS_ROOT="no"; [ "$(id -u)" -eq 0 ] && IS_ROOT="yes"
if [ "$ACTION" != "check" ] && [ "$IS_ROOT" = "no" ]; then
    echo -e "${RED}--${ACTION} changes the system — run it with sudo.${NC}"
    exit 2
fi

echo -e "${BOLD}=== nginx2root (CVE-2026-123007 + 4) checker — ${HOST} — $(date '+%Y-%m-%d %H:%M %Z') ===${NC}\n"
[ "$IS_ROOT" = "no" ] && echo -e "${YELLOW}Not root: running masters, containers and full configs can't be read — re-run with sudo.${NC}\n"

# a <= b, version-wise
ver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }
ver_ge() { ver_le "$2" "$1"; }

OS_CODENAME=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
OS_ID=$(. /etc/os-release 2>/dev/null; echo "${ID:-linux}")

# Is this upstream nginx version past the fix?
upstream_fixed() {
    local v="$1"
    case "$v" in
        1.30.*) ver_ge "$v" "$FIX_1_30" ;;
        1.31.*) ver_ge "$v" "$FIX_1_31" ;;
        *)      ver_ge "$v" "1.32.0" ;;
    esac
}

# The nginx2root CVEs a given nginx version contains (per nginx.org's advisories)
cves_for() {
    local v="$1" h3="$2" out="CVE-2026-123634 CVE-2026-113425"
    ver_ge "$v" "1.9.5"  && out="CVE-2026-123007 CVE-2026-123633 $out"
    ver_ge "$v" "1.25.0" && [ "$h3" = "yes" ] && out="$out CVE-2026-121810"
    echo "$out"
}

# Where a build came from: path for panels/vendors, package version for apt/rpm
nginx_source() {
    local bin="$1" pkg="$2" pv="$3"
    case "$bin" in
        ctr:*)                    ;;
        /usr/local/openresty/*|*/openresty*) echo "OpenResty"; return ;;
        /opt/psa/*|*sw-cp-server*)           echo "Plesk"; return ;;
    esac
    case "$pkg" in
        ea-nginx*)   echo "cPanel"; return ;;
        sw-nginx*)   echo "Plesk"; return ;;
        openresty*)  echo "OpenResty"; return ;;
    esac
    [ -z "$pkg" ] && { echo "custom"; return; }
    case "$pv" in
        *deb.sury.org*)        echo "Ondrej" ;;
        *-[0-9]~[a-z]*|*.ngx)  echo "nginx.org" ;;     # 1.30.7-1~jammy / 1.30.7-1.el7.ngx
        *+esm*)                echo "Ubuntu-ESM" ;;
        *ubuntu*)              echo "Ubuntu" ;;
        *+deb[0-9]*|*-[0-9])   echo "Debian" ;;
        *tuxcare*)             echo "TuxCare" ;;
        *.el[0-9]*)            echo "EL/EPEL" ;;
        *-r[0-9]*)             echo "Alpine" ;;
        *)                     echo "${OS_ID}" ;;
    esac
}

# Hours since the last `apt update` (same logic as check-php-up-2026.sh)
apt_update_age() {
    local newest
    newest=$(stat -c %Y /var/cache/apt/pkgcache.bin /var/lib/apt/periodic/update-success-stamp \
                2>/dev/null | sort -n | tail -1)
    [ -z "$newest" ] && newest=$(stat -c %Z /var/lib/apt/lists/*_InRelease 2>/dev/null | sort -n | tail -1)
    [ -n "$newest" ] && echo $(( ($(date +%s) - newest) / 3600 ))
}

confirm() {
    [ "$ASSUME_YES" = "yes" ] && return 0
    read -r -p "$1 [y/N] " ans < /dev/tty
    [[ "$ans" =~ ^[Yy]$ ]]
}

# The nginx2root CVE IDs named in a package's changelog (prefix = container root or "")
changelog_cves() {
    local pkg="$1" prefix="$2" bin="$3" txt=""
    if [ -n "$pkg" ] && [ -d "$prefix/var/lib/dpkg" ]; then
        for f in "$prefix"/usr/share/doc/"$pkg"/changelog.Debian.gz \
                 "$prefix"/usr/share/doc/nginx-common/changelog.Debian.gz \
                 "$prefix"/usr/share/doc/nginx/changelog.Debian.gz; do
            [ -f "$f" ] && txt+=$(zcat "$f" 2>/dev/null)$'\n'
        done
    fi
    if [ -z "$prefix" ] && command -v rpm >/dev/null 2>&1 && ! [ -d /var/lib/dpkg ]; then
        local owner
        owner=$(rpm -qf "$bin" 2>/dev/null) && txt+=$(rpm -q --changelog "$owner" 2>/dev/null)
    fi
    echo "$txt" | grep -oE 'CVE-2026-(123007|123633|123634|121810|113425)' | sort -u | tr '\n' ' '
}

# Config with comments stripped: nginx -T when possible, else the files on disk.
# Also sets CONF_FILES (every file the config is made of).
conf_dump() {
    local bin="$1" conf="$2" prefix="$3" dump="" dir
    CONF_FILES=""
    if [ -z "$prefix" ] && [ -x "$bin" ]; then
        if [ -n "$conf" ]; then dump=$("$bin" -q -T -c "$conf" 2>/dev/null)
        else dump=$("$bin" -q -T 2>/dev/null); fi
    fi
    if echo "$dump" | grep -q '^# configuration file '; then
        CONF_FILES=$(echo "$dump" | sed -n 's/^# configuration file \(.*\):$/\1/p')
    else
        [ -z "$conf" ] && conf="/etc/nginx/nginx.conf"
        dir=$(dirname "$prefix$conf")
        [ -d "$dir" ] || return
        CONF_FILES=$(find -L "$dir" -maxdepth 3 -type f \( -name '*.conf' -o -path '*-enabled/*' \) 2>/dev/null)
        dump=$(cat $CONF_FILES 2>/dev/null)
    fi
    echo "$dump" | sed 's/#.*//'
}

# Which nginx2root attack paths does this config switch on? Sets EXP and EXP_NOTE.
analyze_conf() {
    local d="$1" h2 h3 mailp res dyn sub
    local S='(^|[;{}])[[:space:]]*'           # start of a directive, also mid-line
    EXP=""; EXP_NOTE=""
    h2=$(echo "$d" | grep -cE "${S}listen[[:space:]][^;]*[[:space:]]http2([[:space:]]|;)|${S}http2[[:space:]]+on[[:space:]]*;")
    h3=$(echo "$d" | grep -cE "${S}listen[[:space:]][^;]*[[:space:]]quic([[:space:]]|;)")
    mailp=$(echo "$d" | grep -cE "${S}mail[[:space:]]*\{")
    res=$(echo "$d" | grep -cE "${S}resolver[[:space:]]")
    dyn=$(echo "$d" | grep -cE "${S}(proxy|grpc|fastcgi|uwsgi|scgi)_pass[[:space:]]+[^;]*\\\$")
    sub=$(echo "$d" | grep -cE "${S}(mirror[[:space:]]+/|ssi[[:space:]]+on|auth_request[[:space:]]+/|add_(before|after)_body[[:space:]])")
    [ "$h2" -gt 0 ] && EXP+="http2 " && EXP_NOTE+="HTTP/2 on ${h2} listen/server line(s) [123007, 123633]; "
    [ "$h3" -gt 0 ] && EXP+="http3 " && EXP_NOTE+="QUIC/HTTP/3 on ${h3} listener(s) [121810]; "
    if [ "$mailp" -gt 0 ] && echo "$d" | grep -qE "${S}auth_http[[:space:]]"; then
        EXP+="mail " ; EXP_NOTE+="mail proxy with auth_http [113425]; "
    fi
    # 123634 needs request-time DNS (resolver + variable *_pass) AND subrequests
    if [ "$res" -gt 0 ] && [ "$dyn" -gt 0 ]; then
        if [ "$sub" -gt 0 ]; then
            EXP+="resolver "; EXP_NOTE+="resolver + variable *_pass + mirror/SSI/auth_request [123634]; "
        else
            EXP_NOTE+="resolver + variable *_pass, no subrequest directives seen [123634: lower risk]; "
        fi
    fi
}

# ── 1. Find every nginx: files on disk + running masters (incl. containers) ──
declare -A SEEN=() RUNPID=() STALE=() RUNCONF=()
BINS=()
add_bin() {
    local real="$1"
    [ -n "${SEEN[$real]:-}" ] && return
    SEEN[$real]=1; BINS+=("$real")
}

for b in $(command -v nginx openresty 2>/dev/null) \
         /usr/sbin/nginx /usr/local/sbin/nginx /usr/local/nginx/sbin/nginx /opt/nginx/sbin/nginx \
         /usr/local/openresty/nginx/sbin/nginx /usr/sbin/sw-cp-serverd /opt/psa/admin/sbin/nginx \
         /usr/sbin/nginx-debug; do
    [ -x "$b" ] || continue
    real=$(readlink -f "$b" 2>/dev/null || echo "$b")
    # /usr/bin/openresty is a symlink to the real nginx; only keep ELF binaries
    head -c4 "$real" 2>/dev/null | grep -q 'ELF' || continue
    add_bin "$real"
done

SELF_NS=$(readlink /proc/self/ns/mnt 2>/dev/null)
CTR_INFO=""
command -v docker >/dev/null 2>&1 && [ "$IS_ROOT" = "yes" ] && \
    CTR_INFO=$(timeout 10 docker ps --no-trunc --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null)
for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
    case "$cmd" in "nginx: master process"*|*"sw-cp-serverd: master"*) ;; *) continue ;; esac
    exe=$(readlink "$p/exe" 2>/dev/null)
    conf=$(echo "$cmd" | grep -oE '(^| )-c [^ ]+' | awk '{print $2}')
    ns=$(readlink "$p/ns/mnt" 2>/dev/null)
    if [ -n "$ns" ] && [ -n "$SELF_NS" ] && [ "$ns" != "$SELF_NS" ]; then
        key="ctr:$pid"                               # nginx inside a container
        add_bin "$key"; RUNPID[$key]=$pid; RUNCONF[$key]="$conf"
        continue
    fi
    if [ -z "$exe" ]; then                           # not root: guess from the command line
        exe=$(echo "$cmd" | awk '{print $4}')
        [[ "$exe" == /* ]] || exe=$(command -v "$exe" 2>/dev/null)
        [ -z "$exe" ] && continue
    fi
    stale=""
    case "$exe" in *" (deleted)") exe=${exe% (deleted)}; stale=1 ;; esac
    real=$(readlink -f "$exe" 2>/dev/null || echo "$exe")
    [ -n "$stale" ] && STALE[$real]=1
    add_bin "$real"; RUNPID[$real]="${RUNPID[$real]:+${RUNPID[$real]},}$pid"
    [ -n "$conf" ] && RUNCONF[$real]="$conf"
done

if [ ${#BINS[@]} -eq 0 ]; then
    echo -e "${GREEN}No nginx / OpenResty binaries or running masters found — not affected.${NC}"
    echo "RESULT|${HOST}|NO-NGINX|-"
    exit 0
fi

# Host binaries we may run -t / reload with
host_bins() { local b; for b in "${BINS[@]}"; do [[ "$b" == ctr:* ]] || echo "$b"; done; }

# Reload (config change) or restart (new binary still not running) each nginx service
bounce_nginx() {
    local units="" u how
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && \
    units=$(systemctl list-units --type=service --state=running --plain --no-legend \
                'nginx*' 'openresty*' 'sw-nginx*' 'sw-cp-server*' 2>/dev/null | awk '{print $1}')
    for u in $units; do
        how="reload"
        # A reload keeps the old executable; if the package replaced it, restart
        for pid in $(systemctl show -p MainPID "$u" 2>/dev/null | cut -d= -f2); do
            readlink "/proc/$pid/exe" 2>/dev/null | grep -q ' (deleted)$' && how="restart"
        done
        if systemctl "$how" "$u" 2>/dev/null; then
            echo -e "  ${GREEN}${how}ed ${u}${NC}"
        else
            echo -e "  ${RED}failed to ${how} ${u} — check: systemctl status ${u}${NC}"
        fi
    done
    if [ -z "$units" ]; then
        local b p
        for b in $(host_bins); do
            [ -n "${RUNPID[$b]:-}" ] || continue
            "$b" ${RUNCONF[$b]:+-c ${RUNCONF[$b]}} -s reload 2>/dev/null \
                && echo -e "  ${GREEN}reloaded $b (no systemd unit)${NC}" \
                || echo -e "  ${RED}could not reload $b — do it by hand${NC}"
            for p in ${RUNPID[$b]//,/ }; do
                readlink "/proc/$p/exe" 2>/dev/null | grep -q ' (deleted)$' && \
                    echo -e "  ${YELLOW}$b (pid $p) still runs the old binary — restart it (stop + start) to load the fix.${NC}"
            done
        done
    fi
}

test_all() {
    local b ok=0 list=""
    for b in $(host_bins); do [ -n "${RUNPID[$b]:-}" ] && list+="$b "; done
    [ -z "$list" ] && list=$(readlink -f "$(command -v nginx 2>/dev/null)" 2>/dev/null)
    for b in $list; do
        if ! out=$("$b" -t ${RUNCONF[$b]:+-c ${RUNCONF[$b]}} 2>&1); then
            echo -e "  ${RED}$b -t failed:${NC}"; echo "$out" | sed 's/^/    /'; ok=1
        fi
    done
    return $ok
}

# Files of every host nginx config that contain an http2/quic line we would change
mitigation_targets() {
    local b f
    for b in $(host_bins); do
        conf_dump "$b" "${RUNCONF[$b]:-}" "" >/dev/null    # sets CONF_FILES
        for f in $CONF_FILES; do
            [ -f "$f" ] && echo "$(readlink -f "$f")"
        done
    done | sort -u | while read -r f; do
        grep -E "$MIT_RE" "$f" | grep -qvF "$MARK" && echo "$f"
    done
}

do_mitigate() {
    echo -e "${BOLD}--- Applying stopgap: HTTP/2 + HTTP/3 off, SCTP module blocked ---${NC}"
    local files f
    files=$(mitigation_targets)
    if [ -z "$files" ]; then
        echo "  No vhost turns on HTTP/2 or HTTP/3 — nothing to change in nginx."
    else
        echo "  These lines will change (each keeps the original after '# ${MARK} was:'):"
        for f in $files; do
            grep -nE "$MIT_RE" "$f" | grep -vF "$MARK" \
                | sed "s|^|    $f:|"
        done
        echo "  HTTP/1.1 keeps working; gRPC-over-HTTP/2 services and HTTP/3 clients lose those protocols."
        if confirm "  Turn HTTP/2 and HTTP/3 off in these files?"; then
            for f in $files; do
                cp -p "$f" "$f.${MARK}.bak"
                MARK="$MARK" perl -i -pe '
                    next if /^\s*#/ || /$ENV{MARK}/;
                    my $o = $_; chomp $o; my $n = $o;
                    $n =~ s/((?:^|[;{])\s*)listen\s[^#;]*\squic\b[^#;]*;/$1/g;    # drop QUIC listeners
                    $n =~ s/((?:^|[;{])\s*listen\s[^#;]*?)\s+http2(?=[\s;])/$1/g;
                    $n =~ s/((?:^|[;{])\s*http[23])\s+on\s*;/$1 off;/g;
                    $n = "#" if $n =~ /^\s*$/;
                    $_ = "$n  # $ENV{MARK} was: $o\n" if $n ne $o;
                ' "$f"
                echo -e "  ${GREEN}edited $f${NC} (backup: $f.${MARK}.bak)"
            done
            if test_all; then
                bounce_nginx
                echo "  Existing HTTP/2 connections stay on old workers until they close; if"
                echo "  'nginx: worker process is shutting down' lingers, run: sudo systemctl restart nginx"
            else
                echo -e "  ${RED}nginx -t failed — putting the files back.${NC}"
                for f in $files; do mv -f "$f.${MARK}.bak" "$f"; done
            fi
            for f in $files; do rm -f "$f.${MARK}.bak"; done
            if [ -d /usr/local/cpanel ] || [ -d /opt/psa ]; then
                echo -e "  ${YELLOW}Panel-managed configs are rewritten on rebuild — re-run --mitigate after"
                echo -e "  any WHM/Plesk change, or turn HTTP/2 off in the panel (Plesk: plesk bin http2_pref --disable).${NC}"
            fi
        else
            echo "  Skipped."
        fi
    fi
    # Kernel half of the chain (worker → root): Xint's advice for hosts that don't use SCTP
    if [ -f "$SCTP_CONF" ]; then
        echo "  SCTP module already blocked ($SCTP_CONF)."
    elif [ -d /sys/module/sctp ] && [ ! -f /sys/module/sctp/initstate ]; then
        echo -e "  ${YELLOW}SCTP is built into this kernel — it can't be blocked; patch the kernel.${NC}"
    elif confirm "  Block the SCTP kernel module (worker→root step; skip if you use SCTP)?"; then
        printf '%s\n' "# nginx2root stopgap — remove once the kernel is patched:" \
            "#   sudo $(readlink -f "$0") --unmitigate" "install sctp /bin/false" > "$SCTP_CONF"
        echo -e "  ${GREEN}wrote $SCTP_CONF${NC}"
        [ -d /sys/module/sctp ] && echo -e "  ${YELLOW}sctp is already loaded — blocking only stops new loads; reboot or 'modprobe -r sctp' if unused.${NC}"
    fi
    echo -e "  ${YELLOW}Not covered by a config switch: CVE-2026-123634 (resolver) and CVE-2026-113425 (mail) —"
    echo -e "  see the per-binary notes below. Only the upgrade fixes everything.${NC}\n"
}

do_unmitigate() {
    echo -e "${BOLD}--- Removing stopgap ---${NC}"
    local files f b
    # Edited files are no longer in the config if nginx -T fails, so also search the conf dirs
    files=$(for b in $(host_bins); do
                conf_dump "$b" "${RUNCONF[$b]:-}" "" >/dev/null
                for f in $CONF_FILES; do readlink -f "$f"; done
            done | sort -u | xargs -r grep -lsF "# ${MARK} was: " 2>/dev/null)
    files=$( { echo "$files"; grep -rlsF "# ${MARK} was: " /etc/nginx /usr/local/nginx/conf \
                   /usr/local/openresty/nginx/conf 2>/dev/null | xargs -r readlink -f; } | grep . | sort -u)
    if [ -z "$files$( [ -f "$SCTP_CONF" ] && echo x)" ]; then
        echo -e "  No ${MARK} lines or $SCTP_CONF found — nothing to remove.\n"; return
    fi
    [ -n "$files" ] && echo "$files" | sed 's/^/    /'
    [ -f "$SCTP_CONF" ] && echo "    $SCTP_CONF"
    confirm "  Restore these?" || { echo "  Skipped."; echo; return; }
    for f in $files; do
        MARK="$MARK" perl -i -pe 's/^.*?  # \Q$ENV{MARK}\E was: (.*)$/$1/' "$f"
        echo -e "  ${GREEN}restored $f${NC}"
    done
    rm -f "$SCTP_CONF"
    if [ -n "$files" ]; then
        if test_all; then bounce_nginx
        else echo -e "  ${RED}nginx -t failed — fix the config, then reload.${NC}"; fi
    fi
    echo
}

do_upgrade() {
    echo -e "${BOLD}--- Upgrading nginx packages ---${NC}"
    local installed upgradable
    if command -v apt-get >/dev/null 2>&1; then
        echo "  apt-get update ..."
        local upd_err
        upd_err=$(apt-get update -qq -o Acquire::AllowReleaseInfoChange::Label=true 2>&1 >/dev/null) \
            || echo -e "  ${YELLOW}apt-get update reported errors — continuing:${NC}"
        [ -n "$upd_err" ] && echo "$upd_err" | grep -E '^(E|W):' | sed -n '1,5s/^/    /p'
        installed=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nginx*' 'libnginx-mod-*' \
                        'openresty*' 'sw-nginx*' 'ea-nginx*' 2>/dev/null | awk '$1=="ii"{print $2}')
        upgradable=$(apt list --upgradable 2>/dev/null | cut -d/ -f1 | grep -xF -f <(echo "$installed"))
        if [ -z "$upgradable" ]; then
            echo -e "  ${YELLOW}No nginx updates in your apt sources yet — see the verdict below for options.${NC}\n"
            return
        fi
        echo "  Upgradable nginx packages:"
        apt list --upgradable 2>/dev/null | grep -F -f <(echo "$upgradable" | sed 's|$|/|') | sed 's/^/    /'
        confirm "  Upgrade these (configs kept) and reload nginx?" || { echo "  Skipped."; echo; return; }
        DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
            -o Dpkg::Options::=--force-confold $upgradable \
            || { echo -e "  ${RED}apt-get install failed — see output above.${NC}"; return; }
    elif command -v yum >/dev/null 2>&1; then
        installed=$(rpm -qa --qf '%{NAME}\n' 'nginx*' 'ea-nginx*' 'openresty*' 'sw-nginx*' 2>/dev/null | sort -u)
        [ -z "$installed" ] && { echo -e "  ${YELLOW}No nginx RPMs installed — upgrade it the way it was built.${NC}\n"; return; }
        upgradable=$(yum -q check-update $installed 2>/dev/null | awk 'NF==3{print $1}' | sed 's/\.[^.]*$//')
        if [ -z "$upgradable" ]; then
            echo -e "  ${YELLOW}No nginx updates in your yum repos yet — see the verdict below for options.${NC}\n"
            return
        fi
        echo "  Upgradable: $upgradable"
        confirm "  Upgrade these (rpm keeps changed configs) and reload nginx?" || { echo "  Skipped."; echo; return; }
        yum -y update $upgradable || { echo -e "  ${RED}yum update failed — see output above.${NC}"; return; }
    else
        echo -e "  ${RED}Neither apt-get nor yum found — upgrade nginx the way it was installed.${NC}\n"
        return
    fi
    if test_all; then
        bounce_nginx          # restarts instead of reloading where the old binary still runs
    else
        echo -e "  ${RED}nginx -t failed — not reloading. The old nginx keeps running until fixed.${NC}"
    fi
    echo
}

case "$ACTION" in
    mitigate)   do_mitigate ;;
    unmitigate) do_unmitigate ;;
    upgrade)    do_upgrade ;;
esac

# Re-read which masters run a deleted (replaced) binary after any action
if [ "$ACTION" != "check" ]; then
    STALE=()
    for b in "${BINS[@]}"; do
        [[ "$b" == ctr:* ]] && continue
        run="${RUNPID[$b]:-}"
        for pid in ${run//,/ }; do
            readlink "/proc/$pid/exe" 2>/dev/null | grep -q ' (deleted)$' && STALE[$b]=1
            [ -d "/proc/$pid" ] || RUNPID[$b]=""
        done
    done
    for p in /proc/[0-9]*; do         # masters may have new PIDs after a restart
        cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
        case "$cmd" in "nginx: master process"*) ;; *) continue ;; esac
        exe=$(readlink -f "$p/exe" 2>/dev/null) || continue
        [ -n "${SEEN[$exe]:-}" ] && RUNPID[$exe]="${p#/proc/}"
    done
fi

# ── 2. Per-binary version, source, build, config exposure, patch state ──
echo -e "${BOLD}--- nginx builds ---${NC}"
ANY_EXPOSED="no"; ANY_LATENT="no"; ANY_UNKNOWN="no"; DETAILS=""; ALL_EXP=""
declare -A TODO_UPGRADE=() TODO_MAYBE=() TODO_WAIT=() TODO_MANUAL=() TODO_RESTART=()
for bin in "${BINS[@]}"; do
    prefix=""; label="$bin"; pid="${RUNPID[$bin]:-}"
    if [[ "$bin" == ctr:* ]]; then
        cpid=${bin#ctr:}; prefix="/proc/$cpid/root"
        vline=$(grep -aoE -m1 '(nginx|openresty)/[0-9]+(\.[0-9]+){2,3}' "/proc/$cpid/exe" 2>/dev/null | head -1)
        cfg=$(grep -aoE -m1 'configure arguments:[^"]*' "/proc/$cpid/exe" 2>/dev/null | head -1)
        cid=$(grep -oE '[0-9a-f]{64}' "/proc/$cpid/cgroup" 2>/dev/null | head -1)
        cname=$(echo "$CTR_INFO" | awk -v id="$cid" '$1==id{print $2" ("$3")"}')
        [ -z "$cname" ] && cname="$(head -c12 "$prefix/etc/hostname" 2>/dev/null) pid $cpid"
        label="container ${cname}"
    else
        vline=$("$bin" -v 2>&1 | grep -oE '(nginx|openresty)/[0-9]+(\.[0-9]+){2,3}' | head -1)
        cfg=$("$bin" -V 2>&1 | grep 'configure arguments')
    fi
    RAWVER=${vline#*/}
    if [ -z "$RAWVER" ]; then
        echo -e "  ${YELLOW}$label — could not read version${NC}"; ANY_UNKNOWN="yes"; continue
    fi
    VER=$(echo "$RAWVER" | cut -d. -f1-3)                    # OpenResty 1.29.2.5 → nginx core 1.29.2

    # Build: which vulnerable modules are compiled in
    BH2="no"; BH3="no"; BMAIL="no"
    echo "$cfg" | grep -q -- '--with-http_v2_module' && BH2="yes"
    echo "$cfg" | grep -q -- '--with-http_v3_module' && BH3="yes"
    echo "$cfg" | grep -qE -- '--with-mail(=dynamic)?( |$)' && BMAIL="yes"
    BUILD="h2=${BH2} h3=${BH3} mail=${BMAIL}"

    # Package + source
    PKG=""; PKGVER=""
    if [ -n "$prefix" ]; then
        if [ -f "$prefix/var/lib/dpkg/status" ]; then
            PKGVER=$(awk '/^Package: nginx$/{f=1} f&&/^Version:/{print $2; exit}' "$prefix/var/lib/dpkg/status")
            [ -n "$PKGVER" ] && PKG="nginx"
        elif [ -f "$prefix/lib/apk/db/installed" ]; then
            PKGVER=$(awk '/^P:nginx$/{f=1} f&&/^V:/{print substr($0,3); exit}' "$prefix/lib/apk/db/installed")
            [ -n "$PKGVER" ] && PKG="nginx"
        fi
    elif [ -d /var/lib/dpkg ]; then
        PKG=$(dpkg -S "$bin" 2>/dev/null | grep -v '^diversion' | head -1 | cut -d: -f1)
        [ -n "$PKG" ] && PKGVER=$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null)
    elif command -v rpm >/dev/null 2>&1; then
        PKG=$(rpm -qf --qf '%{NAME}' "$bin" 2>/dev/null) || PKG=""
        [ -n "$PKG" ] && PKGVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$PKG" 2>/dev/null | head -1)
    fi
    SRC=$(nginx_source "$bin" "$PKG" "$PKGVER")

    # Patched? Upstream version first, then a backport named in the changelog
    NEED=$(cves_for "$VER" "$BH3")
    HAVE=$(changelog_cves "$PKG" "$prefix" "$bin")
    MISSING=""
    for c in $NEED; do [[ " $HAVE " == *" $c "* ]] || MISSING+="$c "; done
    if [ "$SRC" = "OpenResty" ]; then
        if [ -n "$OPENRESTY_FIXED" ] && ver_ge "$RAWVER" "$OPENRESTY_FIXED"; then FIXSTATE="upstream"
        elif [ -n "$HAVE" ] && [ -z "$MISSING" ]; then FIXSTATE="backport"
        else FIXSTATE="none"; fi
    elif upstream_fixed "$VER"; then FIXSTATE="upstream"
    elif [ -n "$HAVE" ] && [ -z "$MISSING" ]; then FIXSTATE="backport"
    elif [ -n "$HAVE" ]; then FIXSTATE="partial"
    else FIXSTATE="none"; fi

    # Config exposure (the config this binary runs with)
    DUMP=$(conf_dump "$bin" "${RUNCONF[$bin]:-}" "$prefix")
    echo "$DUMP" | grep -qE 'load_module[[:space:]][^;]*ngx_mail_module' && BMAIL="yes(dynamic)" \
        && BUILD="h2=${BH2} h3=${BH3} mail=${BMAIL}"
    analyze_conf "$DUMP"
    [ "$BH2" = "no" ] && EXP=${EXP/http2 /}
    [ "$BH3" = "no" ] && EXP=${EXP/http3 /}
    if ! echo "$DUMP" | grep -q '[^[:space:]]'; then
        EXP_NOTE="config not readable — exposure unknown"; EXP="unknown-config "
    fi

    RUNNING="not running"; [ -n "$pid" ] && RUNNING="running (pid ${pid})"
    [ -n "${STALE[$bin]:-}" ] && RUNNING="RUNNING A DELETED BINARY (pid ${pid}) — upgraded on disk, not restarted"

    if [ "$FIXSTATE" = "upstream" ] || [ "$FIXSTATE" = "backport" ]; then
        if [ -n "${STALE[$bin]:-}" ]; then
            STATE="VULNERABLE — fixed on disk, old binary still running"; COLOR="$RED"
            ANY_EXPOSED="yes"; TODO_RESTART[$label]=1
        elif [ "$FIXSTATE" = "upstream" ]; then
            STATE="PATCHED (upstream fix)"; COLOR="$GREEN"
        else
            STATE="PATCHED (distro backport)"; COLOR="$GREEN"
        fi
    elif ! ver_ge "$VER" "0.5.15"; then
        STATE="NOT AFFECTED (predates every nginx2root bug)"; COLOR="$GREEN"
    else
        if [ -n "$EXP" ] && [ -n "$pid" ]; then
            STATE="VULNERABLE — exposed: ${EXP% }"; COLOR="$RED"; ANY_EXPOSED="yes"
        elif [ -z "$pid" ]; then
            STATE="VULNERABLE — installed, not running"; COLOR="$YELLOW"; ANY_LATENT="yes"
        else
            STATE="VULNERABLE — code present, no known attack path enabled"; COLOR="$YELLOW"; ANY_LATENT="yes"
        fi
        [ "$FIXSTATE" = "partial" ] && STATE+=" (partial backport, missing: ${MISSING% })"
        ALL_EXP+="$EXP"
    fi

    printf "  %-34s %-10s %-11s " "$label" "$RAWVER" "$SRC"
    echo -e "${COLOR}${STATE}${NC}"
    echo "      build: ${BUILD}   ${RUNNING}"
    [ -n "$PKG" ] && echo "      package: ${PKG} ${PKGVER}${HAVE:+  (changelog names: ${HAVE% })}"
    [ -n "$EXP_NOTE" ] && echo "      config: ${EXP_NOTE%; }"
    DETAILS+="${RAWVER}:${STATE%% *}:${SRC}:exp=$(echo "${EXP:-none}" | tr ' ' '+' | sed 's/+$//') "

    case "$STATE" in VULNERABLE*) ;; *) continue ;; esac
    [ -n "${TODO_RESTART[$label]:-}" ] && { echo -e "      ${YELLOW}↳ restart nginx to load the fixed binary${NC}"; continue; }

    # Vulnerable: can it be fixed right now? (local package lists — no network for apt)
    LABEL="nginx ${RAWVER} (${SRC})"
    CAND=""
    if [ -n "$prefix" ]; then
        HOW="pull/rebuild the image with nginx ${FIX_1_30}+ / ${FIX_1_31}+ (e.g. nginx:${FIX_1_31}), then recreate the container"
        echo -e "      ${YELLOW}↳ container: ${HOW}${NC}"; TODO_MANUAL[$LABEL]="$HOW"; continue
    fi
    if [ -n "$PKG" ] && command -v apt-cache >/dev/null 2>&1; then
        CAND=$(apt-cache policy "$PKG" 2>/dev/null | awk '/Candidate:/{print $2}')
    elif [ -n "$PKG" ] && command -v yum >/dev/null 2>&1; then
        CAND=$(timeout 90 yum -q check-update "$PKG" 2>/dev/null | awk -v p="$PKG" 'NF==3 && $1 ~ "^"p"\\." {print $2}')
        [ -z "$CAND" ] && CAND="(none)"
    fi
    if [ -z "$PKG" ] || [ -z "$CAND" ]; then
        case "$SRC" in
            OpenResty) HOW="upgrade OpenResty once a fixed release is out (openresty.org); none on 2026-11-19" ;;
            Plesk)     HOW="update via Plesk → Tools & Settings → Updates" ;;
            cPanel)    HOW="update ea-nginx via WHM → EasyApache 4 (or yum update ea-nginx)" ;;
            *)         HOW="built from source — rebuild from nginx ${FIX_1_30} / ${FIX_1_31} with the same ./configure flags (nginx -V)" ;;
        esac
        echo -e "      ${YELLOW}↳ not package-managed: ${HOW}${NC}"
        TODO_MANUAL[$LABEL]="$HOW"
    elif [ "$CAND" != "(none)" ] && [ "$CAND" != "$PKGVER" ] && \
         { ! command -v dpkg >/dev/null 2>&1 || dpkg --compare-versions "$CAND" gt "$PKGVER"; }; then
        CUP=$(echo "$CAND" | sed 's/^[0-9]*://' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
        if [ -n "$CUP" ] && upstream_fixed "$CUP"; then
            FIXED="yes"
        elif command -v apt-get >/dev/null 2>&1; then
            # Same upstream version: only a backport helps. Ubuntu's changelog server
            # can lag new uploads by hours; PPAs/nginx.org have none → unknown.
            if ! out=$(timeout 25 apt-get changelog "$PKG" 2>/dev/null); then FIXED="unknown"
            elif echo "$out" | grep -q 'CVE-2026-123007'; then FIXED="yes"
            else FIXED="no"; fi
        else
            FIXED="unknown"
        fi
        case "$FIXED" in
            yes) echo -e "      ${GREEN}↳ fix available: ${CAND}${NC}"; TODO_UPGRADE[$LABEL]="$CAND" ;;
            no)  echo -e "      ${YELLOW}↳ update ${CAND} is available but does NOT contain the fix yet${NC}"; TODO_WAIT[$LABEL]="$SRC" ;;
            *)   echo -e "      ${YELLOW}↳ update available: ${CAND} — can't confirm it has the fix; upgrade, then re-check${NC}"
                 TODO_MAYBE[$LABEL]="$CAND" ;;
        esac
    else
        echo -e "      ${YELLOW}↳ no fix in your package sources yet${NC}"
        TODO_WAIT[$LABEL]="$SRC"
    fi
done
echo

# ── 3. Kernel half of the chain (worker → root via SCTP) ───────────────
echo -e "${BOLD}--- SCTP (kernel step from nginx worker to root) ---${NC}"
if [ -f "$SCTP_CONF" ]; then SCTP="blocked"; echo -e "  ${GREEN}Module load blocked by $SCTP_CONF${NC}"
elif [ -d /sys/module/sctp ] && [ ! -f /sys/module/sctp/initstate ]; then
    SCTP="builtin"; echo -e "  ${YELLOW}SCTP is built into this kernel — can't be blocked; only a kernel fix helps (none yet).${NC}"
elif [ -d /sys/module/sctp ]; then SCTP="loaded"; echo -e "  ${YELLOW}sctp module is loaded — reachable from a compromised worker${NC}"
elif modinfo sctp >/dev/null 2>&1 || ls /lib/modules/"$(uname -r)"/kernel/net/sctp/sctp.ko* >/dev/null 2>&1; then
    SCTP="loadable"; echo "  sctp module is available and auto-loads on first use (no kernel fix yet)."
else SCTP="absent"; echo "  sctp module not found for this kernel."; fi
echo

# ── 4. Verdict ────────────────────────────────────────────────────────
echo -e "${BOLD}=== VERDICT ===${NC}"
SELF=$(readlink -f "$0")
NEXT="none"
MITIGATED=$(grep -rlsF "# ${MARK} was: " /etc/nginx /usr/local/nginx/conf /usr/local/openresty/nginx/conf 2>/dev/null | head -1)
if [ "$ANY_EXPOSED" = "yes" ] || [ "$ANY_LATENT" = "yes" ]; then
    if [ "$ANY_EXPOSED" = "yes" ]; then
        STATUS="VULNERABLE"
        echo -e "${RED}A vulnerable nginx is running with an nginx2root attack path enabled.${NC}"
    else
        STATUS="VULNERABLE-NOT-EXPOSED"
        echo -e "${YELLOW}Vulnerable nginx code is installed, but nothing running has a known attack path on.${NC}"
        echo -e "${YELLOW}Practical risk: LOW — still upgrade; a config change could expose it.${NC}"
    fi
    echo
    if [ ${#TODO_RESTART[@]} -gt 0 ]; then
        NEXT="restart"
        echo -e "  ${RED}•  Fixed package installed but the old binary is still running${NC}: ${!TODO_RESTART[*]}"
        echo "       sudo nginx -t && sudo systemctl restart nginx"
    fi
    if [ ${#TODO_UPGRADE[@]} -gt 0 ]; then
        [ "$NEXT" = "none" ] && NEXT="upgrade-now"
        echo -e "  ${GREEN}•  Fix is in your package sources now${NC} for: ${!TODO_UPGRADE[*]}"
        echo "       sudo $SELF --upgrade"
    fi
    if [ ${#TODO_MAYBE[@]} -gt 0 ]; then
        [ "$NEXT" = "none" ] && NEXT="upgrade-maybe"
        echo -e "  ${YELLOW}•  Update available that may contain the fix${NC} for: ${!TODO_MAYBE[*]}"
        echo "       sudo $SELF --upgrade   # the check afterwards says for sure"
    fi
    if [ ${#TODO_WAIT[@]} -gt 0 ]; then
        [ "$NEXT" = "none" ] && NEXT="wait"
        echo -e "  ${YELLOW}•  No fix in your package sources yet${NC} for: ${!TODO_WAIT[*]}"
        SRCS=" ${TODO_WAIT[*]} "
        if [[ "$SRCS" == *" Ondrej "* ]]; then
            echo "       Ondrej's nginx PPAs are gone from Launchpad — no fixed build will come from there."
        fi
        case "$OS_CODENAME" in
            focal|bionic)
                echo "       Ubuntu ${OS_CODENAME}: fixes come only via Ubuntu Pro (esm-infra); none published yet."
                [ "$OS_CODENAME" = "focal" ] && last="1.28.0" || last="1.24.0"
                echo "       nginx.org stopped building for ${OS_CODENAME} (last: ${last}), so it won't help either."
                command -v pro >/dev/null 2>&1 && ! pro status 2>/dev/null | grep -qE '^esm-infra +yes +enabled' \
                    && echo "       esm-infra is NOT enabled here: sudo pro attach <token>  (then re-run)" ;;
            jammy|noble|resolute)
                echo "       Ubuntu hadn't published fixed nginx packages yet (tracker, 2026-11-18)."
                echo "       nginx.org's repo already has ${FIX_1_30} / ${FIX_1_31} for ${OS_CODENAME} — switching is"
                echo "       an option, but its packages lay out /etc/nginx differently; test first." ;;
        esac
        if command -v apt-get >/dev/null 2>&1; then
            AGE=$(apt_update_age)
            if [ -z "$AGE" ] || [ "$AGE" -ge 1 ]; then
                echo "       apt was last updated ${AGE:-?}h ago — refresh, then re-run this check:"
                echo "         sudo apt-get update"
            fi
        else
            [[ " ${TODO_WAIT[*]} " == *" EL/EPEL "* ]] && grep -qs 'release 7' /etc/redhat-release && \
                echo "       EL7 is end-of-life: EPEL/CentOS won't ship this fix — TuxCare ELS or a newer OS will."
            echo "       Refresh and re-run later: sudo yum clean expire-cache"
        fi
    fi
    if [ ${#TODO_MANUAL[@]} -gt 0 ]; then
        [ "$NEXT" = "none" ] && NEXT="manual"
        echo -e "  ${YELLOW}•  Not managed by this host's packages${NC} — update these yourself:"
        for k in "${!TODO_MANUAL[@]}"; do echo "       $k: ${TODO_MANUAL[$k]}"; done
    fi
    if [ "$STATUS" = "VULNERABLE" ]; then
        if [ -n "$MITIGATED" ] && [[ "$ALL_EXP" != *http2* ]] && [[ "$ALL_EXP" != *http3* ]]; then
            echo -e "  •  HTTP/2+3 stopgap ${GREEN}already applied${NC} — keep it until the verdict says PATCHED."
        elif [[ "$ALL_EXP" == *http2* ]] || [[ "$ALL_EXP" == *http3* ]]; then
            echo "  •  Until upgraded, turn HTTP/2 + HTTP/3 off (blocks 123007, 123633, 121810):"
            echo "       sudo $SELF --mitigate"
        fi
        if [[ "$ALL_EXP" == *resolver* ]]; then
            echo "  •  resolver + variable proxy_pass (123634): point proxy_pass at a fixed upstream{} group,"
            echo "     and turn off mirror / SSI there, until upgraded."
        fi
        if [[ "$ALL_EXP" == *mail* ]]; then
            echo "  •  mail proxy + auth_http (113425): bind the mail listeners to 127.0.0.1 or firewall"
            echo "     them to trusted IPs until upgraded."
        fi
        echo "  •  From outside, confirm HTTP/2 is really off on each site (prints nothing when off):"
        echo "       openssl s_client -connect SITE:443 -servername SITE -alpn h2 </dev/null 2>&1 | grep 'ALPN protocol: h2'"
    fi
    [ "$SCTP" = "loadable" ] && echo "  •  Kernel step (worker → root): block SCTP if unused — included in --mitigate."
    RC=1
elif [ "$ANY_UNKNOWN" = "yes" ]; then
    STATUS="UNKNOWN"
    echo -e "${YELLOW}Could not classify every nginx — review the list above.${NC}"
    RC=2
else
    STATUS="PATCHED"
    echo -e "${GREEN}Every nginx is on ${FIX_1_30}+ / ${FIX_1_31}+ or carries a distro backport.${NC}"
    [ -n "$MITIGATED" ] && echo "  → HTTP/2+3 stopgap no longer needed: sudo $SELF --unmitigate  (SCTP block: keep until the kernel is fixed)"
    RC=0
fi
echo
echo "Authoritative status: https://nginx.org/en/security_advisories.html"
echo "                      https://ubuntu.com/security/CVE-2026-123007"
echo "RESULT|${HOST}|${STATUS}|next=${NEXT} sctp=${SCTP} mitigated=$([ -n "$MITIGATED" ] && echo yes || echo no) ${DETAILS% }"
exit $RC
