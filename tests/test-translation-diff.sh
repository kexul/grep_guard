#!/bin/bash
# DIFFERENTIAL tests for the grep->rg translation.
#
# Every case below is executed twice:
#   A) real GNU grep   (SEARCH_GUARD_GREP_AS_RG=0 forces the fallback path)
#   B) the wrapper     (translation to rg)
# and stdout + exit code must match. Lines are compared as sorted sets
# because rg's parallel output may order files differently than grep's
# argv order (documented known difference; content must be identical).
#
# Run:  bash tests/test-translation-diff.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SG_DIR="$(cd "$SCRIPT_DIR/../shims" && pwd)"
# shellcheck source=_fixtures.sh
source "$SCRIPT_DIR/_fixtures.sh"

export BASH_ENV="$SG_DIR/init.sh"
export PATH="$SG_DIR:$PATH"
export SEARCH_GUARD_ENTRY_CAP=100000 # fixtures are tiny; never trip the guard

FIX=$(mktemp -d)
make_fixtures "$FIX"

CASES=(
	# ---- basic patterns, single file ----
	'TODO f1.txt'
	'alpha f1.txt'
	'TODO -i f1.txt'
	'-in TODO f1.txt'
	'-n TODO f1.txt'
	'-o TODO f1.txt'
	'-c TODO f1.txt'
	'-v TODO f1.txt'
	'-w TODO f1.txt'
	'-x TODO f2.md'
	'-h TODO f1.txt'
	'-H TODO f1.txt'
	'-l TODO f1.txt f2.md'
	'-L zzzz f1.txt f2.md'
	'-m 1 TODO f1.txt'
	'-m 2 TODO f1.txt'
	'-A 1 TODO f1.txt'
	'-B 1 TODO f1.txt'
	'-C 1 TODO f1.txt'
	'--context=1 zz f1.txt'
	'--max-count=2 TODO f1.txt'

	# ---- multiple files / ordering-insensitive ----
	'TODO f1.txt f2.md'
	'-n TODO f1.txt f2.md'
	'-c TODO f1.txt f2.md'
	'-c zz f1.txt f2.md'
	'-c TODO empty.txt'
	'TODO "my file.txt"'

	# ---- recursion (hidden dirs, .gitignore must not apply) ----
	'-r TODO .'
	'-rn TODO .'
	'-rl TODO .'
	'-rc TODO .'
	'-r TODO sub'
	'-ri alpha .'
	'-r --include=*.md TODO .'
	'-r --exclude=*.md TODO .'
	'-r --exclude-dir=sub TODO .'
	'-r --exclude-dir=sub TODO sub'
	'--recursive -n TODO .'

	# ---- long options ----
	'--ignore-case alpha f1.txt'
	'--count TODO f1.txt f2.md'
	'--files-with-matches TODO f1.txt f2.md'
	'--invert-match TODO f1.txt'
	'--word-regexp TODO f1.txt'
	'--only-matching TODO f1.txt'
	'--with-filename TODO f1.txt'
	'--no-filename TODO f1.txt f2.md'
	'--fixed-strings "TODO.*two" f1.txt'
	'--line-regexp TODO f2.md'

	# ---- multiple -e / -f ----
	'-e TODO -e zz f1.txt f2.md'
	'-e alpha f1.txt'
	'-f pats.txt f1.txt'
	'-f pats.txt -r .'

	# ---- ERE / fixed-string flavors ----
	"-E 'a{2}' f1.txt"
	"-E 'TODO (one|two)' f1.txt"
	"egrep 'a{3}b' f1.txt"
	"fgrep 'TODO.*two' f1.txt"
	"fgrep 'a{2}' f1.txt"

	# ---- BRE constructs (must fall back to real grep, same result) ----
	"'a\{2\}' f1.txt"
	"'a\+' f1.txt"
	"'(bar)' f2.md"
	"'TODO|zz' f1.txt f2.md"

	# ---- clusters ----
	'-rin TODO .'
	'-nc TODO f1.txt f2.md'
	'-on TODO f1.txt'
	'-iv ALPHA f1.txt'

	# ---- quiet (exit-code semantics) ----
	'-q TODO f1.txt'
	'-q zzzz f1.txt'
	'-s TODO f1.txt'

	# ---- stdin ----
	'pipe printf "TODO x\nnope\n" | grep TODO'
	'pipe printf "TODO x\nnope\n" | grep -c TODO'

	# ---- no match (exit code 1 on both sides) ----
	'zzzz f1.txt'
	'-r zzzz .'

	# ---- find -> rg --files mapping (+ faithful fallback cases) ----
	'find . -type f -name "*.txt"'
	'find sub -type f -name "*.log"'
	'find . -type f -iname "*.MD"'
	'find . -type f -name "*.log" -o -name "*.md"'
	'find . -type f -name "*"'
	'find . -maxdepth 1 -type f -name "*"'
	'find f1.txt -type f -name "f1.txt"'
	'find . -type f -maxdepth 2 -name "*.md"'
	'find . -type f -name "*.txt" -o -name "*.md"'
	'find sub .hidden -type f -name "*"'
	'find sub -type f -name "*.log" -print'
	'find . -type f -name "*.nope"'
	'find . -type d -name "sub"'
	'find . -type f ! -name "*.md"'
	'find . -name "*.ts"'
	'find missing_dir -type f -name "*"'
)

pass=0; fail=0
for c in "${CASES[@]}"; do
	case "$c" in
	pipe*) cmd="${c#pipe }" ;; # full pipeline, don't prefix
	find*) cmd="$c" ;;          # find -> rg --files mapping
	*) cmd="grep $c" ;;
	esac
	real_out=$(cd "$FIX" && SEARCH_GUARD_GREP_AS_RG=0 bash -c "$cmd" 2>/dev/null | LC_ALL=C sort; exit "${PIPESTATUS[0]:-0}")
	real_rc=$?
	tr_out=$(cd "$FIX" && bash -c "$cmd" 2>/dev/null | LC_ALL=C sort; exit "${PIPESTATUS[0]:-0}")
	tr_rc=$?
	if [ "$real_out" = "$tr_out" ] && [ "$real_rc" = "$tr_rc" ]; then
		pass=$((pass+1)); echo "PASS | $cmd"
	else
		fail=$((fail+1))
		echo "FAIL | $cmd  (rc real=$real_rc translated=$tr_rc)"
		echo "----- real -----"; printf '%s\n' "$real_out" | head -8
		echo "----- translated -----"; printf '%s\n' "$tr_out" | head -8
	fi
done

echo
echo "pass=$pass fail=$fail"
rm -rf "$FIX"
[ "$fail" -eq 0 ]
