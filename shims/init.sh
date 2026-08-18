# search-guard init — loaded automatically via BASH_ENV (set by the pi
# search-guard extension) before every non-interactive bash command.
#
# Defines wrapper functions for recursive search tools. The shell has already
# expanded variables/globs/quotes by the time these run, so the probe sees the
# final arguments. Keep this file fast and side-effect free (no output!).

if [ -z "${__SG_LOADED:-}" ]; then
	__SG_LOADED=1
	__sg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
	__sg_probe="$__sg_dir/probe.mjs"

	# Build a PATH without the shim dir once (cheap string ops). Real binaries
	# are resolved lazily via normal lookup against this clean PATH, so shells
	# that never search pay almost nothing.
	__sg_clean_path=""
	__sg_oldifs="$IFS"
	IFS=":"
	for __sg_p in $PATH; do
		if [ -n "$__sg_p" ] && [ "$__sg_p" != "$__sg_dir" ]; then
			__sg_clean_path="${__sg_clean_path:+$__sg_clean_path:}$__sg_p"
		fi
	done
	IFS="$__sg_oldifs"

	__sg_active() {
		[ -z "${SEARCH_GUARD_OFF:-}" ] &&
			[ -f "$__sg_probe" ] &&
			command -v node >/dev/null 2>&1
	}

	__sg_check() {
		# $1 = tool name, rest = original argv. Return 1 to block.
		node "$__sg_probe" "$@"
		[ $? -eq 1 ] && return 1
		return 0
	}

	__sg_is_recursive_grep() {
		local a
		for a in "$@"; do
			case "$a" in
			--recursive)
				return 0
				;;
			--*) ;;
			-*)
				case "$a" in
				*[rR]*) return 0 ;;
				esac
				;;
			esac
		done
		return 1
	}

	grep() {
		if __sg_active && __sg_is_recursive_grep "$@"; then
			__sg_check grep "$@" || return 1
		fi
		__SG_PROBED=1 PATH="$__sg_clean_path" command grep "$@"
	}

	egrep() {
		if __sg_active && __sg_is_recursive_grep "$@"; then
			__sg_check egrep "$@" || return 1
		fi
		__SG_PROBED=1 PATH="$__sg_clean_path" command egrep "$@"
	}

	fgrep() {
		if __sg_active && __sg_is_recursive_grep "$@"; then
			__sg_check fgrep "$@" || return 1
		fi
		__SG_PROBED=1 PATH="$__sg_clean_path" command fgrep "$@"
	}

	rg() {
		if __sg_active; then
			__sg_check rg "$@" || return 1
		fi
		__SG_PROBED=1 PATH="$__sg_clean_path" command rg "$@"
	}

	ag() {
		if __sg_active; then
			__sg_check ag "$@" || return 1
		fi
		__SG_PROBED=1 PATH="$__sg_clean_path" command ag "$@"
	}

	find() {
		if __sg_active; then
			__sg_check find "$@" || return 1
		fi
		__SG_PROBED=1 PATH="$__sg_clean_path" command find "$@"
	}
fi
