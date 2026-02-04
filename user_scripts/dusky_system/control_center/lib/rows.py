"""
Row widget definitions for the Dusky Control Center.
Optimized for stability (Thread Guards) and efficiency.
Refactored to remove __slots__ to fix GObject layout conflicts.
"""
from __future__ import annotations

import logging
import os
import shlex
import subprocess
import threading
from typing import TYPE_CHECKING, Any, Final

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk, Pango

import lib.utility as utility

if TYPE_CHECKING:
    pass

log = logging.getLogger(__name__)

# =============================================================================
# CONSTANTS
# =============================================================================
DEFAULT_ICON: Final[str] = "utilities-terminal-symbolic"
DEFAULT_INTERVAL: Final[int] = 5
MONITOR_INTERVAL: Final[int] = 2
MIN_STEP_VALUE: Final[float] = 1e-9

LABEL_PLACEHOLDER: Final[str] = "..."
LABEL_NA: Final[str] = "N/A"
LABEL_TIMEOUT: Final[str] = "Timeout"
LABEL_ERROR: Final[str] = "Error"
STATE_ON: Final[str] = "On"
STATE_OFF: Final[str] = "Off"

SUBPROCESS_TIMEOUT_SHORT: Final[int] = 2
SUBPROCESS_TIMEOUT_LONG: Final[int] = 5

TRUE_VALUES: Final[frozenset[str]] = frozenset(
    {"enabled", "yes", "true", "1", "on", "active", "set", "running", "open", "high"}
)


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
def _safe_int(value: Any, default: int) -> int:
    """Safely convert a value to int, returning default on failure."""
    if isinstance(value, int):
        return value
    try:
        return int(value)
    except (ValueError, TypeError):
        return default


def _is_dynamic_icon(icon_config: Any) -> bool:
    """Check if an icon config specifies a dynamic (exec) icon."""
    return (
        isinstance(icon_config, dict)
        and icon_config.get("type") == "exec"
        and _safe_int(icon_config.get("interval"), 0) > 0
    )


def _perform_redirect(
    page_id: str,
    config: dict[str, Any],
    sidebar: Gtk.ListBox | None,
    content_title_label: Gtk.Label | None,
) -> None:
    """Navigate to a page by its ID."""
    if not page_id or not sidebar:
        return

    pages = config.get("pages", [])
    for idx, page in enumerate(pages):
        if isinstance(page, dict) and page.get("id") == page_id:
            if row := sidebar.get_row_at_index(idx):
                sidebar.select_row(row)
            # Title update handled by page header now
            return


