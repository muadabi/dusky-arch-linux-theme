#!/usr/bin/env bash

# ================================================================================
# NVIDIA Driver Installer for Arch Linux (2026 Edition)
# Targets: Hyprland / Wayland / NVIDIA 590+ Driver Architecture
#
# Supports:
#   - Turing+ (RTX 20xx+, GTX 16xx, Professional) → nvidia-open-dkms
#   - Maxwell / Pascal / Volta (GTX 750+, 9xx, 10xx) → nvidia-580xx-dkms (AUR)
#   - Hybrid GPU (Optimus) detection for correct env vars
#   - All official and community Arch kernels
#
# Usage: Run as a normal user (not root). The script will invoke sudo as needed.
# ================================================================================

# --- Strict Mode ---
set -uo pipefail

# --- Constants ---
readonly SCRIPT_NAME="${0##*/}"
readonly MODPROBE_CONF="/etc/modprobe.d/nvidia.conf"
readonly NOUVEAU_CONF="/etc/modprobe.d/nouveau-blacklist.conf"
readonly MKINITCPIO_CONF="/etc/mkinitcpio.conf"
readonly MKINITCPIO_BAK="/etc/mkinitcpio.conf.bak.nvidia-installer"
readonly HYPR_ENV_FILE="${HOME}/.config/hypr/envs.conf"
readonly SENTINEL_BEGIN="# >>> NVIDIA-AUTO-CONFIG-BEGIN >>>"
readonly SENTINEL_END="# <<< NVIDIA-AUTO-CONFIG-END <<<"

# --- Global State (declared for set -u safety) ---
declare AUR_HELPER=""
declare IS_HYBRID=false
declare NVIDIA_GPU=""
declare GPU_ARCH=""
declare GPU_MARKETING_NAME=""
declare GPU_CHIP_NAME=""
declare PCI_DEVICE_ID=""
declare -a DRIVER_PACKAGES=()
declare -a HEADER_PACKAGES=()
declare SCRIPT_SUCCESS=false
declare SYSTEM_MODIFIED=false

# --- Color Codes ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# --- Logging Functions ---
log_info()    { printf '%b[INFO]%b %s\n'    "$CYAN"   "$NC" "$1"; }
log_success() { printf '%b[SUCCESS]%b %s\n' "$GREEN"  "$NC" "$1"; }
log_warn()    { printf '%b[WARN]%b %s\n'    "$YELLOW" "$NC" "$1"; }
log_error()   { printf '%b[ERROR]%b %s\n'   "$RED"    "$NC" "$1" >&2; }

die() {
    log_error "$1"
    exit "${2:-1}"
}

# --- Cleanup / Rollback Trap ---
cleanup() {
    if [[ "$SCRIPT_SUCCESS" == true ]]; then
        return 0
    fi
    if [[ "$SYSTEM_MODIFIED" == true ]] && [[ -f "$MKINITCPIO_BAK" ]]; then
        log_warn "Script did not complete successfully."
        log_warn "Restoring mkinitcpio.conf from backup..."
        sudo cp "$MKINITCPIO_BAK" "$MKINITCPIO_CONF" 2>/dev/null || true
        sudo mkinitcpio -P 2>/dev/null || true
        log_warn "mkinitcpio.conf restored. Review system state before rebooting."
    fi
}
trap cleanup EXIT

# --- Preflight Checks ---
preflight_checks() {
    # AUR helpers must not run as root
    if [[ $EUID -eq 0 ]]; then
        die "Do not run this script as root. Run as your normal user; sudo will be invoked where needed."
    fi

    if [[ ! -f /etc/arch-release ]]; then
        die "This script is designed for Arch Linux only."
    fi

    # dkms is omitted: it is pulled as a dependency of the driver packages
    local -a required_tools=(lspci pacman grep sed sudo mkinitcpio)
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            die "Required tool '${tool}' is not installed or not in PATH."
        fi
    done
}

# --- Hybrid GPU Detection ---
detect_hybrid_gpu() {
    local igpu_count
    igpu_count=$(lspci -nn 2>/dev/null \
        | grep -icE '\[03(00|02)\].*\b(intel|amd|radeon)\b') || true

    if [[ "$igpu_count" -ge 1 ]]; then
        IS_HYBRID=true
        log_info "Hybrid GPU (Optimus/PRIME) setup detected."
    else
        IS_HYBRID=false
        log_info "Single NVIDIA GPU setup detected."
    fi

    local gpu_count
    gpu_count=$(lspci -nn 2>/dev/null \
        | grep -iE '\[03(00|02)\]' \
        | grep -ic nvidia) || true
    if [[ "$gpu_count" -gt 1 ]]; then
        log_warn "Multiple NVIDIA GPUs detected; using first for classification."
    fi
}

