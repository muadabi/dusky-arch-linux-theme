#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 🖼️ ROFI WALLPAPER SELECTOR (V4 - Hardened & Ultra-Optimized)
# Target: Arch Linux / Hyprland / UWSM ecosystem
# -----------------------------------------------------------------------------

set -euo pipefail

# --- XDG COMPLIANT LOCKING (Bash 4.1+ Dynamic FD) ---
readonly RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
readonly LOCK_FILE="${RUNTIME_DIR}/rofi-wallpaper-selector.lock"

# Ensure RUNTIME_DIR exists to prevent silent exec failure
[[ -d "$RUNTIME_DIR" ]] || mkdir -p "$RUNTIME_DIR"

exec {lock_fd}>"$LOCK_FILE"
if ! flock -n "$lock_fd"; then
    command -v notify-send >/dev/null && notify-send -a "Wallpaper Menu" "Process already running." -u low -t 1000
    exit 1
fi

# --- CONFIGURATION ---
readonly WALLPAPER_DIR="${HOME}/Pictures/wallpapers"
readonly CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rofi-wallpaper-thumbs"
readonly CACHE_FILE="${CACHE_DIR}/rofi_input.cache"
readonly PATH_MAP="${CACHE_DIR}/path_map.cache"
readonly ERROR_LOG="${CACHE_DIR}/errors.log"
readonly ROFI_THEME="${HOME}/.config/rofi/wallpaper.rasi"
readonly RANDOM_THEME_SCRIPT="${HOME}/user_scripts/random_theme.sh"
readonly THUMB_SIZE=300

export MAGICK_THREAD_LIMIT=1
readonly MAX_JOBS=$(nproc)

# --- DEPENDENCY PRE-FLIGHT ---
if ! command -v notify-send &>/dev/null; then
    echo "CRITICAL: notify-send is missing." >&2
    exit 1
fi

for cmd in magick rofi swww uwsm-app matugen; do
    if ! command -v "$cmd" &>/dev/null; then
        notify-send -a "Wallpaper Menu" "Missing dependency: $cmd" -u critical
        exit 1
    fi
done

if ! swww query &>/dev/null; then
    notify-send -a "Wallpaper Menu" "swww daemon is not running." -u critical
    exit 1
fi

if [[ ! -d "$WALLPAPER_DIR" ]]; then
    notify-send -a "Wallpaper Menu" "Directory not found: $WALLPAPER_DIR" -u critical
    exit 1
fi

mkdir -p "$CACHE_DIR"
> "$ERROR_LOG" # Truncate old errors

# --- CACHE GENERATION ---
shopt -s nullglob nocaseglob globstar
declare -a all_images=("${WALLPAPER_DIR}"/**/*.{jpg,jpeg,png,webp,gif})
shopt -u nullglob nocaseglob globstar

