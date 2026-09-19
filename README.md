# Jev Computer Use for macOS

用 TypeSafe Jev 做快速结构化决策，通过原生 macOS Accessibility (AX) 操作界面的实验性 Codex Skill。

**Skill 名称：`jev-mac-use`。当前为开发原型，尚未完成 Mac 原生编译与桌面验收。**

Codex 负责目标拆解、准备输入文本和处理异常；Jev 从当前可用动作中选择下一步；Swift AX 执行器负责操作和读取结果。一次本地脚本调用可以持续执行多步，复用 HTTPS 连接和原生进程。

## 在 Mac 本地安装

依赖 macOS、Python 3.10+、Git 与 Xcode Command Line Tools。

```bash
mkdir -p "$HOME/.agents/skills"
git clone https://github.com/Caho1/jev-computer-use.git "$HOME/.agents/skills/jev-mac-use"
cd "$HOME/.agents/skills/jev-mac-use"
bash scripts/build.sh
python3 scripts/mac_use.py doctor
```

若目录已经存在，请先检查内容，不要覆盖。更新本仓库安装时，在目录内执行 `git pull --ff-only`。若缺少 Swift 编译器，运行 `xcode-select --install` 完成安装。

本地 Codex 会从 [用户级 Skill 目录](https://learn.chatgpt.com/docs/build-skills) 加载此 Skill。打开本地会话后输入：

> 使用 $jev-mac-use，确认 Darwin 环境，检查辅助功能权限，运行内置 Demo 并记录端到端耗时。

本地安装不会让云端 Linux 会话获得 Mac 执行权限，需要使用本地执行环境。

## 辅助功能权限

构建会生成 `~/Library/Caches/jev-mac-use/axbridge`。若 doctor 显示 `accessibility_trusted: false`，在系统设置的“隐私与安全性 → 辅助功能”中，为 macOS 实际识别的执行器或负责启动它的终端/宿主授权。系统授权需由用户手动完成。此版本只使用 AX，不需要屏幕录制权限。

## 配置 Key 并运行 Demo

在同一个本机终端中用隐藏输入设置 Key，兼容 zsh 和 bash：

```bash
export TYPESAFE_API_KEY="$(python3 -c 'import getpass; print(getpass.getpass("TypeSafe API key: "))')"
```

然后在 Skill 目录运行：

```bash
bash scripts/demo.sh
python3 scripts/mac_use.py run --task references/demo-task.json --execute --trace "/tmp/jev-mac-demo-$(date +%s).jsonl"
```

保持 Jev Mac Lab 在前台。预期输入框为 `penguin`、结果为 `Results for: penguin`，最后返回 `verified`。任务同时核对输入框与结果，避免把旧结果误认为成功。Key 只保留在当前终端环境中，已运行的桌面应用不会自动继承它。

## 当前能力与边界

支持具有 `AXPress`、`AXShowMenu` 或可写 `AXValue` 的语义控件。带有操作范围、元素失效检查、步骤与时间预算、概率门槛、逐步计时和明确的完成断言。Jev 不生成文本，输入内容由主 Agent 提前准备。

本版本要求先观察界面并准备范围明确的动作选择器。暂未实现开放式工作流探索、拖拽、滚动、键盘注入、自定义画布、截图理解或多应用自动切换。它使用独立执行器，不修改 Codex 内置 Computer Use。

必要的 UI 标签和值会发给 TypeSafe。系统标识的密码字段被排除，但未提供全面敏感信息识别。仓库不包含 API Key。请只用于已授权的应用与操作。

## 已完成的验证

- 17 项离线 Python 行为测试通过。
- 61 次真实 Jev API 请求，包括 1 次冷启动和 60 次人工 AX 场景请求。
- Swift/AppKit 部分在 Linux 环境中编写，尚未在 Mac 上编译或进行端到端验收。

| 模式 | 稳态请求数 | p50 | p95 |
| --- | ---: | ---: | ---: |
| 完整动作 Choice | 30 | 313.769 ms | 393.131 ms |
| 操作与目标并行判断 | 30 | 306.216 ms | 388.543 ms |

测量日期为 2026-09-18，模型为 `jev-1.13.0`，Linux 云端通过环境配置的 HTTPS 代理请求。耗时包含网络。另一次冷启动为 6376.420 ms。测试只有 10 种独立人工场景，每模式每场景重复 3 次；这些数据不代表真实 Mac 任务耗时或成功率。

## 测试与使用

```bash
python3 -m unittest discover -s scripts/tests -v
python3 scripts/mac_use.py observe --app APP_BUNDLE_ID
python3 scripts/mac_use.py run --task TASK.json --execute --trace TRACE.jsonl
```

省略 `--execute` 只预测一步；`--mode fanout` 使用并行操作/目标判断。默认运行上限为 12 步和 60 秒。首次预热单独记录，不包含在每步耗时中。

运行人工 AX API benchmark 会调用付费 API，默认 61 次请求：

```bash
python3 scripts/benchmark.py --ask-key --out RESULTS.json
```

完整说明：[Skill](SKILL.md)、[本机安装](references/local-install.md)、[运行机制与任务格式](references/runtime.md)、[调研与测量边界](references/research.md)、[演示任务](references/demo-task.json)。