# =============================================================================
# MIXINS FOR SHARED BEHAVIOR
# =============================================================================
class DynamicIconMixin:
    """Mixin providing thread-safe dynamic icon updates."""
    # NO __slots__ - Conflicts with GObject layout

    def _init_dynamic_icon_state(self) -> None:
        """Initialize mixin state. Must be called after shared state is ready."""
        self.icon_source_id: int | None = None
        self._is_icon_updating: bool = False
        # Ensure lock exists if not created by another mixin/base
        if not hasattr(self, "_destroy_lock"):
            self._destroy_lock = threading.Lock()
        if not hasattr(self, "_is_destroyed"):
            self._is_destroyed = False

    def _start_icon_update_loop(self, icon_config: dict[str, Any]) -> None:
        """Start the periodic icon update loop."""
        interval = _safe_int(icon_config.get("interval"), DEFAULT_INTERVAL)
        cmd = icon_config.get("command", "")
        if interval > 0 and cmd:
            self._do_single_icon_fetch(cmd)
            self.icon_source_id = GLib.timeout_add_seconds(
                interval, self._update_icon_tick, cmd
            )

    def _update_icon_tick(self, command: str) -> bool:
        """Timer callback for icon updates."""
        with self._destroy_lock:
            if self._is_destroyed:
                return GLib.SOURCE_REMOVE
        
        if self._is_icon_updating:
            return GLib.SOURCE_CONTINUE

        self._is_icon_updating = True
        threading.Thread(
            target=self._fetch_icon_async, args=(command,), daemon=True
        ).start()
        return GLib.SOURCE_CONTINUE

    def _do_single_icon_fetch(self, command: str) -> None:
        """Trigger a one-off async icon fetch."""
        with self._destroy_lock:
            if self._is_destroyed:
                return
        
        if self._is_icon_updating:
            return

        self._is_icon_updating = True
        threading.Thread(
            target=self._fetch_icon_async, args=(command,), daemon=True
        ).start()

    def _fetch_icon_async(self, command: str) -> None:
        """Fetch icon name in background thread."""
        try:
            with self._destroy_lock:
                if self._is_destroyed:
                    return
            res = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                text=True,
                timeout=SUBPROCESS_TIMEOUT_SHORT,
            )
            new_icon = res.stdout.strip()
            if new_icon:
                GLib.idle_add(self._apply_icon_update, new_icon)
        except subprocess.TimeoutExpired:
            log.debug("Icon command timed out: %s", command)
        except Exception as e:
            log.warning("Icon fetch failed for '%s': %s", command, e)
        finally:
            self._is_icon_updating = False

    def _apply_icon_update(self, new_icon: str) -> bool:
        """Apply icon update on main thread."""
        with self._destroy_lock:
            if self._is_destroyed:
                return GLib.SOURCE_REMOVE
        if hasattr(self, "icon_widget") and self.icon_widget.get_icon_name() != new_icon:
            self.icon_widget.set_from_icon_name(new_icon)
        return GLib.SOURCE_REMOVE

    def _cleanup_icon_source(self) -> None:
        """Clean up icon update timer."""
        if self.icon_source_id is not None:
            GLib.source_remove(self.icon_source_id)
            self.icon_source_id = None


class StateMonitorMixin:
    """Mixin providing thread-safe state monitoring for toggles."""
    # NO __slots__ - Conflicts with GObject layout

    def _init_monitor_state(self) -> None:
        """Initialize mixin state. Must be called after shared state is ready."""
        self.monitor_source_id: int | None = None
        self._is_monitoring: bool = False
        # Ensure lock exists
        if not hasattr(self, "_destroy_lock"):
            self._destroy_lock = threading.Lock()
        if not hasattr(self, "_is_destroyed"):
            self._is_destroyed = False

    def _start_state_monitor(self) -> None:
        """Start the state monitoring loop if configured."""
        if "key" not in self.properties and "state_command" not in self.properties:
            return

        interval = _safe_int(self.properties.get("interval"), MONITOR_INTERVAL)
        if interval > 0:
            self.monitor_source_id = GLib.timeout_add_seconds(
                interval, self._monitor_state_tick
            )

    def _monitor_state_tick(self) -> bool:
        """Timer callback for state monitoring."""
        with self._destroy_lock:
            if self._is_destroyed:
                return GLib.SOURCE_REMOVE
        
        if self._is_monitoring:
            return GLib.SOURCE_CONTINUE

        self._is_monitoring = True
        threading.Thread(target=self._check_state_async, daemon=True).start()
        return GLib.SOURCE_CONTINUE

    def _check_state_async(self) -> None:
        """Check state in background thread."""
        try:
            with self._destroy_lock:
                if self._is_destroyed:
                    return

            state_cmd = self.properties.get("state_command", "").strip()
            if state_cmd:
                res = subprocess.run(
                    state_cmd,
                    shell=True,
                    capture_output=True,
                    text=True,
                    timeout=SUBPROCESS_TIMEOUT_SHORT,
                )
                is_on = res.stdout.strip().lower() in TRUE_VALUES
                GLib.idle_add(self._apply_state_update, is_on)
                return

            key = self.properties.get("key", "").strip()
            if key:
                file_state = utility.load_setting(key, False, self.key_inverse)
                if isinstance(file_state, bool):
                    GLib.idle_add(self._apply_state_update, file_state)

        except subprocess.TimeoutExpired:
            log.debug("State command timed out.")
        except Exception as e:
            log.warning("State check failed: %s", e)
        finally:
            self._is_monitoring = False

    def _apply_state_update(self, new_state: bool) -> bool:
        """Apply state update on main thread. Override in subclass."""
        raise NotImplementedError

    def _cleanup_monitor_source(self) -> None:
        """Clean up monitor timer."""
        if self.monitor_source_id is not None:
            GLib.source_remove(self.monitor_source_id)
            self.monitor_source_id = None


