#!/usr/bin/env bash
# =============================================================================
# build-iso.sh - Docker-based AlmaLinux 9 live ISO builder
# =============================================================================
# Substitutes placeholders in kickstart/live.ks.template using the snapshot
# tarball, users.conf and policy.conf, validates the resulting kickstart, then
# invokes livemedia-creator inside the almalinux9-live-builder container to
# produce a bootable ISO.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local ts
    ts="$(date -u +%FT%TZ)"
    printf '[%s] %s\n' "$ts" "$*"
}
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SNAPSHOT=""
TEMPLATE=""
USERS_FILE=""
POLICY_FILE=""
OUTPUT=""
HOSTNAME_VAL="livecd"
DESKTOP="gnome"
EXTRA_PACKAGES=""
IMAGE_NAME="almalinux9-live-builder:latest"
REBUILD_IMAGE=0

TMPDIR_ROOT=""
LORAX_LOG_HINT=""

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    local rc=$?
    if [[ -n "$TMPDIR_ROOT" && -d "$TMPDIR_ROOT" ]]; then
        log "Cleaning up temp dir $TMPDIR_ROOT"
        rm -rf "$TMPDIR_ROOT"
    fi
    if (( rc != 0 )) && [[ -n "$LORAX_LOG_HINT" && -f "$LORAX_LOG_HINT" ]]; then
        echo
        log "Last 50 lines of $LORAX_LOG_HINT:"
        tail -n 50 "$LORAX_LOG_HINT" || true
    fi
    exit $rc
}
#trap cleanup EXIT

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [options]

Required:
  --snapshot <path>        Path to system-snapshot.tar.gz
  --template <path>        Path to kickstart/live.ks.template
  --users <path>           Path to users.conf
  --policy <path>          Path to policy.conf
  --output <iso-filename>  Output ISO filename (lands in ./data/output/)

Optional:
  --hostname <name>        Hostname for the live system (default: livecd)
  --desktop <gnome|kde>    Desktop package group (default: gnome)
  --extra-packages <list>  Comma-separated list of additional RPM names
  --image <name:tag>       Docker image name (default: almalinux9-live-builder:latest)
  --rebuild-image          Rebuild the Docker image before building the ISO
  -h, --help               Show this help
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --snapshot)       SNAPSHOT="$2"; shift 2 ;;
        --template)       TEMPLATE="$2"; shift 2 ;;
        --users)          USERS_FILE="$2"; shift 2 ;;
        --policy)         POLICY_FILE="$2"; shift 2 ;;
        --output)         OUTPUT="$2"; shift 2 ;;
        --hostname)       HOSTNAME_VAL="$2"; shift 2 ;;
        --desktop)        DESKTOP="$2"; shift 2 ;;
        --extra-packages) EXTRA_PACKAGES="$2"; shift 2 ;;
        --image)          IMAGE_NAME="$2"; shift 2 ;;
        --rebuild-image)  REBUILD_IMAGE=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage; die "Unknown argument: $1" ;;
    esac
done

for var in SNAPSHOT TEMPLATE USERS_FILE POLICY_FILE OUTPUT; do
    [[ -n "${!var}" ]] || { usage; die "$var is required"; }
done

[[ -f "$SNAPSHOT"    ]] || die "snapshot not found: $SNAPSHOT"
[[ -f "$TEMPLATE"    ]] || die "template not found: $TEMPLATE"
[[ -f "$USERS_FILE"  ]] || die "users.conf not found: $USERS_FILE"
[[ -f "$POLICY_FILE" ]] || die "policy.conf not found: $POLICY_FILE"

# Resolve to absolute paths (Docker bind mounts demand them)
SNAPSHOT="$(cd "$(dirname "$SNAPSHOT")"   && pwd)/$(basename "$SNAPSHOT")"
TEMPLATE="$(cd "$(dirname "$TEMPLATE")"   && pwd)/$(basename "$TEMPLATE")"
USERS_FILE="$(cd "$(dirname "$USERS_FILE")"   && pwd)/$(basename "$USERS_FILE")"
POLICY_FILE="$(cd "$(dirname "$POLICY_FILE")" && pwd)/$(basename "$POLICY_FILE")"

