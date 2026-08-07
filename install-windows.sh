#!/bin/bash
###############################################################################
# Windows Server 2025 Automated Installer for Hetzner Dedicated Servers
# 
# CLOUD-READY: No SCP needed. Users only need PuTTY SSH.
# 
# ONE-LINER INSTALL (run from Hetzner rescue via PuTTY):
#   wget -qO- https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install.sh | bash
#
# Or download and run directly:
#   wget -O install-windows.sh https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install-windows.sh && bash install-windows.sh
#
# This script handles everything:
#   - Dependency installation
#   - Disk detection and partitioning
#   - ISO download and extraction
#   - VirtIO driver injection
#   - Unattended answer file generation
#   - Hetzner network configuration (auto-detects /32 point-to-point or standard)
#   - Bootloader setup (UEFI + Legacy BIOS)
#   - Post-install RDP, firewall, and optimization
#   - Network repair script placed on Windows drive
#
# Usage: bash install-windows.sh [options]
#   --ip <IP>           Server IPv4 address (auto-detected from rescue env)
#   --gateway <GW>      Gateway address (auto-detected)
#   --password <PASS>   Administrator password (default: generated)
#   --iso-url <URL>     Custom ISO download URL
#   --target-disk <DEV> Target disk for Windows (default: auto-detect)
#   --work-disk <DEV>   Work disk for temp files (default: auto-detect)
#   --skip-confirm      Skip confirmation prompts (default when stdin is not a TTY)
#   --confirm           Require interactive confirmation before wiping disks
#   --uefi              Force UEFI boot mode
#   --bios              Force Legacy BIOS boot mode
#   --interactive       Launch interactive wizard (best for PuTTY users)
#   --dry-run           Validate detection and configuration only
#   --force / --clean   Clear resume state and force full wipe/reinstall
#   --version           Print SCRIPT_VERSION and exit
#   --telegram-token    Telegram bot token (or TELEGRAM_BOT_TOKEN)
#   --telegram-chat     Telegram chat id (or TELEGRAM_CHAT_ID)
#   --discord-webhook   Discord webhook URL (or DISCORD_WEBHOOK_URL)
#
# Requirements:
#   - Hetzner dedicated/Cloud server booted into rescue mode
#   - At least 2 physical drives (or Cloud disk + Volume)
#   - Minimum 4GB RAM
#
# Notes:
#   - Disks are selected by size (largest = Windows, second-largest = workspace),
#     never by /dev/sdX letter order (Cloud often swaps sda/sdb).
#   - Resume state stores /dev/disk/by-id paths so letter swaps cannot retarget disks.
#   - Equal-size top disks refuse auto-select (require --target-disk / --work-disk).
#   - VirtIO storage + network drivers are injected and registered boot-start (Cloud).
#   - Cloud Legacy BIOS: GRUB ntldr on instance + Volume, /Boot/HETZNER marker,
#     purge stale WIM Boot\\BCD, patch BCD winload.efi→winload.exe, VirtIO CriticalDeviceDatabase.
#   - VirtIO hive edits prefer python3-hivex (dict values); hivexsh fallback; Start=0/3
#     and CriticalDeviceDatabase Service presence are the success gates (resume-safe;
#     no false-negative verify dies — never invert if ! python success/fail).
#   - python3-hivex + libhivex-bin + grub-pc are installed BEFORE disk wipe on Cloud/BIOS.
#   - UEFI remains preferred when available; --bios forces Legacy; --uefi forces UEFI.
#   - Legacy BIOS uses GRUB i386-pc + ntldr /bootmgr (does not rely on NTFS VBR alone).
#   - This version requires a dedicated workspace disk and does not support
#     single-disk installs safely.
#   - Progress is saved to /root/.hetzner-win-install-state for resume.
#
###############################################################################

set -euo pipefail

# ===================== Configuration Defaults =====================

SCRIPT_VERSION="3.8.1"

# Default ISO URL (Windows Server 2025 Evaluation — official Microsoft)
DEFAULT_ISO_URL="https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1742.240906-0331.ge_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"

# Alternate ISO mirror hosted by Hetzner. Kept as a fallback for environments
# where the Microsoft CDN is slow or temporarily unavailable.
HETZNER_ISO_MIRROR_URL="https://download.hetzner.com/bootimages/windows/SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-81891.ISO"

# VirtIO drivers ISO (Red Hat signed, for Hetzner's KVM/QEMU if needed)
VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

# wimlib source fallback when apt has no wimtools package
WIMLIB_SRC_URL="https://wimlib.net/downloads/wimlib-1.14.4.tar.gz"
DEBIAN_WIMLIB_POOL="https://deb.debian.org/debian/pool/main/w/wimlib"

# Hetzner DNS servers
DNS_PRIMARY="185.12.64.1"
DNS_SECONDARY="185.12.64.2"

MIN_TARGET_DISK_BYTES=40000000000
MIN_WORK_DISK_BYTES=8000000000

# Working directories
MOUNT_ISO="/mnt/iso"
MOUNT_WORK="/mnt/work"
MOUNT_TARGET="/mnt/target"

# Persist progress across re-runs in the same rescue session
STATE_FILE="/root/.hetzner-win-install-state"
LOG_FILE="/root/install.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ===================== Functions =====================

setup_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    # Mirror all stdout/stderr to the log while keeping console colors
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "Logging to $LOG_FILE (installer v${SCRIPT_VERSION})"
}

set_stage() {
    local stage="$1"
    {
        echo "STAGE=$stage"
        echo "UPDATED=$(date -Iseconds 2>/dev/null || date)"
        echo "STATE_VERSION=$SCRIPT_VERSION"
        echo "TARGET_DISK=${TARGET_DISK:-}"
        echo "WORK_DISK=${WORK_DISK:-}"
        echo "TARGET_DISK_ID=${TARGET_DISK_ID:-}"
        echo "WORK_DISK_ID=${WORK_DISK_ID:-}"
        echo "SERVER_IP=${SERVER_IP:-}"
        echo "GATEWAY=${GATEWAY:-}"
        echo "BOOT_MODE=${BOOT_MODE:-}"
        echo "ADMIN_PASSWORD=${ADMIN_PASSWORD:-}"
        echo "ISO_URL=${ISO_URL:-}"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
    log_detail "Checkpoint: $stage"
}

clear_state() {
    rm -f "$STATE_FILE"
    STAGE=""
    RESUME_MODE=0
    SKIP_WORKSPACE_WIPE=0
    SKIP_PARTITION=0
    SKIP_WIM_APPLY=0
    TARGET_DISK_ID=""
    WORK_DISK_ID=""
    log_info "Cleared install state ($STATE_FILE); full reinstall forced."
}

load_state() {
    if [ ! -f "$STATE_FILE" ]; then
        return 0
    fi
    # Import only known keys — never source raw file (avoids clobbering SCRIPT_VERSION).
    local key val
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[A-Z_]+= ]] || continue
        key="${line%%=*}"
        val="${line#*=}"
        case "$key" in
            STAGE|TARGET_DISK|WORK_DISK|TARGET_DISK_ID|WORK_DISK_ID|SERVER_IP|GATEWAY|BOOT_MODE|ADMIN_PASSWORD|ISO_URL|STATE_VERSION|UPDATED)
                printf -v "$key" '%s' "$val"
                ;;
        esac
    done < "$STATE_FILE"
    RESUME_MODE=1
    log_info "Found previous state ($STATE_FILE): STAGE=${STAGE:-unknown}"
}

# Logs go to stderr so command substitutions like image_index=$(select_...)
# only capture the intended return value on stdout (not log arrows).
# IMPORTANT: never echo -e the message body — "\v" in viostor becomes a vertical tab.
log_info()    { printf '%b[INFO]%b %s\n' "${GREEN}" "${NC}" "$*" >&2; }
log_warn()    { printf '%b[WARN]%b %s\n' "${YELLOW}" "${NC}" "$*" >&2; }
log_error()   { printf '%b[ERROR]%b %s\n' "${RED}" "${NC}" "$*" >&2; }
log_step()    { printf '%b[STEP]%b %s\n' "${CYAN}" "${NC}" "$*" >&2; }
log_detail()  { printf '%b  →%b %s\n' "${BLUE}" "${NC}" "$*" >&2; }

TOTAL_STEPS=10

progress_step() {
    local step="$1"
    local label="$2"
    local percent=$(( step * 100 / TOTAL_STEPS ))
    local filled=$(( percent / 5 ))
    local bar

    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
    printf "\n${CYAN}[PROGRESS]${NC} Step %s/%s (%s%%) %-20s [%s%-*s]\n" \
        "$step" "$TOTAL_STEPS" "$percent" "$label" "$bar" "$((20 - filled))" "" >&2
}

prefix_to_netmask() {
    local prefix="$1"
    if ! [[ "$prefix" =~ ^[0-9]+$ ]] || [ "$prefix" -lt 0 ] || [ "$prefix" -gt 32 ]; then
        die "Invalid subnet prefix: $prefix"
    fi
    local mask=""
    local octet
    local remaining=$prefix

    for _ in 1 2 3 4; do
        if [ "$remaining" -ge 8 ]; then
            octet=255
            remaining=$((remaining - 8))
        elif [ "$remaining" -gt 0 ]; then
            octet=$((256 - 2 ** (8 - remaining)))
            remaining=0
        else
            octet=0
        fi

        if [ -n "$mask" ]; then
            mask+="."
        fi
        mask+="$octet"
    done

    echo "$mask"
}

is_valid_ipv4() {
    local ip="$1"
    local octet

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
}

# List physical disks as: /dev/NAME SIZE_BYTES  (largest first).
# Never rely on kernel /dev/sdX order — Hetzner Cloud swaps sda/sdb across reboots.
get_candidate_disks() {
    lsblk -dbno NAME,SIZE,TYPE | awk '$3 == "disk" && $2 > 0 {print "/dev/" $1 " " $2}' | sort -k2,2nr
}

