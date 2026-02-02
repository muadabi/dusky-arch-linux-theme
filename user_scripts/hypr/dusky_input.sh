#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Input (v2.3 - Production / Optimized)
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM
# Description: Tabbed TUI to modify input.conf.
# Base Architecture: Ported from Dusky Appearances v6.1
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
readonly VERSION="2.3"
readonly CONFIG_FILE="${HOME}/.config/hypr/edit_here/source/input.conf"
declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_INNER_WIDTH=76
declare -ri ITEM_START_ROW=5
declare -ri ADJUST_THRESHOLD=40

# --- Pre-computed Constants (Performance Optimization) ---
# Generate horizontal line of BOX_INNER_WIDTH '─' characters without subshells
declare _H_LINE_BUF
printf -v _H_LINE_BUF '%*s' "$BOX_INNER_WIDTH" ''
readonly H_LINE=${_H_LINE_BUF// /─}

# --- ANSI Constants ---
readonly C_RESET=$'\033[0m'
readonly C_CYAN=$'\033[1;36m'
readonly C_GREEN=$'\033[1;32m'
readonly C_MAGENTA=$'\033[1;35m'
readonly C_RED=$'\033[1;31m'
readonly C_WHITE=$'\033[1;37m'
readonly C_GREY=$'\033[1;30m'
readonly C_INVERSE=$'\033[7m'
readonly CLR_EOL=$'\033[K'
readonly CLR_EOS=$'\033[J'
readonly CURSOR_HOME=$'\033[H'
readonly CURSOR_HIDE=$'\033[?25l'
readonly CURSOR_SHOW=$'\033[?25h'
readonly MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
readonly MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

# --- State ---
declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
readonly -a TABS=("Keyboard" "Mouse" "Touchpad" "Cursor" "Gestures")
declare -ri TAB_COUNT=${#TABS[@]}

# Zones for mouse clicks
declare -a TAB_ZONES=()

# --- Data Structures ---
declare -A ITEM_MAP      # label -> config
declare -A VALUE_CACHE   # label -> cached value
declare -A CONFIG_CACHE  # key|block -> raw file value
declare -a TAB_ITEMS_0=() TAB_ITEMS_1=() TAB_ITEMS_2=() TAB_ITEMS_3=() TAB_ITEMS_4=()

# --- Helpers ---
log_err() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET"
    # Optional: Clear screen on exit, or just leave it
    # clear 
}

# Escape special characters for sed replacement (using | as delimiter)
escape_sed_replacement() {
    local s=$1
    s=${s//\\/\\\\}  # Escape Backslash first
    s=${s//|/\\|}    # Escape the Sed Delimiter
    s=${s//&/\\&}    # Escape Ampersand
    s=${s//$'\n'/\\$'\n'} # Escape Newlines
    printf '%s' "$s"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Registration ---
register() {
    local -i tab_idx=$1
    local label=$2 config=$3

    # Bounds check for safety
    if (( tab_idx < 0 || tab_idx >= TAB_COUNT )); then
        cleanup
        printf '%s[FATAL]%s Invalid tab index %d for "%s"\n' "$C_RED" "$C_RESET" "$tab_idx" "$label" >&2
        exit 1
    fi

    ITEM_MAP["$label"]=$config
    local -n tab_ref="TAB_ITEMS_${tab_idx}"
    tab_ref+=("$label")
}

# --- DEFINITIONS ---

# Tab 0: Keyboard (Block: 'input')
register 0 "Layout"             "kb_layout|cycle|input|us,uk,de,fr,es|us|"
register 0 "Numlock Default"    "numlock_by_default|bool|input|||"
register 0 "Repeat Rate"        "repeat_rate|int|input|10|100|5"
register 0 "Repeat Delay"       "repeat_delay|int|input|100|1000|50"
register 0 "Resolve Binds Sym"  "resolve_binds_by_sym|bool|input|||"

# Tab 1: Mouse (Block: 'input')
register 1 "Sensitivity"        "sensitivity|float|input|-1.0|1.0|0.1"
register 1 "Accel Profile"      "accel_profile|cycle|input|flat,adaptive,custom|adaptive|"
register 1 "Force No Accel"     "force_no_accel|bool|input|||"
register 1 "Left Handed"        "left_handed|bool|input|||"
register 1 "Follow Mouse"       "follow_mouse|int|input|0|3|1"
register 1 "Mouse Refocus"      "mouse_refocus|bool|input|||"
register 1 "Mouse Nat Scroll"   "natural_scroll|bool|input|||"
register 1 "Scroll Method"      "scroll_method|cycle|input|2fg,edge,on_button_down,no_scroll|2fg|"

# Tab 2: Touchpad (Block: 'touchpad')
register 2 "TP Nat Scroll"      "natural_scroll|bool|touchpad|||"
register 2 "Tap to Click"       "tap-to-click|bool|touchpad|||"
register 2 "Disable While Typing" "disable_while_typing|bool|touchpad|||"
register 2 "Clickfinger Behav"  "clickfinger_behavior|bool|touchpad|||"
register 2 "Drag Lock"          "drag_lock|bool|touchpad|||"

# Tab 3: Cursor (Block: 'cursor')
register 3 "No HW Cursors"      "no_hardware_cursors|int|cursor|0|2|1"
register 3 "Use CPU Buffer"     "use_cpu_buffer|int|cursor|0|2|1"
register 3 "Hide On Key"        "hide_on_key_press|bool|cursor|||"
register 3 "Inactive Timeout"   "inactive_timeout|int|cursor|0|60|5"
register 3 "Warp On Change"     "warp_on_change_workspace|int|cursor|0|2|1"
register 3 "No Break VRR"       "no_break_fs_vrr|int|cursor|0|2|1"
register 3 "Zoom Factor"        "zoom_factor|float|cursor|1.0|5.0|0.1"

# Tab 4: Gestures (Block: 'gestures')
register 4 "Swipe Distance"     "workspace_swipe_distance|int|gestures|100|1000|50"
register 4 "Swipe Cancel Ratio" "workspace_swipe_cancel_ratio|float|gestures|0.0|1.0|0.1"
register 4 "Swipe Invert"       "workspace_swipe_invert|bool|gestures|||"
register 4 "Swipe Create New"   "workspace_swipe_create_new|bool|gestures|||"
register 4 "Swipe Forever"      "workspace_swipe_forever|bool|gestures|||"

# --- DEFAULTS ---
declare -A DEFAULTS=(
    # Keyboard
    ["Layout"]="us"
    ["Numlock Default"]="true"
    ["Repeat Rate"]="35"
    ["Repeat Delay"]="250"
    ["Resolve Binds Sym"]="false"
    # Mouse
    ["Sensitivity"]="0"
    ["Accel Profile"]="adaptive"
    ["Force No Accel"]="false"
    ["Left Handed"]="true"
    ["Follow Mouse"]="1"
    ["Mouse Refocus"]="true"
    ["Mouse Nat Scroll"]="false"
    ["Scroll Method"]="2fg"
    # Touchpad
    ["TP Nat Scroll"]="true"
    ["Tap to Click"]="true"
    ["Disable While Typing"]="true"
    ["Clickfinger Behav"]="false"
    ["Drag Lock"]="false"
    # Cursor
    ["No HW Cursors"]="2"
    ["Use CPU Buffer"]="2"
    ["Hide On Key"]="false"
    ["Inactive Timeout"]="0"
    ["Warp On Change"]="0"
    ["No Break VRR"]="2"
    ["Zoom Factor"]="1.0"
    # Gestures
    ["Swipe Distance"]="300"
    ["Swipe Cancel Ratio"]="0.5"
    ["Swipe Invert"]="true"
    ["Swipe Create New"]="true"
    ["Swipe Forever"]="false"
)

# --- Core Logic ---

# CACHE ENGINE: Reads the entire file once.
populate_config_cache() {
    CONFIG_CACHE=()
    local key_part value_part key_name

    while IFS='=' read -r key_part value_part; do
        [[ -z "$key_part" ]] && continue
        CONFIG_CACHE["$key_part"]=$value_part
        
        # Fallback for "First Match Anywhere"
        key_name=${key_part%%|*}
        if [[ -z ${CONFIG_CACHE["$key_name|"]:-} ]]; then
            CONFIG_CACHE["$key_name|"]=$value_part
        fi
    done < <(awk '
        BEGIN { depth=0 }
        
        # Skip comment-only lines
        /^[[:space:]]*#/ { next }
        
        {
            line = $0
            sub(/#.*/, "", line) # Strip inline comments
            
            # Detect Block Opening: "block_name {"
            if (match(line, /[a-zA-Z0-9_.:-]+[[:space:]]*\{/)) {
                block_start = RSTART
                block_len = RLENGTH
                block_str = substr(line, block_start, block_len)
                sub(/[[:space:]]*\{/, "", block_str) # Remove brace/spaces
                
                depth++
                block_stack[depth] = block_str
            }
            
            # Detect Key = Value
            if (line ~ /=/) {
                eq_pos = index(line, "=")
                if (eq_pos > 0) {
                    key = substr(line, 1, eq_pos - 1)
                    val = substr(line, eq_pos + 1)
                    
                    # Trim Whitespace
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    
                    if (key != "") {
                        current_block = (depth > 0) ? block_stack[depth] : ""
                        print key "|" current_block "=" val
                    }
                }
            }
            
            # Detect Block Closing
            n = gsub(/\}/, "}", line)
            while (n > 0 && depth > 0) {
                depth--
                n--
            }
        }
    ' "$CONFIG_FILE")
}

write_value_to_file() {
    local key=$1 new_val=$2 block=${3:-}
    local safe_val
    safe_val=$(escape_sed_replacement "$new_val")

    if [[ -n $block ]]; then
        sed --follow-symlinks -i \
            "/^[[:space:]]*${block}[[:space:]]*{/,/^[[:space:]]*}/ {
                s|^\([[:space:]]*${key}[[:space:]]*=[[:space:]]*\)[^#[:space:]]*|\1${safe_val}|
            }" "$CONFIG_FILE"
    else
        sed --follow-symlinks -i \
            "s|^\([[:space:]]*${key}[[:space:]]*=[[:space:]]*\)[^#[:space:]]*|\1${safe_val}|" \
            "$CONFIG_FILE"
    fi

    # Update Memory Cache
    CONFIG_CACHE["$key|$block"]=$new_val
    if [[ -z $block ]]; then
        CONFIG_CACHE["$key|"]=$new_val
    fi
}

load_tab_values() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item key type block val

    for item in "${items_ref[@]}"; do
        IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$item]}"
        
        # Use cache lookup
        val=${CONFIG_CACHE["$key|$block"]:-}
        VALUE_CACHE["$item"]=${val:-unset}
    done
}

modify_value() {
    local label=$1
    local -i direction=$2
    local key type block min max step current new_val

    IFS='|' read -r key type block min max step <<< "${ITEM_MAP[$label]}"
    current=${VALUE_CACHE[$label]:-}
    [[ $current == "unset" ]] && current=""

    case $type in
        int)
            if [[ ! $current =~ ^-?[0-9]+$ ]]; then current=${min:-0}; fi
            local -i int_step=${step:-1}
            local -i int_val=$current
            # Consistent with dusky_appearances: use || : for set -e safety
            (( int_val += direction * int_step )) || :
            
            if [[ -n $min ]] && (( int_val < min )); then int_val=$min; fi
            if [[ -n $max ]] && (( int_val > max )); then int_val=$max; fi
            new_val=$int_val
            ;;
        float)
            if [[ ! $current =~ ^-?[0-9]*\.?[0-9]+$ ]]; then current=${min:-0.0}; fi
            new_val=$(awk -v c="$current" -v dir="$direction" -v s="${step:-0.1}" \
                          -v mn="$min" -v mx="$max" '
                BEGIN {
                    val = c + (dir * s)
                    if (mn != "" && val < mn) val = mn
                    if (mx != "" && val > mx) val = mx
                    printf "%.4g", val
                }
            ')
            ;;
        bool)
            [[ $current == "true" ]] && new_val="false" || new_val="true"
            ;;
        cycle)
            # Cycle logic preserved from original input script
            local options_str=$min
            IFS=',' read -r -a opts <<< "$options_str"
            local -i idx=0 found=0 count=${#opts[@]}
            
            for (( i=0; i<count; i++ )); do
                [[ "${opts[i]}" == "$current" ]] && { idx=$i; found=1; break; }
            done
            
            [[ $found -eq 0 ]] && idx=0
            (( idx += direction )) || :
            if (( idx < 0 )); then idx=$(( count - 1 )); fi
            if (( idx >= count )); then idx=0; fi
            new_val=${opts[idx]}
            ;;
        *) return 0 ;;
    esac

    write_value_to_file "$key" "$new_val" "$block"
    VALUE_CACHE["$label"]=$new_val
}

set_absolute_value() {
    local label=$1 new_val=$2
    local key type block
    IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$label]}"
    
    write_value_to_file "$key" "$new_val" "$block"
    VALUE_CACHE["$label"]=$new_val
}

reset_defaults() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item def_val
    
    for item in "${items_ref[@]}"; do
        def_val=${DEFAULTS[$item]:-}
        [[ -n $def_val ]] && set_absolute_value "$item" "$def_val"
    done
}