# --- GPU Detection & Driver Selection ---
detect_gpu_and_driver() {
    local gpu_line
    gpu_line=$(lspci -nn 2>/dev/null \
        | grep -iE '\[03(00|02)\]' \
        | grep -i 'nvidia' \
        | head -n 1) || true

    if [[ -z "$gpu_line" ]]; then
        die "No NVIDIA GPU detected via lspci."
    fi

    NVIDIA_GPU="$gpu_line"
    log_info "Detected GPU: ${BOLD}${NVIDIA_GPU}${NC}"

    # --- Extract marketing name ---
    # lspci -nn format examples:
    #   "... NVIDIA Corporation AD102 [GeForce RTX 4090] [10de:2684] (rev a1)"
    #   "... NVIDIA Corporation GP107 [GeForce GTX 1050] [10de:1c81]"
    #   "... NVIDIA Corporation Device 2900 [10de:2900]"   (unknown to pci.ids)
    #
    # Strategy: extract the text inside brackets immediately before [10de:XXXX]
    GPU_MARKETING_NAME=$(echo "$gpu_line" \
        | grep -oP '\[\K[^\]]+(?=\]\s*\[10de:)') || true

    # Extract chip codename: text between "NVIDIA Corporation" and the first "["
    GPU_CHIP_NAME=$(echo "$gpu_line" \
        | sed -E 's/.*NVIDIA Corporation\s+//' \
        | sed -E 's/\s*\[.*//' \
        | sed -E 's/\s*\(rev .*\)//') || true

    # If no bracketed marketing name, use the chip/device string as fallback
    if [[ -z "$GPU_MARKETING_NAME" ]]; then
        GPU_MARKETING_NAME="$GPU_CHIP_NAME"
    fi

    # Extract PCI device ID for diagnostics
    PCI_DEVICE_ID=$(echo "$gpu_line" | grep -oP '\[10de:\K[0-9a-fA-F]{4}') || true

    log_info "GPU Name: ${BOLD}${GPU_MARKETING_NAME}${NC}"
    log_info "Chip: ${BOLD}${GPU_CHIP_NAME:-unknown}${NC}"
    log_info "PCI Device ID: ${BOLD}10de:${PCI_DEVICE_ID:-unknown}${NC}"

    local gpu_name="$GPU_MARKETING_NAME"

    # -----------------------------------------------------------------------
    # Classification Logic — Two-Pass Approach
    #
    # Pass 1: Match on marketing name (e.g., "GeForce RTX 4090")
    #         This is the primary and most reliable method.
    #
    # Pass 2: If pass 1 fails, match on chip codename (e.g., "TU117", "AD102")
    #         This handles VMs, passthrough, outdated pci.ids, and unknown devices.
    #
    # Turing+ (2018+): GTX 16xx, RTX 20xx-50xx+, Professional A/L/H/T/B
    #   → nvidia-open-dkms (supports GSP firmware)
    #
    # Maxwell/Pascal/Volta (2014-2018):
    #   Maxwell: GTX 745, GTX 750/750 Ti, GTX 8xx (mobile), GTX 9xx
    #   Pascal:  GTX 10xx, GT 10xx, MX150-350, Quadro P, Tesla P
    #   Volta:   Titan V, Quadro GV100, Tesla V100
    #   → nvidia-580xx-dkms from AUR (dropped from mainline in 590+)
    #
    # Kepler and older: NOT handled by this script.
    # -----------------------------------------------------------------------

    # --- Pass 1: Marketing Name Patterns ---

    # Turing+ marketing names
    local turing_name='GTX 16[0-9]{2}'                    # GTX 1630, 1650, 1660
    turing_name+='|RTX [2-9][0-9]{3}'                     # RTX 2060-5090+
    turing_name+='|RTX PRO'                                # 2025+ professional rebrand
    turing_name+='|Quadro RTX [0-9]+'                      # Quadro RTX 3000-8000
    turing_name+='|RTX A[0-9]+'                            # RTX A2000-A6000
    turing_name+='|\b[ALHTB][1-9][0-9]{0,3}\b'            # A2, A100, L4, L40, H100, T4, B100, B200
    turing_name+='|MX[45][0-9]0'                           # MX450, MX550 (Turing+)

    # Maxwell/Pascal/Volta marketing names
    local legacy_name='GTX 750'                            # Maxwell (GM107), matches "750 Ti" too
    legacy_name+='|GTX 745'                                # Maxwell (GM107)
    legacy_name+='|GTX 8[0-9]{2}'                          # 800M series (mobile Maxwell)
    legacy_name+='|GTX 9[0-9]{2}'                          # GTX 950-980 Ti (Maxwell)
    legacy_name+='|GTX 10[0-9]{2}'                         # GTX 1050-1080 Ti (Pascal)
    legacy_name+='|GT 10[0-9]{2}'                          # GT 1030 (Pascal)
    legacy_name+='|Quadro [MP][0-9]+'                      # Quadro M/P series
    legacy_name+='|Quadro GP100'                           # Pascal professional
    legacy_name+='|Quadro GV100'                           # Volta professional
    legacy_name+='|MX[1-3][0-9]0'                          # MX110-MX350
    legacy_name+='|TITAN X\b|TITAN Xp|TITAN V'            # Maxwell/Pascal/Volta Titans
    legacy_name+='|Tesla [PMV][0-9]+'                      # Tesla P100, M40, V100

    # --- Pass 2: Chip Codename Patterns ---

    # Turing+ chip codenames
    local turing_chip='TU10[0-9]'                          # Turing: TU102, TU104, TU106, etc.
    turing_chip+='|TU11[0-9]'                              # Turing: TU116, TU117
    turing_chip+='|GA10[0-9]'                              # Ampere: GA102, GA104, GA106, GA107
    turing_chip+='|AD10[0-9]'                              # Ada Lovelace: AD102, AD103, AD104, AD106, AD107
    turing_chip+='|GB20[0-9]'                              # Blackwell: GB202, GB203, GB205, GB206, GB207

    # Maxwell/Pascal/Volta chip codenames
    local legacy_chip='GM[12][0-9]{2}'                     # Maxwell: GM107, GM108, GM200, GM204, GM206
    legacy_chip+='|GP10[0-9]'                              # Pascal: GP100, GP102, GP104, GP106, GP107, GP108
    legacy_chip+='|GV10[0-9]'                              # Volta: GV100

    # --- Execute classification ---
    if echo "$gpu_name" | grep -qEi "(${turing_name})"; then
        _set_turing_plus "marketing name"

    elif echo "$gpu_name" | grep -qEi "(${legacy_name})"; then
        _set_legacy "marketing name"

    elif [[ -n "$GPU_CHIP_NAME" ]] && echo "$GPU_CHIP_NAME" | grep -qE "(${turing_chip})"; then
        log_warn "Marketing name not recognized; classified via chip codename '${GPU_CHIP_NAME}'."
        _set_turing_plus "chip codename"

    elif [[ -n "$GPU_CHIP_NAME" ]] && echo "$GPU_CHIP_NAME" | grep -qE "(${legacy_chip})"; then
        log_warn "Marketing name not recognized; classified via chip codename '${GPU_CHIP_NAME}'."
        _set_legacy "chip codename"

    else
        log_error "GPU not recognized: ${gpu_name} (chip: ${GPU_CHIP_NAME:-unknown})"
        log_error "PCI ID: 10de:${PCI_DEVICE_ID:-unknown}"
        die "Kepler (GTX 6xx/7xx), Fermi, or older GPUs require nvidia-470xx/nvidia-390xx (not handled). GT 710/720/730/740 have mixed Kepler/Fermi silicon — identify your chip and install manually."
    fi
}