# ---------------------------------------------------------------------------
# Step 1: Verify Docker is installed and running
# ---------------------------------------------------------------------------
log "Verifying Docker"
command -v docker >/dev/null || die "docker not found on PATH"
docker info >/dev/null 2>&1 || die "docker daemon is not reachable; start Docker first"

# ---------------------------------------------------------------------------
# Step 2: Build (or rebuild) image if needed
# ---------------------------------------------------------------------------
needs_build=0
if (( REBUILD_IMAGE == 1 )); then
    needs_build=1
elif ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    needs_build=1
fi

if (( needs_build == 1 )); then
    [[ -f "$PROJECT_ROOT/Dockerfile" ]] || die "Dockerfile not found at $PROJECT_ROOT/Dockerfile"
    log "Building Docker image $IMAGE_NAME"
    docker build -t "$IMAGE_NAME" -f "$PROJECT_ROOT/Dockerfile" "$PROJECT_ROOT"
else
    log "Using existing Docker image $IMAGE_NAME"
fi

# ---------------------------------------------------------------------------
# Step 3: Stage build dir
# ---------------------------------------------------------------------------
HOST_BUILD_DIR="$PROJECT_ROOT/data/build"
HOST_OUTPUT_DIR="$PROJECT_ROOT/data/output"
mkdir -p "$HOST_BUILD_DIR" "$HOST_OUTPUT_DIR"

chmod a+rx "$PROJECT_ROOT"
chmod a+rx "$PROJECT_ROOT/data"
chmod a+rx "$HOST_BUILD_DIR"
chmod a+rx "$HOST_OUTPUT_DIR"

TMPDIR_ROOT="$(mktemp -d "$HOST_BUILD_DIR/iso-build.XXXXXX")"

chmod 755 "$TMPDIR_ROOT"

log "Staging build artifacts under $TMPDIR_ROOT"

# ---------------------------------------------------------------------------
# Step 4: Base64-encode snapshot
# ---------------------------------------------------------------------------
B64_FILE="$TMPDIR_ROOT/snapshot.b64"
log "Base64-encoding $SNAPSHOT"
# -w0 prints one long line on GNU coreutils; macOS base64 lacks -w but the
# build-iso.sh is designed to run on any Docker host, so we wrap at 76 cols.
if base64 --help 2>&1 | grep -q -- '-w,'; then
    base64 -w 76 "$SNAPSHOT" > "$B64_FILE"
else
    base64 "$SNAPSHOT" > "$B64_FILE"
fi
b64_lines="$(wc -l < "$B64_FILE")"
log "Snapshot encoded to $b64_lines lines"

