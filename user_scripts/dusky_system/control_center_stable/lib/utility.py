"""
Utility functions for the Dusky Control Center.

Thread-safe, secure utility library for GTK4 control center on Arch Linux (Hyprland).
All file I/O is atomic. All public functions are safe to call from any thread.

Design Invariants:
    1. All mutable global state is protected by explicit locks.
    2. File writes use atomic rename (write-to-temp, fsync, rename, fsync-dir).
    3. Path validation uses allowlist containment via Path.relative_to().
    4. Subprocess spawning is fire-and-forget with proper session isolation.
"""
from __future__ import annotations

import logging
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING, Final, TypeVar, overload

import yaml

if TYPE_CHECKING:
    from gi.repository import Adw

log = logging.getLogger(__name__)

_T = TypeVar("_T")


# =============================================================================
# CONSTANTS & PATHS
# =============================================================================
LABEL_NA: Final[str] = "N/A"

# Characters requiring shell interpretation (POSIX sh metacharacters)
_SHELL_METACHARACTERS: Final[frozenset[str]] = frozenset(
    "|&;()<>$`\\\"'*?[]#~=!{}%"
)

# Regex to find unquoted tildes for expansion
_TILDE_PATTERN: Final[re.Pattern[str]] = re.compile(r"(?:^|(?<=\s))~(?=/|$|\s)")


def _get_xdg_path(env_var: str, default_suffix: str) -> Path:
    """Get XDG base directory path with validation.

    Per the XDG Base Directory Specification, paths MUST be absolute.
    If the environment variable is unset, empty, or contains a relative path,
    the default is used.
    """
    value = os.environ.get(env_var, "").strip()
    if value:
        candidate = Path(value)
        if candidate.is_absolute():
            return candidate
        log.warning(
            "Ignoring non-absolute %s='%s'; using default", env_var, value
        )
    return Path.home() / default_suffix


_XDG_CACHE_HOME: Final[Path] = _get_xdg_path("XDG_CACHE_HOME", ".cache")
_XDG_CONFIG_HOME: Final[Path] = _get_xdg_path("XDG_CONFIG_HOME", ".config")

CACHE_DIR: Final[Path] = _XDG_CACHE_HOME / "duskycc"
SETTINGS_DIR: Final[Path] = _XDG_CONFIG_HOME / "dusky" / "settings"


# =============================================================================
# THREAD-SAFE STATE CONTAINERS
# =============================================================================
class _ResolvedDirectoryCache:
    """Thread-safe lazy initializer for a directory path.

    Ensures the directory exists and caches its resolved (absolute, symlink-free) path.
    Uses double-checked locking for efficiency.
    """

    __slots__ = ("_base_dir", "_lock", "_resolved")

    def __init__(self, base_dir: Path) -> None:
        self._base_dir: Final[Path] = base_dir
        self._lock: Final[threading.Lock] = threading.Lock()
        self._resolved: Path | None = None

    def get(self) -> Path:
        """Return the resolved directory path, creating it if necessary."""
        # Fast path: already resolved (volatile read is safe for immutable Path)
        resolved = self._resolved
        if resolved is not None:
            return resolved

        with self._lock:
            # Re-check under lock
            if self._resolved is not None:
                return self._resolved

            self._base_dir.mkdir(parents=True, exist_ok=True)
            self._resolved = self._base_dir.resolve(strict=True)
            return self._resolved


class _ComputeOnceCache:
    """Thread-safe cache for lazily computed values.

    Each key's computation is performed at most once. Computations for different
    keys can proceed concurrently if they don't overlap.
    """

    __slots__ = ("_cache", "_in_flight", "_lock")

    def __init__(self) -> None:
        self._lock: Final[threading.Lock] = threading.Lock()
        self._cache: dict[str, object] = {}
        # Condition variables per in-flight computation
        self._in_flight: dict[str, threading.Condition] = {}

    def get_or_compute(self, key: str, compute_fn: Callable[[], _T]) -> _T:
        """Return cached value for key, computing it if absent.

        If another thread is currently computing the same key, this thread
        waits for that computation to complete rather than computing redundantly.
        """
        with self._lock:
            if key in self._cache:
                return self._cache[key]  # type: ignore[return-value]

            if key in self._in_flight:
                # Another thread is computing this key; wait for it
                cond = self._in_flight[key]
                cond.wait()
                # After waking, the value should be cached
                return self._cache[key]  # type: ignore[return-value]

            # We will compute this key; create a condition for waiters
            cond = threading.Condition(self._lock)
            self._in_flight[key] = cond

        # Compute outside the lock to avoid blocking unrelated keys
        try:
            value = compute_fn()
        except BaseException:
            # On failure, clean up and re-raise
            with self._lock:
                self._in_flight.pop(key, None)
                cond.notify_all()
            raise

        with self._lock:
            self._cache[key] = value
            del self._in_flight[key]
            cond.notify_all()

        return value


