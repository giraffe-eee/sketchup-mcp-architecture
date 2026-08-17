# 首次 Codex 会话提示词

把本项目作为 Codex 工作区打开后，在新会话的第一条消息中使用下面的安装提示词。提示词中的“本项目”指当前打开的仓库，不需要手动替换项目路径。

## 首次安装提示词

```text
你是 SketchUp MCP 项目的安装与验证助手。请先完整阅读 AGENTS.md、README.md 和 FIRST_SESSION_PROMPTS.md，再开始操作。

请按以下顺序完成安装：
1. 确认当前工作区根目录就是本项目，不要在其他目录创建配置或复制插件。
2. 确认 SketchUp 已关闭后，运行 .\scripts\install.ps1。它会自动发现 Python、创建项目自己的 .venv、安装固定版本的依赖，并发现已安装的 SketchUp Plugins 目录。
3. 如果它报告已有插件，先报告当前版本和建议操作；只有我明确同意后才运行 .\scripts\install.ps1 -Update。不要在 SketchUp 正在运行时安装或更新插件。
4. 如果 Python 或 SketchUp 使用了非标准目录，先使用脚本支持的 -PythonPath、-SketchUpVersion 或 -PluginsRoot 参数，不要把绝对路径硬编码进项目文件。自定义 SketchUp Plugins 目录必须使用 -PluginsRoot 指定。
5. 提醒我重启 SketchUp，然后运行 .\scripts\check-bridge.ps1，并报告 bridge_status、协议版本和已安装插件版本；随后调用 inspect_model，报告只读质量检查结果。
6. 安装阶段不要修改当前 .skp 模型，不要删除任何模型实体，也不要执行任意 Ruby 代码。

遇到错误时，请报告实际错误、你检查过的路径和下一条可执行的排查命令；不要用猜测的路径继续安装。
```

## 新会话首次建模提示词

```text
请先调用 bridge_status 确认 SketchUp MCP 桥接，再调用 inspect_model 检查当前模型。除非我明确授权，不要删除或覆盖已有实体。

如果这是新建建筑模型：
- 先建立覆盖足够范围的绿色 site-ground/lawn 地面，并明确顶面标高；
- 首层基础、墙体、入口和楼梯必须与地面连接；
- 没有明确要求时，二层沿用一层完整外轮廓，不要自动缩进；
- 如果确实需要退台，楼板必须完整覆盖二层墙体投影，并在完成后检查空隙、悬空墙和楼梯连接；
- 使用 sketchup_stream 分成小阶段，每阶段完成后做质量检查；
- 所有尺寸使用毫米；
- 建模完成后同时报告质量检查结果和仍需人工从视图确认的比例、材质或细节问题。
```

## 修改已有模型提示词

```text
先调用 list_entities 和 quality_check，说明当前模型中将要受影响的实体。只修改我明确指定的对象，保留其他模型内容。把修改拆成可回滚的小批次，每批后运行 quality_check；完成后说明是否存在空隙、悬空、低于地面的楼梯或未连接构件，并提醒我从正面、侧面和鸟瞰视图检查。
```

## 常用更新提示词

```text
这是插件更新，不是新建模型。请确认 SketchUp 已关闭，然后运行 .\scripts\install-plugin.ps1 -Update；保留项目内备份。重启 SketchUp 后运行 .\scripts\check-bridge.ps1，确认版本和桥接状态，再继续建模。
```
