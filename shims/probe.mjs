#!/usr/bin/env node
/**
 * search-guard probe.
 *
 * Invoked by shell wrapper functions / PATH shims right before a recursive
 * search tool executes, with the tool's FINAL argv (after full shell
 * expansion). Decides whether the search roots are small enough.
 *
 *   node probe.mjs <grep|egrep|fgrep|rg|ag|find> <argv...>
 *
 * Exit codes: 0 = allowed, 1 = blocked (message on stderr),
 *             3 = could not decide (allow, fail-open).
 *
 * Env: SEARCH_GUARD_OFF=1 disables the guard,
 *      SEARCH_GUARD_ENTRY_CAP (default 15000),
 *      SEARCH_GUARD_TIME_BUDGET_MS (default 2000).
 */

import { readdirSync, statSync, readFileSync, writeFileSync } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

const CAP = Number(process.env.SEARCH_GUARD_ENTRY_CAP ?? 15_000);
const TIME_MS = Number(process.env.SEARCH_GUARD_TIME_BUDGET_MS ?? 2_000);
const TTL_MS = 30_000;
const CACHE_FILE = path.join(os.tmpdir(), "search-guard-probe-cache.json");

const tool = process.argv[2] ?? "";
const argv = process.argv.slice(3);

if (process.env.SEARCH_GUARD_OFF) process.exit(0);
if (argv.includes("--help") || argv.includes("--version")) process.exit(0);

/* ---------- probe with entry cap + time budget ---------- */

function probe(root) {
	let count = 0;
	let truncated = false;
	const started = Date.now();
	const queue = [root];

	while (queue.length > 0) {
		if (count > CAP || Date.now() - started > TIME_MS) {
			truncated = true;
			break;
		}
		const batch = queue.splice(0, 64);
		for (const dir of batch) {
			let entries;
			try {
				entries = readdirSync(dir, { withFileTypes: true });
			} catch {
				continue;
			}
			for (const e of entries) {
				count += 1;
				if (e.isDirectory()) queue.push(path.join(dir, e.name));
				if (count > CAP) {
					truncated = true;
					break;
				}
			}
			if (truncated) break;
		}
	}
	return { count, truncated };
}

/* ---------- tiny file cache (probe results, TTL 30s) ---------- */

function loadCache() {
	try {
		const data = JSON.parse(readFileSync(CACHE_FILE, "utf8"));
		const now = Date.now();
		const fresh = {};
		for (const [k, v] of Object.entries(data)) {
			if (typeof v?.t === "number" && now - v.t < TTL_MS) fresh[k] = v;
		}
		return fresh;
	} catch {
		return {};
	}
}

const cache = loadCache();

function probeCached(abs) {
	const key = abs.toLowerCase();
	const hit = cache[key];
	if (hit) return { count: hit.c ?? 0, truncated: !!hit.tr };
	const result = probe(abs);
	cache[key] = { t: Date.now(), c: result.count, tr: result.truncated };
	try {
		writeFileSync(CACHE_FILE, JSON.stringify(cache));
	} catch {
		/* best effort */
	}
	return result;
}

/* ---------- argv parsing per tool ---------- */

const LONG_VALUE_OPTS = {
	grep: new Set([
		"regexp", "file", "include", "exclude", "include-dir", "exclude-dir",
		"exclude-from", "label", "max-count", "binary-files", "directories",
		"devices", "context", "after-context", "before-context", "color", "colour",
	]),
	rg: new Set([
		"regexp", "file", "glob", "iglob", "type", "type-not", "max-count",
		"max-depth", "depth", "threads", "context", "after-context",
		"before-context", "max-columns", "pre", "pre-glob", "sort", "sortr",
		"engine", "max-filesize", "max-data-size", "max-buffer-size",
	]),
	ag: new Set(["ignore", "ignore-dir", "path-to-ignore", "file-search-regex", "pager", "color"]),
};

const SHORT_VALUE_OPTS = {
	grep: new Set(["e", "f", "m", "A", "B", "C", "d", "D"]),
	rg: new Set(["e", "f", "g", "j", "m", "M", "C", "A", "B", "d"]),
	ag: new Set(["A", "B", "C", "G", "g", "W"]),
};

function collectRoots(toolName, args) {
	if (toolName === "find") {
		const paths = [];
		for (const a of args) {
			if (/^-(H|L|P|D|O)/.test(a)) continue; // find's own leading options
			if (a.startsWith("-") || a.startsWith("!") || a.startsWith("(")) break;
			paths.push(a);
		}
		return paths.length > 0 ? paths : ["."];
	}

	const longValues = LONG_VALUE_OPTS[toolName] ?? LONG_VALUE_OPTS.grep;
	const shortValues = SHORT_VALUE_OPTS[toolName] ?? SHORT_VALUE_OPTS.grep;
	const paths = [];
	let patternProvidedSeparately = false; // saw -e/-f/--regexp/--file
	let patternSeen = false;

	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		if (a === "--") {
			paths.push(...args.slice(i + 1));
			break;
		}
		if (a.startsWith("--")) {
			const eq = a.indexOf("=");
			const name = eq >= 0 ? a.slice(2, eq) : a.slice(2);
			if (name === "regexp" || name === "file") patternProvidedSeparately = true;
			if (eq < 0 && longValues.has(name)) i += 1; // consume attached value
			continue;
		}
		if (a.startsWith("-") && a.length > 1) {
			const letters = a.slice(1);
			if (letters.includes("e") || letters.includes("f")) patternProvidedSeparately = true;
			const last = letters[letters.length - 1];
			if (shortValues.has(last)) i += 1; // consume option value
			continue;
		}
		if (!patternProvidedSeparately && !patternSeen) {
			patternSeen = true; // first positional is the search pattern
			continue;
		}
		paths.push(a);
	}
	return paths;
}

/* ---------- main ---------- */

function block(rawLabel, abs) {
	process.stderr.write(
		`[search-guard] Blocked: ${rawLabel} (resolved to ${abs}) holds more than ${CAP} entries; ` +
			`a recursive ${tool} here would take far too long.\n` +
			`  Fix: narrow the path (e.g. ${tool} <pattern> ./specific/subdir), ` +
			`add exclusions (rg -g '!node_modules'), or inspect the tree first (ls/fd).\n` +
			`  One-shot bypass if truly intended: SEARCH_GUARD_OFF=1 ${tool} ...\n`,
	);
	process.exit(1);
}

try {
	let roots = collectRoots(tool, argv);

	// No paths: rg/ag read stdin when it is piped (no disk scan => allow).
	// grep/find always fall back to "." regardless of stdin.
	if (roots.length === 0) {
		if ((tool === "rg" || tool === "ag") && !process.stdin.isTTY) process.exit(0);
		roots = ["."];
	}

	const seen = new Set();
	for (const raw of roots) {
		if (raw === "-") continue; // stdin marker
		if (seen.has(raw)) continue;
		seen.add(raw);

		const expanded = raw === "~" ? os.homedir()
			: raw.startsWith("~/") ? path.join(os.homedir(), raw.slice(2))
			: raw;
		const abs = path.resolve(expanded);

		let stat;
		try {
			stat = statSync(abs);
		} catch {
			continue; // missing path: the command fails on its own, no hang risk
		}
		if (!stat.isDirectory()) continue; // single files are fine

		const { truncated } = probeCached(abs);
		if (truncated) block(`"${raw}"`, abs);
	}
	process.exit(0);
} catch (err) {
	process.stderr.write(`[search-guard] probe error: ${err?.message ?? err}\n`);
	process.exit(3); // fail-open
}