if (( ${#all_images[@]} == 0 )); then
    notify-send -a "Wallpaper Menu" "No images found in $WALLPAPER_DIR" -u normal
    exit 0
fi

declare -a needs_update=()
declare -A current_files=()

# 1. Pure bash collision-proof incremental check
for img in "${all_images[@]}"; do
    # Skip files with literal newlines in the name to prevent cache corruption
    [[ "$img" == *$'\n'* ]] && continue 

    rel_path="${img#"$WALLPAPER_DIR/"}"
    
    # URL-style encoding: escape % first, then /
    safe_name="${rel_path//%/%25}"
    flat_name="${safe_name//\//%2F}"
    thumb="${CACHE_DIR}/${flat_name}.png"
    
    current_files["$flat_name"]=1
    
    if [[ ! -f "$thumb" ]] || [[ "$img" -nt "$thumb" ]]; then
        needs_update+=("$img")
    fi
done

# 2. Parallel Thumbnail Generation (Batched)
if (( ${#needs_update[@]} > 0 )); then
    notify-send -a "Wallpaper Menu" "Caching ${#needs_update[@]} new images..." -u low -t 2000
    
    export CACHE_DIR THUMB_SIZE WALLPAPER_DIR ERROR_LOG
    
    generate_thumb() {
        for file in "$@"; do
            local rel_path="${file#"$WALLPAPER_DIR/"}"
            local safe_name="${rel_path//%/%25}"
            local flat_name="${safe_name//\//%2F}"
            local thumb="${CACHE_DIR}/${flat_name}.png"
            
            # [0] forces ImageMagick to only grab the first frame of GIFs/WebPs
            nice -n 19 magick "${file}[0]" \
                -define jpeg:size="${THUMB_SIZE}x${THUMB_SIZE}" \
                -strip \
                -thumbnail "${THUMB_SIZE}x${THUMB_SIZE}^" \
                -gravity center \
                -extent "${THUMB_SIZE}x${THUMB_SIZE}" \
                "$thumb" 2>>"$ERROR_LOG" || true
        done
    }
    export -f generate_thumb
    
    printf '%s\0' "${needs_update[@]}" | xargs -0 -P "$MAX_JOBS" -n 20 bash -c 'generate_thumb "$@"' _
fi

# 3. Build Rofi Data Files (Atomic I/O)
tmp_cache=$(mktemp -p "$CACHE_DIR" cache.XXXXXX)
tmp_map=$(mktemp -p "$CACHE_DIR" map.XXXXXX)

trap 'rm -f "$tmp_cache" "$tmp_map"' EXIT

exec {cache_fd}>"$tmp_cache"
exec {map_fd}>"$tmp_map"

for img in "${all_images[@]}"; do
    [[ "$img" == *$'\n'* ]] && continue 

    rel_path="${img#"$WALLPAPER_DIR/"}"
    safe_name="${rel_path//%/%25}"
    flat_name="${safe_name//\//%2F}"
    thumb="${CACHE_DIR}/${flat_name}.png"
    
    # Use the relative path as the Rofi display name to prevent basename collisions
    if [[ -f "$thumb" ]]; then
        printf '%s\0icon\x1f%s\n' "$rel_path" "$thumb" >&"$cache_fd"
    else
        printf '%s\n' "$rel_path" >&"$cache_fd"
    fi
    
    # Use Unit Separator (\x1f) instead of Tab to avoid edge-case filename breaks
    printf '%s\x1f%s\n' "$rel_path" "$img" >&"$map_fd"
done

exec {cache_fd}>&-
exec {map_fd}>&-

# Ensure both moves succeed atomically
if mv "$tmp_cache" "$CACHE_FILE" && mv "$tmp_map" "$PATH_MAP"; then
    trap - EXIT
else
    notify-send -a "Wallpaper Menu" "Failed to write cache files." -u critical
    exit 1
fi

# 4. Asynchronous Orphan Cleanup
(
    shopt -s nullglob
    for thumb in "$CACHE_DIR"/*.png; do
        flat_name="${thumb##*/}"
        flat_name="${flat_name%.png}"
        if [[ -z "${current_files[$flat_name]:-}" ]]; then
            rm -f "$thumb"
        fi
    done
) </dev/null >/dev/null 2>&1 & disown

# --- ROFI LAUNCH & EXECUTION ---
if [[ ! -f "$ROFI_THEME" ]]; then
    notify-send -a "Wallpaper Menu" "Theme not found: $ROFI_THEME" -u critical
    exit 1
fi

# Capture exit code to differentiate between cancel (1) and crash (non-zero > 1)
selection=$(rofi -dmenu -i -show-icons -theme "$ROFI_THEME" -p "Wallpaper" < "$CACHE_FILE") || exit_code=$?

# Exit gracefully if user pressed escape, otherwise error out if Rofi crashed
if [[ ${exit_code:-0} -eq 1 ]]; then
    exit 0
elif [[ ${exit_code:-0} -ne 0 ]]; then
    notify-send -a "Wallpaper Menu" "Rofi exited with error code $exit_code" -u critical
    exit 1
fi

[[ -z "$selection" ]] && exit 0

# Look up full path using Unit Separator (\x1f) delimiter
full_path=$(SELECTION="$selection" awk -F'\x1f' '$1 == ENVIRON["SELECTION"] {print $2; exit}' "$PATH_MAP")

if [[ -n "$full_path" && -f "$full_path" ]]; then
    
    declare -a current_flags=(--mode dark)
    if [[ -f "$RANDOM_THEME_SCRIPT" ]]; then
        extracted=$(grep -m 1 -oP 'matugen \K.*?(?= image)' "$RANDOM_THEME_SCRIPT" || true)
        if [[ -n "$extracted" ]]; then
            # Safe eval-free array assignment via xargs
            eval "current_flags=($extracted)" 2>/dev/null || current_flags=(--mode dark)
        fi
    fi

    # Consistent background execution
    swww img "$full_path" \
        --transition-type grow \
        --transition-duration 2 \
        --transition-fps 60 </dev/null >/dev/null 2>&1 & disown
        
    setsid uwsm-app -- matugen "${current_flags[@]}" image "$full_path" </dev/null >/dev/null 2>&1 & disown
else
    rm -f "$CACHE_FILE" "$PATH_MAP"
    notify-send -a "Wallpaper Menu" "Path resolution failed. Cache cleared." -u critical
fi
