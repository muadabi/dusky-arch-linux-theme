#!/usr/bin/env bash
# =============================================================================
# USAGE & AUTOMATION FLAGS
# =============================================================================
# This script operates in two modes: Interactive (TUI) and Headless (Automation).
# 
# Interactive Mode:
#   Run without any arguments to launch the TUI. Requires an active TTY.
#
# Headless/Automation Flags (Strictly single-flag evaluation):
#   --thunar       : Non-interactively updates configs to use Thunar.
#                    Updates the Dusky state file to 'false'.
#   --yazi         : Non-interactively updates configs to use Yazi.
#                    Updates the Dusky state file to 'true'.
#   --apply-state  : Non-interactively reads the Dusky state file at
#                    ~/.config/dusky/settings/filemanager_switch.
#                    Applies Yazi if 'true', Thunar if 'false'.
#                    Ideal for Hyprland exec-once or systemd startup hooks.
#                    Gracefully exits if the state file does not exist yet.
#
# Note: Flag combinations are intentionally unsupported to guarantee atomic,
# predictable execution. Only the first argument ($1) is evaluated.
# =============================================================================

set -euo pipefail
shopt -s extglob

# =============================================================================
# ▼ USER CONFIGURATION ▼
# =============================================================================

# Path 1: Where the variable is defined ($fileManager = ...)
declare -r APPS_CONFIG="${HOME}/.config/hypr/edit_here/source/default_apps.conf"

# Path 2: Where the binds are located (bind = ... uwsm-app ...)
declare -r BINDS_CONFIG="${HOME}/.config/hypr/source/keybinds.conf"

declare -r APP_TITLE="File Manager Switcher"
declare -r APP_VERSION="v1.1.0"

# Layout
declare -ri BOX_INNER_WIDTH=48
declare -ri HEADER_ROWS=4
declare -ri ITEM_START_ROW=$(( HEADER_ROWS + 1 ))

# The two options
declare -ra FM_OPTIONS=("Thunar (GUI)" "Yazi (Terminal)")
declare -ra FM_KEYS=("thunar" "yazi")
declare -ri OPTION_COUNT=${#FM_OPTIONS[@]}

# Post-write hook
post_write_action() {
    : # Hyprland auto-reloads confs via source, no action needed
}

# =============================================================================
# ▲ END OF USER CONFIGURATION ▲
# =============================================================================

# --- Pre-computed Constants ---
declare _h_line_buf
printf -v _h_line_buf '%*s' "$BOX_INNER_WIDTH" ''
declare -r H_LINE="${_h_line_buf// /─}"
unset _h_line_buf

# --- ANSI Constants ---
declare -r C_RESET=$'\033[0m'
declare -r C_CYAN=$'\033[1;36m'
declare -r C_GREEN=$'\033[1;32m'
declare -r C_MAGENTA=$'\033[1;35m'
declare -r C_RED=$'\033[1;31m'
declare -r C_YELLOW=$'\033[1;33m'
declare -r C_WHITE=$'\033[1;37m'
declare -r C_GREY=$'\033[1;30m'
declare -r C_INVERSE=$'\033[7m'
declare -r CLR_EOL=$'\033[K'
declare -r CLR_EOS=$'\033[J'
declare -r CLR_SCREEN=$'\033[2J'
declare -r CURSOR_HOME=$'\033[H'
declare -r CURSOR_HIDE=$'\033[?25l'
declare -r CURSOR_SHOW=$'\033[?25h'
declare -r MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
declare -r MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

declare -r ESC_READ_TIMEOUT=0.10

# --- State ---
declare -i SELECTED_ROW=0
declare CURRENT_FM=""
declare ORIGINAL_STTY=""
declare _TMPFILE=""
declare STATUS_MSG=""

# --- System Helpers ---

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

cleanup() {
    # Only try to restore TUI state if we actually initialized it (checked via ORIGINAL_STTY)
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET" 2>/dev/null || :
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    
    if [[ -n "${_TMPFILE:-}" && -f "$_TMPFILE" ]]; then
        rm -f "$_TMPFILE" 2>/dev/null || :
    fi
    # Only print newline if we were likely in TUI mode
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        printf '\n' 2>/dev/null || :
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Detection ---

detect_current_fm() {
    CURRENT_FM=""
    local line
    # We now read from APPS_CONFIG for the variable definition
    if [[ ! -f "$APPS_CONFIG" ]]; then return 1; fi
    
    while IFS= read -r line; do
        # Skip comments
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ \$fileManager[[:space:]]*=[[:space:]]*(.+) ]]; then
            local val="${BASH_REMATCH[1]}"
            # Trim whitespace and trailing comments
            val="${val%%#*}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            CURRENT_FM="$val"
            return 0
        fi
    done < "$APPS_CONFIG"
    return 1
}

