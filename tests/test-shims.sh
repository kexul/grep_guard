#!/bin/bash
# End-to-end tests for the PRECISE layer (BASH_ENV functions + PATH shims).
# Requires Git Bash and node.
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
echo "TODO a" > "$PROJ/src/a.ts"; echo hello > "$PROJ/README.md"
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

# --- PATH shim layer (xargs / command bypasses the functions) ---
shim_only "command rg 绕过函数走 shim" blocked "rg TODO '$BIG'"
shim_only "command rg 小目录" allowed "rg TODO '$PROJ/src'"
t "xargs 调起的 rg" blocked "echo '$BIG' | xargs -I{} rg TODO {}"
t "xargs 传具体文件放行" allowed "find '$BIG/d0' -name 'f0.txt' | xargs grep x"

echo
echo "pass=$pass fail=$fail"
rm -rf "$BASE"
[ "$fail" -eq 0 ]
