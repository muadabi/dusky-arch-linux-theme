#!/usr/bin/env python3
"""
Dusky Control Center (Production Build)
A GTK4/Libadwaita configuration launcher for the Dusky Dotfiles.
Fully UWSM-compliant for Arch Linux/Hyprland environments.
"""
from __future__ import annotations

import logging
import os
import sys
from copy import deepcopy
from pathlib import Path
from typing import TYPE_CHECKING, Any, Final, Iterator

# =============================================================================
# VERSION CHECK
# =============================================================================
if sys.version_info < (3, 10):
    sys.exit("[FATAL] Python 3.10+ is required for this application.")

# =============================================================================
# LOGGING CONFIGURATION
# =============================================================================
logging.basicConfig(
    level=logging.INFO,
    format="[%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger(__name__)

# =============================================================================
# CACHE CONFIGURATION
# =============================================================================
def _setup_cache() -> None:
    """Configure pycache directory following XDG spec."""
    try:
        xdg_cache_env = os.environ.get("XDG_CACHE_HOME", "").strip()
        if xdg_cache_env:
            xdg_cache = Path(xdg_cache_env)
        else:
            xdg_cache = Path.home() / ".cache"

        cache_dir = xdg_cache / "duskycc"
        cache_dir.mkdir(parents=True, exist_ok=True)
        sys.pycache_prefix = str(cache_dir)
    except OSError as e:
        log.warning("Could not set custom pycache location: %s", e)

_setup_cache()

# =============================================================================
# IMPORTS & PRE-FLIGHT
# =============================================================================
import lib.utility as utility

utility.preflight_check()

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango

import lib.rows as rows

if TYPE_CHECKING:
    from collections.abc import Callable

# =============================================================================
# CONSTANTS
# =============================================================================
APP_ID: Final[str] = "com.github.dusky.controlcenter"
APP_TITLE: Final[str] = "Dusky Control Center"
CONFIG_FILENAME: Final[str] = "dusky_config.yaml"
CSS_FILENAME: Final[str] = "dusky_style.css"
SCRIPT_DIR: Final[Path] = Path(__file__).resolve().parent

PAGE_PREFIX: Final[str] = "page-"
SEARCH_PAGE_ID: Final[str] = "search-results"
EMPTY_STATE_ID: Final[str] = "empty-state"
DEFAULT_TITLE: Final[str] = "Settings"

SEARCH_DEBOUNCE_MS: Final[int] = 200
DEFAULT_TOAST_TIMEOUT: Final[int] = 2


class DuskyControlCenter(Adw.Application):
    """Main application class."""

    __slots__ = (
        "config",
        "sidebar_list",
        "stack",
        "toast_overlay",
        "search_bar",
        "search_entry",
        "search_btn",
        "search_page",
        "search_results_group",
        "last_visible_page",
        "search_debounce_source",
        "_css_content",
    )

    def __init__(self) -> None:
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.config: dict[str, Any] = {}
        self.sidebar_list: Gtk.ListBox | None = None
        self.stack: Adw.ViewStack | None = None
        self.toast_overlay: Adw.ToastOverlay | None = None
        self.search_bar: Gtk.SearchBar | None = None
        self.search_entry: Gtk.SearchEntry | None = None
        self.search_btn: Gtk.ToggleButton | None = None
        self.search_page: Adw.NavigationPage | None = None
        self.search_results_group: Adw.PreferencesGroup | None = None
        self.last_visible_page: str | None = None
        self.search_debounce_source: int | None = None
        self._css_content: str | None = None

    # ─────────────────────────────────────────────────────────────────────────
    # LIFECYCLE HOOKS
    # ─────────────────────────────────────────────────────────────────────────
    def do_activate(self) -> None:
        """GTK Application activation hook."""
        self._load_css()
        self.config = utility.load_config(SCRIPT_DIR / CONFIG_FILENAME)
        self._validate_config()
        self._apply_css()
        self._build_ui()

    def do_shutdown(self) -> None:
        """GTK Application shutdown hook."""
        self._cancel_debounce()
        Adw.Application.do_shutdown(self)

    def _cancel_debounce(self) -> None:
        """Safely cancel any pending debounce timer."""
        if self.search_debounce_source is not None:
            try:
                GLib.source_remove(self.search_debounce_source)
            except GLib.Error:
                pass
            finally:
                self.search_debounce_source = None

    # ─────────────────────────────────────────────────────────────────────────
    # CONFIGURATION
    # ─────────────────────────────────────────────────────────────────────────
    def _validate_config(self) -> None:
        """Ensure critical config keys exist."""
        if not isinstance(self.config, dict):
            self.config = {}
        if not isinstance(self.config.get("pages"), list):
            self.config["pages"] = []

    def _load_css(self, force_reload: bool = False) -> None:
        """Load CSS from file safely, caching the result unless forced."""
        if self._css_content is not None and not force_reload:
            return

        css_path = SCRIPT_DIR / CSS_FILENAME
        try:
            self._css_content = css_path.read_text(encoding="utf-8")
        except OSError:
            log.warning("CSS file not found or unreadable: %s", css_path)
            self._css_content = ""

    def _apply_css(self) -> None:
        """Load and apply the custom CSS stylesheet."""
        if not self._css_content:
            return

        provider = Gtk.CssProvider()
        provider.load_from_string(self._css_content)

        display = Gdk.Display.get_default()
        if display:
            Gtk.StyleContext.add_provider_for_display(
                display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

    def _get_context(
        self,
        nav_view: Adw.NavigationView | None = None,
        builder_func: Callable | None = None,
    ) -> dict[str, Any]:
        """Build the shared context dictionary for row widgets."""
        return {
            "stack": self.stack,
            "config": self.config,
            "sidebar": self.sidebar_list,
            "toast_overlay": self.toast_overlay,
            "nav_view": nav_view,
            "builder_func": builder_func,
        }

    # ─────────────────────────────────────────────────────────────────────────
    # MAIN UI CONSTRUCTION
    # ─────────────────────────────────────────────────────────────────────────
    def _build_ui(self) -> None:
        """Construct the main application window and layout."""
        window = Adw.Window(application=self, title=APP_TITLE)
        window.set_default_size(1180, 780)

        key_controller = Gtk.EventControllerKey()
        key_controller.connect("key-pressed", self._on_key_pressed)
        window.add_controller(key_controller)

        self.toast_overlay = Adw.ToastOverlay()

        split = Adw.OverlaySplitView()
        split.set_min_sidebar_width(220)
        split.set_max_sidebar_width(260)
        split.set_sidebar_width_fraction(0.25)
        split.set_sidebar(self._create_sidebar())
        split.set_content(self._create_content_panel())

        self.toast_overlay.set_child(split)
        window.set_content(self.toast_overlay)

        self._create_search_page()
        self._populate_pages()
        window.present()

    def _on_key_pressed(
        self,
        controller: Gtk.EventControllerKey,
        keyval: int,
        keycode: int,
        state: Gdk.ModifierType,
    ) -> bool:
        """Handle global keyboard shortcuts."""
        ctrl_held = bool(state & Gdk.ModifierType.CONTROL_MASK)

        if ctrl_held:
            if keyval == Gdk.KEY_r:
                self._reload_app()
                return True
            if keyval == Gdk.KEY_f:
                self._activate_search()
                return True
            if keyval == Gdk.KEY_q:
                self.quit()
                return True

        if keyval == Gdk.KEY_Escape:
            if self.search_bar and self.search_bar.get_search_mode():
                self._deactivate_search()
                return True

        return False

    def _activate_search(self) -> None:
        """Focus and activate the search bar."""
        if self.search_bar and self.search_entry and self.search_btn:
            self.search_bar.set_search_mode(True)
            self.search_btn.set_active(True)
            self.search_entry.grab_focus()

    def _deactivate_search(self) -> None:
        """Deactivate search bar and sync toggle button state."""
        if self.search_bar:
            self.search_bar.set_search_mode(False)
        if self.search_btn:
            self.search_btn.set_active(False)
        self._exit_search_mode()

    def _reload_app(self) -> None:
        """Hot Reload: Refresh config and rebuild UI with rollback on failure."""
        log.info("Hot Reload Initiated...")

        old_config = self.config
        try:
            new_config = utility.load_config(SCRIPT_DIR / CONFIG_FILENAME)
            if not isinstance(new_config, dict):
                raise ValueError("Configuration must be a dictionary")
            
            self._load_css(force_reload=True)
            self._apply_css()

            self.config = new_config
            self._validate_config()
            self._clear_ui()
            self._create_search_page()
            self._populate_pages()
            self._toast("Configuration Reloaded 🚀")

        except Exception as e:
            log.error("Hot reload failed: %s", e)
            self.config = old_config
            self._toast("Reload Failed: Check logs", 3)

    def _clear_ui(self) -> None:
        """Remove all dynamic UI elements for reload."""
        if self.sidebar_list:
            while (row := self.sidebar_list.get_row_at_index(0)) is not None:
                self.sidebar_list.remove(row)

        if self.stack:
            while (child := self.stack.get_first_child()) is not None:
                self.stack.remove(child)

    # ─────────────────────────────────────────────────────────────────────────
    # SEARCH LOGIC
    # ─────────────────────────────────────────────────────────────────────────
    def _create_search_page(self) -> None:
        """Create the search results page."""
        self.search_page = Adw.NavigationPage(title="Search", tag="search")
        
        toolbar_view = Adw.ToolbarView()
        header = Adw.HeaderBar()
        toolbar_view.add_top_bar(header)
        
        pref_page = Adw.PreferencesPage()
        self.search_results_group = Adw.PreferencesGroup(title="Search Results")
        pref_page.add(self.search_results_group)
        
        toolbar_view.set_content(pref_page)
        self.search_page.set_child(toolbar_view)

        if self.stack:
            self.stack.add_named(self.search_page, SEARCH_PAGE_ID)

    def _on_search_btn_toggled(self, button: Gtk.ToggleButton) -> None:
        """Handle search button toggle."""
        if button.get_active():
            self._activate_search()
        else:
            self._deactivate_search()

    def _exit_search_mode(self) -> None:
        """Return to the previously visible page."""
        if self.search_entry:
            self.search_entry.set_text("")

        if self.last_visible_page and self.stack:
            self.stack.set_visible_child_name(self.last_visible_page)

    def _on_search_changed(self, entry: Gtk.SearchEntry) -> None:
        """Debounced handler for search input changes."""
        self._cancel_debounce()
        self.search_debounce_source = GLib.timeout_add(
            SEARCH_DEBOUNCE_MS, self._execute_search, entry.get_text()
        )

    def _execute_search(self, query_text: str) -> bool:
        """Execute the search after debounce delay."""
        self.search_debounce_source = None

        if not self.stack or not self.search_page or not self.search_results_group:
            return GLib.SOURCE_REMOVE

        query = query_text.strip().lower()
        if not query:
            self._reset_search_results("Search Results")
            return GLib.SOURCE_REMOVE

        current = self.stack.get_visible_child_name()
        if current and current != SEARCH_PAGE_ID:
            self.last_visible_page = current

        self.stack.set_visible_child_name(SEARCH_PAGE_ID)
        self._reset_search_results(f"Results for '{query}'")
        self._populate_search_results(query)
        return GLib.SOURCE_REMOVE

    def _reset_search_results(self, title: str) -> None:
        """Clear and recreate the search results group."""
        if self.search_page and self.search_results_group:
            toolbar = self.search_page.get_child()
            if isinstance(toolbar, Adw.ToolbarView):
                pref_page = toolbar.get_content()
                if isinstance(pref_page, Adw.PreferencesPage):
                    pref_page.remove(self.search_results_group)
                    self.search_results_group = Adw.PreferencesGroup(title=title)
                    pref_page.add(self.search_results_group)

    def _populate_search_results(self, query: str) -> None:
        """Search all items and populate results."""
        if not self.search_results_group:
            return

        found_count = 0
        for match in self._iter_matching_items(query):
            self.search_results_group.add(self._build_item_row(match, self._get_context()))
            found_count += 1

        if found_count == 0:
            no_results = Adw.ActionRow(title="No results found")
            no_results.set_activatable(False)
            self.search_results_group.add(no_results)

    def _iter_matching_items(self, query: str) -> Iterator[dict[str, Any]]:
        """Yield deep-copied items matching the search query with page context."""
        for page in self.config.get("pages", []):
            if not isinstance(page, dict):
                continue

            page_title = str(page.get("title", "Unknown"))
            yield from self._recursive_search(page.get("layout", []), query, page_title)

    def _recursive_search(
        self, layout_data: list[dict[str, Any]], query: str, context_str: str
    ) -> Iterator[dict[str, Any]]:
        """Recursively search layout and nested layouts for matching items."""
        for section in layout_data:
            if not isinstance(section, dict):
                continue

            for item in section.get("items", []):
                if not isinstance(item, dict):
                    continue

                props = item.get("properties", {})
                if not isinstance(props, dict):
                    continue

                item_type = item.get("type")
                title = str(props.get("title", ""))
                desc = str(props.get("description", ""))

                # Check if current item matches
                # We exclude 'navigation' rows from results because clicking them
                # in a search list (without the nav stack) is broken/confusing.
                # We only want to find the leaf nodes (actions/toggles).
                if item_type != "navigation":
                    if query in title.lower() or query in desc.lower():
                        result = deepcopy(item)
                        result["properties"]["description"] = (
                            f"{context_str} • {desc}" if desc else context_str
                        )
                        yield result

                # Recursive dive: if item has a layout (e.g. navigation row), scan it
                if "layout" in item:
                    sub_title = str(props.get("title", ""))
                    new_context = f"{context_str} > {sub_title}"
                    yield from self._recursive_search(
                        item.get("layout", []), query, new_context
                    )

    # ─────────────────────────────────────────────────────────────────────────
    # SIDEBAR CONSTRUCTION
    # ─────────────────────────────────────────────────────────────────────────
    def _create_sidebar(self) -> Adw.ToolbarView:
        """Build the sidebar navigation panel."""
        view = Adw.ToolbarView()
        view.add_css_class("sidebar-container")

        header = Adw.HeaderBar()
        header.add_css_class("sidebar-header")
        header.set_show_end_title_buttons(False)

        title_box = Gtk.Box(spacing=8)
        icon = Gtk.Image.new_from_icon_name("emblem-system-symbolic")
        icon.add_css_class("sidebar-header-icon")
        label = Gtk.Label(label="Dusky")
        label.add_css_class("title")
        title_box.append(icon)
        title_box.append(label)
        header.set_title_widget(title_box)

        self.search_btn = Gtk.ToggleButton(icon_name="system-search-symbolic")
        self.search_btn.set_tooltip_text("Search Settings (Ctrl+F)")
        self.search_btn.connect("toggled", self._on_search_btn_toggled)
        header.pack_end(self.search_btn)
        view.add_top_bar(header)

        self.search_bar = Gtk.SearchBar()
        self.search_entry = Gtk.SearchEntry(placeholder_text="Find setting...")
        self.search_entry.connect("search-changed", self._on_search_changed)
        self.search_bar.set_child(self.search_entry)
        self.search_bar.connect_entry(self.search_entry)
        view.add_top_bar(self.search_bar)

        self.sidebar_list = Gtk.ListBox()
        self.sidebar_list.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.sidebar_list.add_css_class("sidebar-listbox")
        self.sidebar_list.connect("row-selected", self._on_row_selected)

        scroll = Gtk.ScrolledWindow(vexpand=True)
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_child(self.sidebar_list)
        view.set_content(scroll)

        return view

    def _make_sidebar_row(self, name: str, icon_name: str) -> Gtk.ListBoxRow:
        """Create a sidebar navigation row."""
        row = Gtk.ListBoxRow()
        row.add_css_class("sidebar-row")

        box = Gtk.Box()
        icon = Gtk.Image.new_from_icon_name(icon_name)
        icon.add_css_class("sidebar-row-icon")
        label = Gtk.Label(label=name, xalign=0, hexpand=True)
        label.add_css_class("sidebar-row-label")
        label.set_ellipsize(Pango.EllipsizeMode.END)
        box.append(icon)
        box.append(label)
        row.set_child(box)

        return row

    def _on_row_selected(
        self, listbox: Gtk.ListBox, row: Gtk.ListBoxRow | None
    ) -> None:
        """Handle sidebar row selection."""
        if row is None or self.stack is None:
            return

        index = row.get_index()
        pages = self.config.get("pages", [])

        if 0 <= index < len(pages):
            self.stack.set_visible_child_name(f"{PAGE_PREFIX}{index}")

    def _create_content_panel(self) -> Adw.ViewStack:
        """Build the main content panel (Stack Only)."""
        self.stack = Adw.ViewStack(vexpand=True, hexpand=True)
        return self.stack

    # ─────────────────────────────────────────────────────────────────────────
    # PAGE POPULATION
    # ─────────────────────────────────────────────────────────────────────────
    def _populate_pages(self) -> None:
        """Build and add all pages from config."""
        pages = self.config.get("pages", [])

        if not pages:
            self._show_empty_state()
            return

        first_valid_row: Gtk.ListBoxRow | None = None

        for idx, page_data in enumerate(pages):
            if not isinstance(page_data, dict):
                log.warning("Skipping invalid page at index %d", idx)
                continue

            title = str(page_data.get("title", "Untitled"))
            icon = str(page_data.get("icon", "application-x-executable-symbolic"))

            row = self._make_sidebar_row(title, icon)
            if self.sidebar_list:
                self.sidebar_list.append(row)

            nav_view = Adw.NavigationView()
            context = self._get_context(
                nav_view=nav_view,
                builder_func=self._build_nav_page
            )

            root_page = self._build_nav_page(title, page_data.get("layout", []), context)
            nav_view.add(root_page)

            if self.stack:
                self.stack.add_named(nav_view, f"{PAGE_PREFIX}{idx}")

            if first_valid_row is None:
                first_valid_row = row

        if first_valid_row and self.sidebar_list:
            self.sidebar_list.select_row(first_valid_row)

    def _build_nav_page(
        self, 
        title: str, 
        layout_data: list[dict[str, Any]], 
        context: dict[str, Any]
    ) -> Adw.NavigationPage:
        """Build a NavigationPage containing a ToolbarView(Header+PreferencesPage)."""
        nav_page = Adw.NavigationPage(title=title, tag=title.lower().replace(" ", "-"))
        
        toolbar_view = Adw.ToolbarView()
        header = Adw.HeaderBar()
        toolbar_view.add_top_bar(header)
        
        pref_page = Adw.PreferencesPage()
        self._populate_pref_page_content(pref_page, layout_data, context)
        
        toolbar_view.set_content(pref_page)
        nav_page.set_child(toolbar_view)
        
        return nav_page

    def _populate_pref_page_content(
        self, 
        page: Adw.PreferencesPage, 
        layout_data: list[dict[str, Any]], 
        context: dict[str, Any]
    ) -> None:
        """Fill a PreferencesPage with groups based on layout data."""
        for section_data in layout_data:
            if not isinstance(section_data, dict):
                continue

            section_type = section_data.get("type")

            if section_type == "grid_section":
                page.add(self._build_grid_section(section_data, context))
            elif section_type == "section" or "items" in section_data:
                page.add(self._build_standard_section(section_data, context))
            else:
                group = Adw.PreferencesGroup()
                group.add(self._build_item_row(section_data, context))
                page.add(group)

    def _build_grid_section(
        self, section_data: dict[str, Any], context: dict[str, Any]
    ) -> Adw.PreferencesGroup:
        """Build a grid-layout section."""
        group = Adw.PreferencesGroup()

        props = section_data.get("properties", {})
        title = str(props.get("title", "")) if isinstance(props, dict) else ""
        if title:
            group.set_title(GLib.markup_escape_text(title))

        flowbox = Gtk.FlowBox()
        flowbox.set_valign(Gtk.Align.START)
        flowbox.set_selection_mode(Gtk.SelectionMode.NONE)
        flowbox.set_column_spacing(12)
        flowbox.set_row_spacing(12)

        for item in section_data.get("items", []):
            if not isinstance(item, dict):
                continue

            props = item.get("properties", {})
            item_type = item.get("type")

            if item_type == "toggle_card":
                card = rows.GridToggleCard(props, item.get("on_toggle"), context)
            else:
                card = rows.GridCard(props, item.get("on_press"), context)

            flowbox.append(card)

        group.add(flowbox)
        return group

    def _build_standard_section(
        self, section_data: dict[str, Any], context: dict[str, Any]
    ) -> Adw.PreferencesGroup:
        """Build a standard list section."""
        group = Adw.PreferencesGroup()
        props = section_data.get("properties", {})

        if isinstance(props, dict):
            title = str(props.get("title", ""))
            if title:
                group.set_title(GLib.markup_escape_text(title))

            desc = str(props.get("description", ""))
            if desc:
                group.set_description(GLib.markup_escape_text(desc))

        for item in section_data.get("items", []):
            if isinstance(item, dict):
                group.add(self._build_item_row(item, context))

        return group

    def _build_item_row(
        self, item: dict[str, Any], context: dict[str, Any] | None = None
    ) -> Adw.PreferencesRow:
        """Build a single row widget from an item definition."""
        if context is None:
            context = self._get_context()

        item_type = item.get("type")
        properties = item.get("properties", {})

        row_builders: dict[str, Callable[[], Adw.PreferencesRow]] = {
            "button": lambda: rows.ButtonRow(properties, item.get("on_press"), context),
            "toggle": lambda: rows.ToggleRow(properties, item.get("on_toggle"), context),
            "label": lambda: rows.LabelRow(properties, item.get("value"), context),
            "slider": lambda: rows.SliderRow(properties, item.get("on_change"), context),
            "navigation": lambda: rows.NavigationRow(properties, item.get("layout"), context),
            "warning_banner": lambda: self._build_warning_banner(properties),
        }

        builder = row_builders.get(item_type)
        if builder:
            return builder()

        log.warning("Unknown item type '%s', defaulting to ButtonRow", item_type)
        return rows.ButtonRow(properties, item.get("on_press"), context)

    def _build_warning_banner(self, properties: dict[str, Any]) -> Adw.PreferencesRow:
        """Build a warning banner row."""
        row = Adw.PreferencesRow()
        row.add_css_class("action-row")

        banner_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        banner_box.add_css_class("warning-banner-box")

        icon = Gtk.Image.new_from_icon_name("dialog-warning-symbolic")
        icon.set_halign(Gtk.Align.CENTER)
        icon.set_margin_bottom(8)
        icon.add_css_class("warning-banner-icon")

        title_text = GLib.markup_escape_text(str(properties.get("title", "Warning")))
        title = Gtk.Label(label=title_text)
        title.add_css_class("title-1")
        title.set_halign(Gtk.Align.CENTER)

        message_text = GLib.markup_escape_text(str(properties.get("message", "")))
        message = Gtk.Label(label=message_text)
        message.add_css_class("body")
        message.set_halign(Gtk.Align.CENTER)
        message.set_wrap(True)

        banner_box.append(icon)
        banner_box.append(title)
        banner_box.append(message)
        row.set_child(banner_box)

        return row

    def _show_empty_state(self) -> None:
        """Display empty state when no config is found."""
        box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=8,
            halign=Gtk.Align.CENTER,
            valign=Gtk.Align.CENTER,
        )
        box.add_css_class("empty-state-box")

        icon = Gtk.Image.new_from_icon_name("document-open-symbolic")
        icon.add_css_class("empty-state-icon")

        title = Gtk.Label(label="No Configuration Found")
        title.add_css_class("empty-state-title")

        subtitle = Gtk.Label(
            label="Create a config file to define your control center layout."
        )
        subtitle.add_css_class("empty-state-subtitle")

        box.append(icon)
        box.append(title)
        box.append(subtitle)

        if self.stack:
            self.stack.add_named(box, EMPTY_STATE_ID)

    def _toast(self, message: str, timeout: int = DEFAULT_TOAST_TIMEOUT) -> None:
        """Show a toast notification."""
        if self.toast_overlay:
            self.toast_overlay.add_toast(Adw.Toast(title=message, timeout=timeout))


if __name__ == "__main__":
    app = DuskyControlCenter()
    sys.exit(app.run(sys.argv))
