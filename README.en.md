# ExposeCheck

[中文](README.md) | **English**

> Draw a GDScript class's public interface as a graph — open a class and see at a glance
> what it offers to the outside world.

ExposeCheck is a Godot editor plugin. It analyzes your scripts, turns each class into a node
on a graph, lists the members that are **actually exposed**, and draws the relationships
between classes, inner classes and their parents as connections.

What gets exposed is decided **entirely by explicit markers** (`#expose` / `#region expose`).
There is no "everything is exposed by default" rule to guess at.

---

## Features

- **Interface visualization** — one GraphNode per class, listing exposed signals / variables /
  functions / constants / enums with their parameters, return types and `##` docs
- **Automatic ancestor chain** — drop in a class and its user-defined parents stack up to the
  left, wired together, all the way down to a native base class
- **Inner classes are classes too** — an exposed inner class gets its own node
  (titled `Outer:Inner`) and can nest further
- **Blueprint export / import** — the whole graph (port definitions, member signatures, links)
  goes into a single JSON file you can version-control and share
- **Dirty tracking** — change a script on disk and its node turns red; hit refresh to re-analyze.
  It **never rebuilds on its own**
- **Session autosave** — the graph is saved when you close the editor and restored on next launch
- **Port types** — ports are grouped by type and only connect to the same type; type 0 is
  reserved for inheritance edges
- **Command-line tool** — a headless CLI for batch-inspecting, adding/removing markers, and
  applying a blueprint to scripts
- **AI Skill** — see [`SKILL.md`](SKILL.md) to let an AI assistant operate these markers for you

## Requirements

**Godot 4.7 or newer.**

The plugin uses `EditorDock` / `EditorPlugin.add_dock()`, introduced in 4.7
(the older `add_control_to_dock()` is deprecated as of 4.7). It will not load on 4.6 or earlier.

## Installation

**From the Asset Library**: search for "ExposeCheck" under the editor's `AssetLib` tab, install,
then enable it in `Project → Project Settings → Plugins`.

**Manually**: copy the whole `addons/expose_check/` directory into your project, then tick
**ExposeCheck** in `Project → Project Settings → Plugins`.

Once enabled, an **ExposeCheck** dock appears at the bottom of the editor.

## Quick start

1. **Right-click on the graph → New Node** and pick a `.gd` script
2. The node appears and its user-defined parents stack up to the left
3. Hover a member row: **left-click** shows its `##` docs, **right-click** assigns a port definition
4. **Right-drag** between ports to wire them up (only same-type ports connect)
5. Hit **Export** at the top to save a blueprint JSON

## Exposing things

ExposeCheck **only looks at markers**. To make a member visible to the outside, put a marker
line above it:

```gdscript
#expose
func take_damage(amount: int) -> bool:
	return true

## This line is documentation; it shows up on the node
#expose
var hp: int = 100
```

### Marker reference

| Marker | Effect |
|---|---|
| `#expose` | Applies to the **one** declaration right below it (blank lines, comments and annotations may sit in between) |
| `#unexpose` | Same, but marks that one declaration as **not** exposed |
| `#region expose` | Applies to the **whole region** up to the matching `#endregion` |
| `#region unexpose` | Same, but that whole stretch is **not** exposed |
| `#endregion` | Closes the most recently opened region (stack-based, like `if`/`else`) |

### Precedence

1. **A single-line marker beats a region** — writing `#unexpose` inside `#region expose`
   keeps that member hidden
2. **Inner regions win when nested** — a `#region unexpose` inside a `#region expose` hides its
   members; the inner `#endregion` returns to the outer state automatically

Markers are **case-insensitive** (`#EXPOSE` / `#Expose` both work). But `#exposed` and
`#expose_region` are **not** markers (anything trailing disqualifies them), and neither is
`# region` (a space after the `#`).

### Doc comments

A `##` comment above the declaration — or above the marker — becomes that member's documentation
and shows up on the node. Left-click a member row to read the whole thing.

## Port types

Every member row has a port on each side, and ports have a **type**.
**Only ports of the same type can connect.**

| Port type | Meaning |
|---|---|
| `0` | **Parent-class only.** Used by the node's FatherSolt row; member rows may not use it |
| `1` | **The default at creation time.** It is its own type and **does not correspond to any row in the Settings panel** |
| `t` (≥ 2) | Row `t - 1` of the Settings panel (the row labelled `t-1:` in the UI) |

