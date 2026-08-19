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
		local o_flag=0 v_flag=0 w_flag=0 x_flag=0 globs_present=0 l_flag=0
		local ctx_flag=0
		local -a xdir_globs=()

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
			-A[0-9]*)
				args+=(-A "${a#-A}")
				ctx_flag=1 ;;
			-B[0-9]*)
				args+=(-B "${a#-B}")
				ctx_flag=1 ;;
			-C[0-9]*)
				args+=(-C "${a#-C}")
				ctx_flag=1 ;;
			--recursive)
				recurse=1 ;; # rg recurses by default
			--ignore-case) args+=(-i) ;;
			--word-regexp)
				args+=(-w)
				w_flag=1 ;;
			--line-number) args+=(-n) ;;
			--no-filename)
				args+=(-I)
				fn_explicit=1 ;;
			--with-filename)
				args+=(-H)
				fn_explicit=1 ;;
			--files-with-matches)
				args+=(-l)
				l_flag=1 ;;
			--files-without-match) return 1 ;; # -L exit codes differ between grep/rg
			--count)
				args+=(-c)
				count_flag=1
				;;
			--invert-match)
				args+=(-v)
				v_flag=1 ;;
			--line-regexp)
				args+=(-x)
				x_flag=1 ;;
			--only-matching)
				args+=(-o)
				o_flag=1 ;;
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
				ctx_flag=1
				shift
				;;
			--before-context)
				args+=(-B "$1")
				ctx_flag=1
				shift
				;;
			--context)
				args+=(-C "$1")
				ctx_flag=1
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
			--after-context=*)
				args+=(-A "${a#*=}")
				ctx_flag=1 ;;
			--before-context=*)
				args+=(-B "${a#*=}")
				ctx_flag=1 ;;
			--context=*)
				args+=(-C "${a#*=}")
				ctx_flag=1 ;;
			--include=*)
				args+=(-g "${a#*=}")
				globs_present=1 ;;
			--exclude=*)
				args+=(-g "!${a#*=}")
				globs_present=1 ;;
			--exclude-dir=*)
				args+=(-g "!${a#*=}/")
				xdir_globs+=("${a#*=}")
				globs_present=1 ;;
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
					w)
						singles+=(-w)
						w_flag=1 ;;
					n) singles+=(-n) ;;
					H)
						singles+=(-H)
						fn_explicit=1 ;;
					h)
						singles+=(-I)
						fn_explicit=1 ;;
					l)
						singles+=(-l)
						l_flag=1 ;;
					L) return 1 ;; # -L exit codes differ between grep/rg; use real grep
					c)
						singles+=(-c)
						count_flag=1 ;;
					v)
						singles+=(-v)
						v_flag=1 ;;
					x)
						singles+=(-x)
						x_flag=1 ;;
					o)
						singles+=(-o)
						o_flag=1 ;;
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

		# Flag combinations whose combined semantics differ between grep and rg.
		local __sg_modes=$((fixed + ere + pcre))
		[ $__sg_modes -gt 1 ] && return 1                # -F/-E/-P conflict
		[ $o_flag -eq 1 ] && { [ $count_flag -eq 1 ] || [ $v_flag -eq 1 ]; } && return 1 # -o+-c, -o+-v
		[ $x_flag -eq 1 ] && [ $w_flag -eq 1 ] && return 1 # rg ORs them, grep ANDs
		[ $l_flag -eq 1 ] && [ $count_flag -eq 1 ] && return 1 # grep: -l wins; rg: -c wins
		[ $o_flag -eq 1 ] && [ $ctx_flag -eq 1 ] && return 1  # grep ignores ctx with -o
		# rg ignores -g globs for explicit FILE operands; grep's --include/
		# --exclude apply to them. Bail when any operand is a non-directory.
		if [ $globs_present -eq 1 ]; then
			for __sg_p in "${paths[@]:+${paths[@]}}"; do
				[ -d "$__sg_p" ] || return 1
			done
		fi
		# grep --exclude-dir also skips a matching directory given as an
		# operand; rg would still search it. Bail in that case.
		if [ ${#xdir_globs[@]} -gt 0 ]; then
			for __sg_p in "${paths[@]:+${paths[@]}}"; do
				[ -d "$__sg_p" ] || continue
				__sg_base="${__sg_p%/}"
				__sg_base="${__sg_base##*/}"
				[ -n "$__sg_base" ] || __sg_base="."
				for __sg_g in "${xdir_globs[@]}"; do
					# shellcheck disable=SC2254
					case "$__sg_base" in
					$__sg_g) return 1 ;;
					esac
				done
			done
		fi

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
		# Directory operand without -r: real grep errors ("Is a directory"),
		# so bail instead of silently changing semantics.
		if [ $recurse -eq 0 ]; then
			for __sg_p in "${paths[@]:+${paths[@]}}"; do
				[ -d "$__sg_p" ] && return 1
			done
		fi
		# grep filename rules: names shown for >=2 files or recursion; a single
		# explicit file prints matches alone. Mimic it.
		if [ $fn_explicit -eq 0 ]; then
			if [ $recurse -eq 1 ] || [ ${#paths[@]} -ge 2 ]; then
				final+=(-H)
			elif [ ${#paths[@]} -eq 1 ]; then
				final+=(-I) # single non-recursive file prints matches alone
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

	__sg_strict_ok() {
		# Minimal-core whitelist for SEARCH_GUARD_GREP_AS_RG=strict: only flag
		# combinations whose equivalence can be argued case by case, a pattern
		# restricted to a safe charset, and existing targets.
		local flavor="$1"
		shift
		local pat_count=0 p rest
		local re='^[A-Za-z0-9 _.,:;@%+=/^$*-]+$'
		for p in "$@"; do
			case "$p" in
			--) ;;
			-r | -R | -i | -n | -l | -w | -H | -h | --recursive | --ignore-case | \
				--line-number | --files-with-matches | --word-regexp | \
				--with-filename | --no-filename) ;;
			-*)
				# clusters built only from whitelisted letters (e.g. -rin)
				rest="${p#-}"
				[[ "$rest" =~ ^[rinwlhH]+$ ]] || return 1
				;;
			*)
				if [ $pat_count -eq 0 ]; then
					pat_count=1
					[[ "$p" =~ $re ]] || return 1
				else
					[ -e "$p" ] || return 1
				fi
				;;
			esac
		done
		[ $pat_count -eq 1 ] || return 1
		return 0
	}

	__sg_run_grep() {
		# $1 = flavor (grep|egrep|fgrep), rest = argv. Guard already ran.
		local flavor="$1"
		shift
		local mode="${SEARCH_GUARD_GREP_AS_RG:-1}" translate=0
		case "$mode" in
		0) translate=0 ;;
		strict) __sg_strict_ok "$flavor" "$@" && translate=1 ;;
		*) translate=1 ;;
		esac
		if [ $translate -eq 1 ] && __sg_grep_to_rg "$flavor" "$@"; then
			[ -n "${SEARCH_GUARD_DEBUG:-}" ] &&
				echo "[search-guard] translated to: $__sg_rg_path ${__sg_rg_args[*]}" >&2
			__SG_PROBED=1 command "$__sg_rg_path" "${__sg_rg_args[@]}"
			return $?
		fi
		[ -n "${SEARCH_GUARD_DEBUG:-}" ] &&
			echo "[search-guard] fallback to real $flavor" >&2
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

	__sg_find_to_rg() {
		# Translate find -> rg --files (same order-of-magnitude speedup as the
		# grep mapping). Only the file-enumeration subset is translatable:
		# rg --files lists files, so -type f is required; -exec/-mtime/-size/...
		# bail immediately.
		local -a roots=() sglobs=() iglobs=()
		local have_type_f=0 null_out=0 expr_started=0 a g
		local maxdepth=""
		while [ $# -gt 0 ]; do
			a="$1"
			shift
			if [ $expr_started -eq 0 ]; then
				case "$a" in
				-P) continue ;; # default: don't follow symlinks
				-H | -L | -D* | -O*) return 1 ;;
				-*) expr_started=1 ;; # fall through to expression handling
				*)
					roots+=("$a")
					continue ;;
				esac
			fi
			case "$a" in
			-name)
				sglobs+=("$1")
				shift ;;
			-iname)
				iglobs+=("$1")
				shift ;;
			-o) ;; # rg combines globs with OR anyway
			-type)
				[ "$1" = "f" ] || return 1
				have_type_f=1
				shift ;;
			-maxdepth)
				maxdepth="$1"
				shift ;;
			-print) ;; # the default action
			-print0) null_out=1 ;;
			-depth) ;; # traversal order only; output set identical
			*) return 1 ;;
			esac
		done

		[ $have_type_f -eq 1 ] || return 1 # rg --files cannot match directories
		[ ${#roots[@]} -gt 0 ] || return 1
		__sg_find_rg || return 1
		for a in "${roots[@]}"; do
			[ -e "$a" ] || return 1 # keep find's exact error behavior
		done

		local -a final=(--no-config --files --hidden --no-ignore --path-separator //)
		for g in "${sglobs[@]:+${sglobs[@]}}"; do
			final+=(-g "$g")
		done
		for g in "${iglobs[@]:+${iglobs[@]}}"; do
			final+=(--iglob "$g")
		done
		[ -n "$maxdepth" ] && final+=(--max-depth "$maxdepth")
		[ $null_out -eq 1 ] && final+=(-0)
		final+=("${roots[@]}")
		__sg_rg_args=("${final[@]}")
		return 0
	}

	__sg_strict_find_ok() {
		# strict gate for the find mapping: glob values must stay in the safe
		# charset (no bracket classes, no backslashes).
		local re='^[A-Za-z0-9 *_?.-]+$'
		local prev="" a
		for a in "$@"; do
			case "$prev" in
			-name | -iname)
				[[ "$a" =~ $re ]] || return 1 ;;
			esac
			prev="$a"
		done
		return 0
	}

	find() {
		if __sg_active; then
			__sg_check find "$@" || return 1
		fi
		local mode="${SEARCH_GUARD_GREP_AS_RG:-1}" translate=0
		case "$mode" in
		0) translate=0 ;;
		strict) __sg_strict_find_ok "$@" && translate=1 ;;
		*) translate=1 ;;
		esac
		if [ $translate -eq 1 ] && __sg_find_to_rg "$@"; then
			[ -n "${SEARCH_GUARD_DEBUG:-}" ] &&
				echo "[search-guard] translated to: $__sg_rg_path ${__sg_rg_args[*]}" >&2
			__SG_PROBED=1 command "$__sg_rg_path" "${__sg_rg_args[@]}"
			local rc=$?
			[ $rc -eq 1 ] && rc=0 # find exits 0 when nothing matched; rg exits 1
			return $rc
		fi
		[ -n "${SEARCH_GUARD_DEBUG:-}" ] &&
			echo "[search-guard] fallback to real find" >&2
		__SG_PROBED=1 PATH="$__sg_clean_path" command find "$@"
	}
fi
