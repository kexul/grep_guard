/**
 * Search Guard
 *
 * Guards recursive searches (grep -r / rg / find / ls -R / Get-ChildItem -Recurse ...).
 * Instead of hardcoding "big directories", it probes each search root at runtime:
 * walks the tree up to an entry cap / time budget. If the root holds too many
 * entries, the command is blocked and the agent is told to narrow the scope.
 * Small directories pass through untouched.
 *
 * Compound commands are handled: statements are split on ; \n && ||, `cd` is
 * tracked sequentially, and `bash -c "..."` style wrappers are unwrapped
 * recursively.
 *
 * Tune via env: SEARCH_GUARD_ENTRY_CAP (default 15000),
 * SEARCH_GUARD_TIME_BUDGET_MS (default 2000),
 * SEARCH_GUARD_SHIM_DIR (default ~/.pi/agent/shims),
 * SEARCH_GUARD_OFF=1 disables everything.
 */

import { promises as fs } from "node:fs";
import * as path from "node:path";
import { homedir } from "node:os";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";

// Commands that search recursively.
const SEARCH_PATTERNS: RegExp[] = [
	/\b(?:grep|egrep|fgrep)(?:\.exe)?\b[^|;&]*?(?:\s-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)/i,
	/\b(?:rg|ripgrep|ag)(?:\.exe)?\b/i,
	/\bfind(?:\.exe)?\s/,
	/Get-ChildItem[^|;&]*-Recurse/i,
	/\b(?:gci|dir|ls)\b[^|;&]*(?:\s-R(?:\s|$)|-Recurse\b|\s\/s\b)/i,
];

// Tools whose first positional argument is the search pattern, not a path.
const PATTERN_FIRST_RE = /\b(?:grep|egrep|fgrep|rg|ripgrep|ag)(?:\.exe)?\b/i;
const FIND_RE = /\bfind(?:\.exe)?\s/;

const COMMAND_WORDS = new Set([
	"grep", "egrep", "fgrep", "rg", "ripgrep", "ag", "find",
	"gci", "dir", "ls", "get-childitem",
	"grep.exe", "rg.exe", "find.exe", "ls.exe", "dir.exe",
]);

// `cd` variants (bash + PowerShell).
const CD_RE = /^\s*(?:cd|pushd|chdir|set-location|sl)\b(.*)$/i;

// Wrappers that run another shell: bash -c "...", cmd /c "...", powershell -Command "..."
const WRAPPER_RE =
	/^\s*(?:bash|sh|zsh|dash|cmd|pwsh|powershell)(?:\.exe)?\s+(?:[^ ]+\s+)*?(?:-c|-C|--command|-Command|\/[cC])\s+(.*)$/is;

/* ---------- precise interception layer ----------
 * Static command parsing is heuristic; the definitive guard runs at exec time:
 * - BASH_ENV sources shims/init.sh into every non-interactive bash, defining
 *   wrapper functions that probe the FINAL argv before grep/rg/find run.
 * - PATH is prefixed with the shim dir so xargs / child processes hit the
 *   shims (which probe, then exec the real binary).
 */
const SHIM_DIR =
	process.env.SEARCH_GUARD_SHIM_DIR ??
	path.join(homedir(), ".pi", "agent", "shims");

function toPosix(p: string): string {
	return p
		.replace(/\\/g, "/")
		.replace(/^([A-Za-z]):/, (_m, d: string) => `/${d.toLowerCase()}`);
}

const SHIM_DIR_POSIX = toPosix(SHIM_DIR);
const PATH_PREFIX = `PATH="${SHIM_DIR_POSIX}:$PATH"; `;

const ENTRY_CAP = Number(process.env.SEARCH_GUARD_ENTRY_CAP ?? 15_000);
const TIME_BUDGET_MS = Number(process.env.SEARCH_GUARD_TIME_BUDGET_MS ?? 2_000);
const DEFAULT_TIMEOUT_SECONDS = 60;
const CACHE_TTL_MS = 30_000;

interface ProbeResult {
	count: number;
	truncated: boolean;
}

const probeCache = new Map<string, { at: number; result: ProbeResult }>();

/**
 * Count entries under `root`, stopping as soon as ENTRY_CAP or the time
 * budget is exceeded. Never follows symlinks. Result is cached briefly.
 */