Add port definitions (left/right meaning + color) in the Settings panel, then right-click a
member row to pick one — that row's port color and type follow. When changing a type invalidates
existing connections, the plugin **disconnects them automatically** and tells you.

## Blueprint (export / import)

A blueprint is a JSON file describing the whole graph:

```json
{
	"format_version": 3,
	"generator": "expose_check",
	"port_definitions": [ {"left": "damage", "right": "source", "color": "#ff8800ff"} ],
	"nodes": [ {
		"key": "res://Core/Entity/Player.gd",
		"script_path": "res://Core/Entity/Player.gd",
		"inner_name": "", "class_name": "Player", "title": "Player",
		"script_md5": "…", "position": [0, 0], "size": [220, 300],
		"port_types": { "func\ttake_damage": 2 },
		"members": [ {"kind": "func", "name": "take_damage", "hint": "Takes damage",
									"params": ["amount: int"], "ret_type": "bool", "prefix": ""} ]
	} ],
	"links": [ { "from": {…}, "to": {…}, "semantic": "user" } ],
	"view": { "zoom": 1.0, "scroll": [0, 0] }
}
```

Design notes:

- **Link endpoints are semantic** — port indices shift whenever members are added or removed, so
  an endpoint records "which member of which node, left or right" instead of a port number
- **`kind` is an ASCII id** (`func` / `var` / `signal` / `const` / `enum` / `ab_func` /
  `static_func`), not a localized display name — a blueprint is an interchange format and must not
  carry translated text. The single source of truth for the kind table is
  `ExposeCheck_ScriptInfo.KIND_TABLE` in `ui/script_info.gd`
- **Older versions migrate automatically** — v1 → v2 fills in empty port definitions and member
  lists; v2 → v3 converts `kind` and the `port_types` keys to ASCII ids (both emit a warning)
- A version of `0`, newer than the current one, or one with no migration path is **rejected
  outright** (better an error than parsing garbage with the wrong format)

**Export** stores every node on the graph; **Save Selected** stores only the selection (plus any
link whose both ends are in the set). **Import** always asks you: rebuild from scratch, or merge
into the current graph.

## Refresh and dirty tracking

- The plugin **never rebuilds nodes on its own**
- Once you modify and **save** a script, the state lamp on the right of its node turns **red**
- Press the node's **Refresh** button, or **Refresh All Nodes** at the top, to re-analyze
- Refreshing **preserves** the port definitions you picked and the connections you drew
  (they are re-attached by member identity; links whose member is gone are dropped with a warning)

## Session autosave

When you close the editor the plugin writes the whole graph and its port definitions to
`addons/expose_check/auto_save/session.json`, and reads it back the next time you open the editor.

It lives **inside the plugin's own directory**, which means:

- add `addons/expose_check/auto_save/` to your `.gitignore` if you don't want it version-controlled

That directory contains a `.gdignore`, so Godot never scans it and it stays invisible in the
editor's FileSystem dock. Delete the file if you want to see it again.

## Command-line tool & AI Skill

`tools/expose_cli.gd` is a headless tool that does not need the editor and **shares the exact
same analyzer** as the plugin:

```bash
godot --headless --path <project root> \
	--script res://addons/expose_check/tools/expose_cli.gd -- <command> [args...]
```

| Command | Effect |
|---|---|
| `list <script...>` | List a script's exposed members (with signatures and docs) |
| `outline <script\|blueprint.json>` | Print a markdown outline |
| `expose` / `unexpose <script> <member...>` | Add or remove a single member's marker |
| `region-expose` / `region-unexpose <script> <member...>` | Wrap a run of members in a region |
| `region-remove <script> <member...>` | Remove the region enclosing those members |
| `apply <blueprint.json> [script...]` | Apply a blueprint to scripts (**additive only**) |
| `check <blueprint.json> [script...]` | Report differences without writing anything |
| `blueprint <script...> [-o file]` | Generate a blueprint from scripts (nodes and members only, no links) |

Safeguards when writing: it backs the file up to `<script>.bak` first; it **re-computes the md5
right before writing** and gives up if it changed since the read (meaning the editor just touched
it); it **only ever inserts, deletes or comments out whole lines** and never rewrites a file
wholesale; and it is idempotent.

Pair it with [`SKILL.md`](SKILL.md) to let an AI assistant operate these markers for you.

