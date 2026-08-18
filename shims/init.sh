# search-guard init — loaded automatically via BASH_ENV (set by the pi
# search-guard extension) before every non-interactive bash command.
#
# Defines wrapper functions for recursive search tools. The shell has already
# expanded variables/globs/quotes by the time these run, so the probe sees the
# final arguments. Keep this file fast and side-effect free (no output!).
#
# Additionally, grep/egrep/fgrep invocations are transparently translated into
# equivalent rg invocations (~50-100x faster on Windows). Anything that cannot
# be translated faithfully falls back to the real grep. Disable with
# SEARCH_GUARD_GREP_AS_RG=0.

if [ -z "${__SG_LOADED:-}" ]; then
	__SG_LOADED=1
	__sg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
	__sg_probe="$__sg_dir/probe.mjs"
	__sg_rg_path=""

	# Build a PATH without the shim dir once (cheap string ops). Real binaries
	# are resolved against this clean PATH, so searches never re-enter shims.
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

	__sg_has_bre_escape() {
		# Return 0 if the pattern cannot be mapped to rg's regex faithfully.
		# Covers BRE escapes (\{ \} \( \) \| \+ \? \1-9 \n \t ...) AND chars
		# that are literal in BRE but metacharacters in rg: ( ) { } | + ?
		local p="$1" s
		for s in '\(' '\)' '\{' '\}' '\|' '\+' '\?' '(' ')' '{' '}' '|' '+' '?'; do
			[[ "$p" == *"$s"* ]] && return 0
		done
		for s in 0 1 2 3 4 5 6 7 8 9 n t r f v a e x c; do
			[[ "$p" == *"\\$s"* ]] && return 0
		done
		return 1
	}

	__sg_find_rg() {
		[ -n "$__sg_rg_path" ] && return 0
		__sg_rg_path="$(PATH="$__sg_clean_path" type -P rg 2>/dev/null)"
		[ -n "$__sg_rg_path" ]
	}

	# Translate grep-style argv into rg argv (result in __sg_rg_args).
	# Returns 1 on any construct rg cannot reproduce, so the caller can fall
	# back to the real grep.
	__sg_grep_to_rg() {
		local flavor="$1"
		shift
		local -a args=() paths=() e_patterns=()
		local fixed=0 pcre=0 has_pattern=0 pattern="" a i ch
		local recurse=0 fn_explicit=0 count_flag=0 ere=0

		[ "$flavor" = "fgrep" ] && fixed=1

		while [ $# -gt 0 ]; do
			a="$1"
			shift
			case "$a" in
			--)
				if [ $has_pattern -eq 0 ] && [ $# -gt 0 ]; then
					pattern="$1"
					has_pattern=1
					shift
				fi
				while [ $# -gt 0 ]; do
					paths+=("$1")
					shift
				done
				;;
			-e)
				e_patterns+=("$1")
				has_pattern=1
				shift
				;;
			-f)
				# grep -f reads patterns as BRE; rg -f as regex. Only safe for fgrep -f.
				[ "$flavor" = "fgrep" ] || return 1
				args+=(-f "$1")
				has_pattern=1
				shift
				;;
			-m[0-9]*) args+=(-m "${a#-m}") ;;
			-A[0-9]*) args+=(-A "${a#-A}") ;;
			-B[0-9]*) args+=(-B "${a#-B}") ;;
			-C[0-9]*) args+=(-C "${a#-C}") ;;
			--recursive)
				recurse=1 ;; # rg recurses by default
			--ignore-case) args+=(-i) ;;
			--word-regexp) args+=(-w) ;;
			--line-number) args+=(-n) ;;
			--no-filename)
				args+=(-I)
				fn_explicit=1 ;;
			--with-filename)
				args+=(-H)
				fn_explicit=1 ;;
			--files-with-matches) args+=(-l) ;;
			--files-without-match) return 1 ;; # -L exit codes differ between grep/rg
			--count)
				args+=(-c)
				count_flag=1
				;;
			--invert-match) args+=(-v) ;;
			--line-regexp) args+=(-x) ;;
			--only-matching) args+=(-o) ;;
			--quiet | --silent) args+=(-q) ;;
			--no-messages) args+=(--no-messages) ;;
			--text) args+=(-a) ;;
			--fixed-strings) fixed=1 ;;
			--extended-regexp) ere=1 ;; # rg's default regex covers ERE
			--perl-regexp) pcre=1 ;;
			--regexp)
				e_patterns+=("$1")
				has_pattern=1
				shift
				;;
			--file)
				[ "$flavor" = "fgrep" ] || return 1
				args+=(-f "$1")
				has_pattern=1
				shift
				;;
			--max-count)
				args+=(-m "$1")
				shift
				;;
			--after-context)
				args+=(-A "$1")
				shift
				;;
			--before-context)
				args+=(-B "$1")
				shift
				;;
			--context)
				args+=(-C "$1")
				shift
				;;
			--color | --colour)
				case "$1" in
				never | always | auto) args+=(--color "$1") ;;
				*) return 1 ;;
				esac
				shift
				;;
			--color=* | --colour=*) args+=(--color "${a#*=}") ;;
			--max-count=*) args+=(-m "${a#*=}") ;;
			--after-context=*) args+=(-A "${a#*=}") ;;
			--before-context=*) args+=(-B "${a#*=}") ;;
			--context=*) args+=(-C "${a#*=}") ;;
			--include=*) args+=(-g "${a#*=}") ;;
			--exclude=*) args+=(-g "!${a#*=}") ;;
			--exclude-dir=*) args+=(-g "!${a#*=}/") ;;
			--binary-files=text) args+=(-a) ;;
			-[a-zA-Z0-9]*)
				# Short flag cluster (e.g. -rin): re-dispatch each letter.
				local expanded=0
				local -a singles=()
				for ((i = 1; i < ${#a}; i++)); do
					ch="${a:i:1}"
					case "$ch" in
					r | R) recurse=1 ;;
					i) singles+=(-i) ;;
					w) singles+=(-w) ;;
					n) singles+=(-n) ;;
					H)
						singles+=(-H)
						fn_explicit=1 ;;
					h)
						singles+=(-I)
						fn_explicit=1 ;;
					l) singles+=(-l) ;;
					L) return 1 ;; # -L exit codes differ between grep/rg; use real grep
					c)
						singles+=(-c)
						count_flag=1 ;;
					v) singles+=(-v) ;;
					x) singles+=(-x) ;;
					o) singles+=(-o) ;;
					q) singles+=(-q) ;;
					s) singles+=(--no-messages) ;;
					a) singles+=(-a) ;;
					F) fixed=1 ;;
					E) ere=1 ;;
					P) pcre=1 ;;
					Z | 0) singles+=(-0) ;;
					*) expanded=1 ;; # unknown letter: bail
					esac
				done
				[ $expanded -eq 1 ] && return 1
				args+=("${singles[@]:+${singles[@]}}")
				;;
			-*)
				return 1 # unsupported flag
				;;
			*)
				if [ $has_pattern -eq 0 ]; then
					pattern="$a"
					has_pattern=1
				else
					paths+=("$a")
				fi
				;;
			esac
		done

		[ $has_pattern -eq 0 ] && return 1
		__sg_find_rg || return 1

		# GNU grep's default mode is BRE, rg has no BRE mode. Some escape
		# sequences mean different things (\{ \} \( \) \| \+ \? \1-9 \n \t ...):
		# bail so the real grep handles them. (ERE/-P/-F modes are compatible.)
		if [ $fixed -eq 0 ] && [ $pcre -eq 0 ] && [ "$flavor" = "grep" ] && [ $ere -eq 0 ]; then
			if __sg_has_bre_escape "$pattern"; then
				return 1
			fi
			for __sg_p in "${e_patterns[@]:+${e_patterns[@]}}"; do
				if __sg_has_bre_escape "$__sg_p"; then
					return 1
				fi
			done
		fi

		# --no-config: user's ripgrep config (e.g. default --type filters) must
		# not change grep semantics. grep -r walks hidden dirs and ignores
		# .gitignore; keep that behavior too.
		# '//' because MSYS may convert '/' into a Windows path.
		local -a final=(--no-config --no-heading --color never --hidden --no-ignore --path-separator //)
		[ $fixed -eq 1 ] && final+=(--fixed-strings)
		[ $pcre -eq 1 ] && final+=(--pcre2)
		# grep filename rules: names shown for >=2 files or recursion; a single
		# explicit file prints matches alone. Mimic it.
		if [ $fn_explicit -eq 0 ]; then
			if [ $recurse -eq 1 ] || [ ${#paths[@]} -ge 2 ]; then
				final+=(-H)
			elif [ ${#paths[@]} -eq 1 ]; then
				if [ -d "${paths[0]}" ]; then
					final+=(-H) # directory operand = directory search, shows names
				else
					final+=(-I) # bare grep on one file prints matches alone
				fi
			fi
		fi
		final+=("${args[@]:+${args[@]}}")
		[ $count_flag -eq 1 ] && [ ${#paths[@]} -gt 0 ] && final+=(--include-zero)
		if [ ${#e_patterns[@]} -gt 0 ]; then
			[ -n "$pattern" ] && e_patterns=("$pattern" "${e_patterns[@]}")
			for __sg_p in "${e_patterns[@]}"; do
				final+=(-e "$__sg_p")
			done
		elif [ -n "$pattern" ]; then
			final+=(-e "$pattern")
		fi
		final+=("${paths[@]:+${paths[@]}}")
		__sg_rg_args=("${final[@]}")
		return 0
	}

	__sg_run_grep() {
		# $1 = flavor (grep|egrep|fgrep), rest = argv. Guard already ran.
		local flavor="$1"
		shift
		if [ "${SEARCH_GUARD_GREP_AS_RG:-1}" != "0" ] && __sg_grep_to_rg "$flavor" "$@"; then
			__SG_PROBED=1 command "$__sg_rg_path" "${__sg_rg_args[@]}"
			return $?
		fi
		__SG_PROBED=1 PATH="$__sg_clean_path" command "$flavor" "$@"
	}

	grep() {
		if __sg_active && __sg_is_recursive_grep "$@"; then
			__sg_check grep "$@" || return 1
		fi
		__sg_run_grep grep "$@"
	}

	egrep() {
		if __sg_active && __sg_is_recursive_grep "$@"; then
			__sg_check egrep "$@" || return 1
		fi
		__sg_run_grep egrep "$@"
	}

	fgrep() {
		if __sg_active && __sg_is_recursive_grep "$@"; then
			__sg_check fgrep "$@" || return 1
		fi
		__sg_run_grep fgrep "$@"
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