# ---------------------------------------------------------------------------
# Step 5: Generate the users block from users.conf
# ---------------------------------------------------------------------------
USERS_BLOCK="$TMPDIR_ROOT/users.block"
log "Generating users block from $USERS_FILE"
{
    echo "# --- users block (generated by build-iso.sh) ---"
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        # Trim
        line="${raw#"${raw%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        IFS=':' read -r uname uid ushell groups password <<<"$line"
        [[ -n "$uname" && -n "$uid" ]] || { warn "skipping malformed users.conf line: $raw"; continue; }
        [[ "$uid" =~ ^[0-9]+$ ]] || { warn "skipping users.conf line with non-numeric uid: $raw"; continue; }
        [[ "$password" != "CHANGE_ME" && -n "$password" ]] || die "users.conf: user '$uname' still has password 'CHANGE_ME' (or empty); edit before building"

        : "${ushell:=/bin/bash}"
        primary="${groups%%,*}"
        suppl="${groups#*,}"
        if [[ "$primary" == "$groups" ]]; then suppl=""; fi

        # Escape single quotes in password so the heredoc-style chpasswd line is safe.
        esc_password="${password//\'/\'\\\'\'}"

        # useradd: create group with same name if missing; force exact UID;
        # do not create home if /home/<user> was restored from snapshot.
        cat <<EOF
if id -u '$uname' >/dev/null 2>&1; then
    echo "[users] $uname already exists; updating shell/groups"
    usermod --shell '$ushell' '$uname'
else
    if [[ -d /home/$uname ]]; then
        useradd --uid $uid --shell '$ushell' --no-create-home --home-dir /home/$uname '$uname'
    else
        useradd --uid $uid --shell '$ushell' --create-home '$uname'
    fi
fi
EOF

        if [[ -n "$primary" && "$primary" != "$uname" ]]; then
            cat <<EOF
if ! getent group '$primary' >/dev/null; then groupadd '$primary'; fi
usermod --gid '$primary' '$uname'
EOF
        fi

        if [[ -n "$suppl" ]]; then
            cat <<EOF
usermod --groups '$suppl' --append '$uname'
EOF
        fi

        cat <<EOF
echo '$uname:$esc_password' | chpasswd
chage -d 0 '$uname'
EOF

    done < "$USERS_FILE"
    echo "# --- end users block ---"
} > "$USERS_BLOCK"

USER_COUNT="$(grep -c '^useradd\|^if id -u' "$USERS_BLOCK" || true)"
log "Users block contains $USER_COUNT user record(s)"
[[ "$USER_COUNT" -gt 0 ]] || die "users.conf produced 0 users; aborting"

# ---------------------------------------------------------------------------
# Step 6: Generate policy block from policy.conf
# ---------------------------------------------------------------------------
POLICY_BLOCK="$TMPDIR_ROOT/policy.block"
log "Generating policy block from $POLICY_FILE"

# Defaults match the spec table
declare -A POL=(
    [screen_blank_timeout_seconds]=300
    [screen_lock_enabled]=true
    [auto_lockout_timeout_seconds]=600
    [suspend_enabled]=false
    [screensaver_enabled]=true
    [gdm_autologin_enabled]=false
    [gdm_autologin_user]=""
)

while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw#"${raw%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"
    if [[ -n "${POL[$key]+set}" ]]; then
        POL[$key]="$val"
    else
        warn "unknown policy.conf key '$key' (ignored)"
    fi
done < "$POLICY_FILE"

{
    cat <<EOF
# --- policy block (generated by build-iso.sh) ---
mkdir -p /etc/dconf/db/local.d /etc/dconf/db/local.d/locks /etc/dconf/profile

cat > /etc/dconf/profile/user <<'PROF'
user-db:user
system-db:local
PROF

cat > /etc/dconf/db/local.d/00-custom-policy <<'DCONF'
[org/gnome/desktop/session]
idle-delay=uint32 ${POL[screen_blank_timeout_seconds]}

[org/gnome/desktop/screensaver]
lock-enabled=${POL[screen_lock_enabled]}
lock-delay=uint32 ${POL[auto_lockout_timeout_seconds]}
idle-activation-enabled=${POL[screensaver_enabled]}

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='$( [[ "${POL[suspend_enabled]}" == "true" ]] && echo suspend || echo nothing )'
sleep-inactive-battery-type='$( [[ "${POL[suspend_enabled]}" == "true" ]] && echo suspend || echo nothing )'
DCONF

cat > /etc/dconf/db/local.d/locks/00-custom-policy <<'LOCKS'
/org/gnome/desktop/session/idle-delay
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/lock-delay
/org/gnome/desktop/screensaver/idle-activation-enabled
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type
LOCKS

# logind suspend policy
sed -i \
    -e 's/^[# ]*HandlePowerKey=.*/HandlePowerKey=poweroff/' \
    -e 's/^[# ]*HandleSuspendKey=.*/HandleSuspendKey=ignore/' \
    -e 's/^[# ]*HandleHibernateKey=.*/HandleHibernateKey=ignore/' \
    /etc/systemd/logind.conf
EOF

    if [[ "${POL[suspend_enabled]}" == "false" ]]; then
        cat <<'EOF'
sed -i -e 's/^[# ]*IdleAction=.*/IdleAction=ignore/' /etc/systemd/logind.conf
EOF
    fi

    if [[ "${POL[gdm_autologin_enabled]}" == "true" && -n "${POL[gdm_autologin_user]}" ]]; then
        cat <<EOF
mkdir -p /etc/gdm
cat > /etc/gdm/custom.conf <<'GDM'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=${POL[gdm_autologin_user]}
GDM
EOF
    else
        cat <<'EOF'
if [[ -f /etc/gdm/custom.conf ]]; then
    sed -i \
        -e 's/^AutomaticLoginEnable=.*/AutomaticLoginEnable=False/' \
        /etc/gdm/custom.conf
fi
EOF
    fi

    echo "# --- end policy block ---"
} > "$POLICY_BLOCK"

# ---------------------------------------------------------------------------
# Step 7: Resolve desktop package group
# ---------------------------------------------------------------------------
case "$DESKTOP" in
    gnome) DESKTOP_GROUP="@gnome-desktop" ;;
    kde)   DESKTOP_GROUP="@kde-desktop-environment" ;;
    *)     die "Unknown --desktop value '$DESKTOP' (expected gnome or kde)" ;;
