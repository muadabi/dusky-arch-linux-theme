
# 🎛️ Dusky Control Center: The Master Configuration Manual

> [!SUMMARY] Executive Summary
> 
> **Dusky Control Center (DCC)** is the central nervous system for the Dusky Arch ecosystem. It is a GTK4/Libadwaita application acting as a GUI frontend for system scripts, state toggles, and hierarchical configurations.
> 
> **Key Architecture:**
> 
> - **Frontend:** GTK4 + Libadwaita (Python 3.10+).
>     
> - **Backend:** `uwsm-app` compliant command execution (Shell/Bash).
>     
> - **Navigation:** Infinite nested pages via `Adw.NavigationView` (Breadcrumb style).
>     
> - **State Management:** Thread-safe, atomic file locking.
>     

## 1. File Structure & Locations

DCC uses a split-brain storage model. You must understand this distinction to deploy correctly.

### A. The Layout (ReadOnly / Deployable)

The structural definition of the app (the YAML) is **local to the executable**.

- **Location:** Same directory as `dusky_control_center.py`.
    
- **Filename:** `dusky_config.yaml`
    
- **Purpose:** Defines pages, grids, buttons, and logic.
    

### B. The State (ReadWrite / User Specific)

When a user toggles a switch (e.g., "Dark Mode"), the app remembers the state here.

- **Location:** `$XDG_CONFIG_HOME/dusky/settings/` (Default: `~/.config/dusky/settings/`)
    
- **Purpose:** Stores persistent variables (e.g., `wifi_enabled=true`).
    
- **Note:** You generally do not touch this folder manually; the app manages it.
    

## 2. The Mental Model

The Python engine builds the UI dynamically at startup by parsing the YAML.

1. **Sidebar:** The root level. Generated from the `pages` list.
    
2. **Stack:** The content area.
    
3. **Navigation View:** Every page in the sidebar is a self-contained "browser" that can navigate deeper into subpages.
    
4. **Layouts:** The containers (`section` vs `grid_section`).
    
5. **Items:** The widgets (`button`, `toggle`, etc.).
    

> [!TIP] Production Maintenance Keys
> 
> - **`Ctrl + R`**: **Hot Reload**. Instantly re-reads `dusky_config.yaml` and CSS without closing the app. Essential for testing.
>     
> - **`Ctrl + F`**: Focus Search.
>     
> - **`Ctrl + Q`**: Quit.
>     

## 3. The YAML Blueprint

The root of your YAML file must contain a `pages` list.

```
pages:
  - id: home                  # Unique ID (used for internal redirects)
    title: Home               # Sidebar label
    icon: user-home-symbolic  # GNOME icon name
    layout:                   # The content definition
      - ...
```

## 4. Layout Containers

You have two container types. You can mix and match them on a single page.

### A. `grid_section` (The "Control Center" Look)

A flow-box of square cards.

- **Best for:** Quick toggles, frequent actions.
    
- **Limitation:** **Cannot** contain `navigation` (subpage) rows. Only `button` or `toggle_card`.
    

```
- type: grid_section
  properties:
    title: Quick Actions
  items:
    - type: button
      ...
    - type: toggle_card
      ...
```

### B. `section` (The "Settings" Look)

A vertical list of rounded rows with a header.

- **Best for:** Detailed settings, lists, navigation menus.
    
- **Capability:** Supports **all** item types, including `navigation` to subpages.
    

```
- type: section
  properties:
    title: Connectivity
  items:
    - type: toggle
      ...
    - type: navigation
      ...
```

## 5. The Component Library (Forensic Analysis)

### 🔘 Buttons & Cards

Standard clickable items.

- **List Style:** `type: button`
    
- **Grid Style:** `type: button` (inside a `grid_section`)
    

|   |   |   |
|---|---|---|
|**Property**|**Type**|**Description**|
|`title`|String|Main text.|
|`description`|String|Subtitle (List style only).|
|`icon`|String|Icon name.|
|`style`|String|`default`, `suggested` (Blue accent), `destructive` (Red accent).|
|`button_text`|String|Text on the clickable pill (List style only). Default: "Run".|

### 🔛 Toggles

Switches that maintain state.

- **List Style:** `type: toggle`
    
- **Grid Style:** `type: toggle_card`
    

|   |   |
|---|---|
|**Property**|**Description**|
|`key`|Filename to save state to (`~/.config/dusky/settings/<key>`).|
|`key_inverse`|`true` = File "1" means UI "Off".|
|`save_as_int`|`true` = Save "1/0". `false` = Save "true/false".|
|`state_command`|**Priority:** If set, runs this shell command to determine state. Active if output contains "yes", "on", "active", "enabled", "running".|
|`interval`|Seconds between state checks. Default: 2.|

### 🏷️ Labels

Read-only information displays.

|   |   |
|---|---|
|**Value Type**|**Description**|
|`static`|Hardcoded text.|
|`file`|Reads contents of a text file (path in `path`).|
|`exec`|Runs a shell command and shows STDOUT (cmd in `command`).|
|`system`|**Optimized.** Uses internal python logic (0 overhead). Keys: `kernel_version`, `cpu_model`, `gpu_model`, `memory_total`.|

### 🎚️ Sliders

Draggable value setters.

|   |   |
|---|---|
|**Property**|**Description**|
|`min` / `max`|Range boundaries.|
|`step`|Snap increment.|
|`default`|Initial value if not touched yet.|

**Important:** The `on_change` command must include `{value}` which is replaced by the number.

### 📂 Navigation (Subpages)

**Exclusive to `section` layouts.** Creates a row that pushes a new page onto the stack.

|   |   |
|---|---|
|**Property**|**Description**|
|`layout`|**Recursive.** A full list of `section` or `grid_section` definitions, just like a top-level page.|

## 6. Action Logic (`on_press` / `on_toggle`)

Every interactive item requires an action block.

### Type: `exec` (Run Command)

Executes a shell command via `uwsm-app` for Wayland compatibility.

```
on_press:
  type: exec
  command: kitty --hold sh -c "htop"
  terminal: false  # true = launch kitty; false = background spawn
```

### Type: `redirect` (Jump Page)

Switches the **Sidebar** selection to a top-level page.

```
on_press:
  type: redirect
  page: network  # Must match an 'id' in your 'pages' list
```

## 7. Dynamic Features

### 7.1 Recursive Search

The search bar (Ctrl+F) uses a recursive algorithm.

1. It scans the current page.
    
2. If it finds a `navigation` row, it dives inside that row's layout.
    
3. It repeats infinitely.
    
4. **Result:** It presents the "Leaf" item (the button/toggle) directly in the search results, with a breadcrumb trail in the description.
    

### 7.2 Dynamic Icons

Any `icon` property can be script-driven instead of a static string.

```
icon:
  type: exec
  command: scripts/check_vpn_status.sh # Must echo an icon name (e.g. 'network-vpn-symbolic')
  interval: 5
```