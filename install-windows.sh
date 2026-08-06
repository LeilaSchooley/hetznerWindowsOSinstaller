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
#
# Requirements:
#   - Hetzner dedicated/Cloud server booted into rescue mode
#   - At least 2 physical drives (or Cloud disk + Volume)
#   - Minimum 4GB RAM
#
# Notes:
#   - Disks are selected by size (largest = Windows, second-largest = workspace),
#     never by /dev/sdX letter order (Cloud often swaps sda/sdb).
#   - VirtIO storage + network drivers are always injected (required on Cloud).
#   - This version requires a dedicated workspace disk and does not support
#     single-disk installs safely.
#
###############################################################################

set -euo pipefail

# ===================== Configuration Defaults =====================

SCRIPT_VERSION="3.3.0"

# Default ISO URL (Windows Server 2025 Evaluation — official Microsoft)
DEFAULT_ISO_URL="https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1742.240906-0331.ge_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"

# Alternate ISO mirror hosted by Hetzner. Kept as a fallback for environments
# where the Microsoft CDN is slow or temporarily unavailable.
HETZNER_ISO_MIRROR_URL="https://download.hetzner.com/bootimages/windows/SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-81891.ISO"

# VirtIO drivers ISO (Red Hat signed, for Hetzner's KVM/QEMU if needed)
VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

# Hetzner DNS servers
DNS_PRIMARY="185.12.64.1"
DNS_SECONDARY="185.12.64.2"

MIN_TARGET_DISK_BYTES=40000000000
MIN_WORK_DISK_BYTES=8000000000

# Working directories
MOUNT_ISO="/mnt/iso"
MOUNT_WORK="/mnt/work"
MOUNT_TARGET="/mnt/target"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ===================== Functions =====================

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $*"; }
log_detail()  { echo -e "${BLUE}  →${NC} $*"; }

TOTAL_STEPS=10

