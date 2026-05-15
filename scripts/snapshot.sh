#!/usr/bin/env bash
# =============================================================================
# snapshot.sh - capture reference system state and auto-generate the build
#               input files (users.conf, policy.conf, system-snapshot.tar.gz).
# =============================================================================
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/snapshot.log"

log() {
    local ts
    ts="$(date -u +%FT%TZ)"
    printf '[%s] %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
}

warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [--output-dir <directory>]

Captures the configured reference system into a tarball and generates
users.conf and policy.conf reflecting current system state.

If --output-dir is omitted, defaults to \$PWD/build-inputs (so that
'curl http://builder/snapshot.sh | sudo bash' from a directory with
free disk space Just Works).

Outputs (in <output-dir>):
  system-snapshot.tar.gz
  users.conf
  policy.conf
  MANIFEST.txt
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OUTPUT_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            [[ $# -ge 2 ]] || die "--output-dir requires a path argument"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Unknown argument: $1" ;;
    esac
done

# Default to ./build-inputs if not provided (works with 'curl ... | sudo bash')
[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$PWD/build-inputs"
[[ $EUID -eq 0 ]] || die "Must be run as root"

touch "$LOG_FILE"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
log "snapshot.sh starting; output dir = $OUTPUT_DIR"

SNAPSHOT_TARBALL="$OUTPUT_DIR/system-snapshot.tar.gz"
USERS_CONF="$OUTPUT_DIR/users.conf"
POLICY_CONF="$OUTPUT_DIR/policy.conf"
MANIFEST="$OUTPUT_DIR/MANIFEST.txt"

# ---------------------------------------------------------------------------
# Paths to capture (per spec)
# ---------------------------------------------------------------------------
PATHS_TO_CAPTURE=(
    /home
    /opt
    /etc/skel
    /etc/dconf/db
    /etc/dconf/profile
    /etc/gdm
    /etc/systemd/logind.conf
    /etc/profile.d
    /etc/plymouth
    /etc/default/grub
    /usr/share/plymouth/themes
)

# ---------------------------------------------------------------------------
# Existence check + manifest
# ---------------------------------------------------------------------------
log "Building capture manifest"
: > "$MANIFEST"
present=()
for p in "${PATHS_TO_CAPTURE[@]}"; do
    if [[ -e "$p" ]]; then
        size_kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
        mtime=$(stat -c '%y' "$p" 2>/dev/null || echo unknown)
        printf '%-40s  %10s KB  mtime=%s\n' "$p" "${size_kb:-?}" "$mtime" >> "$MANIFEST"
        present+=("$p")
    else
        warn "expected path does not exist: $p (skipping)"
        printf '%-40s  MISSING\n' "$p" >> "$MANIFEST"
    fi
done

[[ ${#present[@]} -gt 0 ]] || die "Nothing to snapshot; all target paths missing"

# ---------------------------------------------------------------------------
# Warnings about possibly machine-specific state
# ---------------------------------------------------------------------------
if [[ -f /etc/hostname ]]; then
    hn="$(cat /etc/hostname || true)"
    warn "/etc/hostname is NOT captured but reference hostname is '$hn'; live system uses --hostname at build time"
fi

if grep -RIl --include='*.connection' --include='*.nmconnection' \
        -e 'method=manual' /etc/NetworkManager/system-connections 2>/dev/null | grep -q .; then
    warn "static NetworkManager connections detected under /etc/NetworkManager/system-connections; these are NOT captured but may carry MAC/IP affinity if you add them"
fi

if [[ -f /etc/machine-id ]]; then
    warn "/etc/machine-id is NOT captured (correct); each booted live system will generate its own"
fi

# ---------------------------------------------------------------------------
# Create tarball
# ---------------------------------------------------------------------------
log "Creating tarball: $SNAPSHOT_TARBALL"
# --absolute-names keeps the leading /, --xattrs/--acls preserve metadata,
# --warning=no-file-changed avoids noisy errors on live /home updates.
tar \
    --create \
    --gzip \
    --file "$SNAPSHOT_TARBALL" \
    --absolute-names \
    --xattrs \
    --acls \
    --selinux \
    --warning=no-file-changed \
    --warning=no-file-removed \
    "${present[@]}"

snapshot_size_bytes=$(stat -c '%s' "$SNAPSHOT_TARBALL")
snapshot_size_mb=$(( snapshot_size_bytes / 1024 / 1024 ))
log "Snapshot tarball size: ${snapshot_size_mb} MB"

if (( snapshot_size_mb > 500 )); then
    warn "snapshot tarball is ${snapshot_size_mb} MB (> 500 MB); the resulting ISO will be large and may be slow to load into RAM"
fi

# ---------------------------------------------------------------------------
# users.conf - read /etc/passwd for UIDs >= 1000 (excluding nobody @ 65534)
# ---------------------------------------------------------------------------
log "Generating users.conf"
{
    cat <<'EOF'
# users.conf - auto-generated by snapshot.sh
# Format: username:uid:shell:groups:password
#   password = "CHANGE_ME" means you MUST edit before building the ISO.
# Lines beginning with # are ignored.
EOF
    while IFS=: read -r uname _ uid _ _ _ ushell; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= 1000 && uid < 65534 )) || continue
        # Collect supplemental groups (all groups whose member list contains uname),
        # plus the user's primary group name from id(1).
        primary_group="$(id -gn "$uname" 2>/dev/null || true)"
        suppl_groups="$(id -Gn "$uname" 2>/dev/null | tr ' ' '\n' | grep -vx "$primary_group" | paste -sd, - || true)"
        if [[ -n "$primary_group" && -n "$suppl_groups" ]]; then
            groups_csv="$primary_group,$suppl_groups"
        elif [[ -n "$primary_group" ]]; then
            groups_csv="$primary_group"
        else
            groups_csv="$suppl_groups"
        fi
        printf '%s:%s:%s:%s:%s\n' "$uname" "$uid" "$ushell" "$groups_csv" "CHANGE_ME"
    done < /etc/passwd
} > "$USERS_CONF"
log "Wrote $USERS_CONF"
warn "edit $USERS_CONF and replace CHANGE_ME with real passwords before building the ISO"

# ---------------------------------------------------------------------------
# policy.conf - auto-generated from current dconf + logind state
# ---------------------------------------------------------------------------
log "Generating policy.conf"

dconf_read_as_user() {
    # Read a dconf key from localadmin (or the first non-system user we find)
    # so we get the merged db state, not just the system override layer.
    local key="$1"
    local user
    user="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)"
    if [[ -z "$user" ]]; then
        printf ''
        return
    fi
    sudo -u "$user" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$user")/bus" \
        dconf read "$key" 2>/dev/null || true
}

logind_value() {
    local key="$1"
    grep -E "^[[:space:]]*${key}=" /etc/systemd/logind.conf 2>/dev/null \
        | tail -n1 \
        | sed -E "s/^[[:space:]]*${key}=//" \
        | tr -d '[:space:]' \
        || true
}

bool_from_dconf() {
    # dconf returns 'true'/'false' (or empty). Normalise to true/false.
    local raw="$1"
    case "$(printf '%s' "$raw" | tr -d "[:space:]'")" in
        true)  printf 'true'  ;;
        false) printf 'false' ;;
        *)     printf 'unknown' ;;
    esac
}

int_from_dconf() {
    local raw="$1"
    # dconf can return uint32 like 'uint32 300'; strip type prefix
    raw="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]*(uint32|int32)[[:space:]]+//')"
    raw="$(printf '%s' "$raw" | tr -d "[:space:]'")"
    [[ "$raw" =~ ^[0-9]+$ ]] && printf '%s' "$raw" || printf ''
}

screen_blank_raw="$(dconf_read_as_user /org/gnome/desktop/session/idle-delay)"
screen_blank_seconds="$(int_from_dconf "$screen_blank_raw")"
: "${screen_blank_seconds:=300}"

screen_lock_raw="$(dconf_read_as_user /org/gnome/desktop/screensaver/lock-enabled)"
screen_lock_enabled="$(bool_from_dconf "$screen_lock_raw")"
[[ "$screen_lock_enabled" == "unknown" ]] && screen_lock_enabled="true"

lock_delay_raw="$(dconf_read_as_user /org/gnome/desktop/screensaver/lock-delay)"
auto_lockout_seconds="$(int_from_dconf "$lock_delay_raw")"
: "${auto_lockout_seconds:=600}"

screensaver_raw="$(dconf_read_as_user /org/gnome/desktop/screensaver/idle-activation-enabled)"
screensaver_enabled="$(bool_from_dconf "$screensaver_raw")"
[[ "$screensaver_enabled" == "unknown" ]] && screensaver_enabled="true"

# Suspend disabled when EITHER logind says ignore OR dconf says nothing/never
logind_idle_action="$(logind_value IdleAction)"
suspend_enabled="true"
if [[ "$logind_idle_action" == "ignore" ]]; then
    suspend_enabled="false"
fi
sleep_inactive_ac_type_raw="$(dconf_read_as_user /org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type)"
case "$(printf '%s' "$sleep_inactive_ac_type_raw" | tr -d "[:space:]'")" in
    nothing|blank) suspend_enabled="false" ;;
    suspend|hibernate) : ;;  # leave as previously determined