esac
log "Desktop group: $DESKTOP_GROUP"

# ---------------------------------------------------------------------------
# Step 8: Build extra-packages block (one per line)
# ---------------------------------------------------------------------------
EXTRA_BLOCK_FILE="$TMPDIR_ROOT/extra-packages.block"
: > "$EXTRA_BLOCK_FILE"
if [[ -n "$EXTRA_PACKAGES" ]]; then
    IFS=',' read -r -a extras <<<"$EXTRA_PACKAGES"
    for pkg in "${extras[@]}"; do
        pkg="${pkg// /}"
        [[ -n "$pkg" ]] && printf '%s\n' "$pkg" >> "$EXTRA_BLOCK_FILE"
    done
    log "Added $(wc -l < "$EXTRA_BLOCK_FILE") extra package(s)"
fi

# ---------------------------------------------------------------------------
# Step 9: Substitute placeholders in template -> live.ks
# ---------------------------------------------------------------------------
LIVE_KS="$TMPDIR_ROOT/live.ks"
log "Generating $LIVE_KS"

# We do placeholder substitution via awk so the large base64 payload doesn't
# need to be passed as a sed argument (which would blow argv limits).
awk -v hostname="$HOSTNAME_VAL" \
    -v desktop="$DESKTOP_GROUP" \
    -v b64file="$B64_FILE" \
    -v usersfile="$USERS_BLOCK" \
    -v policyfile="$POLICY_BLOCK" \
    -v extrafile="$EXTRA_BLOCK_FILE" '
function dump(file,    line) {
    while ((getline line < file) > 0) print line
    close(file)
}
{
    line = $0
    key = line 

    gsub(/\r$/, "",key)
    gsub(/^[ \t]+|[ \t]+$/, "", key)
    
    if (line == /%%SNAPSHOT_B64%%/)   { dump(b64file);	 next }
    if (line == /%%USERS%%/)          { dump(usersfile);  next }
    if (line == /%%POLICY%%/)         { dump(policyfile); next }
    if (line == /%%EXTRA_PACKAGES%%/) { dump(extrafile);  next }
	
    gsub(/%%HOSTNAME%%/, hostname, line)
    gsub(/%%DESKTOP%%/,  desktop,  line)
    print line
}
' "$TEMPLATE" > "$LIVE_KS"

chmod 755 "$TMPDIR_ROOT"
chmod 0644 "$LIVE_KS"
chmod -R a+rX "$TMPDIR_ROOT"

if grep -q '%%EXTRA_PACKAGES%%' "$LIVE_KS"; then
	sed -i '/%%EXTRA_PACKAGES%%/d' "$LIVE_KS"
