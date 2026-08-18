# grep_guard

防止 AI 编码代理（面向 [pi](https://github.com/earendil-works/pi-coding-agent)，可扩展到其它 agent）在大目录上执行递归搜索（`grep -r` / `rg` / `find` / `Get-ChildItem -Recurse` …）导致长时间卡死的三层防护。

## 问题

agent 的工作目录经常就是用户主目录或某个巨型仓库根目录。模型一旦执行 `grep -r TODO`、`rg pattern` 这类不带范围限制的递归搜索，就要遍历几十万甚至上百万个文件，会话卡死数分钟。

**"哪个目录算大"不能靠猜**——名字、位置都不可靠。grep_guard 在拦截前对搜索根目录做**带配额的实时文件计数探测**（条目上限按工具区分：grep 系 10000、rg/find 100000；或 2 秒时间预算，先到即停），数超限才拦截。小目录完全无感放行。

## 三层防护

### 1. 精准层：执行时拦截（核心）

静态解析 shell 命令永远是启发式（变量、引号、循环、xargs…总有漏洞）。精准层的做法是**让 shell 先完成解析，在命令真正执行时拦截**：

- **BASH_ENV 函数**：pi 扩展加载时设置 `BASH_ENV` 指向 `shims/init.sh`，之后每个非交互 bash 都会先加载它，其中定义了 `grep / egrep / fgrep / rg / ag / find` 的包装函数。函数被调用时，变量展开、引号处理、`cd`、循环全部已完成，拿到的就是**最终 argv**——探测通过才 `exec` 真实程序
- **PATH shim**：每条命令前把 `shims/` 目录前置到 PATH，覆盖函数管不到的场景（`xargs`、子进程 exec）

这些场景精准层全部验证过（静态解析做不到）：

```bash
D=$BIG; rg TODO "$D"                        # 变量间接引用
cd "$D" && rg TODO .                        # cd + 相对路径
for p in $BIG; do grep -r TODO "$p"; done   # 循环
echo $BIG | xargs -I{} rg TODO {}           # xargs
bash -c "cd $BIG && rg TODO ."              # 嵌套子 shell
```

探测逻辑在 `shims/probe.mjs`：

- 按工具语义解析 argv（`grep`/`rg` 的第一个位置参数是 pattern；`rg -e` 时所有位置参数都是路径；`find` 的表达式部分不是路径……）
- `rg`/`ag` 无路径且 stdin 是管道时读 stdin（不扫盘）→ 放行；`grep`/`find` 无路径参数必搜 `.` → 照拦
- 单个文件参数、不存在的路径 → 放行（无卡死风险）
- 结果缓存 30 秒；探测本身永不跟随符号链接、有配额上限，不会自己卡死

### 2. 启发式层：执行前静态解析（兜底）

pi 扩展（`extension/search-guard.ts`）在 `tool_call` 事件解析命令文本：

- 按 `;`、`\n`、`&&`、`||` 拆段，顺序跟踪 `cd`（target 会 stat 验证，`cd` 失败则目录不变，和 bash 行为一致；`cd $未知变量` 无法跟踪时直接拦截）
- 解开 `bash -c` / `cmd /c` / `powershell -Command` 套壳递归解析（最多 3 层）
- 只检查每段第一级管道（后面读 stdin）
- 覆盖精准层管不到的 PowerShell（`Get-ChildItem -Recurse`）等

### 3. timeout 兜底

所有放行的递归搜索若未指定超时，自动注入 60 秒 timeout。

## 安装（pi）

```bash
git clone https://github.com/kexul/grep_guard
cd grep_guard
cp extension/search-guard.ts ~/.pi/agent/extensions/
cp -r shims ~/.pi/agent/shims
```

在 pi 会话中执行 `/reload`（或重启 pi）。扩展加载时会自动：

- 设置 `BASH_ENV=~/.pi/agent/shims/init.sh`
- 在每条 bash 命令前注入 PATH 前置

可选：在 `AGENTS.md` 中加一条软约束，让模型自觉收窄搜索范围：

```markdown
禁止对 ~、盘符根目录、node_modules 等大目录做递归搜索。
搜索前把范围限定到具体子目录或文件，并给搜索命令设置 timeout。
```

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SEARCH_GUARD_ENTRY_CAP` | 按工具 | 条目数上限（同时覆盖所有工具）。默认按工具区分：`grep/egrep/fgrep` 10000（实测 ~2.4ms/文件），`rg/ag/find` 100000（快 ~50-100 倍），`ls -R`/`dir /s`/`Get-ChildItem -Recurse` 20000 |
| `SEARCH_GUARD_TIME_BUDGET_MS` | `2000` | 单次探测时间预算 |
| `SEARCH_GUARD_SHIM_DIR` | `~/.pi/agent/shims` | shims 目录位置 |
| `SEARCH_GUARD_OFF` | - | `=1` 时完全禁用（模型被拦截时也会被告知这个逃生门） |

被拦截时模型收到的消息形如：

```
[search-guard] Blocked: "." (resolved to C:\Users\xxx) holds more than 10000 entries;
a recursive grep here would take far too long.
  Fix: narrow the path (e.g. grep <pattern> ./specific/subdir), add exclusions
  (rg -g '!node_modules'), or inspect the tree first (ls/fd).
  One-shot bypass if truly intended: SEARCH_GUARD_OFF=1 grep ...
```

## 测试

```bash
# 启发式层单元测试（Node >= 22.6，28 个用例）
node tests/test-extension.mjs

# 精准层端到端测试（Git Bash，18 个用例）
bash tests/test-shims.sh
```

测试会把条目上限降到 50，并自建"小项目/66 条目大目录"的临时树，不依赖真实环境。

## 性能

| 场景 | 额外开销（Windows 实测） |
|---|---|
| 每条 bash 命令（BASH_ENV 加载） | ~0.1s |
| 递归搜索（probe，node 启动） | ~0.2–0.3s |
| 非递归 grep（快速路径，不启 node） | 近乎 0 |

## 已知限制

- 用绝对路径直调（`/usr/bin/grep`）、`command -p` 类显式绕过，精准层拦不住——此时由启发式层 + timeout 兜底
- 启发式的 token 解析是启发式（带空格未加引号的路径、极端引号嵌套），精准层负责补漏
- 拦截决策基于条目数而非字节数：少量巨型文件不会被拦（但搜索它们通常也不慢）

## License

MIT
