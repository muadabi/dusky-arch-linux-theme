#!/usr/bin/env bash
# ==============================================================================
# WAYCLICK ELITE - ARCH LINUX / UV OPTIMIZED (PLATINUM EDITION)
# ==============================================================================
# "I fear not the man who has practiced 10,000 kicks once,
#  but I fear the man who has practiced one kick 10,000 times." - Bruce Lee
# ==============================================================================

set -euo pipefail
trap cleanup EXIT INT TERM

# --- CONFIGURATION ---
readonly APP_NAME="wayclick"
readonly CONFIG_ENABLE_TRACKPADS="false"
readonly BASE_DIR="$HOME/contained_apps/uv/$APP_NAME"
readonly VENV_DIR="$BASE_DIR/.venv"
readonly PYTHON_BIN="$VENV_DIR/bin/python"
readonly RUNNER_SCRIPT="$BASE_DIR/runner.py"
readonly CONFIG_DIR="$HOME/.config/wayclick"
readonly STATE_FILE="$HOME/.config/dusky/settings/wayclick"

# --- ANSI COLORS ---
readonly C_RED=$'\033[1;31m'
readonly C_GREEN=$'\033[1;32m'
readonly C_BLUE=$'\033[1;34m'
readonly C_CYAN=$'\033[1;36m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_DIM=$'\033[2m'
readonly C_RESET=$'\033[0m'

# --- STATE MANAGEMENT ---
update_state() {
    local status="$1"
    local dir state_tmp
    dir="${STATE_FILE%/*}"
    state_tmp="${STATE_FILE}.tmp.$$"
    
    mkdir -p "$dir" 2>/dev/null || true
    
    # ATOMIC WRITE: Prevents corruption on crash/power loss
    printf '%s\n' "$status" > "$state_tmp" && mv -f "$state_tmp" "$STATE_FILE"
}

cleanup() {
    tput cnorm 2>/dev/null || true
    update_state "False"
}

# --- CHECKS & TOGGLE LOGIC ---

# 0. Root Check
if (( EUID == 0 )); then
    printf "%b[CRITICAL]%b Do not run this script as root.\n" "${C_RED}" "${C_RESET}"
    exit 1
fi

# 1. Toggle Logic (NUCLEAR OPTION - Fixes Ghost Processes)
# We search loosely for 'runner.py' to ensure we kill ANY version (Old or New).
# This prevents "Double Audio" where two scripts fight for the keyboard.
if pgrep -f "runner.py" >/dev/null 2>&1; then
    printf "%b[TOGGLE]%b Stopping active instance...\n" "${C_YELLOW}" "${C_RESET}"
    
    command -v notify-send >/dev/null 2>&1 && notify-send --app-name="WayClick" "WayClick Elite" "Disabled"
    
    # Kill EVERYTHING matching runner.py
    pkill -TERM -f "runner.py" 2>/dev/null || true
    
    # Wait loop with timeout (max 5 seconds)
    local wait_count=0
    while pgrep -f "runner.py" >/dev/null 2>&1 && (( wait_count++ < 50 )); do
        sleep 0.1
    done
    
    # Hard kill if it became a zombie
    pkill -KILL -f "runner.py" 2>/dev/null || true
    exit 0
fi

# 2. Interactive Mode Detection
[[ -t 0 ]] && INTERACTIVE=true || INTERACTIVE=false

notify_user() {
    command -v notify-send >/dev/null 2>&1 && notify-send --app-name="WayClick" "WayClick Elite" "$1"
}

# 3. Dependency Check (Safe Array usage)
declare -a NEEDED_DEPS=()
command -v uv >/dev/null 2>&1 || NEEDED_DEPS+=("uv")
command -v notify-send >/dev/null 2>&1 || NEEDED_DEPS+=("libnotify")

if (( ${#NEEDED_DEPS[@]} > 0 )); then
    if $INTERACTIVE; then
        clear
        printf "%b
╔══════════════════════════════════════════════════════════════╗
║  %bWAYCLICK ELITE%b                                            ║
║  %bHotplug • User Mode • Native AVX2 • Contained%b             ║
╚══════════════════════════════════════════════════════════════╝
%b" "${C_CYAN}" "${C_GREEN}" "${C_CYAN}" "${C_DIM}" "${C_CYAN}" "${C_RESET}"

        printf "%b[SETUP]%b Missing system dependencies:%b %s%b\n" "${C_YELLOW}" "${C_RESET}" "${C_CYAN}" "${NEEDED_DEPS[*]}" "${C_RESET}"
        printf "       Requesting sudo to install via pacman...\n"
        
        if sudo pacman -S --needed --noconfirm "${NEEDED_DEPS[@]}"; then
            printf "%b[SUCCESS]%b Dependencies installed.\n" "${C_GREEN}" "${C_RESET}"
        else
            printf "%b[ERROR]%b Installation failed.\n" "${C_RED}" "${C_RESET}"
            exit 1
        fi
    else
        notify_user "Missing dependencies (${NEEDED_DEPS[*]}). Run in terminal first."
        exit 1
    fi
fi

# 4. Group Permission Check (Reliable Word Boundaries)
if ! id -nG "$USER" | grep -qw input; then
    if $INTERACTIVE; then
        printf "%b[PERM]%b User '%s' is not in the 'input' group.\n" "${C_RED}" "${C_RESET}" "$USER"
        read -rp "Run 'sudo usermod -aG input $USER'? [Y/n] " -n 1
        echo
        if [[ ${REPLY:-Y} =~ ^[Yy]$ ]]; then
            sudo usermod -aG input "$USER"
            printf "%b[INFO]%b Group added. %bLOGOUT REQUIRED%b for changes to apply.\n" "${C_GREEN}" "${C_RESET}" "${C_RED}" "${C_RESET}"
            exit 0
        else
            exit 1
        fi
    else
        notify_user "Permission error: User not in 'input' group. Run in terminal."
        exit 1
    fi
fi

# 5. Sound Files Check
check_sounds() {
    [[ -d "$CONFIG_DIR" && -f "${CONFIG_DIR}/config.json" ]]
}

if ! check_sounds; then
    if $INTERACTIVE; then
        while ! check_sounds; do
            printf "\n%b[ACTION REQUIRED]%b Missing config.json in: %s\n" "${C_YELLOW}" "${C_RESET}" "${CONFIG_DIR}"
            mkdir -p "$CONFIG_DIR" 2>/dev/null || true
            printf "       Please ensure 'config.json' exists in this folder.\n"
            printf "       %bPress Enter to re-scan...%b" "${C_DIM}" "${C_RESET}"
            read -r
        done
        printf "%b[CHECK]%b Configuration found.\n" "${C_GREEN}" "${C_RESET}"
    else
        notify_user "Missing config.json in ~/.config/wayclick. Run in terminal."
        exit 1
    fi
fi

# --- ENVIRONMENT SETUP ---

mkdir -p "$BASE_DIR" 2>/dev/null || true

if [[ ! -d "$VENV_DIR" ]]; then
    if ! $INTERACTIVE; then
        notify_user "Environment not built! Run in terminal once to initialize."
        exit 1
    fi
    printf "%b[BUILD]%b Initializing UV environment...\n" "${C_BLUE}" "${C_RESET}"
    uv venv "$VENV_DIR" --python 3.14 --quiet
fi

# Build marker v5 to ensure fresh compilation with LTO flags
MARKER_FILE="$BASE_DIR/.build_marker_v5"

if [[ ! -f "$MARKER_FILE" ]]; then
    if ! $INTERACTIVE; then
        notify_user "First run setup required! Run in terminal to build native extensions."
        exit 1
    fi

    printf "%b[BUILD]%b Compiling dependencies with NATIVE CPU FLAGS (AVX2+ / LTO)...\n" "${C_YELLOW}" "${C_RESET}"
    printf "       %bThis runs ON THE METAL. No generic binaries allowed.%b\n" "${C_DIM}" "${C_RESET}"
    
    # ---------------------------------------------------------
    # ELITE BUILD FLAGS (LTO Included)
    # -flto=auto: Link-Time Optimization for C extensions (5-15% speedup)
    # ---------------------------------------------------------
    export CFLAGS="-march=native -mtune=native -O3 -pipe -fno-plt -flto=auto -ffat-lto-objects"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-Wl,-O1,--sort-common,--as-needed,-z,now,--relax -flto=auto"
    
    uv pip install --python "$PYTHON_BIN" \
        --no-binary :all: \
        --compile-bytecode \
        evdev pygame-ce

    touch "$MARKER_FILE"
    printf "%b[SUCCESS]%b Native build complete.\n" "${C_GREEN}" "${C_RESET}"
fi

# --- PYTHON RUNNER GENERATION ---
cat > "$RUNNER_SCRIPT" << 'PYTHON_EOF'
import asyncio
import os
import sys
import signal
import random
import json

# === STARTUP OPTIMIZATION ===
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
# 512 Buffer = ~10ms latency (Imperceptible) but ZERO crackle risk.
os.environ['SDL_BUFFER_CHUNK_SIZE'] = '512'
os.environ['SDL_AUDIODRIVER'] = 'pipewire,pulseaudio,alsa'

import pygame
import evdev

C_GREEN, C_YELLOW, C_BLUE, C_RED, C_RESET = "\033[1;32m", "\033[1;33m", "\033[1;34m", "\033[1;31m", "\033[0m"

ASSET_DIR = sys.argv[1]
ENABLE_TRACKPADS = os.environ.get('ENABLE_TRACKPADS', 'false').lower() == 'true'

# === AUDIO INIT ===
# 48000Hz = Native Pipewire Rate (No Resampling = Cleaner Audio)
try:
    pygame.mixer.pre_init(frequency=48000, size=-16, channels=2, buffer=512)
    pygame.mixer.init()
    pygame.mixer.set_num_channels(32)
except pygame.error as e:
    sys.exit(f"{C_RED}[AUDIO ERROR]{C_RESET} {e}")

# === CONFIG LOADING ===
CONFIG_FILE = os.path.join(ASSET_DIR, "config.json")
print(f"{C_BLUE}[INFO]{C_RESET} Loading assets from {ASSET_DIR}...")

try:
    with open(CONFIG_FILE, 'r') as f:
        config_data = json.load(f)
        RAW_KEY_MAP = {int(k): v for k, v in config_data.get("mappings", {}).items()}
        DEFAULTS = config_data.get("defaults", [])
except Exception as e:
    sys.exit(f"{C_RED}[CONFIG ERROR]{C_RESET} Failed to load {CONFIG_FILE}: {e}")

# === SOUND LOADING ===
SOUND_FILES = set(RAW_KEY_MAP.values()) | set(DEFAULTS)
SOUNDS = {}

for filename in SOUND_FILES:
    path = os.path.join(ASSET_DIR, filename)
    if os.path.exists(path):
        try:
            SOUNDS[filename] = pygame.mixer.Sound(path)
        except pygame.error:
            print(f"{C_YELLOW}[WARN]{C_RESET} Failed to load wav: {filename}")
    else:
        print(f"{C_YELLOW}[WARN]{C_RESET} File not found: {filename}")

if not SOUNDS:
    sys.exit("ERROR: No sounds loaded! Check your config.json and .wav files.")

# === PERFORMANCE: LIST CACHE LOOKUP ===
# The 65536 List index is strictly faster than a dict.get() in CPython.
MAX_KEYCODE = 65536
SOUND_CACHE = [None] * MAX_KEYCODE
DEFAULT_SOUND_OBJS = tuple(SOUNDS[f] for f in DEFAULTS if f in SOUNDS)

for code, filename in RAW_KEY_MAP.items():
    if code < MAX_KEYCODE and filename in SOUNDS:
        SOUND_CACHE[code] = SOUNDS[filename]

# === HOT PATH PRE-BINDING (LOAD_FAST vs LOAD_GLOBAL) ===
_random_choice = random.choice
_sound_cache = SOUND_CACHE
_max_keycode = MAX_KEYCODE
_defaults = DEFAULT_SOUND_OBJS
_has_defaults = bool(DEFAULT_SOUND_OBJS)

def play_sound(code):
    """Ultra-minimal hot path relying exclusively on local variables."""
    if code < _max_keycode:
        sound = _sound_cache[code]
        if sound is not None:
            sound.play()
            return
    if _has_defaults:
        _random_choice(_defaults).play()

async def read_device(dev, stop_event):
    """Async reader. Accepts pre-opened device to avoid descriptor thrashing."""
    _play = play_sound
    _is_stopped = stop_event.is_set
    
    print(f"{C_GREEN}[+] Connected:{C_RESET} {dev.name}")
    try:
        async for event in dev.async_read_loop():
            if _is_stopped():
                break
            if event.type == 1 and event.value == 1:
                _play(event.code)
                
    except (OSError, IOError):
        print(f"{C_YELLOW}[-] Disconnected:{C_RESET} {dev.path}")
    except asyncio.CancelledError:
        pass
    finally:
        dev.close()

async def main():
    print(f"{C_BLUE}[CORE]{C_RESET} Engine started. Monitoring devices...")
    
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    
    monitored_tasks = {}
    _list_devices = evdev.list_devices

    while not stop.is_set():
        try:
            all_paths = _list_devices()
            
            for path in all_paths:
                if path in monitored_tasks:
                    continue
                
                try:
                    dev = evdev.InputDevice(path)
                    
                    if not ENABLE_TRACKPADS:
                        name_lower = dev.name.lower()
                        if 'touchpad' in name_lower or 'trackpad' in name_lower:
                            dev.close()
                            continue

                    caps = dev.capabilities()
                    if 1 in caps:  # EV_KEY
                        # ARCHITECTURAL FIX: Pass the opened 'dev' directly to the task.
                        # Do not close it here just to re-open it inside read_device().
                        task = asyncio.create_task(read_device(dev, stop))
                        monitored_tasks[path] = task
                    else:
                        dev.close()
                except (OSError, IOError):
                    continue

        except Exception as e:
            print(f"Discovery Loop Error: {e}")

        # Cleanup completed tasks
        dead_paths = [p for p, t in monitored_tasks.items() if t.done()]
        for p in dead_paths:
            del monitored_tasks[p]

        # Hotplug poll (3s)
        try:
            await asyncio.wait_for(stop.wait(), timeout=3.0)
        except asyncio.TimeoutError:
            continue
    
    # Graceful shutdown
    print("\nStopping...")
    for t in monitored_tasks.values():
        t.cancel()
    if monitored_tasks:
        await asyncio.gather(*monitored_tasks.values(), return_exceptions=True)
    pygame.mixer.quit()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
PYTHON_EOF

# --- EXECUTION ---
printf "%b[RUN]%b Starting engine...\n" "${C_BLUE}" "${C_RESET}"

$INTERACTIVE || notify_user "Enabled"

update_state "True"

# Execute using UV Python. 
# -OOB: Strip asserts (-O), strip docstrings (-OO), don't write pyc (-B)
ENABLE_TRACKPADS="$CONFIG_ENABLE_TRACKPADS" "$PYTHON_BIN" -OOB "$RUNNER_SCRIPT" "$CONFIG_DIR"

printf "\n%b[INFO]%b WayClick stopped.\n" "${C_BLUE}" "${C_RESET}"