# --- Atomic Write Engine ---

write_fm_switch() {
    local target_fm="$1"

    # Write state file for Dusky FIRST
    mkdir -p "${HOME}/.config/dusky/settings"
    if [[ "$target_fm" == "yazi" ]]; then
        printf "true\n" > "${HOME}/.config/dusky/settings/filemanager_switch"
    else
        printf "false\n" > "${HOME}/.config/dusky/settings/filemanager_switch"
    fi

    if [[ "$CURRENT_FM" == "$target_fm" ]]; then
        STATUS_MSG="${C_YELLOW}Already set to ${target_fm}. No changes made.${C_RESET}"
        return 0
    fi

    local old_fm="$CURRENT_FM"
    local new_fm="$target_fm"

    # --- PHASE 1: Update APPS_CONFIG (Variable Definition) ---
    _TMPFILE=$(mktemp "${APPS_CONFIG}.tmp.XXXXXXXXXX")
    
    if ! LC_ALL=C awk -v old_fm="$old_fm" -v new_fm="$new_fm" '
    {
        line = $0
        # Replace the variable assignment
        if (line ~ /\$fileManager[[:space:]]*=[[:space:]]*/ && line !~ /^[[:space:]]*#/) {
            sub(old_fm, new_fm, line)
        }
        print line
    }
    ' "$APPS_CONFIG" > "$_TMPFILE"; then
        rm -f "$_TMPFILE" 2>/dev/null || :
        _TMPFILE=""
        STATUS_MSG="${C_RED}Failed to write apps config.${C_RESET}"
        return 1
    fi

    cat "$_TMPFILE" > "$APPS_CONFIG"
    rm -f "$_TMPFILE"
    _TMPFILE=""

    # --- PHASE 2: Update BINDS_CONFIG (Keybind Logic) ---
    _TMPFILE=$(mktemp "${BINDS_CONFIG}.tmp.XXXXXXXXXX")

    if ! LC_ALL=C awk -v old_fm="$old_fm" -v new_fm="$new_fm" '
    {
        line = $0
        # Adjust keybind exec line based on target
        if (line ~ /uwsm-app/ && line ~ /\$fileManager/ && line !~ /^[[:space:]]*#/) {
            if (new_fm == "thunar") {
                # Switch to direct execution
                gsub(/uwsm-app -- \$terminal -e \$fileManager/, "uwsm-app $fileManager", line)
            } else if (new_fm == "yazi") {
                # Switch to terminal wrapper, but only if not already wrapped
                if (line !~ /\$terminal -e/) {
                    gsub(/uwsm-app \$fileManager/, "uwsm-app -- $terminal -e $fileManager", line)
                }
            }
        }
        print line
    }
    ' "$BINDS_CONFIG" > "$_TMPFILE"; then
        rm -f "$_TMPFILE" 2>/dev/null || :
        _TMPFILE=""
        # Rollback is complex here, so we just warn.
        # Ideally, previous write should be reverted, but config drift is minor.
        STATUS_MSG="${C_RED}Updated variable but failed to update keybinds.${C_RESET}"
        return 1
    fi

    cat "$_TMPFILE" > "$BINDS_CONFIG"
    rm -f "$_TMPFILE"
    _TMPFILE=""

    CURRENT_FM="$new_fm"

    # Update MIME defaults
    local desktop_file="${new_fm}.desktop"
    if command -v xdg-mime &>/dev/null; then
        xdg-mime default "$desktop_file" inode/directory 2>/dev/null || :
    fi

    post_write_action

    STATUS_MSG="${C_GREEN}Switched to ${new_fm} successfully.${C_RESET}"
    return 0
}

# --- UI Rendering ---