# =============================================================================
# BASE ROW CLASS
# =============================================================================
class BaseActionRow(DynamicIconMixin, Adw.ActionRow):
    """Base class with automatic cleanup for intervals and thread safety."""
    # NO __slots__

    def __init__(
        self,
        properties: dict[str, Any],
        on_action: dict[str, Any] | None = None,
        context: dict[str, Any] | None = None,
    ) -> None:
        super().__init__()
        self.add_css_class("action-row")

        self.properties = properties
        self.on_action = on_action or {}
        self.context = context or {}

        self.stack: Adw.ViewStack | None = self.context.get("stack")
        # content_title_label removed as it is no longer used
        self.config: dict[str, Any] = self.context.get("config", {})
        self.sidebar: Gtk.ListBox | None = self.context.get("sidebar")
        self.toast_overlay: Adw.ToastOverlay | None = self.context.get("toast_overlay")
        self.nav_view: Adw.NavigationView | None = self.context.get("nav_view")
        self.builder_func = self.context.get("builder_func")

        self.update_source_id: int | None = None
        self._is_destroyed = False
        self._destroy_lock = threading.Lock()

        self._init_dynamic_icon_state()

        title = properties.get("title", "Unnamed")
        subtitle = properties.get("description", "")
        self.set_title(GLib.markup_escape_text(str(title)))
        if subtitle:
            self.set_subtitle(GLib.markup_escape_text(str(subtitle)))

        icon_config = properties.get("icon", DEFAULT_ICON)
        self.icon_widget = self._create_icon_widget(icon_config)
        self.add_prefix(self.icon_widget)

        self.connect("destroy", self._on_destroy)

        if _is_dynamic_icon(icon_config):
            self._start_icon_update_loop(icon_config)

    def _create_icon_widget(self, icon: Any) -> Gtk.Image:
        """Create the appropriate icon widget based on config."""
        icon_name = DEFAULT_ICON
        if isinstance(icon, dict):
            if icon.get("type") == "file":
                path = os.path.expanduser(icon.get("path", "").strip())
                img = Gtk.Image.new_from_file(path)
                img.add_css_class("action-row-prefix-icon")
                return img
            icon_name = icon.get("name", DEFAULT_ICON)
        elif isinstance(icon, str):
            icon_name = icon

        img = Gtk.Image.new_from_icon_name(icon_name)
        img.add_css_class("action-row-prefix-icon")
        return img

    def _on_destroy(self, widget: Gtk.Widget) -> None:
        """Clean up all timers on widget destruction."""
        with self._destroy_lock:
            self._is_destroyed = True

        if self.update_source_id is not None:
            GLib.source_remove(self.update_source_id)
            self.update_source_id = None
        self._cleanup_icon_source()


