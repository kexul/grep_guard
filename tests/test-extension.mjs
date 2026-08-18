/**
 * Unit tests for the heuristic layer (extension/search-guard.ts).
 *
 * Run with Node >= 22.6 (type stripping):
 *   SEARCH_GUARD_ENTRY_CAP=50 node tests/test-extension.mjs
 *
 * Uses a temp directory tree: "project" (small) and "big" (66 entries).
 * The entry cap is lowered to 50 via env so tests stay fast.
 */

import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

// Point the extension at this repo's shims BEFORE importing it.
process.env.SEARCH_GUARD_SHIM_DIR ??= join(here, "..", "shims");
process.env.SEARCH_GUARD_ENTRY_CAP ??= "50";
process.env.SEARCH_GUARD_TIME_BUDGET_MS ??= "10000";

const { default: guard } = await import("../extension/search-guard.ts");

const home = homedir();
const base = join(tmpdir(), `sg-test-${Date.now()}`);
const project = join(base, "project");
const big = join(base, "big");
mkdirSync(join(project, "src"), { recursive: true });
writeFileSync(join(project, "src", "a.ts"), "TODO a");
writeFileSync(join(project, "src", "b.ts"), "TODO b");
writeFileSync(join(project, "README.md"), "hello");
for (let d = 0; d < 6; d++) {
	mkdirSync(join(big, `d${d}`), { recursive: true });
	for (let f = 0; f < 10; f++) writeFileSync(join(big, `d${d}`, `f${f}.txt`), "x");
}
// big now has 6 dirs + 60 files = 66 entries (> cap 50)

let handler = null;
guard({
	on(name, fn) {
		if (name === "tool_call") handler = fn;
	},
});

async function run(command, timeout, cwd) {
	const event = { toolName: "bash", input: { command, timeout } };
	const ctx = { cwd, ui: { notify() {} } };
	const result = await handler(event, ctx);
	return { blocked: !!result?.block, timeout: event.input.timeout };
}

// [description, command, timeout, cwd, expectBlocked, expectTimeout]
const cases = [
	// --- basics ---
	["grep -r 扫 home", `grep -r TODO ${home}`, undefined, project, true],
	["rg 无路径, cwd=home", `rg TODO`, undefined, home, true],
	["rg 无路径, cwd=小项目", `rg TODO`, undefined, project, false, 60],
	["rg 小目录(放行+注入60s)", `rg TODO ./src`, undefined, project, false, 60],
	["rg 已有timeout(保留)", `rg TODO ./src`, 300, project, false, 300],
	["rg 扫大目录", `rg TODO ${big}`, undefined, project, true],
	["rg 扫大目录的子目录(放行)", `rg TODO ${big}/d0`, undefined, project, false, 60],
	["find 扫大目录", `find ${big} -name "*.ts"`, undefined, project, true],
	["Get-ChildItem -Recurse 大目录", `Get-ChildItem -Recurse ${big}`, undefined, project, true],
	["ls -R 大目录", `ls -R ${big}`, undefined, project, true],
	["管道 rg 读 stdin(home 下也放行)", `cat build.log | rg error`, undefined, home, false],
	["非递归 grep 单文件(完全不管)", `grep foo file.txt`, undefined, home, false, undefined],
	["pattern 恰好很怪也能识别路径", `rg "weird.*pat(" ${big}`, undefined, project, true],
	["路径不存在(命令自己会失败,放行)", `grep -rn TODO missing_file.txt`, undefined, project, false, 60],

	// --- compound commands: cd + search ---
	["cd 大目录 && rg .", `cd ${big} && rg TODO .`, undefined, project, true],
	["换行分隔 cd/rg", `cd ${big}\nrg TODO .`, undefined, project, true],
	["分号分隔 cd/rg", `cd ${big}; rg TODO .`, undefined, project, true],
	["cd 大目录但搜绝对路径小子目录", `cd ${big} && rg TODO ${big}/d0`, undefined, project, false, 60],
	["cd 小子目录 && rg .", `cd ${big}/d0 && rg TODO .`, undefined, project, false, 60],
	["cd 不存在的目录(cd失败,cwd不变)", `cd no_such_dir_xyz && rg TODO .`, undefined, project, false, 60],
	["cd $未知变量 && rg . (无法跟踪)", `cd $NOPE_DIR && rg TODO .`, undefined, project, true],
	["cd 大目录 || exit; rg .", `cd ${big} || exit; rg TODO .`, undefined, project, true],
	["cd $HOME && rg (home很大)", `cd $HOME && rg TODO`, undefined, project, true],

	// --- nested shell wrappers ---
	["bash -c 套壳 cd+rg", `bash -c "cd ${big} && rg TODO ."`, undefined, project, true],
	["bash -c 套壳小目录", `bash -c "cd ${project} && rg TODO ./src"`, undefined, home, false, 60],
	["powershell -Command 大目录", `powershell -Command "Get-ChildItem -Recurse ${big}"`, undefined, project, true],

	// --- longer chains ---
	["cd 大目录后再 cd 小子目录", `cd ${big} && cd d0 && rg TODO .`, undefined, project, false, 60],
	["先做别的再继续 cd+grep", `echo prepare && cd ${big} && grep -r TODO .`, undefined, project, true],
];

let failed = 0;
for (const [desc, command, timeout, cwd, expectBlocked, expectTimeout] of cases) {
	const r = await run(command, timeout, cwd);
	const okTimeout =
		expectTimeout === undefined ? r.timeout === timeout : r.timeout === expectTimeout;
	const ok = r.blocked === expectBlocked && (expectBlocked || okTimeout);
	if (!ok) {
		failed++;
		console.log(`FAIL | ${desc}\n   cmd=${JSON.stringify(command)}\n   got blocked=${r.blocked} timeout=${r.timeout}`);
	} else {
		console.log(`PASS | ${desc}`);
	}
}

rmSync(base, { recursive: true, force: true });
console.log(failed === 0 ? `\nAll ${cases.length} passed` : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