# --- UI Rendering ---

draw_ui() {
    local buf=""
    local -i i current_col=3
    
    buf+="${CURSOR_HOME}"
    
    # Top Border (Optimized)
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'
    
    # Header - Dynamic Centering
    local title_text="Dusky Input v${VERSION}"
    local -i title_len=${#title_text}
    local -i left_pad=$(( (BOX_INNER_WIDTH - title_len) / 2 ))
    local -i right_pad=$(( BOX_INNER_WIDTH - title_len - left_pad ))
    
    buf+="${C_MAGENTA}│"
    buf+=$(printf '%*s' "$left_pad" '')
    buf+="${C_WHITE}${title_text}${C_MAGENTA}"
    buf+=$(printf '%*s' "$right_pad" '')
    buf+="│${C_RESET}"$'\n'
    
    local tab_line="${C_MAGENTA}│ "
    TAB_ZONES=()
    
    for (( i = 0; i < TAB_COUNT; i++ )); do
        local name=${TABS[i]}
        local -i len=${#name}
        local -i zone_start=$current_col
        
        if (( i == CURRENT_TAB )); then
            tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
        else
            tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
        fi
        
        TAB_ZONES+=("${zone_start}:$(( zone_start + len + 1 ))")
        (( current_col += len + 4 )) || :
    done
    
    # Border Alignment Fix
    local -i pad_needed=$(( BOX_INNER_WIDTH - current_col + 2 )) # Adjusted +2 to fix broken right border
    
    if (( pad_needed > 0 )); then
        tab_line+=$(printf '%*s' "$pad_needed" '')
    fi
    tab_line+="${C_MAGENTA}│${C_RESET}"
    
    buf+="${tab_line}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#items_ref[@]}
    local item val display

    # Clamp selection
    if (( count == 0 )); then SELECTED_ROW=0;
    elif (( SELECTED_ROW >= count )); then SELECTED_ROW=$(( count - 1 ));
    elif (( SELECTED_ROW < 0 )); then SELECTED_ROW=0; fi

    for (( i = 0; i < count; i++ )); do
        item=${items_ref[i]}
        val=${VALUE_CACHE[$item]:-unset}

        case $val in
            true)         display="${C_GREEN}ON${C_RESET}" ;;
            false)        display="${C_RED}OFF${C_RESET}" ;;
            unset)        display="${C_RED}unset${C_RESET}" ;;
            *)            display="${C_WHITE}${val}${C_RESET}" ;;
        esac

        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}"
            # Padding 32 to match original input script aesthetic
            buf+=$(printf '%-32s' "$item")
            buf+="${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            buf+="   "
            buf+=$(printf ' %-32s' "$item")
            buf+=" : ${display}${CLR_EOL}"$'\n'
        fi
    done

    for (( i = count; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    buf+=$'\n'"${C_CYAN} [Tab] Category  [r] Reset  [←/→ h/l] Adjust  [↑/↓ j/k] Nav  [q] Quit${C_RESET}"$'\n'
    buf+="${C_CYAN} File: ${C_WHITE}${CONFIG_FILE}${C_RESET}${CLR_EOL}${CLR_EOS}"
    
    printf '%s' "$buf"
}

# --- Input Handling ---

navigate() {
    local -i dir=$1
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#items_ref[@]}
    
    (( count == 0 )) && return 0
    (( SELECTED_ROW += dir )) || :
    
    if (( SELECTED_ROW < 0 )); then SELECTED_ROW=$(( count - 1 ));
    elif (( SELECTED_ROW >= count )); then SELECTED_ROW=0; fi
}

adjust() {
    local -i dir=$1
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    [[ ${#items_ref[@]} -eq 0 ]] && return 0
    modify_value "${items_ref[SELECTED_ROW]}" "$dir"
}

switch_tab() {
    local -i dir=${1:-1}
    (( CURRENT_TAB += dir )) || :
    if (( CURRENT_TAB >= TAB_COUNT )); then CURRENT_TAB=0;
    elif (( CURRENT_TAB < 0 )); then CURRENT_TAB=$(( TAB_COUNT - 1 )); fi
    SELECTED_ROW=0
    load_tab_values
    # Note: 'clear' removed here to prevent flicker. 
    # draw_ui handles repainting via CURSOR_HOME + CLR_EOS.
}

set_tab() {
    local -i idx=$1
    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0
        load_tab_values
    fi
}

handle_mouse() {
    local input=$1
    local -i button x y i
    local type zone start end
    
    if [[ $input =~ ^\[\<([0-9]+)\;([0-9]+)\;([0-9]+)([Mm])$ ]]; then
        button=${BASH_REMATCH[1]}
        x=${BASH_REMATCH[2]}
        y=${BASH_REMATCH[3]}
        type=${BASH_REMATCH[4]}
        
        [[ $type != "M" ]] && return 0

        if (( y == 3 )); then
            for (( i = 0; i < TAB_COUNT; i++ )); do
                zone=${TAB_ZONES[i]}
                start=${zone%%:*}
                end=${zone##*:}
                if (( x >= start && x <= end )); then
                    set_tab "$i"
                    return 0
                fi
            done
        fi
        
        local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
        local -i count=${#items_ref[@]}
        
        if (( y >= ITEM_START_ROW && y < ITEM_START_ROW + count )); then
            SELECTED_ROW=$(( y - ITEM_START_ROW ))
            if (( x > ADJUST_THRESHOLD )); then
                (( button == 0 )) && adjust 1 || adjust -1
            fi
        fi
    fi
}

# --- Main ---

main() {
    # Permissions & Existence Check
    [[ ! -f $CONFIG_FILE ]] && { log_err "Config not found: $CONFIG_FILE"; exit 1; }
    [[ ! -r $CONFIG_FILE ]] && { log_err "Config not readable: $CONFIG_FILE"; exit 1; }
    [[ ! -w $CONFIG_FILE ]] && { log_err "Config not writable: $CONFIG_FILE"; exit 1; }
    
    command -v awk &>/dev/null || { log_err "Required: awk"; exit 1; }
    command -v sed &>/dev/null || { log_err "Required: sed"; exit 1; }

    populate_config_cache
    printf '%s%s' "$MOUSE_ON" "$CURSOR_HIDE"
    load_tab_values
    clear

    local key seq char
    while true; do
        draw_ui
        
        # Safe Read Loop
        if ! IFS= read -rsn1 key; then continue; fi
        
        if [[ $key == $'\x1b' ]]; then
            seq=""
            # Timeout 20ms for reliability (consistent with appearance script)
            while IFS= read -rsn1 -t 0.02 char; do
                seq+="$char"
            done
            
            case $seq in
                '[Z')               switch_tab -1 ;;
                '[A'|'OA')          navigate -1 ;;
                '[B'|'OB')          navigate 1 ;;
                '[C'|'OC')          adjust 1 ;;
                '[D'|'OD')          adjust -1 ;;
                '['*'<'*)           handle_mouse "$seq" ;;
            esac
        else
            case $key in
                k|K)            navigate -1 ;;
                j|J)            navigate 1 ;;
                l|L)            adjust 1 ;;
                h|H)            adjust -1 ;;
                $'\t')          switch_tab 1 ;;
                r|R)            reset_defaults ;;
                q|Q|$'\x03')    break ;;
            esac
        fi
    done
}

main