# Stable identity for a block device (prefer /dev/disk/by-id over sdX letters).
disk_stable_id() {
    local disk="$1"
    local real candidate base score best="" best_score=-1
    real=$(readlink -f "$disk" 2>/dev/null || echo "$disk")

    shopt -s nullglob
    for candidate in /dev/disk/by-id/*; do
        base=$(basename "$candidate")
        [[ "$base" == *-part* ]] && continue
        [ "$(readlink -f "$candidate" 2>/dev/null || true)" = "$real" ] || continue
        score=20
        case "$base" in
            wwn-*) score=100 ;;
            nvme-eui.*|nvme-*) score=90 ;;
            scsi-*) score=80 ;;
            virtio-*) score=75 ;;
            ata-*) score=70 ;;
            *) score=30 ;;
        esac
        if [ "$score" -gt "$best_score" ]; then
            best_score=$score
            best=$candidate
        fi
    done
    shopt -u nullglob

    if [ -n "$best" ]; then
        echo "$best"
    else
        echo "$real"
    fi
}

# Resolve /dev/sdX, /dev/nvmeXnY, or /dev/disk/by-id/... to a canonical block path.
resolve_disk_device() {
    local spec="$1"
    local resolved
    [ -n "$spec" ] || return 1
    if [ -b "$spec" ] || [ -e "$spec" ]; then
        resolved=$(readlink -f "$spec" 2>/dev/null || echo "$spec")
        [ -b "$resolved" ] || return 1
        echo "$resolved"
        return 0
    fi
    return 1
}

disk_size_bytes() {
    lsblk -dbno SIZE "$1" 2>/dev/null || echo 0
}

# True for Hetzner Cloud attached Volumes (must not be the Windows/boot disk).
is_hetzner_cloud_volume() {
    local disk="$1"
    local model id
    model=$(lsblk -dpno MODEL "$disk" 2>/dev/null || true)
    id=$(disk_stable_id "$disk")
    [[ "$model" == *[Vv]olume* ]] || [[ "$id" == *HC_Volume* ]] || [[ "$id" == *scsi-0HC_Volume* ]]
}

# True when running under KVM/QEMU (Hetzner Cloud / most CX/CPX/CAX plans).
is_virtual_machine() {
    if [ -d /sys/firmware/qemu_fw_cfg ] || [ -d /sys/bus/virtio ]; then
        return 0
    fi
    if grep -qiE 'QEMU|KVM|VirtualBox|VMware|Xen|Amazon|Microsoft Corporation' /sys/class/dmi/id/product_name 2>/dev/null \
        || grep -qiE 'QEMU|KVM|Amazon|Google|Microsoft' /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        return 0
    fi
    if command -v systemd-detect-virt &>/dev/null; then
        local virt
        virt=$(systemd-detect-virt 2>/dev/null || true)
        [ -n "$virt" ] && [ "$virt" != "none" ] && return 0
    fi
    return 1
}

# Returns the partition device path for a given disk and partition number.
# Handles NVMe (/dev/nvme0n1 -> /dev/nvme0n1p1), eMMC, loop, and standard
# SCSI/SATA (/dev/sda -> /dev/sda1) naming conventions.
partition_path() {
    local disk="$1" num="$2"
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# Locate the NTFS workspace partition on the work disk.
# Legacy BIOS layout: p1=bios_grub (~1MiB), p2=NTFS workspace.
# Older/UEFI layout: p1=NTFS workspace.
# Never return the bios_grub slice (too small for NTFS).
find_work_partition() {
    local disk="$1"
    local part fstype label size
    local min_bytes=1048576  # 1 MiB — mkfs.ntfs hard floor

    # Prefer labeled WORKSPACE
    while read -r part; do
        [ -b "$part" ] || continue
        size=$(lsblk -dbno SIZE "$part" 2>/dev/null || echo 0)
        [ "$size" -ge "$min_bytes" ] || continue
        label=$(lsblk -no LABEL "$part" 2>/dev/null | head -1 | tr -d '[:space:]')
        if [ "$label" = "WORKSPACE" ]; then
            echo "$part"
            return 0
        fi
    done < <(lsblk -lnpo NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}')

    # Prefer largest NTFS partition on the disk
    local best="" best_size=0
    while read -r part; do
        [ -b "$part" ] || continue
        fstype=$(lsblk -no FSTYPE "$part" 2>/dev/null | head -1 | tr -d '[:space:]')
        [ "$fstype" = "ntfs" ] || continue
        size=$(lsblk -dbno SIZE "$part" 2>/dev/null || echo 0)
        [ "$size" -ge "$min_bytes" ] || continue
        if [ "$size" -gt "$best_size" ]; then
            best="$part"
            best_size="$size"
        fi
    done < <(lsblk -lnpo NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}')
    if [ -n "$best" ]; then
        echo "$best"
        return 0
    fi

    # Fresh layout before format: prefer largest partition >= 1MiB (skip bios_grub).
    best=""
    best_size=0
    while read -r part; do
        [ -b "$part" ] || continue
        size=$(lsblk -dbno SIZE "$part" 2>/dev/null || echo 0)
        [ "$size" -ge "$min_bytes" ] || continue
        if [ "$size" -gt "$best_size" ]; then
            best="$part"
            best_size="$size"
        fi
    done < <(lsblk -lnpo NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}')
    if [ -n "$best" ]; then
        echo "$best"
        return 0
    fi

    # Last resort by number: p2 if present and large enough, else p1 if large enough
    local p1 p2
    p1=$(partition_path "$disk" 1)
    p2=$(partition_path "$disk" 2)
    if [ -b "$p2" ]; then
        size=$(lsblk -dbno SIZE "$p2" 2>/dev/null || echo 0)
        if [ "$size" -ge "$min_bytes" ]; then
            echo "$p2"
            return 0
        fi
    fi
    if [ -b "$p1" ]; then
        size=$(lsblk -dbno SIZE "$p1" 2>/dev/null || echo 0)
        if [ "$size" -ge "$min_bytes" ]; then
            echo "$p1"
            return 0
        fi
    fi
    return 1
}

# Wait until a block device node exists (partprobe races on Cloud).
wait_for_block_dev() {
    local dev="$1"
    local parent_disk="${2:-}"
    local tries="${3:-30}"
    local i
    for i in $(seq 1 "$tries"); do
        if [ -b "$dev" ]; then
            return 0
        fi
        if [ -n "$parent_disk" ] && [ -b "$parent_disk" ]; then
            partprobe "$parent_disk" 2>/dev/null || true
        fi
        udevadm settle --timeout=2 2>/dev/null || true
        sleep 0.5
    done
    [ -b "$dev" ]
}

banner() {
    local ver_line
    ver_line=$(printf "%-62s" "     Windows Server 2025 Installer — v${SCRIPT_VERSION}")
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    printf "║%s║\n" "$ver_line"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

cleanup() {
    # Only print and act if anything is actually mounted
    if mount | grep -qE "$MOUNT_ISO|$MOUNT_WORK|$MOUNT_TARGET|/mnt/efi|/mnt/bootpart" 2>/dev/null; then
        log_info "Cleaning up mount points..."
        umount "$MOUNT_ISO" 2>/dev/null || true
        umount "$MOUNT_WORK" 2>/dev/null || true
        umount "$MOUNT_TARGET" 2>/dev/null || true
        umount /mnt/efi 2>/dev/null || true
        umount /mnt/bootpart 2>/dev/null || true
    fi
    [ -d "$MOUNT_ISO" ] && rmdir "$MOUNT_ISO" 2>/dev/null || true
    [ -d "$MOUNT_WORK" ] && rmdir "$MOUNT_WORK" 2>/dev/null || true
    [ -d "$MOUNT_TARGET" ] && rmdir "$MOUNT_TARGET" 2>/dev/null || true
}

die() {
    log_error "$@"
    exit 1
}

check_rescue_mode() {
    if [ ! -f /etc/hetzner-rescue ]; then
        # Alternative check
        if ! grep -qi "rescue" /etc/hostname 2>/dev/null && \
           ! grep -qi "rescue" /proc/version 2>/dev/null; then
            log_warn "This doesn't appear to be a Hetzner rescue system."
            log_warn "The script is designed for Hetzner rescue mode."
            if [ "${SKIP_CONFIRM:-0}" != "1" ]; then
                read -rp "Continue anyway? (y/N): " confirm
                [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || die "Aborted."
            fi
        fi
    fi
}

interactive_wizard() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           Interactive Installation Wizard                   ║"
    echo "║     Answer a few questions to configure the installation    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Auto-detect IP
    local detected_ip
    detected_ip=$(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1) || true
    
    echo -e "  Detected server IP: ${GREEN}${detected_ip:-none}${NC}"
    read -rp "  Server IP [$detected_ip]: " input_ip
    SERVER_IP="${input_ip:-$detected_ip}"
    
    # Auto-detect gateway
    local detected_gw
    detected_gw=$(ip route | grep default | awk '{print $3}' | head -1) || true
    
    echo -e "  Detected gateway:   ${GREEN}${detected_gw:-none}${NC}"
    read -rp "  Gateway [$detected_gw]: " input_gw
    GATEWAY="${input_gw:-$detected_gw}"
    
    # Password
    echo ""
    read -rp "  Administrator password (empty = auto-generate): " input_pass
    ADMIN_PASSWORD="${input_pass:-}"
    
    # Disk selection
    echo ""
    log_info "Available disks:"
    while read -r disk _size_bytes; do
        [ -n "$disk" ] || continue
        echo -e "    ${GREEN}$(lsblk -dpno NAME,SIZE,MODEL "$disk")${NC}"
    done < <(get_candidate_disks)
    echo ""
    
    local first_disk
    first_disk=$(get_candidate_disks | awk 'NR==1 {print $1}')
    local second_disk
    second_disk=$(get_candidate_disks | awk 'NR==2 {print $1}') || true
    
    read -rp "  Target disk for Windows [$first_disk]: " input_target
    TARGET_DISK="${input_target:-$first_disk}"
    
    if [ -n "$second_disk" ]; then
        read -rp "  Work disk for temp files [$second_disk]: " input_work
        WORK_DISK="${input_work:-$second_disk}"
    else
        die "This installer currently requires a second disk for workspace. Single-disk mode is disabled in this version."
    fi
    
    # ISO URL
    echo ""
    echo -e "  Default ISO: Windows Server 2025 Evaluation"
    read -rp "  Custom ISO URL (empty = default): " input_iso
    if [ -n "$input_iso" ]; then
        ISO_URL="$input_iso"
    fi
    
    echo ""
    log_info "Configuration complete. Proceeding with installation..."
    echo ""
}

# Map a command/tool name to one or more Debian/Ubuntu package names.
tool_to_packages() {
    case "$1" in
        wget) echo "wget" ;;
        parted) echo "parted" ;;
        mkfs.ntfs) echo "ntfs-3g" ;;
        wimlib-imagex) echo "wimtools" ;;
        lsblk) echo "util-linux" ;;
        mkfs.fat|mkfs.vfat) echo "dosfstools" ;;
        awk) echo "gawk" ;;
        cut|numfmt) echo "coreutils" ;;
        ip) echo "iproute2" ;;
        python3) echo "python3" ;;
        blkid) echo "util-linux" ;;
        wipefs) echo "util-linux" ;;
        sgdisk) echo "gdisk" ;;
        efibootmgr) echo "efibootmgr" ;;
        *) echo "" ;;
    esac
}

apt_update_with_retries() {
    local attempt
    for attempt in 1 2 3; do
        log_detail "Running apt-get update (attempt $attempt/3)..."
        if apt-get update; then
            return 0
        fi
        log_warn "apt-get update failed (attempt $attempt/3)"
        sleep $((attempt * 2))
    done
    log_error "apt-get update failed after 3 attempts (see log above)"
    return 1
}

apt_install_with_retries() {
    local pkgs=("$@")
    local attempt
    [ ${#pkgs[@]} -gt 0 ] || return 0

    for attempt in 1 2 3; do
        log_detail "apt-get install -y ${pkgs[*]} (attempt $attempt/3)..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"; then
            return 0
        fi
        log_warn "apt-get install failed (attempt $attempt/3)"
        sleep $((attempt * 2))
        apt-get update || true
    done
    log_error "apt-get install failed for: ${pkgs[*]}"
    return 1
}

refresh_command_hash() {
    hash -r 2>/dev/null || true
    export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
}

install_wimlib_from_debian_debs() {
    log_info "Attempting wimlib install from Debian .deb packages..."
    local tmpdir
    tmpdir=$(mktemp -d /tmp/wimlib-debs.XXXXXX)
    # Older pair first — better chance on older rescue glibc; then newer t64 pair.
    local pairs=(
        "libwim15_1.13.6-1_amd64.deb wimtools_1.13.6-1_amd64.deb"
        "libwim15t64_1.14.4-1.1+b3_amd64.deb wimtools_1.14.4-1.1+b3_amd64.deb"
    )
    local pair lib_deb tools_deb
    for pair in "${pairs[@]}"; do
        lib_deb=${pair%% *}
        tools_deb=${pair#* }
        log_detail "Trying $lib_deb + $tools_deb"
        rm -f "$tmpdir"/*.deb 2>/dev/null || true
        if ! wget -q -O "$tmpdir/$lib_deb" "$DEBIAN_WIMLIB_POOL/$lib_deb"; then
            log_warn "Download failed: $lib_deb"
            continue
        fi
        if ! wget -q -O "$tmpdir/$tools_deb" "$DEBIAN_WIMLIB_POOL/$tools_deb"; then
            log_warn "Download failed: $tools_deb"
            continue
        fi
        if dpkg -i "$tmpdir/$lib_deb" "$tmpdir/$tools_deb"; then
            apt-get install -f -y || true
            refresh_command_hash
            if command -v wimlib-imagex &>/dev/null; then
                log_info "wimlib-imagex installed from Debian debs ($tools_deb)"
                rm -rf "$tmpdir"
                return 0
            fi
        else
            log_warn "dpkg -i failed for $tools_deb; trying apt -f and next pair..."
            apt-get install -f -y || true
            refresh_command_hash
            if command -v wimlib-imagex &>/dev/null; then
                log_info "wimlib-imagex available after apt -f repair"
                rm -rf "$tmpdir"
                return 0
            fi
        fi
    done
    rm -rf "$tmpdir"
    return 1
}

build_wimlib_from_source() {
    log_info "Building wimlib from source ($WIMLIB_SRC_URL)..."
    local build_deps=(build-essential pkg-config make gcc)
    local optional_deps=(libfuse-dev libxml2-dev ntfs-3g-dev libattr1-dev libssl-dev)
    apt_install_with_retries "${build_deps[@]}" || log_warn "Some build-essential packages failed to install"
    apt_install_with_retries "${optional_deps[@]}" || log_warn "Optional wimlib build deps missing; configure may still succeed"

    local tmpdir tarball srcdir
    tmpdir=$(mktemp -d /tmp/wimlib-src.XXXXXX)
    tarball="$tmpdir/wimlib.tar.gz"
    if ! wget -O "$tarball" "$WIMLIB_SRC_URL"; then
        log_warn "Primary wimlib tarball failed; trying 1.14.5..."
        if ! wget -O "$tarball" "https://wimlib.net/downloads/wimlib-1.14.5.tar.gz"; then
            rm -rf "$tmpdir"
            return 1
        fi
    fi

    tar -xzf "$tarball" -C "$tmpdir" || { rm -rf "$tmpdir"; return 1; }
    srcdir=$(find "$tmpdir" -maxdepth 1 -type d -name 'wimlib-*' | head -1)
    if [ -z "$srcdir" ] || [ ! -d "$srcdir" ]; then
        log_error "Could not locate extracted wimlib source directory"
        rm -rf "$tmpdir"
        return 1
    fi

    (
        cd "$srcdir"
        ./configure --prefix=/usr/local
        make -j"$(nproc 2>/dev/null || echo 2)"
        make install
    ) || { rm -rf "$tmpdir"; return 1; }

    refresh_command_hash
    rm -rf "$tmpdir"
    if command -v wimlib-imagex &>/dev/null; then
        log_info "wimlib-imagex built and installed to $(command -v wimlib-imagex)"
        return 0
    fi
    if [ -x /usr/local/bin/wimlib-imagex ]; then
        ln -sf /usr/local/bin/wimlib-imagex /usr/bin/wimlib-imagex 2>/dev/null || true
        refresh_command_hash
    fi
    command -v wimlib-imagex &>/dev/null
}

ensure_wimlib() {
    refresh_command_hash
    if command -v wimlib-imagex &>/dev/null; then
        return 0
    fi

    log_warn "wimlib-imagex still missing after apt — trying Debian .deb fallback..."
    if install_wimlib_from_debian_debs; then
        return 0
    fi

    log_warn "Debian .deb fallback failed — building wimlib from source..."
    if build_wimlib_from_source; then
        return 0
    fi

    return 1
}

# Install each package individually so one missing name (e.g. ms-sys) cannot
# abort the entire recommended set. Always returns 0 — callers must re-check
# required tools explicitly (never let an optional miss block required pkgs).
apt_install_each() {
    local pkg
    for pkg in "$@"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            continue
        fi
        if ! apt_install_with_retries "$pkg"; then
            log_warn "Package unavailable (continuing): $pkg"
        fi
    done
    return 0
}

# Prevent grub-pc apt install from hanging on interactive device selection.
preseed_grub_pc_debconf() {
    if ! command -v debconf-set-selections &>/dev/null; then
        return 0
    fi
    debconf-set-selections <<'EOF' 2>/dev/null || true
grub-pc grub-pc/install_devices multiselect
grub-pc grub-pc/install_devices_empty boolean true
grub-pc grub-pc/install_devices_failed boolean true
EOF
}

ensure_hivexsh() {
    refresh_command_hash
    if command -v hivexsh &>/dev/null; then
        return 0
    fi
    log_detail "Installing libhivex-bin (VirtIO SYSTEM hive registration)..."
    apt_update_with_retries || true
    apt_install_with_retries libhivex-bin || true
    refresh_command_hash
    if command -v hivexsh &>/dev/null; then
        return 0
    fi
    apt_install_with_retries libhivex0 libhivex-bin || true
    refresh_command_hash
    command -v hivexsh &>/dev/null
}

ensure_python_hivex() {
    if python3 -c 'import hivex' >/dev/null 2>&1; then
        return 0
    fi
    log_detail "Installing python3-hivex (preferred VirtIO SYSTEM hive editor)..."
    apt_update_with_retries || true
    apt_install_with_retries python3-hivex || true
    apt_install_with_retries python3 libhivex0 || true
    refresh_command_hash
    python3 -c 'import hivex' >/dev/null 2>&1
}

# Install hive editors BEFORE any destructive disk work on Cloud/KVM.
# Prefers python3-hivex; requires at least one of python3-hivex or hivexsh.
ensure_virtio_hive_tools() {
    local have_py=0 have_sh=0
    ensure_python_hivex && have_py=1 || true
    ensure_hivexsh && have_sh=1 || true

    if [ "$have_py" = "1" ]; then
        log_detail "VirtIO hive editor: python3-hivex (preferred)"
    fi
    if [ "$have_sh" = "1" ]; then
        log_detail "VirtIO hive editor: hivexsh at $(command -v hivexsh)"
    fi

    if [ "$have_py" = "1" ] || [ "$have_sh" = "1" ]; then
        return 0
    fi
    return 1
}

check_dependencies() {
    log_step "Checking dependencies..."
    refresh_command_hash

    local deps=(wget parted mkfs.ntfs wimlib-imagex lsblk mkfs.fat awk cut ip python3 blkid numfmt)
    # Core set — must exist on Debian bookworm rescue. Do NOT include ms-sys
    # (not in bookworm); it is attempted separately as optional.
    local core_pkgs=(
        wget parted ntfs-3g wimtools dosfstools gdisk
        grub-pc grub-pc-bin grub2-common grub-efi-amd64-bin
        efibootmgr libhivex-bin python3-hivex
        util-linux iproute2 python3 ca-certificates
    )
    # ms-sys is not in Debian bookworm — never apt-install it (wastes retries).
    local optional_pkgs=()
    local missing=()
    local dep pkgs

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_info "Missing tools: ${missing[*]}"
    else
        log_info "Core tools present — ensuring boot/VirtIO helper packages..."
    fi

    if ! apt_update_with_retries; then
        log_warn "apt-get update failed; will still attempt package install and offline fallbacks"
    fi

    # Avoid interactive grub-pc prompts hanging noninteractive rescue installs.
    preseed_grub_pc_debconf

    # Install one-by-one so a single unavailable package cannot block hivex/grub.
    apt_install_each "${core_pkgs[@]}"

    # Retry explicitly for any still-missing required tools.
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            pkgs=$(tool_to_packages "$dep")
            if [ -n "$pkgs" ]; then
                # shellcheck disable=SC2086
                apt_install_with_retries $pkgs || log_warn "Could not apt-install packages for '$dep': $pkgs"
            fi
        fi
    done

    # Optional BIOS helper (not in Debian bookworm — ignore failure; GRUB ntldr covers BIOS).
    apt_install_each "${optional_pkgs[@]}"

    refresh_command_hash

    # Critical fallback for wimlib (often missing on slim rescue images).
    if ! command -v wimlib-imagex &>/dev/null; then
        ensure_wimlib || die "Required tool 'wimlib-imagex' not found after apt, Debian .deb, and source-build fallbacks. Check $LOG_FILE and network/apt mirrors."
    fi

    # Cloud: hive tools + grub MUST be present before any disk wipe.
    if is_virtual_machine; then
        ensure_virtio_hive_tools || die "Neither python3-hivex nor hivexsh (libhivex-bin) could be installed — required on Cloud/KVM for VirtIO boot-start registration. See apt errors in $LOG_FILE."
    else
        if ensure_virtio_hive_tools; then
            :
        else
            log_warn "hivex tools unavailable — VirtIO SYSTEM hive registration will be skipped on bare-metal"
        fi
    fi

    preseed_grub_pc_debconf
    if ! command -v grub-install &>/dev/null; then
        ensure_grub_pc || true
    fi
    if command -v grub-install &>/dev/null; then
        log_detail "grub-install: $(command -v grub-install)"
    else
        log_warn "grub-install missing — Legacy BIOS path will fail preflight if BOOT_MODE=bios"
    fi

    if command -v ms-sys &>/dev/null; then
        log_detail "ms-sys: $(command -v ms-sys)"
    else
        log_detail "ms-sys not available (OK — GRUB ntldr is the primary BIOS path)"
    fi

    local still_missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            still_missing+=("$dep")
        fi
    done

    if [ ${#still_missing[@]} -gt 0 ]; then
        for dep in "${still_missing[@]}"; do
            pkgs=$(tool_to_packages "$dep")
            log_error "Required tool '$dep' still missing (tried apt packages: ${pkgs:-unknown})"
        done
        die "Missing required tools after install attempts: ${still_missing[*]}. See apt output in $LOG_FILE."
    fi

    log_info "All dependencies satisfied (wimlib-imagex: $(command -v wimlib-imagex))."
}

detect_network() {
    log_step "Detecting network configuration..."
    local primary_addr

    primary_addr=$(ip -o -4 addr show scope global | awk 'NR==1 {print $2 " " $4}')
    if [ -z "$primary_addr" ]; then
        die "Could not detect IPv4 address from rescue environment."
    fi

    local cidr
    cidr=$(awk '{print $2}' <<< "$primary_addr")

    if [ -z "${SERVER_IP:-}" ]; then
        SERVER_IP="${cidr%/*}"
    fi

    if [ -z "${SUBNET_PREFIX:-}" ]; then
        SUBNET_PREFIX="${cidr#*/}"
    fi

    SUBNET_MASK=$(prefix_to_netmask "$SUBNET_PREFIX")

    if [ -z "${GATEWAY:-}" ]; then
        GATEWAY=$(ip route show default | awk 'NR==1 {print $3}')
    fi

    if [ "$SUBNET_PREFIX" = "32" ]; then
        NETWORK_MODE="point-to-point"
    else
        NETWORK_MODE="standard"
    fi
    
    if [ -z "$SERVER_IP" ]; then
        die "Could not detect server IP. Use --ip to specify."
    fi
    
    if [ -z "$GATEWAY" ]; then
        die "Could not detect gateway. Use --gateway to specify."
    fi

    if ! is_valid_ipv4 "$SERVER_IP"; then
        die "Invalid server IP format: $SERVER_IP"
    fi
    if ! is_valid_ipv4 "$GATEWAY"; then
        die "Invalid gateway format: $GATEWAY"
    fi
    
    log_detail "Server IP:  $SERVER_IP"
    log_detail "Gateway:    $GATEWAY"
    log_detail "Subnet:     $SUBNET_MASK (/$SUBNET_PREFIX)"
    log_detail "Mode:       $NETWORK_MODE"
}