> **Headless crashes on startup?** Godot writes logs to `user://logs/` when it boots. If the CLI
> runs from a process with a file sandbox (some AI agents do this), that directory is outside the
> writable area → it cannot be created → Godot **segfaults**, and it crashes during project load,
> which looks like a broken project. Fix it by pointing `user://` somewhere writable:
> `APPDATA=<project root>/.godot_userdata godot --headless ...`. See `SKILL.md` for details.

## Directory layout

```
addons/expose_check/
├── plugin.cfg                     Plugin manifest
├── expose_check_plugin.gd         EditorPlugin: mounts the dock + session save/restore
├── icon.svg                       Plugin icon (used by the dock)
├── icon.png                       The same art at 128×128, for Asset Library listings
├── LICENSE
├── README.md                      Chinese README
├── README.en.md                   This file
├── SKILL.md                       AI Skill documentation
├── auto_save/
│   ├── .gdignore                  Keeps Godot from scanning this directory
│   └── session.json               Session snapshot (written when the editor closes)
├── tools/
│   └── expose_cli.gd              headless CLI
└── ui/
		├── ExposeCheckPanel.tscn      Main panel scene
		├── expose_check_interface.gd  Panel root: persistent popups, context menus
		├── i18n.gd                     UI localization (Chinese source text as keys)
		├── expose_check_area.gd       GraphEdit: nodes/links/blueprint/refresh
		├── ScriptNode.tscn/.gd        The node representing one class
		├── ContainerBlock.tscn/.gd    The row representing one member
		├── ConfigPanel.gd             The "Settings" panel holding port definitions
		├── InputLine.tscn/.gd         One row in Settings
		├── script_analyzer.gd         Source analysis (single source of truth; the CLI uses it too)
		├── script_info.gd             Analysis result for one class
		├── expose_name_and_dsharp_hint.gd  Record for one member (name / docs / signature)
		├── PortInfo.gd                One port definition
		├── blueprint_io.gd            Blueprint JSON read/write and version migration
		├── member_writer.gd           Marker editing and code stub generation
		└── popup_helper.gd            Popup coordinate conversion
```

## Known limitations

- **Constants and enums cannot be stubbed automatically** — their values cannot be invented, so
  the CLI just reports them for you to fill in by hand
- **Links cannot be written back into scripts** — a blueprint's links express intent on the graph
  and have **no counterpart** in GDScript source. The reverse holds too: generating a blueprint
  from scripts produces nodes and members, never links
- **Give generated stubs a read** — `@abstract` on abstract functions, constant values and so on
  cannot be reconstructed from a name and a type alone
- Deleting a child node leaves its parent node on the graph (there is no automatic cleanup of
  unreferenced ancestors)

## Language

**The editor UI follows Godot's editor language** (`Editor Settings → Interface → Editor Language`):

- Chinese locales (`zh_*`) → Chinese
- **Everything else → English**

**The command-line tool always outputs English** — it usually runs in CI or a pipeline, and
machine-parsed output should not depend on the UI language.

### Adding a language

Edit `TABLE` in `ui/i18n.gd` and add an entry next to `"en"`:

```gdscript
const TABLE := {
	"en": { "设置": "Settings", ... },
	"ja": { "设置": "設定", ... },      # ← new
}
```

The mechanism uses **the Chinese source text as the key**, which means:

- **Not a single `.tscn` file needs changing** — widget text is substituted wholesale by
  `ExposeCheck_I18n.apply(self)` when the panel's `_ready` runs
- Text built at runtime calls `ExposeCheck_I18n.t("中文原文")` right where it is assigned
- A missing translation never becomes blank — it falls through to Chinese, which is easy to spot

### Why not Godot's standard TranslationServer

We tried it. **On this version it is unreliable for editor plugins** (measured on Godot 4.7.1):
`TranslationServer.add_translation()` registers fine and `get_translation_object()` hands the
message back, but neither `TranslationServer.translate()` nor `Control.atr()` **consults it** —
even the editor's own strings (`translate("Import")`) come back unchanged, and `loaded_locales`
starts out as `[]`. Switching to ASCII keys, `StringName`, different locales, or saving the
`Translation` as a `.tres` and reloading it made no difference at all.

So the plugin ships its own table. The upside is that **no `.po` toolchain is involved** — adding
a language is just adding a dictionary entry.

## License

[MIT](LICENSE) © 2026 Douluoxi