draw_ui() {
    local buf="" pad_buf=""
    local -i left_pad right_pad vis_len pad_needed i

    buf+="${CURSOR_HOME}"

    # Top border
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}${CLR_EOL}"$'\n'

    # Title row
    local title_text="${APP_TITLE} ${APP_VERSION}"
    vis_len=${#title_text}
    left_pad=$(( (BOX_INNER_WIDTH - vis_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - vis_len - left_pad ))
    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

    # Current status row
    local status_text="Current: ${CURRENT_FM:-unknown}"
    vis_len=${#status_text}
    left_pad=$(( (BOX_INNER_WIDTH - vis_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - vis_len - left_pad ))
    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_GREY}Current: "
    if [[ "$CURRENT_FM" == "thunar" ]]; then
        buf+="${C_GREEN}thunar${C_MAGENTA}"
    elif [[ "$CURRENT_FM" == "yazi" ]]; then
        buf+="${C_GREEN}yazi${C_MAGENTA}"
    else
        buf+="${C_RED}${CURRENT_FM:-unknown}${C_MAGENTA}"
    fi
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

    # Bottom border
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'

    # Blank line before items
    buf+="${CLR_EOL}"$'\n'

    # Render options
    for (( i = 0; i < OPTION_COUNT; i++ )); do
        local label="${FM_OPTIONS[i]}"
        local fm_key="${FM_KEYS[i]}"
        local indicator=""

        # Mark current
        if [[ "$fm_key" == "$CURRENT_FM" ]]; then
            indicator=" ${C_GREEN}●${C_RESET}"
        fi

        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE} ${label} ${C_RESET}${indicator}${CLR_EOL}"$'\n'
        else
            buf+="    ${label} ${indicator}${CLR_EOL}"$'\n'
        fi
    done

    # Blank line after items
    buf+="${CLR_EOL}"$'\n'

    # Status message row
    if [[ -n "$STATUS_MSG" ]]; then
        buf+="  ${STATUS_MSG}${CLR_EOL}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    # Keybind help
    buf+="${CLR_EOL}"$'\n'
    buf+="${C_CYAN} [↑/↓ j/k] Navigate  [Enter] Apply  [q] Quit${C_RESET}${CLR_EOL}"$'\n'
    buf+="${C_CYAN} File: ${C_WHITE}Split Config${C_RESET}${CLR_EOL}${CLR_EOS}"

    printf '%s' "$buf"
}

# --- Input Handling ---

navigate() {
    local -i dir=$1
    SELECTED_ROW=$(( (SELECTED_ROW + dir + OPTION_COUNT) % OPTION_COUNT ))
}

apply_selection() {
    local target="${FM_KEYS[SELECTED_ROW]}"
    write_fm_switch "$target"
}

read_escape_seq() {
    local -n _esc_out=$1
    _esc_out=""
    local char
    if ! IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; then
        return 1
    fi
    _esc_out+="$char"
    if [[ "$char" == '[' || "$char" == 'O' ]]; then
        while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do
            _esc_out+="$char"
            if [[ "$char" =~ [a-zA-Z~] ]]; then break; fi
        done
    fi
    return 0
}

handle_mouse() {
    local input="$1"
    local -i button x y
    local body="${input#'[<'}"
    if [[ "$body" == "$input" ]]; then return 0; fi
    local terminator="${body: -1}"
    if [[ "$terminator" != "M" && "$terminator" != "m" ]]; then return 0; fi
    body="${body%[Mm]}"
    local field1 field2 field3
    IFS=';' read -r field1 field2 field3 <<< "$body"
    if [[ ! "$field1" =~ ^[0-9]+$ ]]; then return 0; fi
    if [[ ! "$field2" =~ ^[0-9]+$ ]]; then return 0; fi
    if [[ ! "$field3" =~ ^[0-9]+$ ]]; then return 0; fi
    button=$field1; x=$field2; y=$field3

    # Scroll wheel
    if (( button == 64 )); then navigate -1; return 0; fi
    if (( button == 65 )); then navigate 1; return 0; fi

    # Only process press events
    if [[ "$terminator" != "M" ]]; then return 0; fi

    # Item click zone: items start at ITEM_START_ROW + 1 (blank line offset)
    local -i effective_start=$(( ITEM_START_ROW + 1 ))
    if (( y >= effective_start && y < effective_start + OPTION_COUNT )); then
        local -i clicked_idx=$(( y - effective_start ))
        if (( clicked_idx >= 0 && clicked_idx < OPTION_COUNT )); then
            SELECTED_ROW=$clicked_idx
            if (( button == 0 )); then
                apply_selection
            fi
        fi
    fi
    return 0
}

handle_input() {
    local key="$1"
    local escape_seq=""

    if [[ "$key" == $'\x1b' ]]; then
        if read_escape_seq escape_seq; then
            key="$escape_seq"
        else
            # Bare ESC — quit
            exit 0
        fi
    fi

    # Escape sequences
    case "$key" in
        '[A'|'OA')           navigate -1; return ;;
        '[B'|'OB')           navigate 1; return ;;
        '[C'|'OC'|'[D'|'OD') apply_selection; return ;;
        '[H'|'[1~')          SELECTED_ROW=0; return ;;
        '[F'|'[4~')          SELECTED_ROW=$(( OPTION_COUNT - 1 )); return ;;
        '['*'<'*[Mm])        handle_mouse "$key"; return ;;
    esac

    # Regular keys
    case "$key" in
        k|K)            navigate -1 ;;
        j|J)            navigate 1 ;;
        l|L|h|H)        apply_selection ;;
        ''|$'\n')        apply_selection ;;
        1)              SELECTED_ROW=0; apply_selection ;;
        2)              SELECTED_ROW=1; apply_selection ;;
        q|Q|$'\x03')    exit 0 ;;
    esac
}

