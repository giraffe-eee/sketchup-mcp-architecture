# SketchUp Architecture MCP

这是本项目的完整安装和操作说明。Codex 可以直接读取本文件完成配置；当
PowerShell 脚本不可用时，也可按手动步骤安装。

## 项目用途

本项目让 Codex 通过本地 MCP 桥接服务创建和修改 SketchUp 建筑模型。所有尺寸
使用毫米。桥接服务只在本机运行，只接受预定义的建模动作，不执行任意 Ruby 代码。

## 工作原理

```text
Codex
  | STDIO MCP
Python MCP 服务 (mcp-server/sketchup_mcp_server.py)
  | 本地 JSONL 文件队列 (<project>/.runtime/file-queue)
SketchUp Ruby 扩展
  | SketchUp Ruby API
当前 .skp 模型
```

Ruby 扩展在 SketchUp 内实际执行建模。Python 不是 SketchUp 插件，而是供 Codex
启动和调用的 MCP 适配器。本地文件队列让嵌入式 SketchUp Ruby 无法稳定提供 HTTP
服务时仍能可靠通信。

## 推荐环境

- Windows 10/11
- SketchUp 2026（已验证）
- Python 3.12（推荐；Python 3.10 或更高版本为最低要求）

文件队列位于项目目录的 `.runtime\file-queue`。安装脚本会把当前用户的
实际项目路径写入 SketchUp 插件，因此项目可位于任意目录。

## 核心文件

| 路径 | 用途 |
| --- | --- |
| `sketchup-plugin-source/sketchup_mcp_port_bridge.rb` | SketchUp 扩展加载器。 |
| `sketchup-plugin-source/codex_sketchup_mcp/` | Ruby 实现、版本和动作目录。 |
| `mcp-server/sketchup_mcp_server.py` | 面向 Codex 的 MCP 服务。 |
| `mcp-server/requirements.txt` | Python 依赖。 |
| `.codex/config.toml` | 本项目的 Codex MCP 注册配置。 |
| `scripts/bootstrap.ps1` | 可选的 Python 环境安装脚本。 |
| `scripts/install-plugin.ps1` | 可选的 SketchUp 插件安装/更新脚本。 |

不要使用或查看任何无关或损坏的 `project-source` 目录。

## 自动安装

1. 关闭 SketchUp，并保存已打开的模型。
2. 在 Codex 中将本仓库作为受信任工作区打开。
3. 运行：

   ```powershell
   .\scripts\bootstrap.ps1
   .\scripts\install-plugin.ps1
   ```

   如果已经安装过插件，请使用：

   ```powershell
   .\scripts\install-plugin.ps1 -Update
   ```

4. 重启 SketchUp，并在 Codex 中打开本仓库。Codex 会根据
   `.codex/config.toml` 启动 `sketchup_architecture` MCP 服务。
5. 调用 `bridge_info`。正常桥接会报告协议版本 `1.0`，支持动作中包含
   `apply_batch`。
6. 也可运行 `.\scripts\check-bridge.ps1`，检查插件、文件队列与协议是否正常连接。

## 手动安装

当 PowerShell 脚本失败，或需要明确检查每个文件的放置位置时，使用以下步骤。

### 1. 安装 SketchUp 扩展文件

关闭 SketchUp，找到其 Plugins 目录。SketchUp 2026 在 Windows 的默认路径为：

```text
%APPDATA%\SketchUp\SketchUp 2026\SketchUp\Plugins
```

严格按以下对应关系复制：

```text
<project>\sketchup-plugin-source\sketchup_mcp_port_bridge.rb
    -> <Plugins>\sketchup_mcp_port_bridge.rb

<project>\sketchup-plugin-source\codex_sketchup_mcp\
    -> <Plugins>\codex_sketchup_mcp\
```

在 `<Plugins>\codex_sketchup_mcp\runtime_config.json` 创建以下内容，并将
`C:/path/to/sketchup-mcp-architecture` 替换为项目实际路径：

```json
{
  "runtime_dir": "C:/path/to/sketchup-mcp-architecture/.runtime",
  "file_bridge_dir": "C:/path/to/sketchup-mcp-architecture/.runtime/file-queue"
}
```