# --- Driver Package Helpers ---
_set_turing_plus() {
    local classified_by="$1"
    log_info "Architecture: ${BOLD}Turing or newer${NC} (GSP-capable, via ${classified_by})."
    DRIVER_PACKAGES=(
        nvidia-open-dkms
        nvidia-utils
        lib32-nvidia-utils
        opencl-nvidia
        libva-nvidia-driver
        egl-wayland
    )
    GPU_ARCH="turing_plus"
}

_set_legacy() {
    local classified_by="$1"
    log_info "Architecture: ${BOLD}Maxwell / Pascal / Volta${NC} (Legacy, via ${classified_by})."
    log_warn "These GPUs are unsupported in driver 590+. Installing 580xx from AUR."
    DRIVER_PACKAGES=(
        nvidia-580xx-dkms
        nvidia-580xx-utils
        lib32-nvidia-580xx-utils
        opencl-nvidia-580xx
        egl-wayland
    )
    GPU_ARCH="maxwell_pascal_volta"
}

# --- Package Manager Detection (conditional on GPU arch) ---
detect_package_manager() {
    if command -v paru &>/dev/null; then
        AUR_HELPER="paru"
    elif command -v yay &>/dev/null; then
        AUR_HELPER="yay"
    else
        AUR_HELPER=""
    fi

    # AUR helper is only required for legacy 580xx packages
    if [[ -z "$AUR_HELPER" ]] && [[ "$GPU_ARCH" == "maxwell_pascal_volta" ]]; then
        die "AUR helper (paru or yay) is required for nvidia-580xx packages. Install one and rerun."
    fi

    if [[ -n "$AUR_HELPER" ]]; then
        log_info "Package manager: ${BOLD}${AUR_HELPER}${NC}"
    else
        log_info "Package manager: ${BOLD}pacman${NC} (all packages in official repos)"
    fi
}