detect_disks() {
    log_step "Detecting disk configuration..."

    mapfile -t ALL_DISKS < <(get_candidate_disks | awk '{print $1}')
    
    if [ ${#ALL_DISKS[@]} -eq 0 ]; then
        die "No disks detected!"
    fi
    
    log_info "Detected disks:"
    for disk in "${ALL_DISKS[@]}"; do
        local size model stable
        size=$(lsblk -dpno SIZE "$disk" 2>/dev/null || echo "unknown")
        model=$(lsblk -dpno MODEL "$disk" 2>/dev/null || echo "unknown")
        stable=$(disk_stable_id "$disk")
        log_detail "$disk - Size: $size - Model: $model - ID: $stable"
    done
    
    if [ ${#ALL_DISKS[@]} -lt 2 ]; then
        die "This installer currently requires 2 physical disks: one target disk and one workspace disk (e.g. Cloud root disk + Volume). Single-disk mode is not supported safely in this version."
    fi

    # Prefer stable by-id from resume state (survives sda/sdb letter swaps).
    local resolved
    if [ -n "${TARGET_DISK_ID:-}" ]; then
        if resolved=$(resolve_disk_device "$TARGET_DISK_ID"); then
            if [ -n "${TARGET_DISK:-}" ] && [ "$(readlink -f "$TARGET_DISK" 2>/dev/null || true)" != "$resolved" ]; then
                log_warn "Target path changed after reboot (${TARGET_DISK} → ${resolved}); using stable id."
            fi
            TARGET_DISK="$resolved"
            log_detail "Resolved target from stable id: $TARGET_DISK_ID → $TARGET_DISK"
        else
            log_warn "Saved TARGET_DISK_ID not found ($TARGET_DISK_ID); falling back to path/auto-select."
            TARGET_DISK_ID=""
        fi
    fi
    if [ -n "${WORK_DISK_ID:-}" ]; then
        if resolved=$(resolve_disk_device "$WORK_DISK_ID"); then
            if [ -n "${WORK_DISK:-}" ] && [ "$(readlink -f "$WORK_DISK" 2>/dev/null || true)" != "$resolved" ]; then
                log_warn "Work path changed after reboot (${WORK_DISK} → ${resolved}); using stable id."
            fi
            WORK_DISK="$resolved"
            log_detail "Resolved work from stable id: $WORK_DISK_ID → $WORK_DISK"
        else
            log_warn "Saved WORK_DISK_ID not found ($WORK_DISK_ID); falling back to path/auto-select."
            WORK_DISK_ID=""
        fi
    fi

    # Resolve explicit /dev paths or by-id strings from CLI / stale state paths.
    if [ -n "${TARGET_DISK:-}" ]; then
        resolved=$(resolve_disk_device "$TARGET_DISK") || die "Target disk does not exist: $TARGET_DISK"
        TARGET_DISK="$resolved"
    fi
    if [ -n "${WORK_DISK:-}" ]; then
        resolved=$(resolve_disk_device "$WORK_DISK") || die "Work disk does not exist: $WORK_DISK"
        WORK_DISK="$resolved"
    fi

    local size0 size1
    size0=$(disk_size_bytes "${ALL_DISKS[0]}")
    size1=$(disk_size_bytes "${ALL_DISKS[1]}")

    # Select by size: largest = Windows target, second-largest = workspace.
    # Refuse ambiguous equal-size auto-select (would risk wiping the wrong disk).
    if [ -z "${TARGET_DISK:-}" ] && [ -z "${WORK_DISK:-}" ]; then
        if [ "$size0" -eq "$size1" ]; then
            die "Top two disks are the same size ($(numfmt --to=iec "$size0" 2>/dev/null || echo "$size0")). Refusing auto-select to avoid wiping the wrong disk. Pass --target-disk and --work-disk explicitly (prefer /dev/disk/by-id/...)."
        fi
        TARGET_DISK="${ALL_DISKS[0]}"
        WORK_DISK="${ALL_DISKS[1]}"
        log_detail "Auto-selected largest disk as target: $TARGET_DISK"
        log_detail "Auto-selected second-largest disk as workspace: $WORK_DISK"
    elif [ -z "${TARGET_DISK:-}" ]; then
        for disk in "${ALL_DISKS[@]}"; do
            if [ "$(readlink -f "$disk")" != "$(readlink -f "$WORK_DISK")" ]; then
                TARGET_DISK="$disk"
                break
            fi
        done
        [ -n "${TARGET_DISK:-}" ] || die "Could not auto-select a target disk distinct from work disk $WORK_DISK"
        log_detail "Auto-selected target disk (excluding work): $TARGET_DISK"
    elif [ -z "${WORK_DISK:-}" ]; then
        for disk in "${ALL_DISKS[@]}"; do
            if [ "$(readlink -f "$disk")" != "$(readlink -f "$TARGET_DISK")" ]; then
                WORK_DISK="$disk"
                break
            fi
        done
        [ -n "${WORK_DISK:-}" ] || die "Could not auto-select a work disk distinct from target disk $TARGET_DISK"
        log_detail "Auto-selected work disk (excluding target): $WORK_DISK"
    fi
    
    if [ "$(readlink -f "$TARGET_DISK")" = "$(readlink -f "$WORK_DISK")" ]; then
        die "Target disk and work disk cannot be the same device: $TARGET_DISK"
    fi

    if [ ! -b "$TARGET_DISK" ]; then
        die "Target disk does not exist: $TARGET_DISK"
    fi
    if [ ! -b "$WORK_DISK" ]; then
        die "Work disk does not exist: $WORK_DISK"
    fi

    TARGET_DISK_ID=$(disk_stable_id "$TARGET_DISK")
    WORK_DISK_ID=$(disk_stable_id "$WORK_DISK")

    local target_size work_size
    target_size=$(disk_size_bytes "$TARGET_DISK")
    work_size=$(disk_size_bytes "$WORK_DISK")

    # Warn if someone overrode disks and target is smaller than work (common sda/sdb swap mistake)
    if [ "$target_size" -lt "$work_size" ]; then
        log_warn "Target disk ($TARGET_DISK) is smaller than work disk ($WORK_DISK)."
        log_warn "On Hetzner Cloud, Windows should usually go on the larger root disk."
    fi

    [ "$target_size" -ge "$MIN_TARGET_DISK_BYTES" ] || \
        die "Target disk is too small for Windows Server: $TARGET_DISK ($(numfmt --to=iec "$target_size" 2>/dev/null || echo "$target_size"))"
    [ "$work_size" -ge "$MIN_WORK_DISK_BYTES" ] || \
        die "Work disk is too small for ISO workspace: $WORK_DISK ($(numfmt --to=iec "$work_size" 2>/dev/null || echo "$work_size"))"

    # Cloud Volumes are not firmware-bootable — Windows must sit on the instance disk.
    if is_hetzner_cloud_volume "$TARGET_DISK"; then
        die "Target disk $TARGET_DISK looks like a Hetzner Cloud Volume (not firmware-bootable). Put Windows on the instance disk (QEMU HARDDISK) and use the Volume as --work-disk."
    fi
    if is_virtual_machine && is_hetzner_cloud_volume "$WORK_DISK"; then
        log_detail "Work disk is a Cloud Volume (expected for ISO workspace)"
    fi

    log_detail "Target disk (Windows): $TARGET_DISK ($TARGET_DISK_ID)"
    log_detail "Work disk (temp):      $WORK_DISK ($WORK_DISK_ID)"
}

detect_boot_mode() {
    log_step "Detecting boot mode..."
    
    if [ -n "${FORCE_UEFI:-}" ]; then
        BOOT_MODE="uefi"
    elif [ -n "${FORCE_BIOS:-}" ]; then
        BOOT_MODE="bios"
        if is_virtual_machine; then
            log_warn "Legacy BIOS forced on Cloud/KVM via --bios."
        fi
    elif is_virtual_machine; then
        if [ -d /sys/firmware/efi ]; then
            BOOT_MODE="uefi"
            log_detail "Cloud/KVM detected — using UEFI"
        else
            # Guaranteed Legacy path (GRUB on instance + Volume). No --bios flag required.
            BOOT_MODE="bios"
            log_warn "Cloud/KVM Legacy BIOS detected — enabling guaranteed GRUB ntldr boot path."
            log_warn "Tip: enable UEFI in Cloud Console when possible for the simplest boot chain."
        fi
    elif [ -d /sys/firmware/efi ]; then
        BOOT_MODE="uefi"
    else
        BOOT_MODE="bios"
    fi
    
    log_detail "Boot mode: ${BOOT_MODE^^}"
}

# Fail BEFORE wiping disks if Legacy BIOS cannot be made bootable.
preflight_legacy_guaranteed() {
    [ "${BOOT_MODE:-}" = "bios" ] || return 0

    log_step "Legacy BIOS guaranteed-boot preflight..."

    preseed_grub_pc_debconf
    ensure_grub_pc || die "grub-install (grub-pc) is required for guaranteed Legacy BIOS boot and could not be installed. See apt errors in $LOG_FILE."
    log_detail "grub-install OK: $(command -v grub-install)"

    # Cloud Legacy: hive editors must exist before wipe (python3-hivex preferred).
    if is_virtual_machine; then
        ensure_virtio_hive_tools || die "python3-hivex or hivexsh required on Cloud Legacy BIOS for VirtIO boot-start drivers — install failed. See $LOG_FILE."
    fi

    # ms-sys is not in Debian bookworm — do not apt-retry it (noise). GRUB path is enough.
    if command -v ms-sys &>/dev/null; then
        log_detail "ms-sys OK (optional VBR helper)"
    else
        log_detail "ms-sys unavailable — OK, GRUB ntldr does not need it"
    fi

    log_info "Legacy BIOS preflight passed (GRUB + VirtIO hive tools armed before wipe)."
}

preflight_health_check() {
    log_step "Pre-flight health check..."

    local mem_kb mem_bytes mem_human
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    mem_bytes=$((mem_kb * 1024))
    mem_human=$(numfmt --to=iec "$mem_bytes" 2>/dev/null || echo "${mem_kb}K")

    if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 2000000 ]; then
        die "Only ~${mem_human} RAM detected. Need at least ~2GB to apply a Windows Server image."
    elif [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 3600000 ]; then
        log_warn "RAM is ~${mem_human} (< ~3.5GB). Install may be slow or fail on large WIMs."
    else
        log_detail "RAM: ${mem_human}"
    fi

    local disk_count
    disk_count=$(get_candidate_disks | wc -l)
    if [ "$disk_count" -lt 2 ]; then
        die "Pre-flight: need at least 2 disks (found $disk_count). Attach a Volume on Cloud or use a second drive."
    fi
    log_detail "Disks: $disk_count candidates"

    local net_ok=0
    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 \
        || ping -c 1 -W 3 "$DNS_PRIMARY" >/dev/null 2>&1; then
        net_ok=1
        log_detail "Network: ICMP reachability OK"
    else
        # ping may be blocked; try TCP/HTTP to a known host
        if wget -q --spider --timeout=8 https://deb.debian.org 2>/dev/null \
            || wget -q --spider --timeout=8 https://1.1.1.1 2>/dev/null; then
            net_ok=1
            log_detail "Network: HTTP reachability OK"
        fi
    fi
    if [ "$net_ok" != "1" ]; then
        die "Pre-flight: no network reachability to 1.1.1.1 / $DNS_PRIMARY / deb.debian.org"
    fi

    local dns_ok=0
    if getent hosts deb.debian.org >/dev/null 2>&1; then
        dns_ok=1
    elif python3 -c 'import socket; socket.getaddrinfo("deb.debian.org", 80)' >/dev/null 2>&1; then
        dns_ok=1
    fi
    if [ "$dns_ok" = "1" ]; then
        log_detail "DNS: resolution OK"
    else
        die "Pre-flight: DNS resolution failed (tried getent/python for deb.debian.org)"
    fi

    if is_virtual_machine; then
        PLATFORM_TYPE="Cloud/KVM"
        log_detail "Platform: Cloud / virtual machine (VirtIO drivers required)"
    else
        PLATFORM_TYPE="Dedicated/Bare-metal"
        log_detail "Platform: Dedicated / bare-metal"
    fi

    log_info "Pre-flight checks passed ($PLATFORM_TYPE)."
}

assign_partition_vars() {
    if [ "${BOOT_MODE:-}" = "uefi" ]; then
        EFI_PART=$(partition_path "$TARGET_DISK" 1)
        WIN_PART=$(partition_path "$TARGET_DISK" 3)
        BOOT_PART=""
    else
        BOOT_PART=$(partition_path "$TARGET_DISK" 1)
        WIN_PART=$(partition_path "$TARGET_DISK" 2)
        EFI_PART=""
    fi
}

windows_image_present() {
    assign_partition_vars
    [ -n "${WIN_PART:-}" ] && [ -b "$WIN_PART" ] || return 1
    mkdir -p "$MOUNT_TARGET"
    if ! mountpoint -q "$MOUNT_TARGET" 2>/dev/null; then
        mount "$WIN_PART" "$MOUNT_TARGET" 2>/dev/null || return 1
    fi
    [ -f "$MOUNT_TARGET/Windows/System32/ntoskrnl.exe" ]
}

evaluate_resume_options() {
    SKIP_WORKSPACE_WIPE=0
    SKIP_PARTITION=0
    SKIP_WIM_APPLY=0

    if [ "${FORCE_CLEAN:-0}" = "1" ] || [ "${RESUME_MODE:-0}" != "1" ]; then
        return 0
    fi

    log_step "Evaluating resume options from previous run..."

    local work_part iso_path iso_size
    work_part=$(find_work_partition "$WORK_DISK" 2>/dev/null || true)
    if [ -n "$work_part" ] && [ -b "$work_part" ]; then
        mkdir -p "$MOUNT_WORK"
        if mount "$work_part" "$MOUNT_WORK" 2>/dev/null; then
            iso_path="$MOUNT_WORK/windows.iso"
            if [ -f "$iso_path" ]; then
                iso_size=$(stat -c%s "$iso_path" 2>/dev/null || echo 0)
                if [ "$iso_size" -ge 2000000000 ]; then
                    SKIP_WORKSPACE_WIPE=1
                    WORK_PART="$work_part"
                    ISO_PATH="$iso_path"
                    log_info "Resume: reusable ISO on work disk ($(numfmt --to=iec "$iso_size")) — skipping workspace wipe"
                fi
            fi
            if [ "$SKIP_WORKSPACE_WIPE" != "1" ]; then
                umount "$MOUNT_WORK" 2>/dev/null || true
            fi
        fi
    fi

    if windows_image_present; then
        SKIP_PARTITION=1
        SKIP_WIM_APPLY=1
        log_info "Resume: Windows image present at $WIN_PART (ntoskrnl.exe found) — skipping partition wipe and WIM apply"
        log_info "Resume: configuration and bootloader steps will still re-run"
    else
        umount "$MOUNT_TARGET" 2>/dev/null || true
        log_detail "No usable Windows image on target; full apply path will run"
    fi
}

send_completion_notify() {
    local token="${TELEGRAM_BOT_TOKEN:-}"
    local chat="${TELEGRAM_CHAT_ID:-}"
    local webhook="${DISCORD_WEBHOOK_URL:-}"

    if [ -z "$token" ] && [ -z "$webhook" ]; then
        return 0
    fi

    log_step "Sending completion notification..."
    local msg
    msg=$(cat <<EOF
Windows Server 2025 install complete
IP: ${SERVER_IP}
RDP: ${SERVER_IP}:3389
User: Administrator
Password: ${ADMIN_PASSWORD}
EOF
)

    if [ -n "$token" ] && [ -n "$chat" ]; then
        if python3 - "$token" "$chat" "$msg" <<'PY' 2>/dev/null; then
import json, sys, urllib.parse, urllib.request
token, chat, text = sys.argv[1], sys.argv[2], sys.argv[3]
url = f"https://api.telegram.org/bot{token}/sendMessage"
data = urllib.parse.urlencode({"chat_id": chat, "text": text}).encode()
req = urllib.request.Request(url, data=data, method="POST")
urllib.request.urlopen(req, timeout=15).read()
print("ok")
PY
            log_detail "Telegram notification sent"
        else
            log_warn "Telegram notification failed (install continues)"
        fi
    elif [ -n "$token" ] || [ -n "$chat" ]; then
        log_warn "Telegram notify skipped: need both token and chat id"
    fi

    if [ -n "$webhook" ]; then
        if python3 - "$webhook" "$msg" <<'PY' 2>/dev/null; then
import json, sys, urllib.request
webhook, text = sys.argv[1], sys.argv[2]
payload = json.dumps({"content": text[:1900]}).encode()
req = urllib.request.Request(
    webhook,
    data=payload,
    headers={"Content-Type": "application/json", "User-Agent": "hetzner-win-installer"},
    method="POST",
)
urllib.request.urlopen(req, timeout=15).read()
print("ok")
PY
            log_detail "Discord notification sent"
        else
            log_warn "Discord notification failed (install continues)"
        fi
    fi
}

show_admin_password() {
    local reason="${1:-Administrator password}"
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ${reason}${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  Username:  ${GREEN}Administrator${NC}"
    echo -e "${YELLOW}║${NC}  Password:  ${GREEN}${ADMIN_PASSWORD}${NC}"
    echo -e "${YELLOW}║${NC}  RDP:       ${GREEN}${SERVER_IP:-(auto)}:3389${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${CYAN}>>> COPY THIS PASSWORD NOW <<<${NC}"
    echo -e "  ${CYAN}${ADMIN_PASSWORD}${NC}"
    echo ""
}

generate_password() {
    # Generate a secure random password if not provided
    PASSWORD_AUTO_GENERATED=0
    if [ -z "${ADMIN_PASSWORD:-}" ]; then
        ADMIN_PASSWORD=$(python3 - <<'PY'
import secrets
alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%'
print(''.join(secrets.choice(alphabet) for _ in range(16)))
PY
)
        PASSWORD_AUTO_GENERATED=1
        show_admin_password "AUTO-GENERATED PASSWORD — SAVE THIS"
    else
        show_admin_password "Administrator password"
    fi
}

confirm_settings() {
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Installation Summary${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════${NC}"
    echo -e "  Server IP:        ${GREEN}$SERVER_IP${NC}"
    echo -e "  Gateway:          ${GREEN}$GATEWAY${NC}"
    echo -e "  Admin Password:   ${GREEN}$ADMIN_PASSWORD${NC}"
    echo -e "  Target Disk:      ${GREEN}$TARGET_DISK${NC}"
    echo -e "  Target Disk ID:   ${GREEN}${TARGET_DISK_ID:-n/a}${NC}"
    echo -e "  Work Disk:        ${GREEN}$WORK_DISK${NC}"
    echo -e "  Work Disk ID:     ${GREEN}${WORK_DISK_ID:-n/a}${NC}"
    echo -e "  Boot Mode:        ${GREEN}${BOOT_MODE^^}${NC}"
    echo -e "  Network Mode:     ${GREEN}${NETWORK_MODE}${NC}"
    echo -e "  Subnet Mask:      ${GREEN}${SUBNET_MASK}${NC}"
    echo -e "  Platform:         ${GREEN}${PLATFORM_TYPE:-unknown}${NC}"
    local iso_display="$ISO_URL"
    [ ${#iso_display} -gt 60 ] && iso_display="${ISO_URL:0:57}..."
    echo -e "  ISO URL:          ${GREEN}${iso_display}${NC}"
    if [ "${RESUME_MODE:-0}" = "1" ]; then
        echo -e "  Resume:           ${GREEN}yes (stage=${STAGE:-unknown})${NC}"
        echo -e "  Skip work wipe:   ${GREEN}${SKIP_WORKSPACE_WIPE:-0}${NC}"
        echo -e "  Skip WIM apply:   ${GREEN}${SKIP_WIM_APPLY:-0}${NC}"
    fi
    echo -e "${YELLOW}════════════════════════════════════════════════════${NC}"
    echo ""
    if [ "${SKIP_PARTITION:-0}" = "1" ]; then
        echo -e "${YELLOW}  Resume mode: target disk will NOT be wiped (Windows image present).${NC}"
    else
        echo -e "${RED}  ⚠ WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED!${NC}"
    fi
    echo ""
    
    if [ "${SKIP_CONFIRM:-0}" != "1" ]; then
        read -rp "Proceed with installation? (yes/NO): " confirm
        [ "$confirm" = "yes" ] || die "Installation aborted by user."
    fi
}

prepare_work_disk() {
    log_step "Preparing work disk..."

    if [ "${SKIP_WORKSPACE_WIPE:-0}" = "1" ]; then
        if [ -z "${WORK_PART:-}" ] || [ ! -b "${WORK_PART:-}" ]; then
            WORK_PART=$(find_work_partition "$WORK_DISK") || die "Failed to locate existing workspace partition on $WORK_DISK"
        fi
        mkdir -p "$MOUNT_WORK"
        if ! mountpoint -q "$MOUNT_WORK" 2>/dev/null; then
            mount "$WORK_PART" "$MOUNT_WORK" || die "Failed to remount existing workspace ($WORK_PART)"
        fi
        log_info "Reusing existing workspace at $MOUNT_WORK ($WORK_PART)"
        set_stage "workspace"
        return
    fi
    
    # Unmount any existing mounts on work disk
    umount "${WORK_DISK}"* 2>/dev/null || true

    # Wipe and format the entire work disk.
    # On Legacy BIOS, reserve a tiny bios_grub partition so GRUB i386-pc can embed
    # reliably on GPT (Cloud Volume often becomes BIOS hd0).
    wipefs -a "$WORK_DISK" 2>/dev/null || true
    parted -s "$WORK_DISK" mklabel gpt
    if [ "${BOOT_MODE:-}" = "bios" ]; then
        parted -s "$WORK_DISK" mkpart primary 1MiB 2MiB
        parted -s "$WORK_DISK" set 1 bios_grub on
        parted -s "$WORK_DISK" mkpart primary ntfs 2MiB 100%
        # Explicit: workspace is ALWAYS partition 2 with this layout (never bios_grub p1).
        WORK_PART=$(partition_path "$WORK_DISK" 2)
    else
        parted -s "$WORK_DISK" mkpart primary ntfs 1MiB 100%
        WORK_PART=$(partition_path "$WORK_DISK" 1)
    fi
    partprobe "$WORK_DISK" 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || sleep 3
    wait_for_block_dev "$WORK_PART" "$WORK_DISK" 30 || die "Workspace partition $WORK_PART did not appear after partitioning $WORK_DISK"
    # Guard against ever formatting bios_grub (~1MiB)
    local work_size
    work_size=$(lsblk -dbno SIZE "$WORK_PART" 2>/dev/null || echo 0)
    if [ "$work_size" -lt 104857600 ]; then  # < 100 MiB is never a valid ISO workspace
        die "Refusing to format tiny partition $WORK_PART ($(numfmt --to=iec "$work_size" 2>/dev/null || echo "$work_size")) — likely bios_grub, not workspace"
    fi
    
    log_detail "Formatting workspace partition: $WORK_PART ($(numfmt --to=iec "$work_size" 2>/dev/null || echo "$work_size"))"
    mkfs.ntfs -f -L "WORKSPACE" "$WORK_PART" || die "Failed to format workspace"
    
    mkdir -p "$MOUNT_WORK"
    mount "$WORK_PART" "$MOUNT_WORK" || die "Failed to mount workspace"
    
    log_info "Workspace ready at $MOUNT_WORK"
    set_stage "workspace"
}

download_iso() {
    log_step "Downloading Windows Server ISO..."
    
    local iso_path="$MOUNT_WORK/windows.iso"
    
    if [ -f "$iso_path" ]; then
        local iso_size
        iso_size=$(stat -c%s "$iso_path" 2>/dev/null || echo 0)
        if [ "$iso_size" -gt 1000000000 ]; then
            log_info "ISO already exists ($(numfmt --to=iec "$iso_size")), skipping download."
            ISO_PATH="$iso_path"
            return
        fi
    fi
    
    log_detail "URL: $ISO_URL"
    log_detail "This may take 10-20 minutes depending on network speed..."

    local download_url="$ISO_URL"
    if ! wget -O "$iso_path" "$download_url" \
        --progress=bar:force:noscroll 2>&1; then
        if [ "$ISO_URL" = "$DEFAULT_ISO_URL" ]; then
            log_warn "Primary Microsoft ISO download failed. Retrying with Hetzner mirror..."
            download_url="$HETZNER_ISO_MIRROR_URL"
            log_detail "Mirror URL: $download_url"
            wget -O "$iso_path" "$download_url" \
                --progress=bar:force:noscroll 2>&1 || die "Failed to download ISO from both Microsoft and Hetzner mirror"
        else
            die "Failed to download ISO"
        fi
    fi
    
    local final_size
    final_size=$(stat -c%s "$iso_path")
    if [ "$final_size" -lt 2000000000 ]; then
        die "Downloaded ISO is too small ($(numfmt --to=iec "$final_size")). Expected >2GB. The download may have failed or the URL may be invalid."
    fi
    log_info "ISO downloaded successfully ($(numfmt --to=iec "$final_size")) from $download_url"
    
    ISO_PATH="$iso_path"
}

download_virtio() {
    log_step "Downloading VirtIO drivers..."
    
    local virtio_path="$MOUNT_WORK/virtio-win.iso"
    
    if [ -f "$virtio_path" ]; then
        local vio_size
        vio_size=$(stat -c%s "$virtio_path" 2>/dev/null || echo 0)
        if [ "$vio_size" -gt 100000000 ]; then
            log_info "VirtIO ISO already exists, skipping download."
            VIRTIO_PATH="$virtio_path"
            return
        fi
    fi
    
    wget -O "$virtio_path" "$VIRTIO_ISO_URL" \
        --progress=bar:force:noscroll 2>&1 || {
        if is_virtual_machine; then
            die "VirtIO download failed (required on Hetzner Cloud / KVM)."
        fi
        log_warn "VirtIO download failed. Continuing without VirtIO drivers."
        log_warn "This is fine for most Hetzner bare-metal hardware (non-KVM)."
        VIRTIO_PATH=""
        return
    }
    
    VIRTIO_PATH="$virtio_path"
    log_info "VirtIO drivers downloaded."
}

partition_target_disk() {
    log_step "Partitioning target disk ($TARGET_DISK)..."
    
    # Unmount any existing partitions
    umount "${TARGET_DISK}"* 2>/dev/null || true
    
    # Wipe existing partition table
    wipefs -a "$TARGET_DISK" 2>/dev/null || true
    dd if=/dev/zero of="$TARGET_DISK" bs=1M count=10 2>/dev/null || true
    
    if [ "$BOOT_MODE" = "uefi" ]; then
        log_detail "Creating GPT partition table (UEFI)..."
        parted -s "$TARGET_DISK" mklabel gpt
        
        # EFI System Partition (512MB)
        parted -s "$TARGET_DISK" mkpart "EFI" fat32 1MiB 513MiB
        parted -s "$TARGET_DISK" set 1 esp on
        
        # Microsoft Reserved Partition (16MB)  
        parted -s "$TARGET_DISK" mkpart "MSR" 513MiB 529MiB
        parted -s "$TARGET_DISK" set 2 msftres on
        
        # Windows partition (rest of disk)
        parted -s "$TARGET_DISK" mkpart "Windows" ntfs 529MiB 100%
        
        partprobe "$TARGET_DISK" 2>/dev/null || true
        udevadm settle --timeout=10 2>/dev/null || sleep 3
        
        EFI_PART=$(partition_path "$TARGET_DISK" 1)
        WIN_PART=$(partition_path "$TARGET_DISK" 3)
        
        log_detail "Formatting EFI partition..."
        mkfs.fat -F32 -n "EFI" "$EFI_PART" || die "Failed to format EFI partition"
        
    else
        log_detail "Creating MBR partition table (Legacy BIOS)..."
        parted -s "$TARGET_DISK" mklabel msdos
        
        # System Reserved (500MB, active/boot)
        parted -s "$TARGET_DISK" mkpart primary ntfs 1MiB 501MiB
        parted -s "$TARGET_DISK" set 1 boot on
        
        # Windows partition (rest)
        parted -s "$TARGET_DISK" mkpart primary ntfs 501MiB 100%
        
        partprobe "$TARGET_DISK" 2>/dev/null || true
        udevadm settle --timeout=10 2>/dev/null || sleep 3
        
        BOOT_PART=$(partition_path "$TARGET_DISK" 1)
        WIN_PART=$(partition_path "$TARGET_DISK" 2)
        
        log_detail "Formatting boot partition..."
        mkfs.ntfs -f -L "System Reserved" "$BOOT_PART" || die "Failed to format System Reserved partition"
    fi
    
    log_detail "Formatting Windows partition..."
    mkfs.ntfs -f -L "Windows" "$WIN_PART" || die "Failed to format Windows partition"
    
    log_info "Disk partitioned successfully."
    set_stage "partitioned"
}

extract_windows() {
    log_step "Extracting Windows installation files..."

    if [ "${SKIP_WIM_APPLY:-0}" = "1" ]; then
        assign_partition_vars
        mkdir -p "$MOUNT_TARGET"
        if ! mountpoint -q "$MOUNT_TARGET" 2>/dev/null; then
            mount "$WIN_PART" "$MOUNT_TARGET" || die "Failed to mount existing Windows partition"
        fi
        if [ ! -f "$MOUNT_TARGET/Windows/System32/ntoskrnl.exe" ]; then
            die "Resume expected Windows image at $WIN_PART but ntoskrnl.exe is missing"
        fi
        log_info "Skipping WIM apply — existing Windows image will be reconfigured"
        set_stage "windows_applied"
        return
    fi
    
    # Mount ISO
    mkdir -p "$MOUNT_ISO"
    if ! mountpoint -q "$MOUNT_ISO" 2>/dev/null; then
        mount -o loop,ro "$ISO_PATH" "$MOUNT_ISO" || die "Failed to mount ISO"
    fi
    
    # Mount target Windows partition
    mkdir -p "$MOUNT_TARGET"
    if ! mountpoint -q "$MOUNT_TARGET" 2>/dev/null; then
        mount "$WIN_PART" "$MOUNT_TARGET" || die "Failed to mount target partition"
    fi
    
    # Find the install.wim or install.esd
    local wim_file=""
    if [ -f "$MOUNT_ISO/sources/install.wim" ]; then
        wim_file="$MOUNT_ISO/sources/install.wim"
    elif [ -f "$MOUNT_ISO/sources/install.esd" ]; then
        wim_file="$MOUNT_ISO/sources/install.esd"
    else
        die "Cannot find install.wim or install.esd in ISO"
    fi
    
    log_detail "Found: $(basename "$wim_file")"
    
    # List available images (best-effort; never fail the install on metadata display)
    log_detail "Available Windows editions:"
    wimlib-imagex info "$wim_file" 2>/dev/null | grep -E "^(Index|Name|Description)" | head -40 || true
    
    # Prefer Standard Desktop Experience without parsing "Image Count:" (locale/format fragile).
    # Typical Server 2025 EVAL order: 1=Standard Core, 2=Standard Desktop, 3=DC Core, 4=DC Desktop.
    local image_index
    image_index=$(select_windows_image_index "$wim_file")
    # Keep only a bare index (defense in depth if a log line ever leaks to stdout).
    image_index=$(printf '%s\n' "$image_index" | grep -E '^[0-9]+$' | tail -n1)
    [[ "$image_index" =~ ^[0-9]+$ ]] || die "Could not resolve a Windows image index from $(basename "$wim_file")"
    
    wimlib-imagex info "$wim_file" "$image_index" >/dev/null 2>&1 || die "Selected Windows image index $image_index is not available"
    
    log_detail "Applying image index $image_index to $WIN_PART..."
    wimlib-imagex apply "$wim_file" "$image_index" "$MOUNT_TARGET" || die "Failed to apply Windows image"
    
    log_info "Windows files extracted successfully."
    set_stage "windows_applied"
}

# Pick WIM index: prefer "Standard" Desktop (not Core), else hard-code 2, else 1.
select_windows_image_index() {
    local wim_file="$1"
    local info_out
    info_out=$(wimlib-imagex info "$wim_file" 2>/dev/null) || die "Failed to inspect Windows image metadata"

    # Count Index: lines — more robust than "Image Count:" label parsing
    local indexes
    indexes=$(printf '%s\n' "$info_out" | awk '/^Index:/ {print $2}')
    local num_images
    num_images=$(printf '%s\n' "$indexes" | grep -c '^[0-9]\+$' || true)
    [ "${num_images:-0}" -ge 1 ] || die "No Windows image indexes found in $(basename "$wim_file")"

    # Parse Index/Name pairs and prefer Standard Desktop Experience
    local chosen
    chosen=$(WIM_INFO="$info_out" python3 - <<'PY'
import os, re
text = os.environ.get("WIM_INFO", "")
blocks = re.split(r'(?=^Index:\s*\d+)', text, flags=re.M)
best = None
for block in blocks:
    m = re.search(r'^Index:\s*(\d+)', block, re.M)
    if not m:
        continue
    idx = int(m.group(1))
    name = ""
    nm = re.search(r'^Name:\s*(.+)$', block, re.M)
    if nm:
        name = nm.group(1).strip()
    lower = name.lower()
    # Prefer Desktop Experience; deprioritize Core
    if "core" in lower:
        score = 10
    elif "standard" in lower and ("desktop" in lower or "experience" in lower):
        score = 100
    elif "standard" in lower:
        score = 80
    elif "datacenter" in lower and ("desktop" in lower or "experience" in lower):
        score = 70
    elif "datacenter" in lower:
        score = 50
    else:
        score = 20
    # Prefer lower index on tie (Standard usually before Datacenter)
    key = (score, -idx)
    if best is None or key > best[0]:
        best = (key, idx, name)
if best:
    print(best[1])
PY
) || true

    if [[ "${chosen:-}" =~ ^[0-9]+$ ]]; then
        log_detail "Selected image index $chosen by edition name"
        echo "$chosen"
        return
    fi

    # Fallbacks: Standard Desktop is almost always index 2 on Server EVAL ISOs
    if [ "$num_images" -ge 2 ]; then
        log_detail "Falling back to image index 2 (Standard Desktop)"
        echo 2
    else
        log_detail "Only one image present; using index 1"
        echo 1
    fi
}

inject_drivers() {
    if [ -z "${VIRTIO_PATH:-}" ] || [ ! -f "${VIRTIO_PATH:-}" ]; then
        if is_virtual_machine; then
            die "VirtIO drivers are required on Hetzner Cloud / KVM but were not downloaded."
        fi
        log_info "Skipping VirtIO driver injection (not needed for bare-metal)."
        return
    fi
    
    log_step "Injecting VirtIO drivers (storage + network)..."
    
    local virtio_mount="/mnt/virtio"
    mkdir -p "$virtio_mount"
    mount -o loop,ro "$VIRTIO_PATH" "$virtio_mount" || {
        if is_virtual_machine; then
            die "Could not mount VirtIO ISO (required on Cloud/KVM)."
        fi
        log_warn "Could not mount VirtIO ISO, skipping driver injection."
        return
    }
    
    # Stage drivers where Windows Setup / PnP will pick them up on first boot
    local driver_stage="$MOUNT_TARGET/Windows/Drivers/VirtIO"
    mkdir -p "$driver_stage"
    local copied_driver_dirs=0
    local have_viostor=0 have_vioscsi=0 have_netkvm=0

    # Critical for Cloud: viostor (disk), NetKVM (network). Others are best-effort
    # (balloon/viorng/vioserial/qxldod missing is OK and must never abort install).
    local required_pkgs=(viostor vioscsi NetKVM)
    local optional_pkgs=(balloon viorng vioserial qxldod)
    local pkg arch_dir
    for pkg in "${required_pkgs[@]}" "${optional_pkgs[@]}"; do
        arch_dir=""
        for candidate in \
            "$virtio_mount/$pkg/2k25/amd64" \
            "$virtio_mount/$pkg/w11/amd64" \
            "$virtio_mount/$pkg/2k22/amd64" \
            "$virtio_mount/$pkg/2k19/amd64"; do
            if [ -d "$candidate" ]; then
                arch_dir="$candidate"
                break
            fi
        done
        if [ -n "$arch_dir" ]; then
            log_detail "Copying $pkg from $arch_dir"
            # Flatten into one DriverPaths directory (PnP searches this folder)
            if ! cp -r "$arch_dir"/* "$driver_stage/" 2>/dev/null; then
                log_warn "Failed to copy $pkg drivers (continuing)"
            fi
            cp -n "$arch_dir"/*.inf "$MOUNT_TARGET/Windows/INF/" 2>/dev/null || true
            cp -n "$arch_dir"/*.sys "$MOUNT_TARGET/Windows/System32/drivers/" 2>/dev/null || true
            cp -n "$arch_dir"/*.cat "$MOUNT_TARGET/Windows/INF/" 2>/dev/null || true
            copied_driver_dirs=$((copied_driver_dirs + 1))
            case "$pkg" in
                viostor) have_viostor=1 ;;
                vioscsi) have_vioscsi=1 ;;
                NetKVM) have_netkvm=1 ;;
            esac
        else
            case "$pkg" in
                viostor|vioscsi|NetKVM)
                    log_warn "VirtIO package not found in ISO: $pkg"
                    ;;
                *)
                    log_detail "Optional VirtIO package not in ISO (OK): $pkg"
                    ;;
            esac
        fi
    done
    
    umount "$virtio_mount" 2>/dev/null || true
    rmdir "$virtio_mount" 2>/dev/null || true

    if [ "$copied_driver_dirs" -eq 0 ]; then
        if is_virtual_machine; then
            die "No matching VirtIO driver directories found in ISO (Cloud requires viostor + NetKVM)."
        fi
        log_warn "No matching VirtIO driver directories were found in the ISO. Continuing without offline driver injection."
        return
    fi

    # On Cloud, storage + network packages are mandatory — not "any package copied".
    if is_virtual_machine; then
        [ "$have_viostor" = "1" ] || die "VirtIO viostor (storage) drivers were not found/copied — Cloud boot would fail."
        [ "$have_netkvm" = "1" ] || die "VirtIO NetKVM (network) drivers were not found/copied — RDP/network would fail on Cloud."
        local drivers_dir="$MOUNT_TARGET/Windows/System32/drivers"
        if ! compgen -G "$drivers_dir/[Vv]iostor.sys" >/dev/null; then
            die "viostor.sys missing after copy ($drivers_dir)."
        fi
        if ! compgen -G "$drivers_dir/[Nn]et[Kk][Vv][Mm].sys" >/dev/null; then
            die "netkvm.sys missing after copy ($drivers_dir)."
        fi
    fi

    register_virtio_boot_services "$have_viostor" "$have_vioscsi" "$have_netkvm"

    log_info "VirtIO drivers staged ($copied_driver_dirs packages) at Windows\\Drivers\\VirtIO"
}

# Read Services\<name>\Start as a decimal integer (stdout). Empty on failure.
# Accepts bare "0"/"3", "dword:0x0", "dword:3", etc. Idempotent resume-safe.
hivex_read_start_value() {
    local hive="$1" name="$2"
    local got=""

    if python3 -c 'import hivex' >/dev/null 2>&1; then
        got=$(python3 - "$hive" "$name" <<'PY' 2>/dev/null || true
import sys
import hivex
hive_path, name = sys.argv[1], sys.argv[2]
h = hivex.Hivex(hive_path, write=False)

def child(node, key):
    for c in h.node_children(node):
        if h.node_name(c) == key:
            return c
    return None

root = h.root()
cs = child(root, "ControlSet001")
services = child(cs, "Services") if cs else None
svc = child(services, name) if services else None
if svc is None:
    sys.exit(1)
try:
    val = h.node_get_value(svc, "Start")
except Exception:
    sys.exit(1)
try:
    print(h.value_dword(val))
except Exception:
    _t, data = h.value_value(val)
    print(int.from_bytes(data[:4], "little"))
PY
)
        if [[ "$got" =~ ^[0-9]+$ ]]; then
            printf '%s' "$got"
            return 0
        fi
    fi

    if command -v hivexsh &>/dev/null; then
        local start_out
        start_out=$(printf 'cd \\ControlSet001\\Services\\%s\nlsval Start\nquit\n' "$name" | hivexsh "$hive" 2>/dev/null || true)
        # Prefer explicit dword: forms, then bare integers.
        got=$(printf '%s\n' "$start_out" | sed -n 's/.*dword:0x\([0-9a-fA-F]\+\).*/\1/p' | head -1)
        if [ -n "$got" ]; then
            printf '%d' "$((16#$got))"
            return 0
        fi
        got=$(printf '%s\n' "$start_out" | sed -n 's/.*dword:\([0-9]\+\).*/\1/p' | head -1)
        if [[ "$got" =~ ^[0-9]+$ ]]; then
            printf '%s' "$got"
            return 0
        fi
        got=$(printf '%s\n' "$start_out" | grep -oE '[0-9]+' | head -1)
        if [[ "$got" =~ ^[0-9]+$ ]]; then
            printf '%s' "$got"
            return 0
        fi
    fi
    return 1
}

hivex_start_matches() {
    local hive="$1" name="$2" expect="$3"
    local got
    got=$(hivex_read_start_value "$hive" "$name" 2>/dev/null || true)
    [ -n "$got" ] && [ "$got" = "$expect" ]
}

# Register one kernel driver service in an offline SYSTEM hive via hivexsh.
# IMPORTANT hivexsh rules:
#   - setval N replaces ALL values at the node; pass every value in one setval.
#   - type is expandstring: (not expand:)
#   - dword values prefer 0xNN form.
#   - add is idempotent-safe: skip if Services\<name> already exists (resume).
hivex_register_driver_service() {
    local hive="$1" name="$2" start_hex="$3" group="$4" sysfile="$5" storport="${6:-0}"
    local tmp err expect_dec
    tmp=$(mktemp /tmp/virtio-svc.XXXXXX)
    err=$(mktemp /tmp/virtio-svc-err.XXXXXX)

    case "$start_hex" in
        0x0|0x00) expect_dec=0 ;;
        0x3|0x03) expect_dec=3 ;;
        *) expect_dec=$((start_hex)) ;;
    esac

    # Resume fast-path: already correct Start → success (still refresh ImagePath below).
    if hivex_start_matches "$hive" "$name" "$expect_dec"; then
        log_detail "Services\\$name already has Start=$expect_dec — refreshing values"
    fi

    # Ensure Services\<name> exists (do not fail if already present from a prior run).
    if ! printf 'cd \\ControlSet001\\Services\\%s\nquit\n' "$name" | hivexsh "$hive" >/dev/null 2>&1; then
        if ! printf 'cd \\ControlSet001\\Services\nadd %s\ncommit\nquit\n' "$name" | hivexsh -w "$hive" >"$err" 2>&1; then
            # Race/resume: key may have appeared; only fail if still missing.
            if ! printf 'cd \\ControlSet001\\Services\\%s\nquit\n' "$name" | hivexsh "$hive" >/dev/null 2>&1; then
                log_error "hivexsh: failed to create Services\\$name"
                cat "$err" >&2 || true
                rm -f "$tmp" "$err"
                return 1
            fi
        fi
    fi

    # One atomic setval with all service values (setval replaces the whole value set).
    cat > "$tmp" <<EOF
cd \\ControlSet001\\Services\\${name}
setval 5
ErrorControl
dword:0x1
Group
string:${group}
Start
dword:${start_hex}
Type
dword:0x1
ImagePath
expandstring:\\SystemRoot\\System32\\drivers\\${sysfile}
commit
quit
EOF

    if ! hivexsh -w "$hive" < "$tmp" >"$err" 2>&1; then
        log_error "hivexsh: failed to set values for Services\\$name"
        cat "$err" >&2 || true
        # Still accept if Start ended up correct (partial write / resume).
        if hivex_start_matches "$hive" "$name" "$expect_dec"; then
            log_warn "hivexsh setval errored but Start=$expect_dec is present — accepting"
            rm -f "$tmp" "$err"
            return 0
        fi
        rm -f "$tmp" "$err"
        return 1
    fi

    if ! hivex_start_matches "$hive" "$name" "$expect_dec"; then
        local start_out
        start_out=$(hivex_read_start_value "$hive" "$name" 2>/dev/null || echo "?")
        log_error "hivexsh: Start verify failed for $name (got='$start_out', want=$expect_dec)"
        rm -f "$tmp" "$err"
        return 1
    fi

    if [ "$storport" = "1" ]; then
        # Parameters + BusType + PnpInterface (best-effort; keys may already exist on resume)
        printf 'cd \\ControlSet001\\Services\\%s\nadd Parameters\ncommit\nquit\n' "$name" \
            | hivexsh -w "$hive" >/dev/null 2>&1 || true
        cat > "$tmp" <<EOF
cd \\ControlSet001\\Services\\${name}\\Parameters
setval 1
BusType
dword:0x1
commit
quit
EOF
        hivexsh -w "$hive" < "$tmp" >/dev/null 2>&1 || true
        printf 'cd \\ControlSet001\\Services\\%s\\Parameters\nadd PnpInterface\ncommit\nquit\n' "$name" \
            | hivexsh -w "$hive" >/dev/null 2>&1 || true
        cat > "$tmp" <<EOF
cd \\ControlSet001\\Services\\${name}\\Parameters\\PnpInterface
setval 1
5
dword:0x1
commit
quit
EOF
        hivexsh -w "$hive" < "$tmp" >/dev/null 2>&1 || true
    fi

    rm -f "$tmp" "$err"
    log_detail "Registered Services\\$name via hivexsh (Start=$expect_dec, $sysfile)"
    return 0
}

# Python+hivex — values MUST be dicts: {"key","t","value"} (tuples raise TypeError).
# Idempotent: ensure() reuses existing service keys on resume.
hivex_register_driver_service_python() {
    local hive="$1" name="$2" start_int="$3" group="$4" sysfile="$5" storport="${6:-0}"
    local err rc=0
    err=$(mktemp /tmp/virtio-py.XXXXXX)
    python3 - "$hive" "$name" "$start_int" "$group" "$sysfile" "$storport" >"$err" 2>&1 <<'PY' || rc=$?
import sys
try:
    import hivex
except ImportError as e:
    print("ImportError: python3-hivex not importable:", e, file=sys.stderr)
    sys.exit(2)

hive_path, name, start_s, group, sysfile, storport = sys.argv[1:7]
start = int(start_s)

def child(h, node, key):
    for c in h.node_children(node):
        if h.node_name(c) == key:
            return c
    return None

def ensure(h, node, key):
    existing = child(h, node, key)
    if existing is not None:
        return existing
    return h.node_add_child(node, key)

def u16(s):
    return (s + "\0").encode("utf-16le")

def dword(n):
    return int(n).to_bytes(4, "little")

def read_start(h, svc):
    val = h.node_get_value(svc, "Start")
    try:
        return h.value_dword(val)
    except Exception:
        _t, data = h.value_value(val)
        return int.from_bytes(data[:4], "little")

h = hivex.Hivex(hive_path, write=True)
root = h.root()
cs = child(h, root, "ControlSet001")
if cs is None:
    print("ERROR: ControlSet001 missing in SYSTEM hive", file=sys.stderr)
    sys.exit(3)
services = child(h, cs, "Services")
if services is None:
    print("ERROR: Services key missing in SYSTEM hive", file=sys.stderr)
    sys.exit(4)

svc = ensure(h, services, name)
# type: 1=REG_SZ, 2=REG_EXPAND_SZ, 4=REG_DWORD
vals = [
    {"key": "ErrorControl", "t": 4, "value": dword(1)},
    {"key": "Group", "t": 1, "value": u16(group)},
    {"key": "Start", "t": 4, "value": dword(start)},
    {"key": "Type", "t": 4, "value": dword(1)},
    {"key": "ImagePath", "t": 2, "value": u16("\\SystemRoot\\System32\\drivers\\" + sysfile)},
]
h.node_set_values(svc, vals)

if storport == "1":
    params = ensure(h, svc, "Parameters")
    h.node_set_values(params, [{"key": "BusType", "t": 4, "value": dword(1)}])
    pnp = ensure(h, params, "PnpInterface")
    h.node_set_values(pnp, [{"key": "5", "t": 4, "value": dword(1)}])

h.commit(hive_path)

# Re-open for a clean verify (avoids stale handles after commit).
h2 = hivex.Hivex(hive_path, write=False)
cs2 = child(h2, h2.root(), "ControlSet001")
svc2 = child(h2, child(h2, cs2, "Services"), name)
got = read_start(h2, svc2)
if got != start:
    print(f"ERROR: Start verify failed for {name}: got={got} want={start}", file=sys.stderr)
    sys.exit(5)
print(f"OK Services\\{name} Start={got}")
sys.exit(0)
PY
    if [ "$rc" -ne 0 ]; then
        log_error "python3-hivex failed for Services\\$name (exit $rc)"
        cat "$err" >&2 || true
        rm -f "$err"
        # Accept if Start already matches (resume / false-negative verify).
        if hivex_start_matches "$hive" "$name" "$start_int"; then
            log_warn "python path errored but Start=$start_int is present for $name — accepting"
            return 0
        fi
        return "$rc"
    fi
    cat "$err" >&2 || true
    rm -f "$err"
    log_detail "Registered Services\\$name via python3-hivex (Start=$start_int)"
    return 0
}

# Register VirtIO kernel drivers in the offline SYSTEM hive so storage is
# boot-critical before PnP/offlineServicing finishes (avoids INACCESSIBLE_BOOT_DEVICE).
# Picks ONE primary backend for the whole run (python preferred). Fallback only if
# Start is still wrong after the primary attempt — never flip-flop on false verify fails.
register_virtio_boot_services() {
    local have_viostor="${1:-0}" have_vioscsi="${2:-0}" have_netkvm="${3:-0}"
    local hive="$MOUNT_TARGET/Windows/System32/config/SYSTEM"
    local ok=1
    local backend=""

    if [ ! -f "$hive" ]; then
        if is_virtual_machine; then
            die "SYSTEM hive missing; cannot register VirtIO boot drivers."
        fi
        log_warn "SYSTEM hive missing; skipped VirtIO service registration."
        return
    fi

    ensure_virtio_hive_tools || true
    if python3 -c 'import hivex' >/dev/null 2>&1; then
        backend="python"
        log_detail "Using python3-hivex for SYSTEM hive edits (single path)"
    elif command -v hivexsh &>/dev/null; then
        backend="hivexsh"
        log_detail "Using hivexsh for SYSTEM hive edits (single path)"
    else
        if is_virtual_machine; then
            die "Neither python3-hivex nor hivexsh available; cannot register VirtIO boot drivers on Cloud. See $LOG_FILE."
        fi
        log_warn "hivex tools unavailable; skipped VirtIO service registration."
        return
    fi

    log_detail "Registering VirtIO services in offline SYSTEM hive (boot-start storage)..."

    register_one() {
        local name="$1" start_hex="$2" start_int="$3" group="$4" sysfile="$5" storport="$6"

        # Idempotent resume: correct Start already present — refresh via primary path anyway.
        if hivex_start_matches "$hive" "$name" "$start_int"; then
            log_detail "Services\\$name already Start=$start_int (resume) — re-applying to refresh ImagePath"
        fi

        if [ "$backend" = "python" ]; then
            if hivex_register_driver_service_python "$hive" "$name" "$start_int" "$group" "$sysfile" "$storport"; then
                return 0
            fi
            # Primary failed AND Start not accepted inside python helper — try hivexsh once.
            if hivex_start_matches "$hive" "$name" "$start_int"; then
                return 0
            fi
            if command -v hivexsh &>/dev/null || ensure_hivexsh; then
                log_warn "python path left Start!=$start_int for $name — one hivexsh fallback attempt"
                if hivex_register_driver_service "$hive" "$name" "$start_hex" "$group" "$sysfile" "$storport"; then
                    return 0
                fi
            fi
        else
            if hivex_register_driver_service "$hive" "$name" "$start_hex" "$group" "$sysfile" "$storport"; then
                return 0
            fi
            if hivex_start_matches "$hive" "$name" "$start_int"; then
                return 0
            fi
            if python3 -c 'import hivex' >/dev/null 2>&1 || ensure_python_hivex; then
                log_warn "hivexsh path left Start!=$start_int for $name — one python fallback attempt"
                if hivex_register_driver_service_python "$hive" "$name" "$start_int" "$group" "$sysfile" "$storport"; then
                    return 0
                fi
            fi
        fi

        # Final acceptance gate: correct Start means success regardless of tool noise.
        if hivex_start_matches "$hive" "$name" "$start_int"; then
            log_warn "Tool reported failure for $name but Start=$start_int — treating as success"
            return 0
        fi
        log_error "Failed to register Services\\$name (Start want=$start_int)"
        return 1
    }

    if [ "$have_viostor" = "1" ]; then
        register_one "viostor" "0x0" "0" "SCSI miniport" "viostor.sys" "1" || ok=0
    fi
    if [ "$have_vioscsi" = "1" ]; then
        register_one "vioscsi" "0x0" "0" "SCSI miniport" "vioscsi.sys" "1" || ok=0
    fi
    if [ "$have_netkvm" = "1" ]; then
        register_one "netkvm" "0x3" "3" "NDIS" "netkvm.sys" "0" || ok=0
    fi

    sync

    # Cloud hard-require: viostor Start=0 must be present.
    if is_virtual_machine && [ "$have_viostor" = "1" ]; then
        if ! hivex_start_matches "$hive" "viostor" "0"; then
            die "Cloud require: Services\\viostor Start=0 not set in SYSTEM hive after registration. See errors above / $LOG_FILE."
        fi
    fi

    if [ "$ok" = "1" ]; then
        log_info "VirtIO services registered in SYSTEM hive (viostor/vioscsi boot-start)."
    else
        if is_virtual_machine; then
            die "Failed to register VirtIO services in SYSTEM hive (required on Cloud). Check python3-hivex/hivexsh errors above and $LOG_FILE."
        fi
        log_warn "VirtIO SYSTEM hive registration failed; relying on DriverPaths/PnP only."
    fi

    # Boot-critical PCI IDs so winload loads viostor before the system volume is mounted.
    register_virtio_critical_device_database "$have_viostor" "$have_vioscsi"
}

# True if CriticalDeviceDatabase PCI entries have the expected Service values.
# Matching is done entirely in Python (key names contain # and & — never parse in bash).
virtio_cdd_entries_present() {
    local hive="$1" have_viostor="$2" have_vioscsi="$3"
    python3 - "$hive" "$have_viostor" "$have_vioscsi" <<'PY' >/dev/null 2>&1
import sys
import hivex

hive_path, have_viostor, have_vioscsi = sys.argv[1], sys.argv[2], sys.argv[3]
want = {}
if have_viostor == "1":
    for dev in ("1001", "1042"):
        want[f"pci#ven_1af4&dev_{dev}"] = "viostor"
if have_vioscsi == "1":
    for dev in ("1004", "1048"):
        want[f"pci#ven_1af4&dev_{dev}"] = "vioscsi"
if not want:
    sys.exit(0)

h = hivex.Hivex(hive_path, write=False)

def child(node, key):
    for c in h.node_children(node):
        if h.node_name(c) == key:
            return c
    return None

def read_sz(node, name):
    val = h.node_get_value(node, name)
    _t, data = h.value_value(val)
    return data.decode("utf-16le").rstrip("\0")

cs = child(h.root(), "ControlSet001")
if cs is None:
    sys.exit(1)
control = child(cs, "Control")
if control is None:
    sys.exit(1)
cdd = child(control, "CriticalDeviceDatabase")
if cdd is None:
    sys.exit(1)

# Index children by exact node_name (handles # & without shell/path parsers).
by_name = {h.node_name(c): c for c in h.node_children(cdd)}
for key, service in want.items():
    node = by_name.get(key)
    if node is None:
        sys.exit(2)
    try:
        got = read_sz(node, "Service")
    except Exception:
        sys.exit(3)
    if got.lower() != service.lower():
        sys.exit(4)
sys.exit(0)
PY
}

# Populate Control\CriticalDeviceDatabase for VirtIO block/SCSI PCI IDs (Cloud boot).
# Success gate: expected Service values present after write (resume-safe; no false-negative die).
register_virtio_critical_device_database() {
    local have_viostor="${1:-0}" have_vioscsi="${2:-0}"
    local hive="$MOUNT_TARGET/Windows/System32/config/SYSTEM"
    local err rc=0
    [ -f "$hive" ] || return 0
    python3 -c 'import hivex' >/dev/null 2>&1 || ensure_python_hivex || {
        if is_virtual_machine; then
            die "python3-hivex required to write VirtIO CriticalDeviceDatabase on Cloud."
        fi
        log_warn "Skipping CriticalDeviceDatabase (python3-hivex unavailable)"
        return 0
    }

    # Nothing to write — treat as success.
    if [ "$have_viostor" != "1" ] && [ "$have_vioscsi" != "1" ]; then
        return 0
    fi

    # Idempotent resume: already present → done.
    if virtio_cdd_entries_present "$hive" "$have_viostor" "$have_vioscsi"; then
        log_info "VirtIO CriticalDeviceDatabase entries already present."
        return 0
    fi

    log_detail "Writing VirtIO CriticalDeviceDatabase PCI boot entries..."
    err=$(mktemp /tmp/virtio-cdd.XXXXXX)
    python3 - "$hive" "$have_viostor" "$have_vioscsi" >"$err" 2>&1 <<'PY' || rc=$?
import sys
try:
    import hivex
except ImportError as e:
    print("ImportError: python3-hivex not importable:", e, file=sys.stderr)
    sys.exit(2)

hive_path, have_viostor, have_vioscsi = sys.argv[1], sys.argv[2], sys.argv[3]
SCSI_GUID = "{4D36E97B-E325-11CE-BFC1-08002BE10318}"

# Legacy + modern VirtIO blk/scsi device IDs (VEN_1AF4)
entries = []
if have_viostor == "1":
    for dev in ("1001", "1042"):
        entries.append((f"pci#ven_1af4&dev_{dev}", "viostor"))
if have_vioscsi == "1":
    for dev in ("1004", "1048"):
        entries.append((f"pci#ven_1af4&dev_{dev}", "vioscsi"))

if not entries:
    sys.exit(0)

h = hivex.Hivex(hive_path, write=True)

def child(node, key):
    for c in h.node_children(node):
        if h.node_name(c) == key:
            return c
    return None

def ensure(node, key):
    existing = child(node, key)
    if existing is not None:
        return existing
    return h.node_add_child(node, key)

def u16(s):
    return (s + "\0").encode("utf-16le")

root = h.root()
cs = child(root, "ControlSet001")
if cs is None:
    print("ERROR: ControlSet001 missing", file=sys.stderr)
    sys.exit(3)
control = ensure(cs, "Control")
cdd = ensure(control, "CriticalDeviceDatabase")

for key, service in entries:
    node = ensure(cdd, key)
    h.node_set_values(node, [
        {"key": "Service", "t": 1, "value": u16(service)},
        {"key": "ClassGUID", "t": 1, "value": u16(SCSI_GUID)},
    ])
    print(f"OK CriticalDeviceDatabase\\{key} -> {service}", flush=True)

commit_err = None
try:
    h.commit(None)
except Exception as e1:
    try:
        h.commit(hive_path)
    except Exception as e2:
        commit_err = f"{e1}; retry: {e2}"

# Re-open and verify by exact node_name (keys contain # & — no path parsing).
h2 = hivex.Hivex(hive_path, write=False)

def child2(node, key):
    for c in h2.node_children(node):
        if h2.node_name(c) == key:
            return c
    return None

cs2 = child2(h2.root(), "ControlSet001")
if cs2 is None:
    print("ERROR: ControlSet001 missing after commit", file=sys.stderr)
    sys.exit(5)
control2 = child2(cs2, "Control")
cdd2 = child2(control2, "CriticalDeviceDatabase") if control2 is not None else None
if cdd2 is None:
    print("ERROR: CriticalDeviceDatabase missing after commit", file=sys.stderr)
    sys.exit(6)

by_name = {h2.node_name(c): c for c in h2.node_children(cdd2)}
missing = []
for key, service in entries:
    node = by_name.get(key)
    if node is None:
        missing.append(key)
        continue
    try:
        val = h2.node_get_value(node, "Service")
        _t, data = h2.value_value(val)
        got = data.decode("utf-16le").rstrip("\0")
    except Exception as e:
        missing.append(f"{key}({e})")
        continue
    if got.lower() != service.lower():
        missing.append(f"{key}->got:{got}")

if missing:
    if commit_err:
        print(f"ERROR: commit/verify failed: {commit_err}", file=sys.stderr)
    print("ERROR: missing/mismatched CDD entries: " + ", ".join(missing), file=sys.stderr)
    sys.exit(7)

if commit_err:
    print(f"WARN commit noisily failed but verify OK: {commit_err}", file=sys.stderr)
print("OK CriticalDeviceDatabase verify")
sys.exit(0)
PY
    cat "$err" >&2 || true
    rm -f "$err"

    # Acceptance gate: presence of Service values wins over tool exit codes
    # (mirrors Start=0/3 gate — avoids false-negative dies after OK writes).
    if virtio_cdd_entries_present "$hive" "$have_viostor" "$have_vioscsi"; then
        if [ "$rc" -ne 0 ]; then
            log_warn "CriticalDeviceDatabase tool exit $rc but entries present — accepting"
        else
            log_info "VirtIO CriticalDeviceDatabase entries written."
        fi
        return 0
    fi

    if is_virtual_machine; then
        die "Failed to write VirtIO CriticalDeviceDatabase (required on Cloud). See $LOG_FILE."
    fi
    log_warn "CriticalDeviceDatabase write failed (continuing on bare-metal)"
    return 0
}

generate_unattend_xml() {
    log_step "Generating unattended answer file..."

    mkdir -p "$MOUNT_TARGET/Windows/Panther"
    
    cat > "$MOUNT_TARGET/Windows/Panther/unattend.xml" << 'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
    </settings>
    <settings pass="offlineServicing">
        <component name="Microsoft-Windows-PnpCustomizationsNonWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DriverPaths>
                <PathAndCredentials wcm:action="add" wcm:keyValue="1">
                    <Path>C:\Windows\Drivers\VirtIO</Path>
                </PathAndCredentials>
            </DriverPaths>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>WIN-HETZNER</ComputerName>
            <TimeZone>UTC</TimeZone>
        </component>
        <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <fDenyTSConnections>false</fDenyTSConnections>
        </component>
        <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <FirewallGroups>
                <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
                    <Active>true</Active>
                    <Group>Remote Desktop</Group>
                    <Profile>all</Profile>
                </FirewallGroup>
            </FirewallGroups>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>__ADMIN_PASSWORD__</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <AutoLogon>
                <Enabled>true</Enabled>
                <Count>10</Count>
                <Username>Administrator</Username>
                <Password>
                    <Value>__ADMIN_PASSWORD__</Value>
                    <PlainText>true</PlainText>
                </Password>
            </AutoLogon>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>cmd /c bcdboot C:\Windows /f ALL</CommandLine>
                    <Description>Rebuild BCD boot configuration</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <CommandLine>cmd /c C:\setup-network.cmd</CommandLine>
                    <Description>Configure Hetzner Network</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <CommandLine>cmd /c C:\post-install.cmd</CommandLine>
                    <Description>Post-installation tasks</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
</unattend>
XMLEOF
    
    # Replace password placeholder via stdin to avoid exposure in process list.
    # XML-escape special characters to prevent broken unattend.xml.
    python3 -c "
import sys, html
pw = sys.stdin.readline().rstrip('\\n')
escaped = html.escape(pw, quote=True)
with open(sys.argv[1], 'r') as f: data = f.read()
data = data.replace('__ADMIN_PASSWORD__', escaped)
with open(sys.argv[1], 'w') as f: f.write(data)
" "$MOUNT_TARGET/Windows/Panther/unattend.xml" <<< "$ADMIN_PASSWORD"
    
    # Also place at root for Windows Setup to find it
    cp "$MOUNT_TARGET/Windows/Panther/unattend.xml" "$MOUNT_TARGET/unattend.xml"
    cp "$MOUNT_TARGET/Windows/Panther/unattend.xml" "$MOUNT_TARGET/Autounattend.xml"
    
    log_info "Unattended answer file generated."
}

create_network_script() {
    log_step "Creating Hetzner network configuration script..."
    
    if [ "$NETWORK_MODE" = "point-to-point" ]; then
        cat > "$MOUNT_TARGET/setup-network.cmd" << NETEOF
@echo off
REM ============================================================
REM Hetzner Network Configuration for Windows Server
REM Configures /32 point-to-point routing (Hetzner standard)
REM ============================================================

echo Configuring Hetzner network...

REM Wait for network adapter to be ready
timeout /t 10 /nobreak >nul

REM Detect connected network adapter (handles multi-word adapter names)
set "ADAPTER="
powershell -NoProfile -Command "(Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1 -ExpandProperty Name)" > "%TEMP%\nic.txt" 2>nul
set /p ADAPTER=<"%TEMP%\nic.txt"
del "%TEMP%\nic.txt" >nul 2>&1
if not defined ADAPTER (
    for %%n in ("Ethernet" "Ethernet0" "Local Area Connection") do (
        netsh interface show interface name=%%n >nul 2>&1
        if not errorlevel 1 (
            set "ADAPTER=%%~n"
            goto :adapter_found
        )
    )
    echo [ERROR] No network adapter found >> C:\hetzner-setup.log
    exit /b 1
)
:adapter_found

echo Using adapter: %ADAPTER%

REM Remove any existing IP configuration  
netsh interface ip set address name="%ADAPTER%" source=dhcp >nul 2>&1
timeout /t 3 /nobreak >nul

REM Configure static IP with /32 subnet (Hetzner point-to-point)
netsh interface ipv4 set address name="%ADAPTER%" static ${SERVER_IP} ${SUBNET_MASK} none >nul 2>&1
if errorlevel 1 exit /b 1

REM Add gateway route (Hetzner requires the gateway to be added as a /32 route first)
route delete 0.0.0.0 >nul 2>&1
netsh interface ipv4 delete route ${GATEWAY}/32 "%ADAPTER%" >nul 2>&1
netsh interface ipv4 delete route 0.0.0.0/0 "%ADAPTER%" >nul 2>&1
netsh interface ipv4 add neighbors "%ADAPTER%" ${GATEWAY} 00-00-00-00-00-00 >nul 2>&1
netsh interface ipv4 add route ${GATEWAY}/32 "%ADAPTER%" 0.0.0.0 >nul 2>&1
netsh interface ipv4 add route 0.0.0.0/0 "%ADAPTER%" ${GATEWAY} >nul 2>&1
route print 0.0.0.0 | find "${GATEWAY}" >nul 2>&1 || exit /b 1

REM Configure DNS servers
netsh interface ipv4 set dns name="%ADAPTER%" static ${DNS_PRIMARY}
netsh interface ipv4 add dns name="%ADAPTER%" ${DNS_SECONDARY} index=2
ipconfig | find "${SERVER_IP}" >nul 2>&1 || exit /b 1

REM Disable IPv6 privacy extensions (servers should use static addresses)  
netsh interface ipv6 set privacy state=disabled

REM Enable ping (ICMP) for monitoring
netsh advfirewall firewall add rule name="Allow ICMPv4" protocol=icmpv4 dir=in action=allow >nul 2>&1
netsh advfirewall firewall add rule name="Allow ICMPv6" protocol=icmpv6 dir=in action=allow >nul 2>&1

echo Network configuration applied.
echo IP: ${SERVER_IP}/${SUBNET_PREFIX}
echo Gateway: ${GATEWAY}
echo DNS: ${DNS_PRIMARY}, ${DNS_SECONDARY}

REM Log the configuration
echo %date% %time% - Network configured: ${SERVER_IP}/${SUBNET_PREFIX} via ${GATEWAY} >> C:\hetzner-setup.log

NETEOF
    else
        cat > "$MOUNT_TARGET/setup-network.cmd" << NETEOF
@echo off
REM ============================================================
REM Standard static IPv4 configuration for Windows Server
REM ============================================================

echo Configuring server network...
timeout /t 10 /nobreak >nul

REM Detect connected network adapter (handles multi-word adapter names)
set "ADAPTER="
powershell -NoProfile -Command "(Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1 -ExpandProperty Name)" > "%TEMP%\nic.txt" 2>nul
set /p ADAPTER=<"%TEMP%\nic.txt"
del "%TEMP%\nic.txt" >nul 2>&1
if not defined ADAPTER (
    for %%n in ("Ethernet" "Ethernet0" "Local Area Connection") do (
        netsh interface show interface name=%%n >nul 2>&1
        if not errorlevel 1 (
            set "ADAPTER=%%~n"
            goto :adapter_found
        )
    )
    echo [ERROR] No network adapter found >> C:\hetzner-setup.log
    exit /b 1
)
:adapter_found

echo Using adapter: %ADAPTER%
netsh interface ip set address name="%ADAPTER%" source=dhcp >nul 2>&1
timeout /t 3 /nobreak >nul

netsh interface ipv4 set address name="%ADAPTER%" static ${SERVER_IP} ${SUBNET_MASK} ${GATEWAY} 1
if errorlevel 1 exit /b 1
netsh interface ipv4 set dns name="%ADAPTER%" static ${DNS_PRIMARY}
netsh interface ipv4 add dns name="%ADAPTER%" ${DNS_SECONDARY} index=2
netsh interface ipv6 set privacy state=disabled
netsh advfirewall firewall add rule name="Allow ICMPv4" protocol=icmpv4 dir=in action=allow >nul 2>&1
netsh advfirewall firewall add rule name="Allow ICMPv6" protocol=icmpv6 dir=in action=allow >nul 2>&1
ipconfig | find "${SERVER_IP}" >nul 2>&1 || exit /b 1

echo Network configuration applied.
echo IP: ${SERVER_IP}/${SUBNET_PREFIX}
echo Gateway: ${GATEWAY}
echo DNS: ${DNS_PRIMARY}, ${DNS_SECONDARY}
echo %date% %time% - Network configured: ${SERVER_IP}/${SUBNET_PREFIX} via ${GATEWAY} >> C:\hetzner-setup.log
NETEOF
    fi

    log_info "Network configuration script created."
}

create_post_install_script() {
    log_step "Creating post-installation script..."
    
    cat > "$MOUNT_TARGET/post-install.cmd" << 'POSTEOF'
@echo off
REM ============================================================
REM Post-Installation Configuration for Hetzner Windows Server
REM ============================================================

echo Running post-installation tasks...

REM --- Enable Remote Desktop ---
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 0 /f >nul 2>&1

REM --- Open RDP Firewall Rule ---
netsh advfirewall firewall set rule group="Remote Desktop" new enable=yes >nul 2>&1
netsh advfirewall firewall add rule name="RDP-TCP-3389" protocol=TCP dir=in localport=3389 action=allow >nul 2>&1
netsh advfirewall firewall add rule name="RDP-UDP-3389" protocol=UDP dir=in localport=3389 action=allow >nul 2>&1

REM --- Configure RDP Settings ---
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber /t REG_DWORD /d 3389 /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v SecurityLayer /t REG_DWORD /d 2 /f >nul 2>&1

REM --- Set High Performance Power Plan ---
powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1

REM --- Disable Server Manager at Login ---
reg add "HKLM\SOFTWARE\Microsoft\ServerManager" /v DoNotOpenServerManagerAtLogon /t REG_DWORD /d 1 /f >nul 2>&1

REM --- Disable IE Enhanced Security Configuration ---
reg add "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" /v IsInstalled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" /v IsInstalled /t REG_DWORD /d 0 /f >nul 2>&1

REM --- Enable Remote Desktop Services ---
sc config TermService start= auto >nul 2>&1
net start TermService >nul 2>&1

REM --- Set timezone to UTC ---
tzutil /s "UTC" >nul 2>&1

REM --- Disable Ctrl+Alt+Del requirement ---
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableCAD /t REG_DWORD /d 1 /f >nul 2>&1

REM --- Configure Windows Update to manual ---
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /t REG_DWORD /d 3 /f >nul 2>&1

REM --- Optimize network adapter for server use ---
powershell -Command "Set-NetAdapterAdvancedProperty -Name '*' -RegistryKeyword '*SpeedDuplex' -RegistryValue 0" >nul 2>&1
powershell -Command "Set-NetAdapterAdvancedProperty -Name '*' -RegistryKeyword '*FlowControl' -RegistryValue 3" >nul 2>&1

REM --- Install .NET 3.5 if available ---
REM dism /online /enable-feature /featurename:NetFx3 /all >nul 2>&1

REM --- Clean up (keep setup-network.cmd and fix-network.cmd as repair tools) ---
del /q C:\post-install.cmd >nul 2>&1

echo %date% %time% - Post-installation completed >> C:\hetzner-setup.log
echo Post-installation tasks completed.
echo.
echo ============================================
echo  Windows Server is ready!
echo  RDP: Connect to this server's IP on port 3389
echo  Username: Administrator
echo ============================================

POSTEOF

    log_info "Post-installation script created."
}

create_fix_network_script() {
    log_step "Embedding network repair tool on Windows drive..."
    
    # This script gets placed on C:\ so users can run it from KVM console
    # if network doesn't work after install — no SCP needed!
    cat > "$MOUNT_TARGET/fix-network.cmd" << FIXEOF
@echo off
REM ============================================================
REM Hetzner Network Fix - Run from KVM console if RDP fails
REM Auto-generated by installer for this server
REM ============================================================

echo ============================================
echo  Hetzner Network Configuration Fix
echo  Server: ${SERVER_IP}
echo ============================================
echo.

set SERVER_IP=${SERVER_IP}
set GATEWAY=${GATEWAY}
set SUBNET_MASK=${SUBNET_MASK}
set SUBNET_PREFIX=${SUBNET_PREFIX}
set NETWORK_MODE=${NETWORK_MODE}
set DNS1=${DNS_PRIMARY}
set DNS2=${DNS_SECONDARY}

REM Detect connected network adapter (handles multi-word adapter names)
set "ADAPTER="
powershell -NoProfile -Command "(Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).Name" > "%TEMP%\nic.txt" 2>nul
set /p ADAPTER=<"%TEMP%\nic.txt"
del "%TEMP%\nic.txt" >nul 2>&1
if not defined ADAPTER (
    for %%n in ("Ethernet" "Ethernet0" "Local Area Connection") do (
        netsh interface show interface name=%%n >nul 2>&1
        if not errorlevel 1 (
            set "ADAPTER=%%~n"
            goto :found
        )
    )
    echo [ERROR] No network adapter found!
    pause
    exit /b 1
)

:found
echo Using adapter: %ADAPTER%
echo.

echo [1/5] Resetting IP configuration...
netsh interface ip set address name="%ADAPTER%" source=dhcp >nul 2>&1
timeout /t 3 /nobreak >nul

echo [2/5] Setting static IP (%SERVER_IP%/%SUBNET_PREFIX%)...
netsh interface ipv4 set address name="%ADAPTER%" static %SERVER_IP% %SUBNET_MASK% %GATEWAY% 1

echo [3/5] Configuring routing...
if /I "%NETWORK_MODE%"=="point-to-point" (
    route delete 0.0.0.0 >nul 2>&1
    netsh interface ipv4 delete route %GATEWAY%/32 "%ADAPTER%" >nul 2>&1
    netsh interface ipv4 delete route 0.0.0.0/0 "%ADAPTER%" >nul 2>&1
    netsh interface ipv4 add neighbors "%ADAPTER%" %GATEWAY% 00-00-00-00-00-00 >nul 2>&1
    netsh interface ipv4 add route %GATEWAY%/32 "%ADAPTER%" 0.0.0.0 >nul 2>&1
    netsh interface ipv4 add route 0.0.0.0/0 "%ADAPTER%" %GATEWAY% >nul 2>&1
)
route print 0.0.0.0 | find "%GATEWAY%" >nul 2>&1 || echo [WARN] Default route verification failed

echo [4/5] Setting DNS (%DNS1%, %DNS2%)...
netsh interface ipv4 set dns name="%ADAPTER%" static %DNS1%
netsh interface ipv4 add dns name="%ADAPTER%" %DNS2% index=2

echo [5/5] Enabling RDP and firewall rules...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f >nul 2>&1
netsh advfirewall firewall set rule group="Remote Desktop" new enable=yes >nul 2>&1
netsh advfirewall firewall add rule name="RDP-TCP-3389" protocol=TCP dir=in localport=3389 action=allow >nul 2>&1
netsh advfirewall firewall add rule name="Allow ICMPv4" protocol=icmpv4 dir=in action=allow >nul 2>&1

echo.
echo Testing connectivity...
ping -n 2 %DNS1% >nul 2>&1
if %errorlevel%==0 (
    echo [OK] Network is working - DNS %DNS1% reachable
    ping -n 2 google.com >nul 2>&1
    if %errorlevel%==0 (
        echo [OK] Internet connectivity confirmed
    ) else (
        echo [WARN] DNS resolution issue - try restarting DNS Client service
    )
) else (
    echo [FAIL] Cannot reach DNS - check gateway ARP entry
    echo Attempting ARP fix...
    netsh interface ipv4 add neighbors "%ADAPTER%" %GATEWAY% 00-00-00-00-00-00 >nul 2>&1
    echo Retry: ping %DNS1%
)

echo.
echo ============================================
echo  RDP: %SERVER_IP%:3389
echo  User: Administrator
echo ============================================
pause
FIXEOF

    log_info "Network repair tool embedded at C:\\fix-network.cmd"
}

setup_san_policy() {
    log_step "Configuring SAN policy for disk recognition..."

    local san_xml="$MOUNT_TARGET/san-policy.xml"
    cat > "$san_xml" << 'SANEOF'
<?xml version='1.0' encoding='utf-8' standalone='yes'?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="offlineServicing">
    <component name="Microsoft-Windows-PartitionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SanPolicy>1</SanPolicy>
    </component>
  </settings>
</unattend>
SANEOF

    # Apply the SAN policy directly in the SYSTEM registry hive
    if command -v hivexsh &>/dev/null; then
        log_detail "Applying SAN policy via registry hive..."
        if [ -f "$MOUNT_TARGET/Windows/System32/config/SYSTEM" ]; then
            python3 - "$MOUNT_TARGET/Windows/System32/config/SYSTEM" <<'PYEOF' 2>/dev/null || true
import subprocess, sys
hive = sys.argv[1]
# SAN Policy 1 = Online All Disks
# Set via hivexsh on the SYSTEM hive at ControlSet001\Services\partmgr\Parameters
try:
    proc = subprocess.run(['hivexsh', '-w', hive], input=(
        'cd \\ControlSet001\\Services\\partmgr\\Parameters\n'
        'setval 1\n'
        'SanPolicy\n'
        'dword:00000001\n'
    ), capture_output=True, text=True, timeout=10)
except Exception:
    pass
PYEOF
        fi
    fi
    rm -f "$san_xml"

    log_info "SAN policy configured."
}

setup_bootloader() {
    log_step "Setting up Windows bootloader..."
    
    if [ "$BOOT_MODE" = "uefi" ]; then
        setup_uefi_boot
    else
        setup_bios_boot
    fi
}

setup_uefi_boot() {
    log_detail "Configuring UEFI boot..."
    
    # Mount EFI partition
    local efi_mount="/mnt/efi"
    mkdir -p "$efi_mount"
    mount "$EFI_PART" "$efi_mount" || die "Failed to mount EFI partition"
    
    # Create EFI boot directory structure
    mkdir -p "$efi_mount/EFI/Microsoft/Boot"
    mkdir -p "$efi_mount/EFI/Boot"
    
    # Copy Windows boot EFI binaries (but NOT the BCD — it contains stale
    # device references from the WIM image and causes 0xc000000f).
    if [ -d "$MOUNT_TARGET/Windows/Boot/EFI" ]; then
        cp "$MOUNT_TARGET/Windows/Boot/EFI/bootmgfw.efi" "$efi_mount/EFI/Microsoft/Boot/" 2>/dev/null || true
        cp "$MOUNT_TARGET/Windows/Boot/EFI/bootmgfw.efi" "$efi_mount/EFI/Boot/bootx64.efi" 2>/dev/null || true
        # Copy everything except BCD and BCD.LOG files
        find "$MOUNT_TARGET/Windows/Boot/EFI" -maxdepth 1 -type f \
            ! -iname 'BCD' ! -iname 'BCD.*' \
            -exec cp {} "$efi_mount/EFI/Microsoft/Boot/" \; 2>/dev/null || true
    fi
    
    # Copy boot fonts
    mkdir -p "$efi_mount/EFI/Microsoft/Boot/Fonts"
    cp "$MOUNT_TARGET/Windows/Boot/Fonts/"* "$efi_mount/EFI/Microsoft/Boot/Fonts/" 2>/dev/null || true
    
    # Verify critical boot file
    if [ ! -f "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
        umount "$efi_mount"
        die "CRITICAL: bootmgfw.efi not found after copy. Windows cannot boot."
    fi
    
    umount "$efi_mount"
    rmdir "$efi_mount"
    
    # Use efibootmgr to add UEFI firmware boot entry
    if command -v efibootmgr &>/dev/null; then
        efibootmgr -c -d "$TARGET_DISK" -p 1 -l '\EFI\Microsoft\Boot\bootmgfw.efi' -L "Windows Server 2025" 2>/dev/null || true
    fi
    
    log_info "UEFI boot configured."
}

# Ensure grub-install is available (full grub-pc, not only -bin).
ensure_grub_pc() {
    if command -v grub-install &>/dev/null; then
        return 0
    fi
    log_detail "Installing grub-pc for Legacy BIOS bootloader..."
    preseed_grub_pc_debconf
    apt_install_with_retries grub-pc grub-pc-bin grub2-common || {
        log_error "apt failed installing grub-pc (see log above)"
        return 1
    }
    refresh_command_hash
    if ! command -v grub-install &>/dev/null; then
        log_error "grub-install still missing after installing grub-pc"
        return 1
    fi
    return 0
}

write_grub_ntldr_cfg() {
    local grub_cfg="$1"
    mkdir -p "$(dirname "$grub_cfg")"
    cat > "$grub_cfg" <<'GRUBEOF'
set timeout=0
set default=0

# Guaranteed Legacy BIOS → Windows bootmgr.
# IMPORTANT: search for /Boot/HETZNER (unique marker on System Reserved), NOT
# bare /bootmgr or /Boot/BCD. The applied WIM also ships stale \bootmgr and
# \Boot\BCD on the Windows volume; picking those causes 0xc000000f.
menuentry "Windows Server 2025" {
    insmod part_msdos
    insmod ntfs
    insmod ntldr
    insmod search_fs_file
    search --file --no-floppy --set=root /Boot/HETZNER
    ntldr /bootmgr
}
GRUBEOF
}

# Install GRUB i386-pc + ntldr search on a specific disk.
# boot_directory is where grub/ modules + grub.cfg live (must remain readable at boot
# for non-embedded configs; for target we use the System Reserved partition).
install_grub_bios_ntldr_on_disk() {
    local disk="$1"
    local boot_directory="$2"
    local log_file="${3:-/tmp/grub-install-bios.log}"

    ensure_grub_pc || return 1
    mkdir -p "$boot_directory/grub"

    if ! grub-install \
        --target=i386-pc \
        --boot-directory="$boot_directory" \
        --recheck \
        --force \
        --modules="part_msdos ntfs ntldr search_fs_file search_fs_uuid search_label biosdisk" \
        "$disk" >"$log_file" 2>&1; then
        log_warn "grub-install failed on $disk (see $log_file)"
        return 1
    fi

    write_grub_ntldr_cfg "$boot_directory/grub/grub.cfg"
    [ -f "$boot_directory/grub/grub.cfg" ] || return 1
    [ -d "$boot_directory/grub/i386-pc" ] || [ -f "$boot_directory/grub/i386-pc/core.img" ] || return 1
    log_detail "GRUB ntldr installed on $disk (boot-dir $boot_directory)"
    return 0
}

# Cloud Legacy often enumerates Volume as sda (BIOS hd0) while Windows is on sdb.
# Installing the same search-/bootmgr GRUB on the work disk guarantees firmware
# disk-0 still reaches Windows.
install_grub_bios_on_work_disk() {
    [ "${BOOT_MODE:-}" = "bios" ] || return 0
    [ -n "${WORK_DISK:-}" ] && [ -b "$WORK_DISK" ] || return 0

    log_step "Installing GRUB redirect on work disk ($WORK_DISK) for BIOS disk-0 safety..."

    local work_part
    work_part="${WORK_PART:-$(find_work_partition "$WORK_DISK" 2>/dev/null || true)}"
    if [ -z "$work_part" ] || [ ! -b "$work_part" ]; then
        log_warn "Could not locate work-disk NTFS partition for GRUB redirect"
        return 1
    fi
    WORK_PART="$work_part"
    mkdir -p "$MOUNT_WORK"
    if ! mountpoint -q "$MOUNT_WORK" 2>/dev/null; then
        mount "$work_part" "$MOUNT_WORK" 2>/dev/null || {
            log_warn "Could not mount work disk ($work_part) to install GRUB redirect"
            return 1
        }
    fi

    local grub_dir="$MOUNT_WORK/.bios-grub"
    if install_grub_bios_ntldr_on_disk "$WORK_DISK" "$grub_dir" /tmp/grub-install-work.log; then
        log_info "Work-disk GRUB redirect OK — firmware can boot Volume or instance disk."
        return 0
    fi

    if is_virtual_machine; then
        die "Failed to install GRUB redirect on work disk $WORK_DISK (required on Cloud Legacy when Volume may be BIOS disk 0). See /tmp/grub-install-work.log"
    fi
    log_warn "Work-disk GRUB redirect failed (non-fatal on bare-metal)"
    return 1
}

verify_legacy_boot_ready() {
    [ "${BOOT_MODE:-}" = "bios" ] || return 0

    log_step "Verifying Legacy BIOS boot chain..."
    local boot_mount="/mnt/bootpart"
    mkdir -p "$boot_mount"
    if ! mountpoint -q "$boot_mount" 2>/dev/null; then
        mount "$BOOT_PART" "$boot_mount" || die "Cannot mount boot partition for final verify"
    fi

    local errors=0
    [ -f "$boot_mount/bootmgr" ] || { log_error "Missing bootmgr on System Reserved"; errors=$((errors + 1)); }
    [ -f "$boot_mount/Boot/BCD" ] || { log_error "Missing Boot\\BCD on System Reserved"; errors=$((errors + 1)); }
    [ -f "$boot_mount/Boot/HETZNER" ] || { log_error "Missing Boot\\HETZNER GRUB search marker"; errors=$((errors + 1)); }
    [ -f "$boot_mount/grub/grub.cfg" ] || { log_error "Missing grub.cfg on System Reserved"; errors=$((errors + 1)); }
    if [ -f "$boot_mount/grub/grub.cfg" ] && ! grep -q 'HETZNER' "$boot_mount/grub/grub.cfg"; then
        log_error "grub.cfg does not search /Boot/HETZNER (would hit stale WIM BCD)"
        errors=$((errors + 1))
    fi
    # Stale WIM boot files on Windows volume must stay gone
    if [ -f "$MOUNT_TARGET/Boot/BCD" ] || [ -f "$MOUNT_TARGET/bootmgr" ]; then
        log_error "Stale bootmgr/BCD still present on Windows volume (causes 0xc000000f)"
        errors=$((errors + 1))
    fi
    [ -d "$boot_mount/grub/i386-pc" ] || [ -f "$boot_mount/grub/i386-pc/core.img" ] \
        || { log_error "Missing GRUB i386-pc modules on System Reserved"; errors=$((errors + 1)); }

    # MBR magic 0x55AA on target
    local mbr_sig
    mbr_sig=$(od -An -tx1 -N2 -j510 "$TARGET_DISK" 2>/dev/null | tr -d ' \n')
    if [ "$mbr_sig" != "55aa" ]; then
        log_error "Target disk MBR signature invalid (got '$mbr_sig', want 55aa)"
        errors=$((errors + 1))
    else
        log_detail "Target MBR signature OK (55aa)"
    fi

    # Cloud: work-disk GRUB redirect must also have a valid MBR (Volume may be BIOS hd0).
    if is_virtual_machine && [ -n "${WORK_DISK:-}" ] && [ -b "$WORK_DISK" ]; then
        local work_mbr
        work_mbr=$(od -An -tx1 -N2 -j510 "$WORK_DISK" 2>/dev/null | tr -d ' \n')
        if [ "$work_mbr" != "55aa" ]; then
            log_error "Work disk MBR signature invalid (got '$work_mbr', want 55aa) — BIOS disk-0 redirect broken"
            errors=$((errors + 1))
        else
            log_detail "Work disk MBR signature OK (55aa)"
        fi
        if [ -d "$MOUNT_WORK/.bios-grub/grub" ] || mountpoint -q "$MOUNT_WORK" 2>/dev/null; then
            [ -f "$MOUNT_WORK/.bios-grub/grub/grub.cfg" ] \
                || log_warn "Work-disk grub.cfg not visible at $MOUNT_WORK/.bios-grub/grub/grub.cfg (mount state may differ)"
        fi
    fi

    umount "$boot_mount" 2>/dev/null || true

    [ "$errors" -eq 0 ] || die "Legacy BIOS boot verification failed ($errors error(s)). Not rebooting into a broken chain. See $LOG_FILE."
    log_info "Legacy BIOS boot chain verified (bootmgr + BCD + GRUB)."
}

setup_bios_boot() {
    log_detail "Configuring guaranteed Legacy BIOS boot (GRUB ntldr on instance disk)..."

    ensure_grub_pc || die "grub-install required for Legacy BIOS but is not available."

    # Re-assert active/boot flag before staging files
    parted -s "$TARGET_DISK" set 1 boot on 2>/dev/null || true

    # Mount boot partition (System Reserved)
    local boot_mount="/mnt/bootpart"
    mkdir -p "$boot_mount"
    mount "$BOOT_PART" "$boot_mount" || die "Failed to mount boot partition"

    mkdir -p "$boot_mount/Boot"

    if [ -d "$MOUNT_TARGET/Windows/Boot/PCAT" ]; then
        # Copy everything except BCD and BCD.LOG (stale device refs → 0xc000000f)
        find "$MOUNT_TARGET/Windows/Boot/PCAT" -maxdepth 1 -type f \
            ! -iname 'BCD' ! -iname 'BCD.*' \
            -exec cp {} "$boot_mount/Boot/" \; 2>/dev/null || true
        find "$MOUNT_TARGET/Windows/Boot/PCAT" -mindepth 1 -maxdepth 1 -type d \
            -exec cp -r {} "$boot_mount/Boot/" \; 2>/dev/null || true
    fi

    # bootmgr must live on the active/boot partition root (System Reserved only).
    if [ -f "$MOUNT_TARGET/bootmgr" ]; then
        cp "$MOUNT_TARGET/bootmgr" "$boot_mount/" || die "Failed to copy bootmgr to boot partition"
    elif [ -f "$MOUNT_TARGET/Windows/Boot/PCAT/bootmgr" ]; then
        cp "$MOUNT_TARGET/Windows/Boot/PCAT/bootmgr" "$boot_mount/" || die "Failed to copy bootmgr to boot partition"
    else
        umount "$boot_mount" 2>/dev/null || true
        die "bootmgr not found in applied Windows image — BIOS boot cannot be configured"
    fi

    # CRITICAL: Remove WIM-shipped bootmgr + stale Boot\BCD from the Windows
    # volume. GRUB search --file /bootmgr previously landed here and bootmgr
    # then loaded the stale BCD → 0xc000000f.
    rm -f "$MOUNT_TARGET/bootmgr" \
        "$MOUNT_TARGET/Boot/BCD" "$MOUNT_TARGET/Boot/BCD.LOG" \
        "$MOUNT_TARGET/Boot/BCD.LOG1" "$MOUNT_TARGET/Boot/BCD.LOG2" \
        "$MOUNT_TARGET/Boot/HETZNER" 2>/dev/null || true
    mkdir -p "$MOUNT_TARGET/Boot"
    if [ -d "$MOUNT_TARGET/Windows/Boot/PCAT" ]; then
        find "$MOUNT_TARGET/Windows/Boot/PCAT" -maxdepth 1 -type f \
            ! -iname 'BCD' ! -iname 'BCD.*' ! -iname 'bootmgr' \
            -exec cp -n {} "$MOUNT_TARGET/Boot/" \; 2>/dev/null || true
    fi

    mkdir -p "$boot_mount/Boot/Fonts"
    cp "$MOUNT_TARGET/Windows/Boot/Fonts/"* "$boot_mount/Boot/Fonts/" 2>/dev/null || true

    # Unique GRUB search marker — only on System Reserved
    echo "hetzner-bios-boot" > "$boot_mount/Boot/HETZNER"

    if [ ! -f "$boot_mount/bootmgr" ]; then
        umount "$boot_mount" 2>/dev/null || true
        die "BIOS boot files incomplete after copy (bootmgr missing)"
    fi

    # Optional NTFS VBR (helps chainloader +1); GRUB ntldr does not depend on it.
    if command -v ms-sys &>/dev/null; then
        ms-sys -n "$BOOT_PART" 2>/dev/null && log_detail "Wrote NTFS VBR boot code to $BOOT_PART" || true
    fi

    # Required: GRUB → search /Boot/HETZNER → ntldr /bootmgr
    if ! install_grub_bios_ntldr_on_disk "$TARGET_DISK" "$boot_mount" /tmp/grub-install-bios.log; then
        umount "$boot_mount" 2>/dev/null || true
        die "GRUB ntldr install failed on $TARGET_DISK — Legacy BIOS cannot be guaranteed. See /tmp/grub-install-bios.log"
    fi

    parted -s "$TARGET_DISK" set 1 boot on 2>/dev/null || true

    umount "$boot_mount"
    rmdir "$boot_mount" 2>/dev/null || true

    log_info "Legacy BIOS boot configured on $TARGET_DISK (GRUB → /Boot/HETZNER → bootmgr)."
}

write_boot_bcd() {
    log_step "Creating Boot Configuration Data (BCD)..."
    
    local bcd_path=""
    local mount_point=""
    if [ "$BOOT_MODE" = "uefi" ]; then
        mount_point="/mnt/efi"
        mkdir -p "$mount_point"
        mount "$EFI_PART" "$mount_point"
        bcd_path="$mount_point/EFI/Microsoft/Boot/BCD"
    else
        mount_point="/mnt/bootpart"
        mkdir -p "$mount_point"
        mount "$BOOT_PART" "$mount_point"
        bcd_path="$mount_point/Boot/BCD"
        # Purge WIM stale BCD on the Windows volume (causes 0xc000000f if bootmgr finds it).
        rm -f "$MOUNT_TARGET/Boot/BCD" "$MOUNT_TARGET/Boot/BCD.LOG" \
            "$MOUNT_TARGET/Boot/BCD.LOG1" "$MOUNT_TARGET/Boot/BCD.LOG2" \
            "$MOUNT_TARGET/bootmgr" "$MOUNT_TARGET/Boot/HETZNER" 2>/dev/null || true
    fi
    
    # Remove any stale BCD that was copied from the WIM image.
    rm -f "$bcd_path" "${bcd_path}.LOG" "${bcd_path}.LOG1" "${bcd_path}.LOG2" 2>/dev/null || true
    
    # Locate the BCD-Template shipped inside the installed Windows image.
    # IMPORTANT: Do NOT use $MOUNT_TARGET/Boot/BCD — it contains stale device
    # references from the WIM build environment and causes 0xc000000f.
    local src_bcd=""
    if [ -f "$MOUNT_TARGET/Windows/System32/config/BCD-Template" ]; then
        src_bcd="$MOUNT_TARGET/Windows/System32/config/BCD-Template"
    fi
    
    if [ -z "$src_bcd" ]; then
        umount "$mount_point" 2>/dev/null || true
        if [ "$BOOT_MODE" = "bios" ]; then
            die "No BCD-Template in Windows image — Legacy BIOS cannot build Boot\\BCD. Re-apply image or use UEFI."
        fi
        log_warn "No BCD template found. Adding bcdboot recovery to first-boot commands."
        return
    fi
    
    sync
    udevadm settle --timeout=5 2>/dev/null || true

    mkdir -p "$(dirname "$bcd_path")"
    cp "$src_bcd" "$bcd_path" || {
        umount "$mount_point" 2>/dev/null || true
        die "Failed to write BCD to $bcd_path"
    }
    [ -f "$bcd_path" ] || {
        umount "$mount_point" 2>/dev/null || true
        die "BCD missing after write: $bcd_path"
    }
    log_detail "BCD initialized from $src_bcd"

    if [ "$BOOT_MODE" = "bios" ]; then
        # BCD-Template often references winload.efi — fatal on Legacy BIOS (0xc0000001).
        [ -f "$MOUNT_TARGET/Windows/System32/winload.exe" ] || {
            umount "$mount_point" 2>/dev/null || true
            die "winload.exe missing from Windows volume — image apply incomplete."
        }
        patch_bios_bcd_winload "$bcd_path" || {
            umount "$mount_point" 2>/dev/null || true
            die "Failed to patch BCD for BIOS (winload.exe). See $LOG_FILE."
        }

        # Ensure unique GRUB search marker co-located with good BCD + bootmgr
        echo "hetzner-bios-boot" > "$mount_point/Boot/HETZNER"
        [ -f "$mount_point/bootmgr" ] || die "bootmgr missing on System Reserved while writing BCD"
        [ -f "$mount_point/Boot/HETZNER" ] || die "HETZNER boot marker missing after BCD write"
        # Re-write grub.cfg in case boot setup order left an old search-/bootmgr config
        if [ -d "$mount_point/grub" ]; then
            write_grub_ntldr_cfg "$mount_point/grub/grub.cfg"
            log_detail "Refreshed GRUB cfg to search /Boot/HETZNER (avoid stale WIM BCD)"
        fi
    fi

    # BCD-Template uses "locate" device entries that search partitions for winload.
    # First-boot bcdboot then writes permanent partition-specific entries.
    
    umount "$mount_point" 2>/dev/null || true
    log_info "BCD setup completed."
}

# Patch offline BCD store for Legacy BIOS: winload.efi → winload.exe (element 0x12000002).
# Without this, bootmgr loads the BCD then fails with 0xc0000001 on CSM/Legacy.
patch_bios_bcd_winload() {
    local bcd_path="$1"
    [ -f "$bcd_path" ] || return 1
    python3 -c 'import hivex' >/dev/null 2>&1 || ensure_python_hivex || return 1

    log_detail "Patching BCD application paths for BIOS (winload.exe / winresume.exe)..."
    python3 - "$bcd_path" <<'PY'
import re
import sys
import hivex

bcd_path = sys.argv[1]
h = hivex.Hivex(bcd_path, write=True)

def child(node, key):
    for c in h.node_children(node):
        if h.node_name(c) == key:
            return c
    return None

def u16(s):
    return (s + "\0").encode("utf-16le")

root = h.root()
objects = child(root, "Objects")
if objects is None:
    print("ERROR: BCD Objects key missing", file=sys.stderr)
    sys.exit(2)

patched = 0
scanned = 0
for obj in h.node_children(objects):
    elements = child(obj, "Elements")
    if elements is None:
        continue
    el = child(elements, "12000002")
    if el is None:
        continue
    scanned += 1
    try:
        val = h.node_get_value(el, "Element")
    except Exception:
        continue
    t, data = h.value_value(val)
    try:
        s = data.decode("utf-16le", errors="strict").rstrip("\0")
    except Exception:
        s = data.decode("utf-16le", errors="ignore").rstrip("\0")
    news = re.sub(r"winload\.efi", "winload.exe", s, flags=re.IGNORECASE)
    news = re.sub(r"winresume\.efi", "winresume.exe", news, flags=re.IGNORECASE)
    if news != s:
        h.node_set_values(el, [{"key": "Element", "t": 1, "value": u16(news)}])
        patched += 1
        print(f"OK patched: {s} -> {news}")

h.commit(bcd_path)
print(f"OK BCD path scan={scanned} patched={patched}")
# Must have patched at least one path on Server images, OR already be .exe-only
if scanned == 0:
    print("ERROR: no ApplicationPath (12000002) elements in BCD", file=sys.stderr)
    sys.exit(3)
sys.exit(0)
PY
}

create_winpeshl_ini() {
    log_step "Configuring Windows Setup for first boot..."
    
    # Create a script that Windows PE will run to apply the image properly
    # This ensures the unattend.xml is picked up during the specialize pass
    
    # Make sure the Panther directory exists
    mkdir -p "$MOUNT_TARGET/Windows/Panther"
    
    # Create SetupComplete script that handles final configuration
    mkdir -p "$MOUNT_TARGET/Windows/Setup/Scripts"
    
    cat > "$MOUNT_TARGET/Windows/Setup/Scripts/SetupComplete.cmd" << SETUPEOF
@echo off
REM SetupComplete.cmd runs BEFORE FirstLogonCommands.
REM Only rebuild BCD here; network and post-install run via FirstLogonCommands
REM to avoid double-execution and file-deletion races.

echo Running Hetzner first-boot setup... >> C:\hetzner-setup.log

REM Rebuild BCD with correct partition references (critical for first boot)
echo Rebuilding BCD boot configuration... >> C:\hetzner-setup.log
bcdboot C:\Windows /f ALL >> C:\hetzner-setup.log 2>&1
REM BIOS hardening: also rewrite NT60 boot code on system/boot volumes when available
if exist "%SystemRoot%\System32\bootsect.exe" (
    bootsect /nt60 SYS /mbr >> C:\hetzner-setup.log 2>&1
    bootsect /nt60 ALL /force >> C:\hetzner-setup.log 2>&1
)
echo BCD rebuild complete. >> C:\hetzner-setup.log

REM Clean up this script
del /q "%~f0" >nul 2>&1
SETUPEOF

    log_info "First-boot configuration ready."
}

finalize_installation() {
    log_step "Finalizing installation..."
    
    # Ensure all files are synced to disk
    sync
    
    # Unmount all
    umount "$MOUNT_TARGET" 2>/dev/null || true
    umount "$MOUNT_ISO" 2>/dev/null || true
    umount "$MOUNT_WORK" 2>/dev/null || true
    
    # Note: Do NOT run ntfsfix here. On a freshly applied WIM image the NTFS
    # journal is clean; ntfsfix can alter metadata in ways that trigger an
    # unwanted chkdsk on first Windows boot.
    
    log_info "Installation finalized."
}

print_completion() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          Installation Complete!                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  The server will now boot into Windows Server 2025 setup."
    echo -e "  After Windows finishes installing (5-15 minutes), you can"
    echo -e "  connect via RDP."
    echo ""

    # Always print password loudly at the end (easy to miss earlier in a long log)
    show_admin_password "FINAL CREDENTIALS — COPY BEFORE REBOOT"

    echo -e "  ${YELLOW}Important Notes:${NC}"
    echo -e "  • Windows may restart several times during setup"
    echo -e "  • First boot takes longer due to hardware detection"
    echo -e "  • If RDP doesn't connect, wait 5 more minutes"
    echo -e "  • Use KVM console if network issues occur"
    echo -e "  • Windows evaluation period: 180 days"
    echo ""
    
    # Save credentials to a file
    cat > "/root/windows-credentials.txt" << CREDEOF
Windows Server 2025 - Hetzner Installation
===========================================
Date: $(date)

RDP Address:  ${SERVER_IP}:3389
Username:     Administrator
Password:     ${ADMIN_PASSWORD}

Gateway:      ${GATEWAY}
DNS:          ${DNS_PRIMARY}, ${DNS_SECONDARY}
Boot Mode:    ${BOOT_MODE^^}
Target Disk:  ${TARGET_DISK}
Target ID:    ${TARGET_DISK_ID:-n/a}
Work Disk:    ${WORK_DISK}
Work ID:      ${WORK_DISK_ID:-n/a}
===========================================
CREDEOF
    chmod 600 /root/windows-credentials.txt
    echo -e "  Credentials saved to: ${GREEN}/root/windows-credentials.txt${NC}"
    echo ""

    # Optional Telegram / Discord notify — never fail the install
    send_completion_notify || log_warn "Notification helper returned an error (ignored)"

    set_stage "complete"
    rm -f "$STATE_FILE" 2>/dev/null || true
    
    if [ "${SKIP_CONFIRM:-0}" != "1" ]; then
        read -rp "Reboot the server now? (Y/n): " reboot_confirm
        if [ "$reboot_confirm" != "n" ] && [ "$reboot_confirm" != "N" ]; then
            log_info "Rebooting server..."
            reboot
        else
            log_info "Reboot skipped. Run 'reboot' when ready."
        fi
    else
        # Give time to copy the password from the console before reboot
        echo -e "${YELLOW}Password again: ${GREEN}${ADMIN_PASSWORD}${NC}"
        echo -e "${CYAN}Rebooting in 20 seconds — copy the password above now...${NC}"
        sleep 20
        log_info "Rebooting server..."
        reboot
    fi
}

# ===================== Argument Parsing =====================

parse_args() {
    ISO_URL="$DEFAULT_ISO_URL"
    SERVER_IP=""
    GATEWAY=""
    SUBNET_PREFIX=""
    SUBNET_MASK=""
    NETWORK_MODE=""
    ADMIN_PASSWORD=""
    TARGET_DISK=""
    WORK_DISK=""
    TARGET_DISK_ID=""
    WORK_DISK_ID=""
    # Non-interactive by default for piped one-liners; --confirm or a TTY wizard can override.
    if [ -t 0 ]; then
        SKIP_CONFIRM=0
    else
        SKIP_CONFIRM=1
    fi
    FORCE_UEFI=""
    FORCE_BIOS=""
    INTERACTIVE_MODE=""
    DRY_RUN=0
    FORCE_CLEAN=0
    RESUME_MODE=0
    SKIP_WORKSPACE_WIPE=0
    SKIP_PARTITION=0
    SKIP_WIM_APPLY=0
    PLATFORM_TYPE=""
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
    DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --ip)
                [ $# -ge 2 ] || die "$1 requires a value."
                SERVER_IP="$2"; shift 2 ;;
            --gateway)
                [ $# -ge 2 ] || die "$1 requires a value."
                GATEWAY="$2"; shift 2 ;;
            --password)
                [ $# -ge 2 ] || die "$1 requires a value."
                ADMIN_PASSWORD="$2"; shift 2 ;;
            --iso-url)
                [ $# -ge 2 ] || die "$1 requires a value."
                ISO_URL="$2"; shift 2 ;;
            --target-disk)
                [ $# -ge 2 ] || die "$1 requires a value."
                TARGET_DISK="$2"; shift 2 ;;
            --work-disk)
                [ $# -ge 2 ] || die "$1 requires a value."
                WORK_DISK="$2"; shift 2 ;;
            --skip-confirm)
                SKIP_CONFIRM=1; shift ;;
            --confirm)
                SKIP_CONFIRM=0; shift ;;
            --uefi)
                [ -n "${FORCE_BIOS:-}" ] && die "Cannot use both --uefi and --bios."
                FORCE_UEFI=1; shift ;;
            --bios)
                [ -n "${FORCE_UEFI:-}" ] && die "Cannot use both --uefi and --bios."
                FORCE_BIOS=1; shift ;;
            --single-disk)
                die "--single-disk is not supported safely in this version. Use a second disk for workspace." ;;
            --interactive|-i)
                INTERACTIVE_MODE=1; SKIP_CONFIRM=0; shift ;;
            --dry-run)
                DRY_RUN=1; SKIP_CONFIRM=1; shift ;;
            --force|--clean)
                FORCE_CLEAN=1; shift ;;
            --version)
                echo "hetznerWindowsOSinstaller $SCRIPT_VERSION"
                exit 0
                ;;
            --telegram-token)
                [ $# -ge 2 ] || die "$1 requires a value."
                TELEGRAM_BOT_TOKEN="$2"; shift 2 ;;
            --telegram-chat)
                [ $# -ge 2 ] || die "$1 requires a value."
                TELEGRAM_CHAT_ID="$2"; shift 2 ;;
            --discord-webhook)
                [ $# -ge 2 ] || die "$1 requires a value."
                DISCORD_WEBHOOK_URL="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --ip <IP>           Server IPv4 address (auto-detected)"
                echo "  --gateway <GW>      Gateway address (auto-detected)"
                echo "  --password <PASS>   Administrator password (auto-generated)"
                echo "  --iso-url <URL>     Windows ISO download URL"
                echo "  --target-disk <DEV> Target disk for Windows (largest disk if omitted; prefer by-id)"
                echo "  --work-disk <DEV>   Work disk for temp files (second-largest if omitted; prefer by-id)"
                echo "  --skip-confirm      Skip all confirmation prompts (default if stdin is not a TTY)"
                echo "  --confirm           Require typing 'yes' before wiping disks"
                echo "  --uefi              Force UEFI boot mode"
                echo "  --bios              Force Legacy BIOS (auto on Cloud when firmware is Legacy)"
                echo "  --single-disk       Not supported safely in this version"
                echo "  --interactive, -i   Launch interactive wizard"
                echo "  --dry-run           Validate detection and configuration only"
                echo "  --force, --clean    Clear resume state and force full wipe/reinstall"
                echo "  --version           Print version and exit"
                echo "  --telegram-token    Telegram bot token (or TELEGRAM_BOT_TOKEN)"
                echo "  --telegram-chat     Telegram chat id (or TELEGRAM_CHAT_ID)"
                echo "  --discord-webhook   Discord webhook URL (or DISCORD_WEBHOOK_URL)"
                echo "  --help              Show this help"
                exit 0
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

# ===================== Main Execution =====================

main() {
    # Capture CLI-provided values before optional state load overwrites empties
    local cli_server_ip="$SERVER_IP"
    local cli_gateway="$GATEWAY"
    local cli_password="$ADMIN_PASSWORD"
    local cli_target="$TARGET_DISK"
    local cli_work="$WORK_DISK"
    local cli_iso_url="$ISO_URL"

    setup_logging
    banner
    
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root."
    fi

    if [ "${FORCE_CLEAN:-0}" = "1" ]; then
        clear_state
    elif [ -f "$STATE_FILE" ]; then
        load_state
        # CLI flags win over saved state
        # CLI flags win over saved state when provided
        [ -n "$cli_server_ip" ] && SERVER_IP="$cli_server_ip"
        [ -n "$cli_gateway" ] && GATEWAY="$cli_gateway"
        [ -n "$cli_password" ] && ADMIN_PASSWORD="$cli_password"
        if [ -n "$cli_target" ]; then
            TARGET_DISK="$cli_target"
            TARGET_DISK_ID=""  # re-resolve; do not keep stale by-id from prior selection
        fi
        if [ -n "$cli_work" ]; then
            WORK_DISK="$cli_work"
            WORK_DISK_ID=""
        fi
        # parse_args always sets ISO_URL to default; only override state when user passed --iso-url
        # Detect via: if state had a custom URL and CLI is still default, keep state.
        if [ "$cli_iso_url" != "$DEFAULT_ISO_URL" ]; then
            ISO_URL="$cli_iso_url"
        fi
    fi
    
    progress_step 1 "Environment"
    check_rescue_mode
    check_dependencies
    set_stage "deps"
    
    if [ "${INTERACTIVE_MODE:-}" = "1" ]; then
        interactive_wizard
        # Wizard picks live /dev paths; clear any resumed by-id so detect_disks recomputes.
        TARGET_DISK_ID=""
        WORK_DISK_ID=""
    fi
    
    progress_step 2 "Detection"
    detect_network
    detect_disks
    detect_boot_mode
    generate_password
    preflight_health_check
    preflight_legacy_guaranteed
    evaluate_resume_options
    set_stage "detection"
    
    progress_step 3 "Confirmation"
    confirm_settings

    if [ "$DRY_RUN" = "1" ]; then
        log_info "Dry run completed successfully. No disks were modified."
        return
    fi
    
    progress_step 4 "Workspace"
    prepare_work_disk
    
    progress_step 5 "Downloads"
    download_iso
    download_virtio
    set_stage "downloads"
    
    progress_step 6 "Partitioning"
    if [ "${SKIP_PARTITION:-0}" = "1" ]; then
        assign_partition_vars
        log_info "Skipping target disk wipe/partition (resume)"
    else
        partition_target_disk
    fi

    progress_step 7 "Windows image"
    extract_windows
    inject_drivers
    
    # Configuration + bootloader always re-run (safe to overwrite)
    progress_step 8 "Configuration"
    generate_unattend_xml
    create_network_script
    create_post_install_script
    create_fix_network_script
    setup_san_policy
    create_winpeshl_ini
    set_stage "configured"
    
    progress_step 9 "Boot setup"
    setup_bootloader
    write_boot_bcd
    install_grub_bios_on_work_disk
    verify_legacy_boot_ready
    set_stage "boot_setup"
    
    progress_step 10 "Finalize"
    finalize_installation
    print_completion
}

# Parse command line arguments
parse_args "$@"

# Set up trap for cleanup on error
trap cleanup EXIT

# Run main
main
