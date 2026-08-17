# SketchUp Architecture MCP

这是一个让 Codex 通过本地 MCP 控制 SketchUp 建筑建模的项目。它不执行
任意 Ruby 指令，而是只允许墙体、楼板、门窗、楼梯、材质和质量检查等已定义
的建模动作。

## 工作原理

```text
Codex -> Python MCP 服务 -> 本地文件队列 -> SketchUp Ruby 插件 -> .skp 模型
```

Ruby 插件负责在 SketchUp 内实际建模；Python 只负责把 Codex 的 MCP 请求
可靠地转交给该插件。两者都在本机运行，不会把模型发送到外部服务。

## 推荐环境

- SketchUp 2026（已验证）
- Python 3.12（推荐；Python 3.10 或更高版本为最低要求）
- Windows 10/11

安装依赖固定为已验证的 `mcp 1.29.0`，避免不同安装日期得到不同行为的 MCP API。

桥接文件队列存放在项目目录的 `.runtime\file-queue`。安装脚本会把当前用户的
实际项目路径写入 SketchUp 插件，因此项目可以克隆到任意目录。

## 安装与使用

完整的自动安装、手动文件复制、Python 环境配置、Codex 配置修改、验证方法和
故障排查，都在 [AGENTS.md](AGENTS.md)。首次在 Codex 新建会话时可直接复制
[FIRST_SESSION_PROMPTS.md](FIRST_SESSION_PROMPTS.md) 中的提示词。

常规安装只需在关闭 SketchUp 后，从项目根目录运行：

```powershell
.\scripts\install.ps1
```

`install.ps1` 先创建 Python 环境，再安装 SketchUp 插件。已有插件需要显式更新：

```powershell
.\scripts\install.ps1 -Update
```

安装脚本不依赖固定的 Codex、Python 或 SketchUp 可执行文件路径：Python 环境建立在当前项目的 `.venv` 中，
插件运行时配置会写入当前项目的实际绝对路径。Python 会自动检查 `py` 启动器、
PATH、常见安装目录和 Windows 注册表；SketchUp 会自动查找用户配置目录下的
已安装版本和 Windows 注册表，并默认选择最新版本。Codex 只读取项目内的
`.codex/config.toml`，不调用或依赖 `codex.exe` 的安装位置。

多个 SketchUp 版本或非标准安装位置可明确指定：

```powershell
.\scripts\install.ps1 -SketchUpVersion 2025
.\scripts\install.ps1 -PluginsRoot 'D:\custom\SketchUp\Plugins'
.\scripts\install.ps1 -PythonPath 'E:\Python312\python.exe'
```

如果自动发现不到非标准目录，使用上述参数比修改脚本或硬编码路径更可靠。
自定义的 SketchUp 插件目录无法从其应用程序安装目录可靠推断，因此这是唯一需要
明确指定的少数情况。

然后重启 SketchUp，在 Codex 中打开本项目，并运行：

```powershell
.\scripts\check-bridge.ps1
```
