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

## 安装与使用

完整的自动安装、手动文件复制、Python 环境配置、Codex 配置修改、验证方法和
故障排查，都在 [AGENTS.md](AGENTS.md)。这也是可以直接交给 Codex 阅读并
执行的唯一操作文档。

常规安装只需在关闭 SketchUp 后运行：

```powershell
.\scripts\bootstrap.ps1
.\scripts\install-plugin.ps1
```

然后重启 SketchUp，在 Codex 中打开本项目，并调用 `bridge_info` 验证连接。
