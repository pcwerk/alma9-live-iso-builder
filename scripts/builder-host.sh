#!/usr/bin/env bash
# =============================================================================
# builder-host.sh - serve the live ISO builder files over HTTP so the
#                   reference machine can pull kickstart/baseline.ks,
#                   scripts/snapshot.sh, scripts/customize-boot.sh, and
#                   config/boot-config.conf directly.
# =============================================================================
# Runs `python3 -m http.server` from this project directory and prints the
# exact copy-paste commands the operator will run on the reference machine
# (install boot, post-install snapshot, boot customization).
#
# Tarball return path: scp/rsync from reference back to the builder's
# ./data/dropbox/ directory. Easy to feed into build-iso.sh afterward.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_NAME="$(basename "$0")"

PORT=8000
BIND_ADDR="0.0.0.0"
ADVERTISED_HOST=""
DROPBOX_DIR="$PROJECT_ROOT/data/dropbox"

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --port <n>             HTTP server port (default: 8000)
  --bind <addr>          Bind address (default: 0.0.0.0)
  --advertised-host <h>  Hostname/IP shown in printed reference-machine
                         commands. Auto-detected if omitted.
  --dropbox <path>       Where the reference machine should scp the
                         snapshot tarball (default: ./data/dropbox)
  -h, --help             Show this help.

Serves the project directory at:
    kickstart/baseline.ks       -> AlmaLinux 9 installer kickstart
    scripts/snapshot.sh         -> post-install capture script
    scripts/customize-boot.sh   -> boot splash configurator
    config/boot-config.conf     -> boot splash config (edit before running)

Tarball return:
    Reference machine scps build-inputs/system-snapshot.tar.gz back into
    --dropbox on this host, then on this host you run build-iso.sh with
    --snapshot pointing at the file in --dropbox.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)             PORT="$2"; shift 2 ;;
        --bind)             BIND_ADDR="$2"; shift 2 ;;
        --advertised-host)  ADVERTISED_HOST="$2"; shift 2 ;;
        --dropbox)          DROPBOX_DIR="$2"; shift 2 ;;
        -h|--help)          usage; exit 0 ;;
        *)                  usage; echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
command -v python3 >/dev/null \
    || { echo "ERROR: python3 not found on PATH (install python3, then re-run)"; exit 1; }

for f in kickstart/baseline.ks scripts/snapshot.sh scripts/customize-boot.sh config/boot-config.conf; do
    [[ -f "$PROJECT_ROOT/$f" ]] || { echo "ERROR: missing $PROJECT_ROOT/$f"; exit 1; }
done

mkdir -p "$DROPBOX_DIR"
# Ensure the dropbox is readable by the user running this script — scp
# from the reference may land files owned by SUDO_USER/$USER and
# build-iso.sh needs to read them back. 0755 is the right balance:
# owner-writable, world-readable.
chmod 0755 "$DROPBOX_DIR"

# ---------------------------------------------------------------------------
# Detect advertised host if not provided
# ---------------------------------------------------------------------------
detect_host() {
    # 1. Linux: hostname -I prints all RFC1918/etc addresses; take first.
    if command -v hostname >/dev/null 2>&1; then
        local first
        first="$(hostname -I 2>/dev/null | awk '{print $1}')"
        if [[ -n "$first" ]]; then printf '%s' "$first"; return; fi
    fi
    # 2. Linux fallback: use 'ip route' to find the IP toward a public dest.
    if command -v ip >/dev/null 2>&1; then
        local via
        via="$(ip -4 route get 1.1.1.1 2>/dev/null \
               | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
        if [[ -n "$via" ]]; then printf '%s' "$via"; return; fi
    fi
    # 3. macOS: ipconfig getifaddr en0 (Wi-Fi) / en1
    if command -v ipconfig >/dev/null 2>&1; then
        for iface in en0 en1 en2 en3; do
            local v
            v="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
            if [[ -n "$v" ]]; then printf '%s' "$v"; return; fi
        done
    fi
    # 4. Give up
    printf 'YOUR_BUILDER_IP'
}

if [[ -z "$ADVERTISED_HOST" ]]; then
    ADVERTISED_HOST="$(detect_host)"
fi

BASE_URL="http://$ADVERTISED_HOST:$PORT"

# ---------------------------------------------------------------------------
# scp destination string (operator's $USER@<builder>:<dropbox>/)
# ---------------------------------------------------------------------------
SCP_USER="${SUDO_USER:-$USER}"
SCP_DEST="${SCP_USER}@${ADVERTISED_HOST}:${DROPBOX_DIR}/"

# ---------------------------------------------------------------------------
# Print operator instructions
# ---------------------------------------------------------------------------
cat <<EOF

=============================================================================
 AlmaLinux 9 Live ISO Builder - HTTP Host
=============================================================================
 Serving:          $PROJECT_ROOT
 Bind:             ${BIND_ADDR}:${PORT}
 Advertised URL:   $BASE_URL
 Snapshot dropbox: $DROPBOX_DIR
=============================================================================

ON THE REFERENCE MACHINE (run these in order):

 1) BOOT THE ALMALINUX 9 INSTALLER (USB) with:

        inst.ks=${BASE_URL}/kickstart/baseline.ks

    (drop into the boot prompt with Tab or 'e' depending on bootloader)

 2) AFTER INSTALL completes and you have logged in and finished customizing
    (extra dnf installs, /opt drops, dconf tweaks, etc.), CONFIGURE THE
    BOOT SPLASH:

        cd /tmp
        wget ${BASE_URL}/config/boot-config.conf
        vi boot-config.conf                     # edit theme/timeout/etc.
        curl -fsSL ${BASE_URL}/scripts/customize-boot.sh -o customize-boot.sh
        sudo bash customize-boot.sh             # picks up ./boot-config.conf

 3) SNAPSHOT THE REFERENCE SYSTEM (run from a partition with free space):

        cd /var/tmp                             # or any dir with >2 GB free
        curl -fsSL ${BASE_URL}/scripts/snapshot.sh | sudo bash

    Produces ./build-inputs/{system-snapshot.tar.gz,users.conf,policy.conf}

 4) RETURN THE SNAPSHOT to this builder:

        scp ./build-inputs/system-snapshot.tar.gz \\
            ./build-inputs/users.conf \\
            ./build-inputs/policy.conf \\
            ${SCP_DEST}

ON THIS BUILDER MACHINE, after the files land in $DROPBOX_DIR:

 5) EDIT ${DROPBOX_DIR}/users.conf to replace each CHANGE_ME password,
    review policy.conf, then build the ISO:

        ./scripts/build-iso.sh \\
            --snapshot ${DROPBOX_DIR}/system-snapshot.tar.gz \\
            --template ./kickstart/live.ks.template \\
            --users    ${DROPBOX_DIR}/users.conf \\
            --policy   ${DROPBOX_DIR}/policy.conf \\
            --output   almalinux9-live-custom.iso

    Final ISO lands in ./data/output/

-----------------------------------------------------------------------------
 Ctrl-C to stop the HTTP server.
=============================================================================
EOF

# ---------------------------------------------------------------------------
# Start the server (foreground; trap so the user sees a clean shutdown)
# ---------------------------------------------------------------------------
trap 'echo; echo "[builder-host] shutting down"; exit 0' INT TERM

cd "$PROJECT_ROOT"
exec python3 -m http.server --bind "$BIND_ADDR" "$PORT"
