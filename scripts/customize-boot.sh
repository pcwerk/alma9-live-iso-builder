#!/usr/bin/env bash
# =============================================================================
# customize-boot.sh - configure Plymouth + GRUB boot splash on the reference
#                     system. Run as root after baseline install.
# =============================================================================
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/tmp/customize-boot.log"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local ts
    ts="$(date -u +%FT%TZ)"
    printf '[%s] %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [--config <path-to-boot-config.conf>]

Reads key=value pairs from the supplied config and configures Plymouth,
GRUB splash, and boot message visibility on the reference system.

If --config is omitted, defaults to \$PWD/boot-config.conf (so that
'wget http://builder/config/boot-config.conf; vi boot-config.conf;
 curl http://builder/scripts/customize-boot.sh | sudo bash' works
without explicit args).
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CONFIG_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [[ $# -ge 2 ]] || die "--config requires a path argument"
            CONFIG_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            die "Unknown argument: $1"
            ;;
    esac
done

# Default to ./boot-config.conf if not provided
[[ -n "$CONFIG_PATH" ]] || CONFIG_PATH="$PWD/boot-config.conf"
[[ -f "$CONFIG_PATH" ]] || die "Config file not found: $CONFIG_PATH (download it from the builder first with: wget http://<builder>:8000/config/boot-config.conf)"
[[ $EUID -eq 0 ]] || die "Must be run as root"

# Make sure log exists and is writable before we start tee'ing
touch "$LOG_FILE"

log "Starting $SCRIPT_NAME with config=$CONFIG_PATH"

# ---------------------------------------------------------------------------
# Config parsing - tolerant of comments, blank lines, quoted values
# ---------------------------------------------------------------------------
declare -A CFG=(
    [plymouth_theme]=""
    [plymouth_custom_theme_dir]=""
    [grub_timeout]="3"
    [grub_background]=""
    [show_kernel_messages]="false"
    [show_progress_bar]="true"
    [splash_resolution]=""
    [boot_quiet]="true"
)

while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    # Skip blanks/comments
    [[ -z "$line" || "$line" == \#* ]] && continue
    # key=value
    [[ "$line" == *=* ]] || { log "WARNING: ignoring malformed line: $line"; continue; }
    key="${line%%=*}"
    value="${line#*=}"
    # Strip surrounding double quotes
    value="${value%\"}"
    value="${value#\"}"
    if [[ -n "${CFG[$key]+set}" ]]; then
        CFG[$key]="$value"
    else
        log "WARNING: unknown config key '$key' (ignored)"
    fi
done < "$CONFIG_PATH"

PLYMOUTH_THEME="${CFG[plymouth_theme]}"
CUSTOM_THEME_DIR="${CFG[plymouth_custom_theme_dir]}"
GRUB_TIMEOUT="${CFG[grub_timeout]}"
GRUB_BACKGROUND="${CFG[grub_background]}"
SHOW_KMSG="${CFG[show_kernel_messages]}"
SHOW_PROGRESS="${CFG[show_progress_bar]}"
SPLASH_RES="${CFG[splash_resolution]}"
BOOT_QUIET="${CFG[boot_quiet]}"

[[ -n "$PLYMOUTH_THEME" ]] || die "plymouth_theme is required in $CONFIG_PATH"

log "Effective config:"
for k in "${!CFG[@]}"; do log "  $k=${CFG[$k]}"; done

# ---------------------------------------------------------------------------
# 1. Ensure Plymouth is installed
# ---------------------------------------------------------------------------
if ! rpm -q plymouth >/dev/null 2>&1; then
    log "Plymouth not installed; installing via dnf"
    dnf install -y plymouth plymouth-scripts dracut-network
fi

# ---------------------------------------------------------------------------
# 2. Install a custom Plymouth theme if requested
# ---------------------------------------------------------------------------
if [[ -n "$CUSTOM_THEME_DIR" ]]; then
    [[ -d "$CUSTOM_THEME_DIR" ]] || die "plymouth_custom_theme_dir does not exist: $CUSTOM_THEME_DIR"
    theme_basename="$(basename "$CUSTOM_THEME_DIR")"
    target="/usr/share/plymouth/themes/$theme_basename"
    log "Installing custom Plymouth theme '$theme_basename' to $target"
    rm -rf "$target"
    mkdir -p "$target"
    cp -a "$CUSTOM_THEME_DIR"/. "$target"/
fi

# ---------------------------------------------------------------------------
# 3. Set Plymouth default theme
# ---------------------------------------------------------------------------
log "Setting Plymouth default theme to '$PLYMOUTH_THEME'"
if ! plymouth-set-default-theme -R "$PLYMOUTH_THEME" 2>>"$LOG_FILE"; then
    # -R asks plymouth to rebuild initramfs; if it fails, fall back to plain
    # set + dracut step later.
    log "WARNING: plymouth-set-default-theme -R failed; trying without -R"
    plymouth-set-default-theme "$PLYMOUTH_THEME"
fi

# ---------------------------------------------------------------------------
# 4. Build kernel cmdline and update /etc/default/grub
# ---------------------------------------------------------------------------
GRUB_FILE="/etc/default/grub"
[[ -f "$GRUB_FILE" ]] || die "$GRUB_FILE not found"

# Preserve a backup the first time we touch it
if [[ ! -f "${GRUB_FILE}.pre-customize" ]]; then
    cp -a "$GRUB_FILE" "${GRUB_FILE}.pre-customize"
    log "Backed up original GRUB defaults to ${GRUB_FILE}.pre-customize"
fi

# Helper: replace or append a GRUB_* key in /etc/default/grub
set_grub_key() {
    local key="$1"
    local value="$2"
    if grep -qE "^${key}=" "$GRUB_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$GRUB_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$GRUB_FILE"
    fi
}

# Build the cmdline. Start from current value, strip terms we manage, append.
# shellcheck disable=SC1090
current_cmdline="$(. "$GRUB_FILE" 2>/dev/null; printf '%s' "${GRUB_CMDLINE_LINUX:-}")"
# Remove tokens we will set ourselves
for token in quiet splash rhgb rd.live.ram=1 vga=current loglevel=[0-9] loglevel=3; do
    current_cmdline="$(printf '%s' "$current_cmdline" | sed -E "s/(^| )${token}( |$)/ /g")"
done
# Trim multiple spaces
current_cmdline="$(printf '%s' "$current_cmdline" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')"

extras=()
[[ "$BOOT_QUIET"     == "true" ]] && extras+=("quiet")
[[ "$SHOW_PROGRESS"  == "true" ]] && extras+=("splash" "rhgb")
[[ "$SHOW_KMSG"      == "true" ]] && extras+=("loglevel=7")
[[ "$SHOW_KMSG"      != "true" ]] && extras+=("loglevel=3")

new_cmdline="$current_cmdline ${extras[*]}"
new_cmdline="$(printf '%s' "$new_cmdline" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')"

set_grub_key "GRUB_TIMEOUT"        "$GRUB_TIMEOUT"
set_grub_key "GRUB_CMDLINE_LINUX"  "\"$new_cmdline\""
set_grub_key "GRUB_TIMEOUT_STYLE"  "menu"
set_grub_key "GRUB_TERMINAL_OUTPUT" "\"gfxterm\""

if [[ -n "$GRUB_BACKGROUND" ]]; then
    if [[ -f "$GRUB_BACKGROUND" ]]; then
        set_grub_key "GRUB_BACKGROUND" "\"$GRUB_BACKGROUND\""
    else
        log "WARNING: grub_background not found ($GRUB_BACKGROUND); leaving GRUB_BACKGROUND unset"
    fi
fi

if [[ -n "$SPLASH_RES" ]]; then
    set_grub_key "GRUB_GFXMODE"        "\"${SPLASH_RES}x32,auto\""
    set_grub_key "GRUB_GFXPAYLOAD_LINUX" "keep"
fi

log "Updated $GRUB_FILE; new GRUB_CMDLINE_LINUX=\"$new_cmdline\""

# ---------------------------------------------------------------------------
# 5. Regenerate grub.cfg for BIOS and UEFI
# ---------------------------------------------------------------------------
log "Regenerating /boot/grub2/grub.cfg"
grub2-mkconfig -o /boot/grub2/grub.cfg

if [[ -d /boot/efi/EFI/almalinux ]]; then
    log "Regenerating /boot/efi/EFI/almalinux/grub.cfg"
    grub2-mkconfig -o /boot/efi/EFI/almalinux/grub.cfg
else
    log "No UEFI grub directory found; skipping EFI grub.cfg regeneration"
fi

# ---------------------------------------------------------------------------
# 6. Rebuild initramfs so Plymouth theme is embedded
# ---------------------------------------------------------------------------
log "Rebuilding initramfs (dracut -f --regenerate-all)"
dracut -f --regenerate-all

log "customize-boot.sh complete"