esac

# GDM autologin (parse /etc/gdm/custom.conf [daemon] section)
gdm_autologin_enabled="false"
gdm_autologin_user=""
if [[ -f /etc/gdm/custom.conf ]]; then
    in_daemon=0
    while IFS= read -r line; do
        # strip whitespace
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        case "$trimmed" in
            \#*|"") continue ;;
            \[daemon\]) in_daemon=1; continue ;;
            \[*\])     in_daemon=0; continue ;;
        esac
        (( in_daemon == 1 )) || continue
        if [[ "$trimmed" =~ ^AutomaticLoginEnable[[:space:]]*=[[:space:]]*(true|True|TRUE|yes|1)$ ]]; then
            gdm_autologin_enabled="true"
        elif [[ "$trimmed" =~ ^AutomaticLogin[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            gdm_autologin_user="${BASH_REMATCH[1]}"
        fi
    done < /etc/gdm/custom.conf
fi

cat > "$POLICY_CONF" <<EOF
# policy.conf - auto-generated by snapshot.sh from current system state.
# Edit values then re-run build-iso.sh. Lines starting with # are ignored.

screen_blank_timeout_seconds=${screen_blank_seconds}
screen_lock_enabled=${screen_lock_enabled}
auto_lockout_timeout_seconds=${auto_lockout_seconds}
suspend_enabled=${suspend_enabled}
screensaver_enabled=${screensaver_enabled}
gdm_autologin_enabled=${gdm_autologin_enabled}
gdm_autologin_user=${gdm_autologin_user}
EOF
log "Wrote $POLICY_CONF"

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
log "snapshot.sh complete. Outputs:"
log "  $SNAPSHOT_TARBALL  (${snapshot_size_mb} MB)"
log "  $USERS_CONF"
log "  $POLICY_CONF"
log "  $MANIFEST"
log "Next: review/edit users.conf (passwords) and policy.conf, then run build-iso.sh"