async function probe(root: string): Promise<ProbeResult> {
	const cached = probeCache.get(root);
	if (cached && Date.now() - cached.at < CACHE_TTL_MS) return cached.result;

	let count = 0;
	let truncated = false;
	const started = Date.now();
	const queue: string[] = [root];

	while (queue.length > 0) {
		if (count > ENTRY_CAP || Date.now() - started > TIME_BUDGET_MS) {
			truncated = true;
			break;
		}
		const batch = queue.splice(0, 64);
		const listings = await Promise.all(
			batch.map((dir) =>
				fs.readdir(dir, { withFileTypes: true }).catch(() => []),
			),
		);
		for (let i = 0; i < listings.length; i++) {
			for (const entry of listings[i] ?? []) {
				count += 1;
				if (entry.isDirectory()) {
					queue.push(path.join(batch[i]!, entry.name));
				}
				if (count > ENTRY_CAP) {
					truncated = true;
					break;
				}
			}
			if (truncated) break;
		}
	}

	const result: ProbeResult = { count, truncated };
	probeCache.set(root, { at: Date.now(), result });
	return result;
}

function stripQuotes(s: string): string {
	return s.replace(/^["']|["']$/g, "");
}

/** Expand ~ / $HOME / %USERPROFILE% and resolve against cwd. Null if the
 * token contains an unresolvable variable. */
function expandToken(token: string, cwd: string): { abs: string; rel: boolean } | null {
	const home = homedir();
	let t = token;
	let rel = true;
	if (t === "~") return { abs: home, rel: false };
	if (t.startsWith("~/")) t = path.join(home, t.slice(2)), (rel = false);
	else {
		t = t.replace(/^\$HOME\b(?=[/\\]|$)/, home).replace(/^%USERPROFILE%(?=[/\\]|$)/i, home);
		if (/^[a-zA-Z]:/.test(t) || t.startsWith("/")) rel = false;
		if (/\$[A-Za-z_{]|%[A-Za-z_]+%/.test(t)) return null; // unknown variable
	}
	return { abs: path.resolve(cwd, t), rel };
}

interface Candidate {
	raw: string;
	abs: string;
	rel: boolean; // resolution depended on the working directory
}

/** Extract search-root candidates from one command fragment. */
function collectCandidates(
	fragment: string,
	cwd: string,
	isFind: boolean,
	patternFirst: boolean,
): Candidate[] {
	const tokens = fragment.match(/"[^"]*"|'[^']*'|\S+/g) ?? [];
	const candidates: Candidate[] = [];

	let commandSeen = false;
	let sawOption = false;
	let patternSkipped = false;

	for (const rawToken of tokens) {
		const t = stripQuotes(rawToken);
		if (/^[<>()$`]+$/.test(t)) continue;

		// Skip the command word itself (once), e.g. "rg", "find", "Get-ChildItem".
		if (!commandSeen) {
			commandSeen = true;
			if (COMMAND_WORDS.has(t.toLowerCase())) continue;
			// first non-command token is a path; fall through
		}

		if (t.startsWith("-")) {
			sawOption = true;
			continue;
		}
		// find: everything after options are expressions (-name ...), not paths.
		if (isFind && (sawOption || t.startsWith("!") || t.startsWith("("))) continue;
		// grep/rg: first positional argument is the pattern.
		if (patternFirst && !patternSkipped) {
			patternSkipped = true;
			continue;
		}

		const expanded = expandToken(t, cwd);
		if (!expanded) continue; // contains an unknown $VAR etc.; bail for this token
		candidates.push({ raw: t, abs: expanded.abs, rel: expanded.rel });
	}
	return candidates;
}

function blockMessage(label: string, root: string): string {
	return (
		`Blocked: search root ${label} (resolved to ${root}) contains more than ` +
		`${ENTRY_CAP} files/directories; a recursive search here would hang for a long time. ` +
		`Narrow the scope: search a specific subdirectory or file (e.g. rg "pattern" ./src/foo), ` +
		`exclude junk (rg -g '!node_modules'), or inspect the tree first with ls / fd. ` +
		`If you cannot locate the right subdirectory, ask the user.`
	);
}

const UNKNOWN_CWD_MESSAGE =
	"Blocked: this command changes directory to a location I cannot track (a variable like $VAR, " +
	"or `cd -`), so I cannot tell how large the search root is. Run the search as a separate command " +
	"using an explicit absolute path, or echo the directory first.";

async function checkCandidates(
	candidates: Candidate[],
	cwd: string,
	cwdKnown: boolean,
): Promise<string | null> {
	// No explicit paths: the search defaults to the working directory.
	if (candidates.length === 0) {
		if (!cwdKnown) return UNKNOWN_CWD_MESSAGE;
		const { truncated } = await probe(cwd);
		return truncated ? blockMessage("the current working directory", cwd) : null;
	}

	for (const c of candidates) {
		if (c.rel && !cwdKnown) return UNKNOWN_CWD_MESSAGE;
		let stat;
		try {
			stat = await fs.stat(c.abs);
		} catch {
			continue; // does not exist: command will fail on its own, no hang risk
		}
		if (!stat.isDirectory()) continue; // single files are fine

		const { truncated } = await probe(c.abs);
		if (truncated) return blockMessage(`"${c.raw}"`, c.abs);
	}
	return null;
}

/** Parse a `cd` statement. Returns the new cwd, whether it is unresolvable,
 * or a noop (target missing / not a directory => cd fails, cwd unchanged). */
async function parseCd(
	rest: string,
	cwd: string,
): Promise<{ cwd: string } | { unresolved: true } | { noop: true }> {
	const tokens = rest.match(/"[^"]*"|'[^']*'|\S+/g) ?? [];
	let target: string | undefined;
	for (const raw of tokens) {
		const t = stripQuotes(raw);
		if (t.startsWith("-")) continue;
		target = t;
		break;
	}
	if (target === undefined) return { cwd: homedir() }; // bare `cd` -> home
	if (target === "-") return { unresolved: true };

	const expanded = expandToken(target, cwd);
	if (!expanded) return { unresolved: true };
	try {
		const stat = await fs.stat(expanded.abs);
		if (!stat.isDirectory()) return { noop: true }; // cd would fail
	} catch {
		return { noop: true };
	}
	return { cwd: expanded.abs };
}

/** Scan a command string; returns a block reason if one applies, and the
 * final tracked working directory. */
async function scanCommand(
	command: string,
	startCwd: string,
	depth = 0,
): Promise<{ block?: string; cwd: string; isSearch: boolean }> {
	let cwd = startCwd;
	let cwdKnown = true;
	let isSearch = false;

	if (depth > 3) return { block: UNKNOWN_CWD_MESSAGE, cwd, isSearch };

	// Split into statements; only the first pipe stage touches the filesystem.
	for (const segment of command.split(/[\n;]|\&\&|\|\|/)) {
		const stage = segment.split("|")[0] ?? "";

		// Unwrap nested shells: bash -c "...", cmd /c "...", powershell -Command "..."
		const wrapper = stage.match(WRAPPER_RE);
		if (wrapper) {
			const payload = stripQuotes(wrapper[1]!.trim());
			const inner = await scanCommand(payload, cwd, depth + 1);
			if (inner.block) return { block: inner.block, cwd: inner.cwd, isSearch: true };
			cwd = inner.cwd;
			continue;
		}

		// Track cd/pushd/Set-Location so relative paths resolve correctly.
		const cd = stage.match(CD_RE);
		if (cd) {
			const parsed = await parseCd(cd[1]!, cwd);
			if ("unresolved" in parsed) cwdKnown = false;
			else if ("cwd" in parsed) {
				cwd = parsed.cwd;
				cwdKnown = true;
			}
			// noop: cd fails, cwd unchanged
			continue;
		}

		if (!SEARCH_PATTERNS.some((re) => re.test(stage))) continue;
		isSearch = true;

		const candidates = collectCandidates(
			stage.trim(),
			cwd,
			FIND_RE.test(stage),
			PATTERN_FIRST_RE.test(stage),
		);
		const reason = await checkCandidates(candidates, cwd, cwdKnown);
		if (reason) return { block: reason, cwd, isSearch };
	}

	return { cwd, isSearch };
}

export default function (pi: ExtensionAPI) {
	// Load the precise guard (bash wrapper functions) into every bash instance.
	process.env.BASH_ENV = `${SHIM_DIR_POSIX}/init.sh`;

	pi.on("tool_call", async (event, ctx) => {
		if (
			!isToolCallEventType<"bash", { command: string; timeout?: number }>(
				"bash",
				event,
			)
		) {
			return;
		}
		const command0 = event.input.command ?? "";

		// Put the shim dir first on PATH (ahead of pi's own bin dir) so
		// xargs / child processes are intercepted too.
		const command = command0.includes(SHIM_DIR_POSIX)
			? command0
			: PATH_PREFIX + command0;
		event.input.command = command;

		const result = await scanCommand(command, ctx.cwd);
		if (result.block) return { block: true, reason: result.block };

		// Fallback: never let a recursive search run without a timeout.
		if (result.isSearch && event.input.timeout === undefined) {
			event.input.timeout = DEFAULT_TIMEOUT_SECONDS;
			ctx.ui.notify(
				`Recursive search: injected default timeout (${DEFAULT_TIMEOUT_SECONDS}s)`,
				"info",
			);
		}
	});
}