# Module-level singletons
_settings_dir_cache: Final = _ResolvedDirectoryCache(SETTINGS_DIR)
_cache_dir_cache: Final = _ResolvedDirectoryCache(CACHE_DIR)
_system_info_cache: Final = _ComputeOnceCache()


def get_cache_dir() -> Path:
    """Return the application cache directory, creating it if necessary.

    Thread-safe. The path is resolved (absolute, no symlinks) and cached.
    """
    return _cache_dir_cache.get()


# =============================================================================
# CONFIGURATION LOADER
# =============================================================================
def load_config(config_path: Path) -> dict[str, object]:
    """Load and parse a YAML configuration file.

    Thread-safe (no shared mutable state).
    Returns an empty dict on missing file, read error, or parse error.
    """
    try:
        content = config_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        log.debug("Config file not found: %s", config_path)
        return {}
    except OSError as e:
        log.error("Failed to read config %s: %s", config_path, e)
        return {}

    try:
        data = yaml.safe_load(content)
    except yaml.YAMLError as e:
        log.error("YAML parse error in %s: %s", config_path, e)
        return {}

    if not isinstance(data, dict):
        log.warning("Config root is not a mapping in %s", config_path)
        return {}

    return data


# =============================================================================
# UWSM-COMPLIANT COMMAND RUNNER
# =============================================================================
def execute_command(cmd_string: str, title: str, run_in_terminal: bool) -> bool:
    """Execute a command via uwsm-app, optionally in a terminal.

    Thread-safe. Uses fire-and-forget pattern with process isolation via setsid.
    Returns True if the process was successfully spawned.
    """
    if not cmd_string or not cmd_string.strip():
        log.debug("Empty command string; nothing to execute")
        return False

    expanded_cmd = _expand_command(cmd_string)
    if not expanded_cmd:
        log.warning("Command expansion resulted in empty string: %r", cmd_string)
        return False

    safe_title = _sanitize_title(title)
    full_cmd = _build_command_list(expanded_cmd, safe_title, run_in_terminal)

    if full_cmd is None:
        log.warning("Failed to build command list for: %r", expanded_cmd)
        return False

    try:
        # Fire-and-forget: start_new_session creates a new process group and
        # session, preventing the child from receiving signals aimed at us and
        # ensuring it's orphaned cleanly when we exit.
        proc = subprocess.Popen(
            full_cmd,
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )
        # Explicitly detach to suppress ResourceWarning in debug mode.
        # The process is orphaned to init/systemd regardless.
        del proc
        return True

    except FileNotFoundError as e:
        log.error(
            "Command not found (check PATH and uwsm-app installation): %s", e
        )
        return False
    except OSError as e:
        log.error("Failed to spawn command: %s", e)
        return False


def _expand_command(cmd_string: str) -> str:
    """Expand environment variables and ~ in command string.

    Handles:
        - Environment variables: $VAR and ${VAR}
        - Home directory: ~ at word boundaries (e.g., ~/foo, ~user/bar)
    """
    # Expand environment variables
    expanded = os.path.expandvars(cmd_string)

    # Expand all unquoted tildes (at word boundaries)
    # This is a simplification; full shell tilde expansion is complex
    def _expand_tilde(match: re.Match[str]) -> str:
        return str(Path.home())

    expanded = _TILDE_PATTERN.sub(_expand_tilde, expanded)

    return expanded.strip()