# --- Kernel Header Detection ---
get_kernel_headers() {
    log_info "Detecting installed kernels..."

    local -a found_kernels=()
    HEADER_PACKAGES=()

    # Match kernel packages: "linux", "linux-lts", "linux-zen", "linux-hardened",
    # "linux-cachyos", "linux-cachyos-bore", "linux-xanmod-edge", "linux-rt-lts", etc.
    #
    # Pattern: "linux" optionally followed by one or more "-segment" parts.
    # Exclusion: anything containing -headers, -firmware, -api-headers, -docs, -tools
    #            at the end or as a middle segment (catches linux-firmware-whence, etc.)
    while IFS= read -r pkg; do
        found_kernels+=("$pkg")
    done < <(pacman -Qq 2>/dev/null \
        | grep -xE 'linux(-[a-z][a-z0-9]*)*' \
        | grep -vE '-(headers|firmware|api-headers|docs|tools)($|-)')

    # Validate that a corresponding -headers package exists
    for kernel in "${found_kernels[@]}"; do
        local headers_pkg="${kernel}-headers"
        if pacman -Si "$headers_pkg" &>/dev/null || pacman -Qi "$headers_pkg" &>/dev/null; then
            HEADER_PACKAGES+=("$headers_pkg")
        else
            log_warn "No headers package found for '${kernel}' — skipping."
        fi
    done

    if [[ ${#HEADER_PACKAGES[@]} -eq 0 ]]; then
        die "No valid kernel headers could be identified. Cannot proceed with DKMS."
    fi

    log_info "Kernel headers to install: ${BOLD}${HEADER_PACKAGES[*]}${NC}"
}

# --- Check Multilib Repository ---
check_multilib() {
    if ! grep -qE '^\s*\[multilib\]' /etc/pacman.conf; then
        log_warn "The [multilib] repository is not enabled in /etc/pacman.conf."
        log_warn "Skipping lib32 packages (needed for 32-bit apps like Steam/Wine)."

        local -a filtered=()
        for pkg in "${DRIVER_PACKAGES[@]}"; do
            if [[ "$pkg" == lib32-* ]]; then
                log_warn "  Skipping: ${pkg}"
                continue
            fi
            filtered+=("$pkg")
        done
        DRIVER_PACKAGES=("${filtered[@]}")
    fi
}

# --- Install libva-nvidia-driver Safely for Legacy ---
_try_add_libva() {
    # For Turing+, libva-nvidia-driver is already in DRIVER_PACKAGES (depends on
    # nvidia-utils which is also in the list). Nothing to do.
    if [[ "$GPU_ARCH" == "turing_plus" ]]; then
        return
    fi

    # For legacy: libva-nvidia-driver depends on nvidia-utils.
    # nvidia-580xx-utils may or may not satisfy this via provides=(nvidia-utils).
    # Check whether the AUR package declares that it provides nvidia-utils.
    if ! pacman -Si libva-nvidia-driver &>/dev/null; then
        log_warn "libva-nvidia-driver not found in repos; skipping VA-API support."
        return
    fi

    # Query the AUR helper for nvidia-580xx-utils package info and check if it
    # provides nvidia-utils. Both paru and yay support -Si for AUR packages.
    # The Provides line format is: "Provides : nvidia-utils=580.xx  lib32-..."
    # We use a broad match across provides and replaces fields.
    local pkg_info
    pkg_info=$("$AUR_HELPER" -Si nvidia-580xx-utils 2>/dev/null) || true

    if [[ -z "$pkg_info" ]]; then
        log_warn "Could not query nvidia-580xx-utils info; skipping libva-nvidia-driver."
        log_warn "Install manually if VA-API hardware decoding is needed."
        return
    fi

    # Check if nvidia-utils appears in the provides or replaces fields
    if echo "$pkg_info" | grep -qiE '(provides|replaces).*nvidia-utils'; then
        DRIVER_PACKAGES+=(libva-nvidia-driver)
        log_info "Added libva-nvidia-driver (dependency satisfied by nvidia-580xx-utils)."
    else
        log_warn "nvidia-580xx-utils does not appear to provide nvidia-utils."
        log_warn "Skipping libva-nvidia-driver to avoid dependency conflict."
        log_warn "Install manually if VA-API hardware decoding is needed."
    fi
}

# --- User Confirmation ---
confirm_installation() {
    local -a all_pkgs=("${HEADER_PACKAGES[@]}" "${DRIVER_PACKAGES[@]}")
    local pkg_mgr="${AUR_HELPER:-pacman}"

    echo ""
    log_info "═══════════════════════════════════════"
    log_info " Installation Summary"
    log_info "═══════════════════════════════════════"
    printf '  GPU:            %s\n' "$GPU_MARKETING_NAME"
    printf '  Chip:           %s\n' "${GPU_CHIP_NAME:-unknown}"
    printf '  PCI ID:         10de:%s\n' "${PCI_DEVICE_ID:-unknown}"
    printf '  Architecture:   %s\n' "$GPU_ARCH"
    printf '  Hybrid GPU:     %s\n' "$IS_HYBRID"
    printf '  Package Mgr:    %s\n' "$pkg_mgr"
    printf '  Packages (%d):\n' "${#all_pkgs[@]}"
    for pkg in "${all_pkgs[@]}"; do
        printf '    - %s\n' "$pkg"
    done
    echo ""
    log_warn "This will perform a full system upgrade (-Syu) and modify boot configuration."
    echo ""

    read -rp "Proceed with installation? [y/N] " response
    case "$response" in
        [yY]|[yY][eE][sS]) ;;
        *)
            log_info "Cancelled by user."
            SCRIPT_SUCCESS=true
            exit 0
            ;;
    esac
}

# --- Remove Conflicting Packages ---
remove_conflicts() {
    local -a conflicts=(xf86-video-nouveau)
    local -a to_remove=()

    for pkg in "${conflicts[@]}"; do
        if pacman -Qi "$pkg" &>/dev/null; then
            to_remove+=("$pkg")
        fi
    done

    if [[ ${#to_remove[@]} -gt 0 ]]; then
        log_warn "Removing conflicting packages: ${to_remove[*]}"
        if ! sudo pacman -Rns --noconfirm "${to_remove[@]}"; then
            log_warn "Failed to remove some conflicting packages. Manual intervention may be needed."
        fi
    fi
}

# --- Blacklist Nouveau ---
blacklist_nouveau() {
    local needs_write=false

    if [[ ! -f "$NOUVEAU_CONF" ]]; then
        needs_write=true
    elif ! grep -qF 'blacklist nouveau' "$NOUVEAU_CONF" \
      || ! grep -qF 'options nouveau modeset=0' "$NOUVEAU_CONF"; then
        needs_write=true
        log_warn "Existing nouveau blacklist is incomplete; rewriting."
    fi

    if [[ "$needs_write" == true ]]; then
        log_info "Blacklisting nouveau driver..."
        printf 'blacklist nouveau\noptions nouveau modeset=0\n' \
            | sudo tee "$NOUVEAU_CONF" >/dev/null
    else
        log_info "Nouveau already properly blacklisted."
    fi
}

# --- Configure Modprobe ---
configure_modprobe() {
    log_info "Configuring NVIDIA kernel module options..."

    # Back up existing file if it wasn't created by this script
    if [[ -f "$MODPROBE_CONF" ]] && ! grep -qF "$SCRIPT_NAME" "$MODPROBE_CONF"; then
        sudo cp "$MODPROBE_CONF" "${MODPROBE_CONF}.bak"
        log_warn "Existing ${MODPROBE_CONF} backed up to ${MODPROBE_CONF}.bak"
    fi

    local modprobe_content
    modprobe_content="# NVIDIA kernel module options — auto-generated by ${SCRIPT_NAME}

# DRM kernel mode setting (required for Wayland compositors)
options nvidia_drm modeset=1

# Framebuffer device support (driver 545+, enables virtual console under Wayland)
options nvidia_drm fbdev=1

# Preserve VRAM across suspend/resume (prevents black screen / corruption on wake)
options nvidia NVreg_PreserveVideoMemoryAllocations=1"

    # Dynamic power management for hybrid Turing+ setups only
    # RTD3 (Runtime D3 power state) requires Turing or newer silicon
    if [[ "$IS_HYBRID" == true ]] && [[ "$GPU_ARCH" == "turing_plus" ]]; then
        modprobe_content+="

# Dynamic power management for hybrid GPU (RTD3 — runtime D3 power state)
# Allows the dGPU to fully power off when idle for battery savings
options nvidia NVreg_DynamicPowerManagement=0x02"
    fi

    printf '%s\n' "$modprobe_content" | sudo tee "$MODPROBE_CONF" >/dev/null
    log_info "Written: ${BOLD}${MODPROBE_CONF}${NC}"
}

# --- Configure mkinitcpio MODULES (no rebuild here) ---
configure_mkinitcpio_modules() {
    log_info "Configuring mkinitcpio MODULES..."

    # Backup (only on first run)
    if [[ ! -f "$MKINITCPIO_BAK" ]]; then
        sudo cp "$MKINITCPIO_CONF" "$MKINITCPIO_BAK"
        log_info "Backup created: ${MKINITCPIO_BAK}"
    fi

    # Required NVIDIA modules for early KMS
    local -a nvidia_mods=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)

    # Read the first uncommented MODULES= line
    local current_modules_line
    current_modules_line=$(grep -E '^\s*MODULES\s*=' "$MKINITCPIO_CONF" | head -n 1) || true

    if [[ -z "$current_modules_line" ]]; then
        # No MODULES line exists; append one
        echo "MODULES=(${nvidia_mods[*]})" | sudo tee -a "$MKINITCPIO_CONF" >/dev/null
        log_info "MODULES line added: MODULES=(${nvidia_mods[*]})"
    else
        # Extract existing modules from within parentheses
        local existing_mods
        existing_mods=$(echo "$current_modules_line" \
            | sed -E 's/.*MODULES\s*=\s*\(?\s*//' \
            | sed -E 's/\s*\)?\s*$//' \
            | sed -E 's/"//g')

        # Build deduplicated module list: keep existing + add missing nvidia modules
        local -a mod_array=()
        if [[ -n "$existing_mods" ]]; then
            read -ra mod_array <<< "$existing_mods"
        fi

        for nmod in "${nvidia_mods[@]}"; do
            local found=false
            for existing in "${mod_array[@]}"; do
                if [[ "$existing" == "$nmod" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                mod_array+=("$nmod")
            fi
        done

        local new_modules_line="MODULES=(${mod_array[*]})"

        # Replace only the first MODULES= line
        sudo sed -i "0,/^\s*MODULES\s*=/{s|^\s*MODULES\s*=.*|${new_modules_line}|}" \
            "$MKINITCPIO_CONF"

        log_info "MODULES set to: ${BOLD}${new_modules_line}${NC}"
    fi
}

# --- Install Packages ---
install_packages() {
    local -a all_pkgs=("${HEADER_PACKAGES[@]}" "${DRIVER_PACKAGES[@]}")

    log_info "Installing ${#all_pkgs[@]} packages (with full system upgrade)..."

    if [[ -n "$AUR_HELPER" ]]; then
        if ! "$AUR_HELPER" -Syu --needed --noconfirm "${all_pkgs[@]}"; then
            die "Package installation failed. Check output above for details."
        fi
    else
        if ! sudo pacman -Syu --needed --noconfirm "${all_pkgs[@]}"; then
            die "Package installation failed. Check output above for details."
        fi
    fi

    log_success "All packages installed successfully."
}

# --- Rebuild Initramfs ---
rebuild_initramfs() {
    log_info "Regenerating initramfs for all kernels..."
    if ! sudo mkinitcpio -P; then
        log_warn "mkinitcpio reported warnings. Review the output above."
    fi
}

# --- Verify DKMS Build ---
verify_dkms() {
    log_info "Verifying DKMS module build status..."

    if ! command -v dkms &>/dev/null; then
        log_warn "dkms command not found. Cannot verify module build status."
        return
    fi

    local dkms_output
    dkms_output=$(dkms status 2>/dev/null | grep -i nvidia) || true

    if [[ -z "$dkms_output" ]]; then
        log_warn "No NVIDIA DKMS modules found in 'dkms status'."
        log_warn "The driver may not load on next boot. Try: sudo dkms autoinstall"
        return
    fi

    # Check for modules that aren't in "installed" or "built" state
    if echo "$dkms_output" | grep -qviE '(installed|built)'; then
        log_warn "Some DKMS modules may not be properly built:"
        while IFS= read -r line; do
            log_warn "  ${line}"
        done <<< "$dkms_output"
    else
        log_success "DKMS modules built successfully:"
        while IFS= read -r line; do
            log_info "  ${line}"
        done <<< "$dkms_output"
    fi
}

# --- Enable Suspend/Resume Services ---
configure_suspend_resume() {
    log_info "Enabling NVIDIA suspend/resume/hibernate services..."

    local -a services=(
        nvidia-suspend.service
        nvidia-hibernate.service
        nvidia-resume.service
    )

    for svc in "${services[@]}"; do
        if systemctl cat "$svc" &>/dev/null; then
            if ! sudo systemctl enable "$svc" 2>/dev/null; then
                log_warn "Failed to enable ${svc}."
            fi
        else
            log_warn "Service ${svc} not found; skipping."
        fi
    done

    log_info "Suspend/resume services configured."
}

# --- Configure Power Management (Hybrid + Turing+ Only) ---
configure_power_management() {
    # nvidia-powerd provides Dynamic Boost which requires Turing or newer
    if [[ "$IS_HYBRID" != true ]] || [[ "$GPU_ARCH" != "turing_plus" ]]; then
        return
    fi

    log_info "Enabling nvidia-powerd for dynamic power management (hybrid Turing+ GPU)..."

    if systemctl cat nvidia-powerd.service &>/dev/null; then
        if ! sudo systemctl enable nvidia-powerd.service 2>/dev/null; then
            log_warn "Failed to enable nvidia-powerd.service."
        else
            log_info "nvidia-powerd.service enabled."
        fi
    else
        log_warn "nvidia-powerd.service not found; skipping."
        log_warn "Dynamic power management may not be available with this driver version."
    fi
}

# --- Configure Hyprland Environment ---
configure_hyprland_env() {
    log_info "Configuring Hyprland environment variables..."

    mkdir -p "$(dirname "$HYPR_ENV_FILE")"

    # Build the config block
    local env_block=""
    env_block+="${SENTINEL_BEGIN}\n"
    env_block+="# NVIDIA Configuration — auto-generated by ${SCRIPT_NAME}\n"
    env_block+="# Generated: $(date -Iseconds)\n"
    env_block+="# GPU: ${GPU_MARKETING_NAME} (${GPU_ARCH})\n"
    env_block+="#\n"
    env_block+="# Wayland / NVIDIA core\n"
    env_block+="env = LIBVA_DRIVER_NAME,nvidia\n"
    env_block+="env = __GLX_VENDOR_LIBRARY_NAME,nvidia\n"
    env_block+="\n"
    env_block+="# VA-API hardware video acceleration\n"
    env_block+="env = NVD_BACKEND,direct\n"
    env_block+="\n"
    env_block+="# Electron / Chromium native Wayland\n"
    env_block+="env = ELECTRON_OZONE_PLATFORM_HINT,auto\n"

    if [[ "$IS_HYBRID" == true ]]; then
        env_block+="\n"
        env_block+="# Hybrid GPU (Optimus) detected\n"
        env_block+="# __GLX_VENDOR_LIBRARY_NAME=nvidia forces XWayland apps to the NVIDIA GPU.\n"
        env_block+="# Remove it if specific X11 apps should render on the integrated GPU.\n"
    fi

    env_block+="${SENTINEL_END}"

    # Remove previous config block if both sentinels are present
    if [[ -f "$HYPR_ENV_FILE" ]]; then
        if grep -qF "$SENTINEL_BEGIN" "$HYPR_ENV_FILE" \
        && grep -qF "$SENTINEL_END" "$HYPR_ENV_FILE"; then
            sed -i "/${SENTINEL_BEGIN//\//\\/}/,/${SENTINEL_END//\//\\/}/d" "$HYPR_ENV_FILE"
            log_info "Removed previous NVIDIA config block."
        elif grep -qF "$SENTINEL_BEGIN" "$HYPR_ENV_FILE"; then
            log_warn "Found BEGIN sentinel without END sentinel in ${HYPR_ENV_FILE}."
            log_warn "Appending fresh config block; review file for duplicates."
        fi
    fi

    # Append new block with a clean blank separator line
    if [[ -f "$HYPR_ENV_FILE" ]] && [[ -s "$HYPR_ENV_FILE" ]]; then
        # File exists and is non-empty: ensure a blank line separates old and new content
        if [[ $(tail -c1 "$HYPR_ENV_FILE" | wc -l) -eq 0 ]]; then
            echo "" >> "$HYPR_ENV_FILE"
        fi
        echo "" >> "$HYPR_ENV_FILE"
    fi
    printf '%b\n' "$env_block" >> "$HYPR_ENV_FILE"
    log_info "Written: ${BOLD}${HYPR_ENV_FILE}${NC}"

    # Warn about sourcing if not already done
    local hypr_main="${HOME}/.config/hypr/hyprland.conf"
    if [[ -f "$hypr_main" ]]; then
        if ! grep -qE '^\s*source\s*=.*envs\.conf' "$hypr_main"; then
            echo ""
            log_warn "Add this line to your hyprland.conf for env vars to take effect:"
            log_warn "  source = ~/.config/hypr/envs.conf"
        else
            log_info "hyprland.conf already sources envs.conf."
        fi
    else
        log_warn "No hyprland.conf found at ${hypr_main}."
        log_warn "Ensure envs.conf is sourced in your Hyprland configuration."
    fi
}

# --- Post-Install Notes ---
show_post_install_notes() {
    echo ""
    log_success "═══════════════════════════════════════"
    log_success " Installation complete!"
    log_success "═══════════════════════════════════════"
    echo ""
    log_info "Post-install notes:"
    echo "  • A REBOOT is REQUIRED to load the NVIDIA kernel modules."
    echo "  • Optional: install 'nvidia-settings' for GUI monitoring/configuration."

    if [[ "$IS_HYBRID" == true ]] && [[ "$GPU_ARCH" == "turing_plus" ]]; then
        echo "  • nvidia-powerd enabled for dynamic GPU power management."
        echo "  • RTD3 (NVreg_DynamicPowerManagement=0x02) configured for battery savings."
    elif [[ "$IS_HYBRID" == true ]]; then
        echo "  • Hybrid GPU detected. RTD3 power management is not supported on legacy GPUs."
    fi

    if [[ "$GPU_ARCH" == "maxwell_pascal_volta" ]]; then
        echo "  • Using nvidia-580xx (legacy branch). Monitor AUR for updates."
        echo "  • These drivers will eventually reach end-of-life. Plan for hardware upgrade."
    fi

    echo "  • Suspend/resume services enabled (NVreg_PreserveVideoMemoryAllocations=1)."
    echo "  • After reboot, verify with: dkms status && nvidia-smi"
    echo ""
}

# --- Main ---
main() {
    echo ""
    log_info "═══════════════════════════════════════"
    log_info " NVIDIA Driver Installer (Arch Linux)"
    log_info "═══════════════════════════════════════"
    echo ""

    # --- Phase 1: Detection & Validation ---
    preflight_checks
    detect_hybrid_gpu
    detect_gpu_and_driver
    detect_package_manager
    get_kernel_headers
    check_multilib
    _try_add_libva

    # --- Phase 2: User Confirmation ---
    confirm_installation

    # --- Phase 3: System Modification ---
    SYSTEM_MODIFIED=true
    remove_conflicts
    blacklist_nouveau
    configure_modprobe
    configure_mkinitcpio_modules
    install_packages
    rebuild_initramfs
    verify_dkms

    # --- Phase 4: Services & Environment ---
    configure_suspend_resume
    configure_power_management
    configure_hyprland_env

    SCRIPT_SUCCESS=true
    show_post_install_notes
}

main "$@"
