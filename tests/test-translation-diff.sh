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

export BASH_ENV="$SG_DIR/init.sh"
export PATH="$SG_DIR:$PATH"
export SEARCH_GUARD_ENTRY_CAP=100000 # fixtures are tiny; never trip the guard

FIX=$(mktemp -d)
mkdir -p "$FIX/sub" "$FIX/.hidden"

cat > "$FIX/f1.txt" <<'EOF'
TODO one
alpha beta
TODO two TODO two
Alpha Beta
zz only here
aab aab
word TODOx TODO word
ctx1
CTX target
ctx2
EOF

cat > "$FIX/f2.md" <<'EOF'
TODO alpha
nothing line
TODO
foo(bar) literal
EOF

printf 'TODO nested\nplain\n' > "$FIX/sub/nested.log"
printf 'TODO hidden\n' > "$FIX/.hidden/secret.txt"
printf 'TODO space\n' > "$FIX/my file.txt"
: > "$FIX/empty.txt"
printf 'TODO\nzz\n' > "$FIX/pats.txt"
# a .gitignore that must NOT affect either implementation
printf 'ignored.txt\n' > "$FIX/.gitignore"
printf 'TODO ignored\n' > "$FIX/ignored.txt"

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
)

pass=0; fail=0
for c in "${CASES[@]}"; do
	case "$c" in
	pipe*) cmd="${c#pipe }" ;; # full pipeline, don't prefix with grep
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