# =============================================================================
# ROW IMPLEMENTATIONS
# =============================================================================
class ButtonRow(BaseActionRow):
    """A row with an action button."""

    def __init__(
        self,
        properties: dict[str, Any],
        on_press: dict[str, Any] | None = None,
        context: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(properties, on_press, context)

        style = str(properties.get("style", "default")).lower()
        label_text = properties.get("button_text", "Run")

        run_btn = Gtk.Button(label=label_text)
        run_btn.add_css_class("run-btn")
        run_btn.set_valign(Gtk.Align.CENTER)

        style_map = {
            "destructive": "destructive-action",
            "suggested": "suggested-action",
        }
        run_btn.add_css_class(style_map.get(style, "default-action"))
        run_btn.connect("clicked", self._on_button_clicked)

        self.add_suffix(run_btn)
        self.set_activatable_widget(run_btn)

    def _on_button_clicked(self, button: Gtk.Button) -> None:
        """Handle button click."""
        action_type = self.on_action.get("type")

        if action_type == "exec":
            command = self.on_action.get("command", "").strip()
            if not command:
                return
            title = self.properties.get("title", "Command")
            success = utility.execute_command(
                command, title, self.on_action.get("terminal", False)
            )
            msg = f"▶ Launched: {title}" if success else f"✖ Failed: {title}"
            utility.toast(self.toast_overlay, msg, 2 if success else 4)

        elif action_type == "redirect":
            _perform_redirect(
                self.on_action.get("page"),
                self.config,
                self.sidebar,
                None # Content label removed
            )


class ToggleRow(StateMonitorMixin, BaseActionRow):
    """A row with a toggle switch."""

    def __init__(
        self,
        properties: dict[str, Any],
        on_toggle: dict[str, Any] | None = None,
        context: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(properties, on_toggle, context)

        self.save_as_int = properties.get("save_as_int", False)
        self.key_inverse = properties.get("key_inverse", False)
        self._programmatic_update = False

        self._init_monitor_state()

        self.toggle_switch = Gtk.Switch()
        self.toggle_switch.set_valign(Gtk.Align.CENTER)

        key = properties.get("key", "").strip()
        if key:
            system_value = utility.load_setting(key, False, self.key_inverse)
            if isinstance(system_value, bool):
                self.toggle_switch.set_active(system_value)

        self.toggle_switch.connect("state-set", self._on_toggle_changed)
        self.add_suffix(self.toggle_switch)
        self.set_activatable_widget(self.toggle_switch)
        self._start_state_monitor()

    def _apply_state_update(self, new_state: bool) -> bool:
        """Apply monitored state to the switch."""
        with self._destroy_lock:
            if self._is_destroyed:
                return GLib.SOURCE_REMOVE

        if new_state != self.toggle_switch.get_active():
            self._programmatic_update = True
            self.toggle_switch.set_active(new_state)
            self._programmatic_update = False
        return GLib.SOURCE_REMOVE

    def _on_destroy(self, widget: Gtk.Widget) -> None:
        """Clean up resources."""
        super()._on_destroy(widget)
        self._cleanup_monitor_source()

    def _on_toggle_changed(self, switch: Gtk.Switch, state: bool) -> bool:
        """Handle user toggle."""
        if self._programmatic_update:
            return False

        action_key = "enabled" if state else "disabled"
        action = self.on_action.get(action_key, {})
        cmd = action.get("command", "").strip()
        if cmd:
            utility.execute_command(cmd, "Toggle", action.get("terminal", False))

        key = self.properties.get("key", "").strip()
        if key:
            utility.save_setting(key, state ^ self.key_inverse, self.save_as_int)
        return False


class LabelRow(BaseActionRow):
    """A row displaying a dynamic or static value."""

    def __init__(
        self,
        properties: dict[str, Any],
        value: dict[str, Any] | None = None,
        context: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(properties, None, context)

        self.value_config = value or {}
        self._is_val_updating = False

        self.value_label = Gtk.Label(label=LABEL_PLACEHOLDER)
        self.value_label.add_css_class("dim-label")
        self.value_label.set_valign(Gtk.Align.CENTER)
        self.value_label.set_halign(Gtk.Align.END)
        self.value_label.set_hexpand(True)
        self.value_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.add_suffix(self.value_label)

        self._trigger_update()

        interval = _safe_int(properties.get("interval"), 0)
        if interval > 0:
            self.update_source_id = GLib.timeout_add_seconds(
                interval, self._on_timeout
            )

    def _on_timeout(self) -> bool:
        """Timer callback for value updates."""
        with self._destroy_lock:
            if self._is_destroyed:
                return GLib.SOURCE_REMOVE
        self._trigger_update()
        return GLib.SOURCE_CONTINUE

    def _trigger_update(self) -> None:
        """Start async value fetch if not already running."""
        # Check flag to prevent thread pile-up
        if self._is_val_updating:
            return
        self._is_val_updating = True
        threading.Thread(target=self._load_value_async, daemon=True).start()

    def _load_value_async(self) -> None:
        """Load value in background thread."""
        try:
            with self._destroy_lock:
                if self._is_destroyed:
                    return
            result = self._get_value_text(self.value_config)
            GLib.idle_add(self._update_label, result)
        finally:
            self._is_val_updating = False

    def _update_label(self, text: str) -> bool:
        """Update label on main thread."""
        with self._destroy_lock:
            if self._is_destroyed:
                return GLib.SOURCE_REMOVE
        if self.value_label.get_label() != text:
            self.value_label.set_label(text)
            self.value_label.remove_css_class("dim-label")
        return GLib.SOURCE_REMOVE

    def _get_value_text(self, value: Any) -> str:
        """Resolve value configuration to display text."""
        if isinstance(value, str):
            return value
        if not isinstance(value, dict):
            return LABEL_NA

        value_type = value.get("type")

        if value_type == "exec":
            return self._exec_command_value(value.get("command", ""))
        if value_type == "static":
            return value.get("text", LABEL_NA)
        if value_type == "file":
            return self._read_file_value(value.get("path", ""))
        if value_type == "system":
            return utility.get_system_value(value.get("key", "")) or LABEL_NA
        return LABEL_NA

    def _exec_command_value(self, command: str) -> str:
        """Execute command and return output."""
        command = command.strip()
        if not command:
            return LABEL_NA

        if command.startswith("cat "):
            try:
                parts = shlex.split(command)
                if len(parts) == 2:
                    return self._read_file_value(parts[1])
            except ValueError:
                pass

        try:
            res = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                text=True,
                timeout=SUBPROCESS_TIMEOUT_LONG,
            )
            return res.stdout.strip() or LABEL_NA
        except subprocess.TimeoutExpired:
            return LABEL_TIMEOUT
        except Exception as e:
            log.warning("Command execution failed for '%s': %s", command, e)
            return LABEL_ERROR

    def _read_file_value(self, path: str) -> str:
        """Read value from file."""
        if not path:
            return LABEL_NA
        try:
            full_path = os.path.expanduser(path)
            with open(full_path, encoding="utf-8") as f:
                return f.read().strip()
        except OSError as e:
            log.debug("Could not read file '%s': %s", path, e)
            return LABEL_NA


class SliderRow(BaseActionRow):
    """A row with a slider control."""

    def __init__(
        self,
        properties: dict[str, Any],
        on_change: dict[str, Any] | None = None,
        context: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(properties, on_change, context)

        self.min_value = float(properties.get("min", 0))
        self.max_value = float(properties.get("max", 100))
        step_raw = float(properties.get("step", 1))
        # Protect against division by zero
        self.step_value = step_raw if step_raw > MIN_STEP_VALUE else 1.0

        self.slider_changing = False
        self.last_snapped_value: float | None = None

        adjustment = Gtk.Adjustment(
            value=float(properties.get("default", self.min_value)),
            lower=self.min_value,
            upper=self.max_value,
            step_increment=self.step_value,
            page_increment=self.step_value * 10,
            page_size=0,
        )

        self.slider = Gtk.Scale(
            orientation=Gtk.Orientation.HORIZONTAL, adjustment=adjustment
        )
        self.slider.set_valign(Gtk.Align.CENTER)
        self.slider.set_hexpand(True)
        self.slider.set_draw_value(False)
        self.slider.connect("value-changed", self._on_slider_changed)
        self.add_suffix(self.slider)

    def _on_slider_changed(self, slider: Gtk.Scale) -> None:
        """Handle slider value change with snapping."""
        if self.slider_changing:
            return

        val = slider.get_value()
        snapped = round(val / self.step_value) * self.step_value
        snapped = max(self.min_value, min(snapped, self.max_value))

        if (
            self.last_snapped_value is not None
            and abs(snapped - self.last_snapped_value) < 1e-9
        ):
            return

        self.last_snapped_value = snapped

        if abs(snapped - val) > 1e-9:
            self.slider_changing = True
            self.slider.set_value(snapped)
            self.slider_changing = False

        if self.on_action.get("type") == "exec":
            cmd = self.on_action.get("command", "").strip()
            if cmd:
                final_cmd = cmd.replace("{value}", str(int(snapped)))
                utility.execute_command(
                    final_cmd, "Slider", self.on_action.get("terminal", False)
                )

class NavigationRow(BaseActionRow):
    """A row that navigates to a subpage."""

    def __init__(
        self,
        properties: dict[str, Any],
        layout_data: list[dict[str, Any]] | None = None,
        context: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(properties, None, context)
        
        self.layout_data = layout_data or []
        self.add_suffix(Gtk.Image.new_from_icon_name("go-next-symbolic"))
        self.set_activatable(True)
        self.connect("activated", self._on_activated)

    def _on_activated(self, row: Adw.ActionRow) -> None:
        """Handle row activation (click)."""
        if not self.nav_view or not self.builder_func:
            log.warning("NavigationRow: Missing nav_view or builder_func in context.")
            return

        title = str(self.properties.get("title", "Subpage"))
        
        # Build the new subpage using the passed builder function
        subpage = self.builder_func(title, self.layout_data, self.context)
        
        # Push to stack
        self.nav_view.push(subpage)


# =============================================================================
# GRID CARD BASE CLASS
# =============================================================================
class GridCardBase(Gtk.Button):
    """Abstract base class for grid-layout cards with common setup."""

    def __init__(
        self,
        properties: dict[str, Any],
        on_action: dict[str, Any] | None = None,
        context: dict[str, Any] | None = None,
    ) -> None:
        super().__init__()
        self.add_css_class("hero-card")

        self.properties = properties
        self.on_action = on_action or {}
        self.context = context or {}
        self.toast_overlay: Adw.ToastOverlay | None = self.context.get("toast_overlay")

        self._is_destroyed = False
        self._destroy_lock = threading.Lock()
        self.icon_widget: Gtk.Image | None = None

        style = str(properties.get("style", "default")).lower()
        style_map = {"destructive": "destructive-card", "suggested": "suggested-card"}
        if style in style_map:
            self.add_css_class(style_map[style])

        self.connect("destroy", self._on_destroy)

    def _on_destroy(self, widget: Gtk.Widget) -> None:
        """Mark widget as destroyed for thread safety."""
        with self._destroy_lock:
            self._is_destroyed = True

    def _build_card_content(
        self, icon_name: str, title_text: str, show_subtitle: bool = False
    ) -> Gtk.Box:
        """Construct the common card layout."""
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)

        self.icon_widget = Gtk.Image.new_from_icon_name(icon_name)
        self.icon_widget.set_pixel_size(42)
        self.icon_widget.add_css_class("hero-icon")
        box.append(self.icon_widget)

        title = Gtk.Label(label=title_text)
        title.add_css_class("hero-title")
        title.set_wrap(True)
        title.set_justify(Gtk.Justification.CENTER)
        title.set_max_width_chars(16)
        box.append(title)

        return box


# =============================================================================
# GRID CARD IMPLEMENTATIONS
# =============================================================================
class GridCard(DynamicIconMixin, GridCardBase):
    """A grid-layout action card."""

    def __init__(
        self,
        properties: dict[str, Any],
        on_press: dict[str, Any] | None = None,
        context: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(properties, on_press, context)
        self._init_dynamic_icon_state()

        icon_config = properties.get("icon", DEFAULT_ICON)
        icon_name = self._resolve_icon_name(icon_config)

        box = self._build_card_content(icon_name, properties.get("title", "Unnamed"))
        self.set_child(box)

        self.connect("clicked", self._on_clicked)

        if _is_dynamic_icon(icon_config):
            self._start_icon_update_loop(icon_config)

    def _resolve_icon_name(self, icon: Any) -> str:
        """Get initial icon name from config."""
        if isinstance(icon, dict):
            return icon.get("name", DEFAULT_ICON)
        return str(icon) if icon else DEFAULT_ICON

    def _on_destroy(self, widget: Gtk.Widget) -> None:
        """Clean up resources."""
        super()._on_destroy(widget)
        self._cleanup_icon_source()

    def _on_clicked(self, button: Gtk.Button) -> None:
        """Handle card click."""
        action_type = self.on_action.get("type")

        if action_type == "exec":
            cmd = self.on_action.get("command", "").strip()
            if cmd:
                success = utility.execute_command(
                    cmd, "Command", self.on_action.get("terminal", False)
                )
                utility.toast(
                    self.toast_overlay, "▶ Launched" if success else "✖ Failed"
                )

        elif action_type == "redirect":
            _perform_redirect(
                self.on_action.get("page"),
                self.context.get("config", {}),
                self.context.get("sidebar"),
                None # Content label removed
            )


class GridToggleCard(StateMonitorMixin, GridCardBase):
    """A grid-layout toggle card."""

    def __init__(
        self,
        properties: dict[str, Any],
        on_toggle: dict[str, Any] | None = None,
        context: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(properties, on_toggle, context)
        self._init_monitor_state()

        self.save_as_int = properties.get("save_as_int", False)
        self.key_inverse = properties.get("key_inverse", False)
        self.is_active = False

        icon_name = properties.get("icon", DEFAULT_ICON)
        box = self._build_card_content(icon_name, properties.get("title", "Toggle"))

        self.status_label = Gtk.Label(label=STATE_OFF)
        self.status_label.add_css_class("hero-subtitle")
        box.append(self.status_label)

        self.set_child(box)

        key = properties.get("key", "").strip()
        if key:
            system_value = utility.load_setting(key, False, self.key_inverse)
            if isinstance(system_value, bool):
                self._set_visual_state(system_value)

        self.connect("clicked", self._on_clicked)
        self._start_state_monitor()

    def _apply_state_update(self, new_state: bool) -> bool:
        """Apply monitored state to the card."""
        with self._destroy_lock:
            if self._is_destroyed:
                return GLib.SOURCE_REMOVE
        if new_state != self.is_active:
            self._set_visual_state(new_state)
        return GLib.SOURCE_REMOVE

    def _on_destroy(self, widget: Gtk.Widget) -> None:
        """Clean up resources."""
        super()._on_destroy(widget)
        self._cleanup_monitor_source()

    def _set_visual_state(self, state: bool) -> None:
        """Update visual appearance based on state."""
        self.is_active = state
        self.status_label.set_label(STATE_ON if state else STATE_OFF)
        if state:
            self.add_css_class("toggle-active")
        else:
            self.remove_css_class("toggle-active")

    def _on_clicked(self, button: Gtk.Button) -> None:
        """Handle card click to toggle state."""
        new_state = not self.is_active
        self._set_visual_state(new_state)

        action_key = "enabled" if new_state else "disabled"
        action = self.on_action.get(action_key, {})
        cmd = action.get("command", "").strip()
        if cmd:
            utility.execute_command(cmd, "Toggle", action.get("terminal", False))

        key = self.properties.get("key", "").strip()
        if key:
            utility.save_setting(key, new_state ^ self.key_inverse, self.save_as_int)
