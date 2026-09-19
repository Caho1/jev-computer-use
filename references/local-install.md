# 在 Mac 本地安装

本说明适用于完整 Skill 文件位于 GitHub 仓库根目录的布局。仓库必须包含 SKILL.md、scripts、references 和 agents；只下载 SKILL.md 无法运行本工具。

## 获取完整代码

完整代码仓库为 [Caho1/jev-computer-use](https://github.com/Caho1/jev-computer-use)。本地目录保留 Skill 名称 jev-mac-use。

```bash
mkdir -p "$HOME/.agents/skills"
git clone https://github.com/Caho1/jev-computer-use.git "$HOME/.agents/skills/jev-mac-use"
cd "$HOME/.agents/skills/jev-mac-use"
python3 scripts/mac_use.py doctor
bash scripts/build.sh
```

Codex CLI/本地代码环境会从 `~/.agents/skills` 加载用户级 Skill，官方说明：https://learn.chatgpt.com/docs/build-skills 。安装后在本地会话中调用 `$jev-mac-use`。安装位置不会让一个云端会话获得 Mac 的执行权限，仍需选择本地执行环境。

如果目标目录已经存在，先检查其来源和内容，不要覆盖或删除；已有的同一仓库可以在目录内执行 `git pull --ff-only` 更新。

依赖 macOS、Python 3.10+ 与 Xcode Command Line Tools。通过 `xcrun --find swiftc` 检查编译器；若缺少命令行工具，在 Mac 上运行 `xcode-select --install` 并完成系统安装。

## 授权和配置 Key

`doctor` 应显示 Darwin。执行器构建后会输出 `accessibility_trusted` 状态。若为 false，打开系统设置的隐私与安全性、辅助功能，按 macOS 显示的实际进程为执行器或负责启动它的终端/宿主授权。不要修改 TCC 数据库。重新编译后系统可能要求重新授权。

在本机终端用隐藏输入设置 Key，以下写法兼容默认 zsh 和 bash：

```bash
export TYPESAFE_API_KEY="$(python3 -c 'import getpass; print(getpass.getpass("TypeSafe API key: "))')"
```

Key 只存在当前终端会话的环境里。不要放入仓库、任务 JSON、聊天提示词或日志。通过这个终端启动的进程才能继承变量，已运行的桌面应用不会自动获得它。

## 运行演示

在上述同一终端会话、Skill 目录内运行：

```bash
bash scripts/demo.sh
python3 scripts/mac_use.py run --task references/demo-task.json --execute --trace "/tmp/jev-mac-demo-$(date +%s).jsonl"
```

保持演示应用在前台。预期是输入框显示 penguin，结果显示 Results for: penguin，脚本返回 verified。可以在本地 Codex 会话中说：使用 $jev-mac-use，确认 Darwin 环境，构建执行器并运行内置 Demo，记录完整流程耗时。

当前状态：Python 测试和 Jev API 已验证，Swift 源码尚未通过 Mac 编译与桌面实测。安装后应先做本机验收。故障解释见 runtime.md。
