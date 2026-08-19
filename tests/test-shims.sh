#!/bin/bash
# End-to-end tests for the PRECISE layer (BASH_ENV functions + PATH shims)
# and the grep->rg translation. Requires Git Bash and node.
#
# Run:  bash tests/test-shims.sh
#
# The entry cap is lowered to 50 via env; the temp "big" tree has 66 entries.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SG_DIR="$(cd "$SCRIPT_DIR/../shims" && pwd)"

export BASH_ENV="$SG_DIR/init.sh"
export PATH="$SG_DIR:$PATH"
export SEARCH_GUARD_ENTRY_CAP=50
export SEARCH_GUARD_TIME_BUDGET_MS=10000

BASE=$(mktemp -d)
PROJ="$BASE/project"; BIG="$BASE/big"
mkdir -p "$PROJ/src"
echo "TODO a" > "$PROJ/src/a.ts"
echo "TODO b" > "$PROJ/src/b.ts"
echo "hello" > "$PROJ/README.md"
echo 'TODO*.magic' > "$PROJ/src/c.txt"
for d in 0 1 2 3 4 5; do
	mkdir -p "$BIG/d$d"
	for f in $(seq 0 9); do echo x > "$BIG/d$d/f$f.txt"; done
done
# BIG has 66 entries > cap 50; HOME is huge.

pass=0; fail=0

t() { # t <desc> <expect: blocked|allowed> <command...>
	local desc="$1" expect="$2"; shift 2
	local err rc
	err=$(cd "$PROJ" && bash -c "$*" 2>&1 >/dev/null); rc=$?
	local got=allowed
	[[ "$err" == *"[search-guard] Blocked"* ]] && got=blocked
	if [ "$got" = "$expect" ]; then pass=$((pass+1)); echo "PASS | $desc"
	else fail=$((fail+1)); echo "FAIL | $desc (expect=$expect got=$got rc=$rc)"; echo "     stderr: $err"; fi
}

shim_only() { # invoke via `command` to bypass the wrapper functions
	local desc="$1" expect="$2"; shift 2
	local err rc
	err=$(cd "$PROJ" && bash -c "command $*" 2>&1 >/dev/null); rc=$?
	local got=allowed
	[[ "$err" == *"[search-guard] Blocked"* ]] && got=blocked
	if [ "$got" = "$expect" ]; then pass=$((pass+1)); echo "PASS | $desc"
	else fail=$((fail+1)); echo "FAIL | $desc (expect=$expect got=$got rc=$rc)"; echo "     stderr: $err"; fi
}

t_out() { # t_out <desc> <needle> <command...>: stdout must contain <needle>
	local desc="$1" needle="$2"; shift 2
	local out rc
	out=$(cd "$PROJ" && bash -c "$*" 2>/dev/null); rc=$?
	if [[ "$out" == *"$needle"* ]]; then pass=$((pass+1)); echo "PASS | $desc"
	else fail=$((fail+1)); echo "FAIL | $desc (rc=$rc)"; echo "     output: '$out' want substring: '$needle'"; fi
}

# --- wrapper functions (final argv, precise) ---
t "变量间接引用(静态解析做不到)" blocked "D='$BIG'; rg TODO \"\$D\""
t "cd 变量 && 相对路径" blocked "D='$BIG'; cd \"\$D\" && rg TODO ."
t "小目录放行" allowed "rg TODO ./src"
t "cwd=HOME 显式搜当前目录" blocked "cd '$HOME' && rg TODO ."
t "管道输入 rg (stdin) 放行" allowed "cat README.md | rg hello"
t "grep -r 无文件参数(必搜 cwd)" blocked "cd '$HOME' && grep -r TODO"
t "rg 显式 stdin(不扫盘)" allowed "rg hello < README.md"
t "grep -r 大目录" blocked "grep -r TODO '$BIG'"
t "grep 非递归单文件(快速路径)" allowed "grep hello README.md"
t "find 大目录" blocked "find '$BIG' -name '*.ts'"
t "嵌套 bash -c" blocked "bash -c \"cd '$BIG' && rg TODO .\""
t "for 循环中的 grep" blocked "for p in '$BIG'; do grep -r TODO \"\$p\"; done"
t "SEARCH_GUARD_OFF 旁路" allowed "SEARCH_GUARD_OFF=1 rg TODO '$BIG/d0'"
t "find 小子目录" allowed "find '$BIG/d0' -name '*.txt'"
t "find -maxdepth 1 浅层放行" allowed "find '$BIG' -maxdepth 1 -type f -name '*'"
t "find -maxdepth 2 超限仍拦" blocked "find '$BIG' -maxdepth 2 -type f"
t "rg --max-depth 1 浅层放行" allowed "rg --max-depth 1 TODO '$BIG'"