fi

if grep -q '%%EXTRA_PACKAGES%%' "$LIVE_KS"; then 
	grep -n '%%' "$LIVE_KS"
   die "Unresolved placeholder remain in generated live.ks"
fi

[[ -s "$LIVE_KS" ]] || die "$LIVE_KS came out empty after substitution"

log "Debugging generated live.ks structure"
grep -n -E '^%post|^%end|%%SNAPSHOT_EOF|^[A-Za-z0-9+/=]{60,}$' "LIVE_KS" | head -80 || true

# ---------------------------------------------------------------------------
# Step 10: Validate live.ks with ksvalidator (inside the build image)
# ---------------------------------------------------------------------------
log "Validating live.ks with ksvalidator (inside container)"
if ! docker run --rm \
	--user 0:0\
	-v "$TMPDIR_ROOT:/build:Z" \
        --entrypoint bash \
        "$IMAGE_NAME" \
	-lc 'id; ls -ld /build; ls -l /build/live.ks; head -n 5 /build/live.ks'; then 
   die "KSvalidator failed; see errors above"
fi
log "ksvalidator passed"

# ---------------------------------------------------------------------------
# Step 11: Invoke livemedia-creator inside the container
# ---------------------------------------------------------------------------
OUTPUT_BASENAME="$(basename "$OUTPUT")"
OUTPUT_PATH="$HOST_OUTPUT_DIR/$OUTPUT_BASENAME"
# livemedia-creator refuses to overwrite, so clear any prior result with the same name
[[ -e "$OUTPUT_PATH" ]] && { log "Removing previous $OUTPUT_PATH"; rm -f "$OUTPUT_PATH"; }

LORAX_LOG_HINT="$HOST_OUTPUT_DIR/lorax.log"

rm -rf "$HOST_OUTPUT_DIR/lmc-result"

log "Running livemedia-creator inside $IMAGE_NAME"
docker run --rm \
    --privileged \
    --device /dev/loop-control \
    --device /dev/loop0 \
    --device /dev/loop1 \
    --device /dev/loop2 \
    -v "$TMPDIR_ROOT:/build:Z" \
    -v "$HOST_OUTPUT_DIR:/output:Z" \
    --entrypoint livemedia-creator \
    "$IMAGE_NAME" \
        --ks /build/live.ks \
        --no-virt \
       	--resultdir /output/lmc-result \
        --project "AlmaLinux 9 Live" \
        --make-iso \
        --iso-only \
        --iso-name "$OUTPUT_BASENAME" \
        --releasever 9 \
        --image-size 5000 \
	--logfile /output/lorax.log


# livemedia-creator drops the ISO inside /output/lmc-result; promote it
if [[ -f "$HOST_OUTPUT_DIR/lmc-result/$OUTPUT_BASENAME" ]]; then
    mv "$HOST_OUTPUT_DIR/lmc-result/$OUTPUT_BASENAME" "$OUTPUT_PATH"
    rm -rf "$HOST_OUTPUT_DIR/lmc-result"
elif [[ -f "$HOST_OUTPUT_DIR/$OUTPUT_BASENAME" ]]; then
    : # already in place
else
    die "ISO not produced (looked in $HOST_OUTPUT_DIR/lmc-result and $HOST_OUTPUT_DIR)"
fi

iso_size_bytes="$(stat -c '%s' "$OUTPUT_PATH" 2>/dev/null || stat -f '%z' "$OUTPUT_PATH")"
iso_size_mb=$(( iso_size_bytes / 1024 / 1024 ))

echo
log "=================================================================="
log "Build succeeded."
log "  ISO:        $OUTPUT_PATH"
log "  Size:       ${iso_size_mb} MB"
log "  Hostname:   $HOSTNAME_VAL"
log "  Desktop:    $DESKTOP"
log "  Users:      $USER_COUNT user(s) from $USERS_FILE"
log "=================================================================="