最终 Plugins 目录必须同时包含 `.rb` 加载器和完整的 `codex_sketchup_mcp` 文件夹。
不要将该文件夹嵌套一层或重命名。启动 SketchUp 后，如被询问是否加载扩展，请允许；
再在“扩展程序”中确认 Codex SketchUp MCP 已启用。

### 2. 创建 Python MCP 环境

推荐安装 Python 3.12；Python 3.10 或更高版本也可使用。在项目根目录运行自动安装命令，或手动运行：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r .\mcp-server\requirements.txt
```

若 `python` 未加入 `PATH`，请替换为 `python.exe` 完整路径，例如：

```text
C:\Users\<username>\AppData\Local\Programs\Python\Python3xx\python.exe
```

### 3. 手动配置 Codex

打开 `<project>/.codex/config.toml`。Codex 将本仓库作为工作区打开时可直接使用
相对路径。若需要绝对路径，请替换完整 `sketchup_architecture` 配置块，并将
`C:/path/to/sketchup-mcp-architecture` 换成实际项目路径。TOML 中使用正斜杠：

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
```

修改后重启 Codex 工作区，使 MCP 服务使用新配置重新启动。

## 常规建模流程

1. 先调用 `bridge_info` 确认桥接连接。
2. 编辑前调用 `list_entities` 和 `quality_check`。
3. 未得到用户明确许可时，禁止删除或覆盖已有模型。
4. 将相关元素拆分为原子性的 `apply_batch` 请求，每批 4-8 条命令；每个结构阶段后
   运行 `quality_check`。
5. 墙体带有实体入户门时，调用 `create_glazing` 时使用 `include_doors: false`。
6. 完成视觉上重要的建模后，检查立面和鸟瞰视图；结构质量检查无法判断比例是否协调
   或装饰元素是否缺失。

## 新建筑默认空间规则

除非用户明确要求其他方案，新开的建筑模型必须遵守以下规则：

1. 先建立一整片绿色场地地面（名称应含 `site`、`ground` 或 `lawn`），并明确它的顶面标高。
2. 建筑基础、首层墙体和入口均以场地顶面为基准在其上方建造。首层入户门若在场地标高，使用平台而不是外台阶。
3. 需要外台阶时，先建立高出场地的入口平台；台阶最低踏步必须不低于场地顶面，最高踏步必须与入口平台顶面齐平且在平面上相接。
4. 没有得到明确的“退台/露台/缩进”要求时，二层楼板和二层外围墙必须复用一层的完整外轮廓。不得为了造型自行缩小二层占地。
5. 如用户明确要求退台，二层墙脚必须落在楼板顶面上，楼板须覆盖全部二层墙体投影；完成后检查是否有竖向空隙、悬空墙或断开的台阶。

`quality_check` 会报告未落在楼板或基础上的高层墙体，以及低于带有 `site`、`ground`、`lawn`、`terrain` 或 `grass` 名称场地的楼梯。它不能判断用户是否主观上想要退台，因此第 4 条仍是强制的默认建模规则。

## 支持的动作

`create_box`、`create_cylinder`、`create_door`、`create_glazing`、
`create_railing`、`create_roof`、`create_slab`、`create_stair`、
`create_wall`、`create_window`、`delete_entity`、`list_entities`、
`move_entity`、`quality_check`、`rebuild_walls`、`repair_wall_joints`、
`set_material`。

权威参数定义位于
`sketchup-plugin-source/codex_sketchup_mcp/action_catalog.json`。

## 故障排查

| 现象 | 检查方式 |
| --- | --- |
| `bridge_info` 超时 | 运行 `.\scripts\check-bridge.ps1`；确认 SketchUp 正在运行，复制 Ruby 文件后已重启，并确认扩展已启用。 |
| Codex 无法启动 MCP 服务 | 运行 Python 安装命令，检查 `.codex/config.toml` 的 `command`、`cwd` 和运行目录路径。 |
| 安装脚本拒绝运行 | 完全关闭 SketchUp；安装脚本不会替换正在使用的插件文件。 |
| SketchUp 未显示插件 | 重新检查两处复制目标，确认复制的是完整的 `codex_sketchup_mcp` 文件夹。 |
| 现有模型意外变化 | 立即停止，调用 `list_entities`，仅在用户明确批准替换后继续。 |

`.venv`、`.runtime` 和安装脚本备份文件夹均为本机生成文件，已被 Git 忽略，
可按本说明重新生成。