# --- PATH shim layer (xargs / command bypasses the functions) ---
shim_only "command rg 绕过函数走 shim" blocked "rg TODO '$BIG'"
shim_only "command rg 小目录" allowed "rg TODO '$PROJ/src'"
t "xargs 调起的 rg" blocked "echo '$BIG' | xargs -I{} rg TODO {}"
t "xargs 传具体文件放行" allowed "find '$BIG/d0' -name 'f0.txt' | xargs grep x"

# --- grep -> rg translation ---
# grep is transparently rewritten to the much faster rg (--no-config, so the
# user's ripgrep config cannot change grep semantics); anything
# untranslatable falls back to the real grep.
t_out "grep -rn 翻译为 rg" "src/a.ts:1:TODO a" "grep -rn TODO ./src"
t_out "grep -i 忽略大小写" "src/a.ts:1:TODO a" "grep -irn todo ./src"
t_out "grep -l 只列文件名" "src/a.ts" "grep -rl TODO ./src"
t_out "grep -c 计数" "1" "grep -c TODO ./src/a.ts"
t_out "组合短选项 -irn" "src/a.ts:1:TODO a" "grep -irn todo ./src"
t_out "不支持的标志回退真 grep" "src/a.ts:1:TODO a" "grep -rn --line-buffered TODO ./src"
t_out "SEARCH_GUARD_GREP_AS_RG=0 禁用翻译" "src/a.ts:1:TODO a" "SEARCH_GUARD_GREP_AS_RG=0 grep -rn TODO ./src"
t_out "fgrep 字面量匹配" "TODO*.magic" "fgrep 'TODO*.magic' ./src/c.txt"
t_out "--include 转为 -g" "src/a.ts:1:TODO a" "grep -rn --include='*.ts' TODO ./src"
t_out "grep 翻译后仍受守卫保护" "[search-guard] Blocked" "grep -r TODO '$BIG' 2>&1"

# --- strict mode: minimal whitelist only, everything else falls back ---
t_route() { # t_route <desc> <expect: translated|fallback> <command...>
	local desc="$1" expect="$2"; shift 2
	local err got
	err=$(cd "$PROJ" && SEARCH_GUARD_DEBUG=1 bash -c "SEARCH_GUARD_GREP_AS_RG=strict $*" 2>&1 >/dev/null)
	got=fallback
	[[ "$err" == *"translated to"* ]] && got=translated
	if [ "$got" = "$expect" ]; then pass=$((pass+1)); echo "PASS | $desc"
	else fail=$((fail+1)); echo "FAIL | $desc (expect=$expect got=$got)"; fi
}

t_route "strict: 核心 -rn 被翻译" translated "grep -rn TODO ./src"
t_route "strict: 核心 -ilw 簇被翻译" translated "grep -rin TODO ./src/a.ts"
t_route "strict: -c 回退" fallback "grep -c TODO src/a.ts"
t_route "strict: -E 回退" fallback "grep -E 'TODO' src/a.ts"
t_route "strict: 反斜杠模式回退" fallback "grep 'TODO\\s' src/a.ts"
t_route "strict: 缺失目标回退" fallback "grep TODO no_such_file.xyz"
t_route "strict: --include 回退" fallback "grep -rn --include='*.ts' TODO ./src"
t_out "strict: 翻译结果仍正确" "src/a.ts:1:TODO a" "SEARCH_GUARD_GREP_AS_RG=strict grep -rn TODO ./src"

# --- find -> rg --files mapping ---
t_out "find -type f -name 翻译为 rg --files" "src/a.ts" "find . -type f -name '*.ts'"
t_out "find -iname 大小写不敏感" "src/b.ts" "find . -type f -iname '*.TS'"
t "find 大目录仍被拦截" blocked "find '$BIG' -type f -name '*'"
t_route "strict: find 核心被翻译" translated "find . -type f -name '*.ts'"
t_route "strict: find -exec 回退" fallback "find src -type f -name '*.ts' -exec echo {} ;"

echo
echo "pass=$pass fail=$fail"
rm -rf "$BASE"
[ "$fail" -eq 0 ]