def _sanitize_title(title: str | None) -> str:
    """Produce a safe terminal title string.

    Removes control characters and ensures a non-empty result.
    """
    base = (title or "").strip() or "Dusky Terminal"
    # Remove control characters and normalize whitespace
    sanitized = "".join(
        c if c.isprintable() and c not in "\n\r\t\x00" else " " for c in base
    )
    return " ".join(sanitized.split()) or "Dusky Terminal"


def _build_command_list(
    expanded_cmd: str,
    safe_title: str,
    run_in_terminal: bool,
) -> list[str] | None:
    """Construct the subprocess argument list for uwsm-app execution."""
    if run_in_terminal:
        # Terminal mode: always use shell to handle complex commands
        return [
            "uwsm-app",
            "--",
            "kitty",
            "--class", "dusky-term",
            "--title", safe_title,
            "--hold",
            "sh", "-c", expanded_cmd,
        ]

    # Non-terminal mode: avoid shell if possible for efficiency and safety
    needs_shell = any(c in expanded_cmd for c in _SHELL_METACHARACTERS)

    if needs_shell:
        return ["uwsm-app", "--", "sh", "-c", expanded_cmd]

    # Attempt to parse as simple argument list
    try:
        parsed_args = shlex.split(expanded_cmd)
    except ValueError as e:
        log.debug("shlex.split failed (%s); falling back to shell", e)
        return ["uwsm-app", "--", "sh", "-c", expanded_cmd]

    if not parsed_args:
        return None

    return ["uwsm-app", "--", *parsed_args]


# =============================================================================
# PRE-FLIGHT DEPENDENCY CHECK
# =============================================================================
def preflight_check() -> None:
    """Verify critical runtime dependencies before startup.

    Logs warnings for non-fatal issues and exits with code 1 for fatal issues.
    """
    missing_deps: list[str] = []
    warnings: list[str] = []

    # Check GTK4/Libadwaita via PyGObject
    try:
        import gi
        gi.require_version("Gtk", "4.0")
        gi.require_version("Adw", "1")
        from gi.repository import Adw, Gtk  # noqa: F401
    except ImportError:
        missing_deps.append("python-gobject")
    except ValueError as e:
        msg = str(e).lower()
        if "gtk" in msg:
            missing_deps.append("gtk4")
        elif "adw" in msg:
            missing_deps.append("libadwaita")
        else:
            missing_deps.append("python-gobject (unknown version error)")

    # Check for uwsm-app (required for UWSM session integration)
    if shutil.which("uwsm-app") is None:
        missing_deps.append("uwsm")

    if missing_deps:
        msg = f"Missing required dependencies: {', '.join(missing_deps)}"
        log.critical(msg)
        print(f"\n[FATAL] {msg}", file=sys.stderr)
        print(
            f"Install with: sudo pacman -S {' '.join(missing_deps)}\n",
            file=sys.stderr,
        )
        sys.exit(1)

    # Verify settings directory is writable
    try:
        test_file = SETTINGS_DIR / ".write_test"
        SETTINGS_DIR.mkdir(parents=True, exist_ok=True)
        test_file.touch()
        test_file.unlink()
    except OSError as e:
        warnings.append(f"Settings directory not writable ({SETTINGS_DIR}): {e}")

    for warning in warnings:
        log.warning(warning)


# =============================================================================
# SYSTEM VALUE RETRIEVAL (CACHED, THREAD-SAFE)
# =============================================================================
def get_system_value(key: str) -> str:
    """Retrieve static system information with thread-safe caching.

    Computed values are cached permanently (system info is immutable at runtime).
    Unknown keys return LABEL_NA.
    """
    return _system_info_cache.get_or_compute(key, lambda: _compute_system_value(key))


def _compute_system_value(key: str) -> str:
    """Dispatch to the appropriate system info collector."""
    match key:
        case "memory_total":
            return _get_memory_total()
        case "cpu_model":
            return _get_cpu_model()
        case "gpu_model":
            return _get_gpu_model()
        case "kernel_version":
            return os.uname().release
        case _:
            log.debug("Unknown system value key: %r", key)
            return LABEL_NA


