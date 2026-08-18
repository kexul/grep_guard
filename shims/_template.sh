#!/bin/bash
# search-guard PATH shim. Copied under the names: grep, egrep, fgrep, rg, ag, find.
# Catches invocations that bypass the shell functions (xargs, child processes).
# Probes the final argv, then execs the real binary.

self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
tool="${0##*/}"
tool="${tool%.exe}"

if [ -z "${SEARCH_GUARD_OFF:-}" ] && [ -z "${__SG_PROBED:-}" ] && command -v node >/dev/null 2>&1; then
	node "$self/probe.mjs" "$tool" "$@"
	rc=$?
	[ "$rc" -eq 1 ] && exit 1
fi
unset __SG_PROBED

# Locate the real binary, excluding this shim directory from PATH.
clean=""
oldifs="$IFS"
IFS=":"
for p in $PATH; do
	if [ -n "$p" ] && [ "$p" != "$self" ]; then
		clean="${clean:+$clean:}$p"
	fi
done
IFS="$oldifs"

# type -P finds external commands only (command -v would report the wrapper
# functions loaded via BASH_ENV, causing infinite recursion).
real="$(PATH="$clean" type -P "$tool" 2>/dev/null)"
if [ -z "$real" ]; then
	echo "search-guard: real '$tool' not found on PATH" >&2
	exit 127
fi
exec "$real" "$@"
