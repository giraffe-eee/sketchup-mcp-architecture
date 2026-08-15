# SketchUp Architecture MCP

This is the complete installation and operation guide. A Codex agent can read
this file and perform the setup; a person can also follow the manual steps
when PowerShell scripts are unavailable.

## What this project does

It lets Codex create and revise SketchUp architecture models through a local
MCP bridge. All dimensions are millimetres. The bridge is local-only and
accepts a fixed catalog of modelling actions instead of arbitrary Ruby code.

## Architecture

```text
Codex
  | STDIO MCP
Python MCP server (mcp-server/sketchup_mcp_server.py)
  | local JSONL file queue (.runtime/file-queue)
SketchUp Ruby extension
  | SketchUp Ruby API
Current .skp model
```

The Ruby extension performs the actual modelling inside SketchUp. Python is
not a SketchUp plugin: it is the small MCP adapter that Codex can start and
call. The local file queue makes the connection reliable even when embedded
SketchUp Ruby threads cannot run a normal HTTP server consistently.

## Files that matter

| Path | Purpose |
| --- | --- |
| `sketchup-plugin-source/sketchup_mcp_port_bridge.rb` | SketchUp extension loader. |
| `sketchup-plugin-source/codex_sketchup_mcp/` | Ruby implementation, version, and action catalog. |
| `mcp-server/sketchup_mcp_server.py` | Codex-facing MCP server. |
| `mcp-server/requirements.txt` | Python dependency list. |
| `.codex/config.toml` | Project-scoped MCP registration for Codex. |
| `scripts/bootstrap.ps1` | Optional Python environment setup. |
| `scripts/install-plugin.ps1` | Optional guarded SketchUp plugin installation/update. |

Do not use or inspect any unrelated or corrupted `project-source` directory.

## Automatic installation

1. Close SketchUp. Save any open model first.
2. Open this repository as a trusted Codex workspace.
3. Run:

   ```powershell
   .\scripts\bootstrap.ps1
   .\scripts\install-plugin.ps1
   ```

   Use `-Update` on the second command if a previous Codex SketchUp MCP plugin
   is already installed:

   ```powershell
   .\scripts\install-plugin.ps1 -Update
   ```

4. Start SketchUp again and open this repository in Codex. Codex starts the
   `sketchup_architecture` MCP server from `.codex/config.toml`.
5. Call `bridge_info`. A healthy bridge reports protocol version `1.0` and
   includes `apply_batch` in its supported actions.

## Manual installation

Use these steps if either PowerShell script fails, or if you prefer to see
every file placement explicitly.

### 1. Install the SketchUp extension files

Close SketchUp. Locate its Plugins directory. For the default SketchUp 2026
Windows installation it is:

```text
%APPDATA%\SketchUp\SketchUp 2026\SketchUp\Plugins
```

Copy these items exactly:

```text
<project>\sketchup-plugin-source\sketchup_mcp_port_bridge.rb
    -> <Plugins>\sketchup_mcp_port_bridge.rb

<project>\sketchup-plugin-source\codex_sketchup_mcp\
    -> <Plugins>\codex_sketchup_mcp\
```

The final Plugins directory must contain both the `.rb` loader and the entire
`codex_sketchup_mcp` folder. Do not put the folder inside another folder and do
not rename it.

Start SketchUp. If SketchUp asks whether to load the extension, allow it.
Verify under `Extensions` that the Codex SketchUp MCP extension is enabled.

### 2. Create the Python MCP environment

Install Python 3.10 or later. From the project root, run either the automatic
bootstrap command above or the following commands manually:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r .\mcp-server\requirements.txt
```

If `python` is not on `PATH`, replace it with the full path to `python.exe`.
For example, a typical per-user installation is:

```text
C:\Users\<username>\AppData\Local\Programs\Python\Python3xx\python.exe
```

### 3. Configure Codex manually

Open `<project>/.codex/config.toml`. Its relative paths work when Codex opens
this repository as the workspace. If a Codex installation requires absolute
paths, replace the whole `sketchup_architecture` block with the following,
substituting `C:/path/to/sketchup-mcp-architecture` for the actual project
path. Use forward slashes in TOML paths.

```toml
[mcp_servers.sketchup_architecture]
command = "C:/path/to/sketchup-mcp-architecture/.venv/Scripts/python.exe"
args = ["mcp-server/sketchup_mcp_server.py"]
cwd = "C:/path/to/sketchup-mcp-architecture"
startup_timeout_sec = 20
tool_timeout_sec = 120
default_tools_approval_mode = "writes"
enabled = true

[mcp_servers.sketchup_architecture.env]
SKETCHUP_MCP_HOST = "127.0.0.1"
SKETCHUP_MCP_PORT = "17654"
SKETCHUP_MCP_TIMEOUT_SEC = "35"
SKETCHUP_MCP_ENABLE_FILE_QUEUE = "true"
SKETCHUP_MCP_RUNTIME_DIR = "C:/path/to/sketchup-mcp-architecture/.runtime"
SKETCHUP_MCP_FILE_BRIDGE_DIR = "C:/path/to/sketchup-mcp-architecture/.runtime/file-queue"
```

Restart the Codex workspace after changing this file so it restarts the MCP
server with the new configuration.

## Normal modelling workflow

1. Confirm the bridge with `bridge_info`.
2. Call `list_entities` and `quality_check` before editing.
3. Never delete or overwrite an existing model without explicit user approval.
4. Create related model elements in atomic `apply_batch` requests of 4-8
   commands. Run `quality_check` after each structural phase.
5. Use `create_glazing` with `include_doors: false` for a wall that has a solid
   entry door.
6. After a visually important build, inspect facade and bird's-eye views.
   A structural quality check cannot judge visual proportion or incomplete
   decorative elements.

## Supported actions

`create_box`, `create_cylinder`, `create_door`, `create_glazing`,
`create_railing`, `create_roof`, `create_slab`, `create_stair`,
`create_wall`, `create_window`, `delete_entity`, `list_entities`,
`move_entity`, `quality_check`, `rebuild_walls`, `repair_wall_joints`, and
`set_material`.

The authoritative parameter schema is
`sketchup-plugin-source/codex_sketchup_mcp/action_catalog.json`.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `bridge_info` times out | Ensure SketchUp is running, restart it after copying the Ruby files, and confirm the extension is enabled. |
| Codex cannot start the MCP server | Run the Python setup commands, then verify `command`, `cwd`, and runtime paths in `.codex/config.toml`. |
| Installer refuses to run | Close SketchUp completely; the installer will not replace active plugin files. |
| Plugin does not appear in SketchUp | Recheck both manual copy targets and make sure the `codex_sketchup_mcp` folder was copied as a folder, not as nested contents. |
| Existing model changes unexpectedly | Stop immediately, use `list_entities`, and only continue after the user explicitly approves the intended replacement. |

`.venv`, `.runtime`, and installer backup folders are local generated files.
They are excluded from Git and can be regenerated from this guide.