def _get_memory_total() -> str:
    """Read total memory from /proc/meminfo."""
    try:
        content = Path("/proc/meminfo").read_text(encoding="utf-8")
        for line in content.splitlines():
            if line.startswith("MemTotal:"):
                parts = line.split()
                if len(parts) >= 2:
                    kb = int(parts[1])
                    gb = round(kb / 1_048_576, 1)
                    return f"{gb} GB"
    except (OSError, ValueError, IndexError) as e:
        log.debug("Failed to read memory info: %s", e)
    return LABEL_NA


def _get_cpu_model() -> str:
    """Read CPU model name from /proc/cpuinfo."""
    try:
        content = Path("/proc/cpuinfo").read_text(encoding="utf-8")
        for line in content.splitlines():
            if line.strip().lower().startswith("model name"):
                _, _, value = line.partition(":")
                raw = value.strip()
                # Strip frequency suffix (e.g., "@ 3.50GHz")
                base, _, _ = raw.partition(" @")
                return base.strip() or raw
    except OSError as e:
        log.debug("Failed to read CPU info: %s", e)
    return LABEL_NA


def _get_gpu_model() -> str:
    """Query GPU model via lspci."""
    try:
        result = subprocess.run(
            ["lspci", "-mm"],  # Machine-readable format for easier parsing
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                # -mm format: Slot, Class, Vendor, Device, SVendor, SDevice, ...
                if '"VGA compatible controller"' in line or '"3D controller"' in line:
                    parts = line.split('"')
                    if len(parts) >= 8:
                        vendor = parts[5]
                        device = parts[7]
                        return f"{vendor} {device}".strip()
            # Fallback: try standard format
            result = subprocess.run(
                ["lspci"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            if result.returncode == 0:
                for line in result.stdout.splitlines():
                    if "VGA compatible controller" in line or "3D controller" in line:
                        parts = line.split(":", 2)
                        if len(parts) > 2:
                            return parts[2].strip()
    except subprocess.TimeoutExpired:
        log.debug("lspci command timed out")
    except (FileNotFoundError, OSError) as e:
        log.debug("lspci unavailable: %s", e)
    return LABEL_NA


# =============================================================================
# SETTINGS PERSISTENCE (ATOMIC, THREAD-SAFE)
# =============================================================================
def _validate_settings_path(key: str) -> Path | None:
    """Validate a settings key and return its safe filesystem path.

    Security: Uses Path.relative_to() for proper containment checking.
    Returns None and logs a warning if the key is invalid or escapes the sandbox.
    """
    if not key or not isinstance(key, str):
        log.warning("Invalid settings key: %r (must be non-empty string)", key)
        return None

    # Block null bytes (can bypass path checks on some systems)
    if "\0" in key:
        log.warning("Null byte in settings key rejected: %r", key)
        return None

    # Block absolute paths and obvious traversal attempts early
    if key.startswith("/") or key.startswith(".."):
        log.warning("Path traversal attempt blocked: %r", key)
        return None

    try:
        resolved_base = _settings_dir_cache.get()
        # Construct path relative to the RESOLVED base, then resolve the result
        candidate = (resolved_base / key).resolve()

        # Security check: ensure candidate is truly inside resolved_base
        # relative_to() raises ValueError if candidate is not a subpath
        candidate.relative_to(resolved_base)

        return candidate

    except ValueError:
        log.warning("Path traversal attempt blocked: %r", key)
        return None
    except OSError as e:
        log.warning("Failed to validate settings path %r: %s", key, e)
        return None


def save_setting(
    key: str,
    value: bool | int | float | str,
    *,
    as_int: bool = False,
) -> bool:
    """Atomically save a setting value to a file.

    Uses the write-to-temp, fsync, rename, fsync-dir pattern for crash safety.
    Thread-safe. Returns True on success, False on failure.
    """
    target_path = _validate_settings_path(key)
    if target_path is None:
        return False

    # Serialize value
    if as_int and isinstance(value, bool):
        content = "1" if value else "0"
    else:
        content = str(value)

    temp_fd: int | None = None
    temp_path: Path | None = None

    try:
        # Ensure parent directory exists
        target_path.parent.mkdir(parents=True, exist_ok=True)

        # Create temp file in same directory (required for atomic rename)
        temp_fd, temp_path_str = tempfile.mkstemp(
            dir=target_path.parent,
            prefix=f".{target_path.name}.",
            suffix=".tmp",
        )
        temp_path = Path(temp_path_str)

        # Write and sync content
        with os.fdopen(temp_fd, "w", encoding="utf-8") as f:
            temp_fd = None  # Ownership transferred to file object
            f.write(content)
            f.flush()
            os.fsync(f.fileno())

        # Atomic rename (POSIX guarantees atomicity within same filesystem)
        temp_path.rename(target_path)

        # Sync directory to ensure rename is durable
        dir_fd = os.open(target_path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)

        temp_path = None  # Success; nothing to clean up
        return True

    except OSError as e:
        log.warning("Failed to save setting %r: %s", key, e)
        return False

    finally:
        # Clean up on failure
        if temp_fd is not None:
            try:
                os.close(temp_fd)
            except OSError:
                pass
        if temp_path is not None:
            try:
                temp_path.unlink(missing_ok=True)
            except OSError:
                pass


# Type-safe overloads for load_setting
@overload
def load_setting(key: str, default: bool, *, is_inversed: bool = False) -> bool: ...
@overload
def load_setting(key: str, default: int, *, is_inversed: bool = False) -> int: ...
@overload
def load_setting(key: str, default: float, *, is_inversed: bool = False) -> float: ...
@overload
def load_setting(key: str, default: str, *, is_inversed: bool = False) -> str: ...
@overload
def load_setting(
    key: str, default: None = None, *, is_inversed: bool = False
) -> str | None: ...


def load_setting(
    key: str,
    default: bool | int | float | str | None = None,
    *,
    is_inversed: bool = False,
) -> bool | int | float | str | None:
    """Load a setting value from a file.

    Thread-safe. Returns the default value if the file is missing or on error.
    The return type matches the type of the default value.

    Args:
        key: The setting key (relative path under settings directory).
        default: Default value; also determines the expected type.
        is_inversed: For boolean defaults, XOR the result with True.
    """
    target_path = _validate_settings_path(key)
    if target_path is None:
        return default

    try:
        raw_value = target_path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return default
    except OSError as e:
        log.warning("Failed to read setting %r: %s", key, e)
        return default

    try:
        match default:
            case bool():
                return _parse_bool(raw_value, is_inversed)
            case int():
                return int(raw_value)
            case float():
                return float(raw_value)
            case _:
                return raw_value
    except ValueError as e:
        log.warning(
            "Failed to parse setting %r with value %r as %s: %s",
            key,
            raw_value,
            type(default).__name__,
            e,
        )
        return default


def _parse_bool(value: str, is_inversed: bool) -> bool:
    """Parse a string as a boolean value.

    Recognizes integers (0 = False, non-zero = True) and common boolean strings.
    """
    lowered = value.lower().strip()

    # Check common true values
    if lowered in {"true", "yes", "on", "1"}:
        result = True
    elif lowered in {"false", "no", "off", "0", ""}:
        result = False
    else:
        # Attempt integer parse for other numeric values
        try:
            result = int(value) != 0
        except ValueError:
            result = False

    return result ^ is_inversed


# =============================================================================
# UI HELPERS
# =============================================================================
def toast(
    toast_overlay: Adw.ToastOverlay | None,
    message: str,
    timeout: int = 2,
) -> None:
    """Display a toast notification.

    Thread-safe: automatically marshals to the main thread if called from
    a background thread.
    """
    if toast_overlay is None:
        log.debug("toast() called with None overlay; message: %s", message)
        return

    # Lazy import to avoid import order issues
    from gi.repository import Adw as AdwLib
    from gi.repository import GLib

    def _show_toast() -> bool:
        """Display the toast on the main thread. Returns SOURCE_REMOVE."""
        try:
            t = AdwLib.Toast.new(message)
            t.set_timeout(timeout)
            toast_overlay.add_toast(t)
        except GLib.Error as e:
            log.warning("GLib error showing toast: %s", e)
        return GLib.SOURCE_REMOVE

    # GLib.idle_add is thread-safe and queues the callback for main loop
    GLib.idle_add(_show_toast)