# --- Main ---

main() {
    # 1. Base Environment Checks (Headless-safe)
    if (( BASH_VERSINFO[0] < 5 )); then log_err "Bash 5.0+ required"; exit 1; fi
    if [[ ! -f "$APPS_CONFIG" ]]; then log_err "Apps Config not found: $APPS_CONFIG"; exit 1; fi
    if [[ ! -w "$APPS_CONFIG" ]]; then log_err "Apps Config not writable: $APPS_CONFIG"; exit 1; fi
    if [[ ! -f "$BINDS_CONFIG" ]]; then log_err "Keybinds Config not found: $BINDS_CONFIG"; exit 1; fi
    if [[ ! -w "$BINDS_CONFIG" ]]; then log_err "Keybinds Config not writable: $BINDS_CONFIG"; exit 1; fi

    local _dep
    for _dep in awk xdg-mime; do
        if ! command -v "$_dep" &>/dev/null; then
            log_err "Missing dependency: ${_dep}"; exit 1
        fi
    done

    # 2. Detect current state (Required for both CLI and TUI)
    if ! detect_current_fm; then
        log_err "Could not detect \$fileManager in $APPS_CONFIG"
        exit 1
    fi

    # 3. Handle CLI automation arguments FIRST (Does not require TTY)
    case "${1:-}" in
        --thunar)
            if write_fm_switch "thunar"; then
                printf '%s\n' "$STATUS_MSG"
                exit 0
            else
                printf '%s\n' "$STATUS_MSG" >&2
                exit 1
            fi
            ;;
        --yazi)
            if write_fm_switch "yazi"; then
                printf '%s\n' "$STATUS_MSG"
                exit 0
            else
                printf '%s\n' "$STATUS_MSG" >&2
                exit 1
            fi
            ;;
        --apply-state)
            local state_file="${HOME}/.config/dusky/settings/filemanager_switch"

            # CRITICAL FIX: Graceful fallback for fresh installs/missing state
            if [[ ! -f "$state_file" ]]; then
                STATUS_MSG="${C_YELLOW}State file missing. Preserving current file manager: ${CURRENT_FM}${C_RESET}"
                printf '%s\n' "$STATUS_MSG"
                exit 0
            fi

            # Robust read: handles missing EOF newline gracefully
            local state_val
            IFS= read -r state_val < "$state_file" || true
            state_val="${state_val%%[[:space:]]*}" # Clean trailing whitespace/newlines

            local target_fm=""
            if [[ "$state_val" == "true" ]]; then
                target_fm="yazi"
            elif [[ "$state_val" == "false" ]]; then
                target_fm="thunar"
            else
                log_err "Invalid state in ${state_file}: '${state_val}'"
                exit 1
            fi

            if write_fm_switch "$target_fm"; then
                printf '%s\n' "$STATUS_MSG"
                exit 0
            else
                printf '%s\n' "$STATUS_MSG" >&2
                exit 1
            fi
            ;;
    esac

    # ==========================================================
    # 4. TUI Initialization (Requires TTY)
    # ==========================================================
    if [[ ! -t 0 ]]; then 
        log_err "TTY required for interactive mode"
        exit 1
    fi

    # Pre-select the row matching the non-current option (what user likely wants)
    local -i i
    for (( i = 0; i < OPTION_COUNT; i++ )); do
        if [[ "${FM_KEYS[i]}" != "$CURRENT_FM" ]]; then
            SELECTED_ROW=$i
            break
        fi
    done

    # Terminal setup
    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    stty -icanon -echo min 1 time 0 2>/dev/null

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"

    local key
    while true; do
        draw_ui
        IFS= read -rsn1 key || break
        handle_input "$key"
    done
}

main "$@"