progress_step() {
    local step="$1"
    local label="$2"
    local percent=$(( step * 100 / TOTAL_STEPS ))
    local filled=$(( percent / 5 ))
    local bar

    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
    printf "\n${CYAN}[PROGRESS]${NC} Step %s/%s (%s%%) %-20s [%s%-*s]\n" \
        "$step" "$TOTAL_STEPS" "$percent" "$label" "$bar" "$((20 - filled))" ""
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

check_dependencies() {
    log_step "Checking dependencies..."
    local deps=(wget parted mkfs.ntfs wimlib-imagex lsblk mkfs.fat awk cut ip python3 blkid numfmt)
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_info "Installing missing dependencies: ${missing[*]}"
        apt-get update -qq
        apt-get install -y -qq wget parted ntfs-3g wimtools dosfstools gdisk grub-pc-bin grub-efi-amd64-bin efibootmgr libhivex-bin ms-sys 2>/dev/null || true
        
        # Re-check
        for dep in "${deps[@]}"; do
            if ! command -v "$dep" &>/dev/null; then
                die "Required tool '$dep' not found and could not be installed."
            fi
        done
    fi
    
    log_info "All dependencies satisfied."
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
        local size
        size=$(lsblk -dpno SIZE "$disk" 2>/dev/null || echo "unknown")
        local model
        model=$(lsblk -dpno MODEL "$disk" 2>/dev/null || echo "unknown")
        log_detail "$disk - Size: $size - Model: $model"
    done
    
    if [ ${#ALL_DISKS[@]} -lt 2 ]; then
        die "This installer currently requires 2 physical disks: one target disk and one workspace disk (e.g. Cloud root disk + Volume). Single-disk mode is not supported safely in this version."
    fi
    
    # Select by size: largest = Windows target, second-largest = workspace.
    # On Cloud + Volume this puts ~40–300+ GB root disk as target and the Volume as work.
    if [ -z "${TARGET_DISK:-}" ]; then
        TARGET_DISK="${ALL_DISKS[0]}"
        log_detail "Auto-selected largest disk as target: $TARGET_DISK"
    fi
    
    if [ -z "${WORK_DISK:-}" ]; then
        WORK_DISK="${ALL_DISKS[1]}"
        log_detail "Auto-selected second-largest disk as workspace: $WORK_DISK"
    fi
    
    if [ "$TARGET_DISK" = "$WORK_DISK" ]; then
        die "Target disk and work disk cannot be the same device: $TARGET_DISK"
    fi

    if [ ! -b "$TARGET_DISK" ]; then
        die "Target disk does not exist: $TARGET_DISK"
    fi
    if [ ! -b "$WORK_DISK" ]; then
        die "Work disk does not exist: $WORK_DISK"
    fi

    local target_size work_size
    target_size=$(lsblk -dbno SIZE "$TARGET_DISK" 2>/dev/null || echo 0)
    work_size=$(lsblk -dbno SIZE "$WORK_DISK" 2>/dev/null || echo 0)

    # Warn if someone overrode disks and target is smaller than work (common sda/sdb swap mistake)
    if [ "$target_size" -lt "$work_size" ]; then
        log_warn "Target disk ($TARGET_DISK) is smaller than work disk ($WORK_DISK)."
        log_warn "On Hetzner Cloud, Windows should usually go on the larger root disk."
    fi

    [ "$target_size" -ge "$MIN_TARGET_DISK_BYTES" ] || \
        die "Target disk is too small for Windows Server: $TARGET_DISK ($(numfmt --to=iec "$target_size" 2>/dev/null || echo "$target_size"))"
    [ "$work_size" -ge "$MIN_WORK_DISK_BYTES" ] || \
        die "Work disk is too small for ISO workspace: $WORK_DISK ($(numfmt --to=iec "$work_size" 2>/dev/null || echo "$work_size"))"

    log_detail "Target disk (Windows): $TARGET_DISK"
    log_detail "Work disk (temp):      $WORK_DISK"
}

detect_boot_mode() {
    log_step "Detecting boot mode..."
    
    if [ -n "${FORCE_UEFI:-}" ]; then
        BOOT_MODE="uefi"
    elif [ -n "${FORCE_BIOS:-}" ]; then
        BOOT_MODE="bios"
    elif [ -d /sys/firmware/efi ]; then
        BOOT_MODE="uefi"
    else
        BOOT_MODE="bios"
    fi
    
    log_detail "Boot mode: ${BOOT_MODE^^}"
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
    echo -e "  Work Disk:        ${GREEN}$WORK_DISK${NC}"
    echo -e "  Boot Mode:        ${GREEN}${BOOT_MODE^^}${NC}"
    echo -e "  Network Mode:     ${GREEN}${NETWORK_MODE}${NC}"
    echo -e "  Subnet Mask:      ${GREEN}${SUBNET_MASK}${NC}"
    local iso_display="$ISO_URL"
    [ ${#iso_display} -gt 60 ] && iso_display="${ISO_URL:0:57}..."
    echo -e "  ISO URL:          ${GREEN}${iso_display}${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${RED}  ⚠ WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED!${NC}"
    echo ""
    
    if [ "${SKIP_CONFIRM:-0}" != "1" ]; then
        read -rp "Proceed with installation? (yes/NO): " confirm
        [ "$confirm" = "yes" ] || die "Installation aborted by user."
    fi
}

prepare_work_disk() {
    log_step "Preparing work disk..."
    
    # Unmount any existing mounts on work disk
    umount "${WORK_DISK}"* 2>/dev/null || true

    # Wipe and format the entire work disk
    wipefs -a "$WORK_DISK" 2>/dev/null || true
    parted -s "$WORK_DISK" mklabel gpt
    parted -s "$WORK_DISK" mkpart primary ntfs 1MiB 100%
    partprobe "$WORK_DISK" 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || sleep 3

    WORK_PART=$(partition_path "$WORK_DISK" 1)
    
    log_detail "Formatting workspace partition: $WORK_PART"
    mkfs.ntfs -f -L "WORKSPACE" "$WORK_PART" || die "Failed to format workspace"
    
    mkdir -p "$MOUNT_WORK"
    mount "$WORK_PART" "$MOUNT_WORK" || die "Failed to mount workspace"
    
    log_info "Workspace ready at $MOUNT_WORK"
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
}

extract_windows() {
    log_step "Extracting Windows installation files..."
    
    # Mount ISO
    mkdir -p "$MOUNT_ISO"
    mount -o loop,ro "$ISO_PATH" "$MOUNT_ISO" || die "Failed to mount ISO"
    
    # Mount target Windows partition
    mkdir -p "$MOUNT_TARGET"
    mount "$WIN_PART" "$MOUNT_TARGET" || die "Failed to mount target partition"
    
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
    
    wimlib-imagex info "$wim_file" "$image_index" >/dev/null 2>&1 || die "Selected Windows image index $image_index is not available"
    
    log_detail "Applying image index $image_index to $WIN_PART..."
    wimlib-imagex apply "$wim_file" "$image_index" "$MOUNT_TARGET" || die "Failed to apply Windows image"
    
    log_info "Windows files extracted successfully."
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

    # Critical for Cloud: viostor (disk), vioscsi, NetKVM (network), plus balloon/viorng/vioserial
    local packages=(viostor vioscsi NetKVM balloon viorng vioserial qxldod)
    local pkg arch_dir
    for pkg in "${packages[@]}"; do
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
            cp -r "$arch_dir"/* "$driver_stage/" 2>/dev/null || log_warn "Failed to copy $pkg drivers"
            cp -n "$arch_dir"/*.inf "$MOUNT_TARGET/Windows/INF/" 2>/dev/null || true
            cp -n "$arch_dir"/*.sys "$MOUNT_TARGET/Windows/System32/drivers/" 2>/dev/null || true
            cp -n "$arch_dir"/*.cat "$MOUNT_TARGET/Windows/INF/" 2>/dev/null || true
            copied_driver_dirs=$((copied_driver_dirs + 1))
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

    log_info "VirtIO drivers staged ($copied_driver_dirs packages) at Windows\\Drivers\\VirtIO"
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

setup_bios_boot() {
    log_detail "Configuring Legacy BIOS boot..."
    
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
    
    # bootmgr must live on the active/boot partition root
    if [ -f "$MOUNT_TARGET/bootmgr" ]; then
        cp "$MOUNT_TARGET/bootmgr" "$boot_mount/" || die "Failed to copy bootmgr to boot partition"
    elif [ -f "$MOUNT_TARGET/Windows/Boot/PCAT/bootmgr" ]; then
        cp "$MOUNT_TARGET/Windows/Boot/PCAT/bootmgr" "$boot_mount/" || die "Failed to copy bootmgr to boot partition"
    else
        die "bootmgr not found in applied Windows image — BIOS boot cannot be configured"
    fi

    # Also keep a copy on the Windows volume (bcdboot / recovery expect it)
    cp "$boot_mount/bootmgr" "$MOUNT_TARGET/bootmgr" 2>/dev/null || true
    
    mkdir -p "$boot_mount/Boot/Fonts"
    cp "$MOUNT_TARGET/Windows/Boot/Fonts/"* "$boot_mount/Boot/Fonts/" 2>/dev/null || true

    # Critical BIOS files
    [ -f "$boot_mount/Boot/bootmgr.exe" ] || [ -f "$boot_mount/bootmgr" ] || \
        die "BIOS boot files incomplete after copy"

    umount "$boot_mount"
    rmdir "$boot_mount"
    
    # Write Windows 7+ MBR and NTFS VBR boot code (ms-sys).
    # Note: bootmgr is a PE executable, NOT MBR boot sector data — never dd it to MBR.
    local mbr_ok=0 vbr_ok=0
    if command -v ms-sys &>/dev/null; then
        if ms-sys -7 "$TARGET_DISK" 2>/dev/null; then
            mbr_ok=1
            log_detail "Wrote Windows MBR to $TARGET_DISK"
        fi
        if ms-sys -n "$BOOT_PART" 2>/dev/null; then
            vbr_ok=1
            log_detail "Wrote NTFS VBR boot code to $BOOT_PART"
        fi
    fi

    if [ "$mbr_ok" != "1" ] || [ "$vbr_ok" != "1" ]; then
        log_warn "ms-sys MBR/VBR write incomplete (mbr=$mbr_ok vbr=$vbr_ok)."
        log_warn "BCD template + first-boot bcdboot should still repair boot on many systems."
        if is_virtual_machine; then
            log_warn "On Hetzner Cloud, prefer UEFI (enable in Cloud Console) and re-run with --uefi."
        fi
    fi
    
    log_info "Legacy BIOS boot configured."
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
    fi
    
    # Remove any stale BCD that was copied from the WIM image.
    # These contain device references to the original media and cause 0xc000000f.
    rm -f "$bcd_path" "${bcd_path}.LOG" "${bcd_path}.LOG1" "${bcd_path}.LOG2" 2>/dev/null || true
    
    # Locate the BCD-Template shipped inside the installed Windows image.
    # IMPORTANT: Do NOT use $MOUNT_TARGET/Boot/BCD — it contains stale device
    # references from the WIM build environment and causes 0xc000000f.
    local src_bcd=""
    if [ -f "$MOUNT_TARGET/Windows/System32/config/BCD-Template" ]; then
        src_bcd="$MOUNT_TARGET/Windows/System32/config/BCD-Template"
    fi
    
    if [ -z "$src_bcd" ]; then
        log_warn "No BCD template found. Adding bcdboot recovery to first-boot commands."
        umount "$mount_point" 2>/dev/null || true
        return
    fi
    
    sync
    udevadm settle --timeout=5 2>/dev/null || true

    mkdir -p "$(dirname "$bcd_path")"
    cp "$src_bcd" "$bcd_path"
    log_detail "BCD initialized from $src_bcd"
    
    # The BCD-Template shipped with Windows uses "locate" device entries
    # that search all partitions for \Windows\system32\winload.efi at boot.
    # This allows the first boot to succeed without patching exact partition
    # GUIDs into the binary BCD hive.  The first-boot bcdboot command
    # (in SetupComplete.cmd and FirstLogonCommands) will then create a
    # permanent BCD with the correct partition references.
    
    umount "$mount_point" 2>/dev/null || true
    log_info "BCD setup completed."
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
===========================================
CREDEOF
    chmod 600 /root/windows-credentials.txt
    echo -e "  Credentials saved to: ${GREEN}/root/windows-credentials.txt${NC}"
    echo ""
    
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
            --help|-h)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --ip <IP>           Server IPv4 address (auto-detected)"
                echo "  --gateway <GW>      Gateway address (auto-detected)"
                echo "  --password <PASS>   Administrator password (auto-generated)"
                echo "  --iso-url <URL>     Windows ISO download URL"
                echo "  --target-disk <DEV> Target disk for Windows (largest disk if omitted)"
                echo "  --work-disk <DEV>   Work disk for temp files (second-largest if omitted)"
                echo "  --skip-confirm      Skip all confirmation prompts (default if stdin is not a TTY)"
                echo "  --confirm           Require typing 'yes' before wiping disks"
                echo "  --uefi              Force UEFI boot mode"
                echo "  --bios              Force Legacy BIOS boot mode"
                echo "  --single-disk       Not supported safely in this version"
                echo "  --interactive, -i   Launch interactive wizard"
                echo "  --dry-run           Validate detection and configuration only"
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
    banner
    
    # Pre-flight checks
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root."
    fi
    
    progress_step 1 "Environment"
    check_rescue_mode
    check_dependencies
    
    # Interactive wizard if requested or if no arguments given
    if [ "${INTERACTIVE_MODE:-}" = "1" ]; then
        interactive_wizard
    fi
    
    # Detection phase (fills in anything not already set)
    progress_step 2 "Detection"
    detect_network
    detect_disks
    detect_boot_mode
    generate_password
    
    # Confirm before proceeding
    progress_step 3 "Confirmation"
    confirm_settings

    if [ "$DRY_RUN" = "1" ]; then
        log_info "Dry run completed successfully. No disks were modified."
        return
    fi
    
    # Prepare workspace
    progress_step 4 "Workspace"
    prepare_work_disk
    
    # Download phase
    progress_step 5 "Downloads"
    download_iso
    download_virtio
    
    # Installation phase
    progress_step 6 "Partitioning"
    partition_target_disk
    progress_step 7 "Windows image"
    extract_windows
    inject_drivers
    
    # Configuration phase
    progress_step 8 "Configuration"
    generate_unattend_xml
    create_network_script
    create_post_install_script
    create_fix_network_script
    setup_san_policy
    create_winpeshl_ini
    
    # Boot setup
    progress_step 9 "Boot setup"
    setup_bootloader
    write_boot_bcd
    
    # Finalize
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
