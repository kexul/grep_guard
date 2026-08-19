#!/bin/bash
# FUZZ tests for the grep->rg translation (differential).
#
# Randomly combines flags x patterns x targets and requires the wrapper's
# output + exit code to match real GNU grep for every generated case.
# Unknown flags hit the fallback path, so the fuzz space exercises BOTH the
# translation and the bail-out logic. Reproduce failures via FUZZ_SEED.
#
#   bash tests/test-translation-fuzz.sh            # 300 cases
#   FUZZ_N=1000 FUZZ_SEED=42 bash tests/test-translation-fuzz.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SG_DIR="$(cd "$SCRIPT_DIR/../shims" && pwd)"
# shellcheck source=_fixtures.sh
source "$SCRIPT_DIR/_fixtures.sh"

export BASH_ENV="$SG_DIR/init.sh"
export PATH="$SG_DIR:$PATH"
export SEARCH_GUARD_ENTRY_CAP=100000 # fixtures are tiny; never trip the guard

FUZZ_N=${FUZZ_N:-300}
SEED=${FUZZ_SEED:-$RANDOM}
RANDOM=$SEED
echo "fuzz seed=$SEED N=$FUZZ_N"

FIX=$(mktemp -d)
make_fixtures "$FIX"

FLAGS=(
	-i -n -l -c -v -x -o -w -H -h -r -F -E
	-in -rn -nc -ic -on -vn
	'-m 1' '-m 2' '-m2' '-A 1' '-C 1' '-B 1'
	--ignore-case --count --files-with-matches --invert-match --word-regexp
	--only-matching --with-filename --no-filename --fixed-strings
	--extended-regexp --max-count=2 --context=1 --after-context=1
	--include='*.txt' --exclude='*.md' --exclude-dir=sub
	--line-regexp --quiet
)
# Patterns: plain words, BRE-compatible regex, and BRE-only constructs that
# MUST fall back to real grep (both sides then trivially agree — we still
# verify the bail-out never changes results).
PATTERNS=(
	TODO alpha 'alpha beta' zz aab CTX word nothing 'TODO two' 'DASH'
	'[Tt]ODO' '^TODO' 'TODO$' 'TODO.*two' 'a*b' 'TODO.' '\.' 'TO?DO'
	'x|y' '(bar)' 'a\{2\}' 'TODO\?' 'C++' '\(zz\)' '[[:alpha:]]+'
)
FILES=(f1.txt f2.md 'f1.txt f2.md' 'f1.txt missing.txt' empty.txt MYFILE pats.txt)
DIRS=(. sub .hidden)

pass=0; fail=0
is_recursive() { # exact per-flag match (substring tests give false hits)
	local f
	for f in $*; do
		case "$f" in
		-r | -R | --recursive | -r[a-zA-Z]* | -R[a-zA-Z]*) return 0 ;;
		esac
	done
	return 1
}

run_parts() { # run_parts <tool> <args...>: builds a properly quoted command
	local tool="$1"
	shift
	local cmdstr
	cmdstr=$(printf '%q ' "$@")
	local real_out tr_out real_rc tr_rc
	real_out=$(cd "$FIX" && SEARCH_GUARD_GREP_AS_RG=0 bash -c "$tool $cmdstr" 2>/dev/null | LC_ALL=C sort; exit "${PIPESTATUS[0]:-0}")
	real_rc=$?
	tr_out=$(cd "$FIX" && bash -c "$tool $cmdstr" 2>/dev/null | LC_ALL=C sort; exit "${PIPESTATUS[0]:-0}")
	tr_rc=$?
	if [ "$real_out" = "$tr_out" ] && [ "$real_rc" = "$tr_rc" ]; then
		pass=$((pass+1))
	else
		fail=$((fail+1))
		echo "FAIL | grep $cmdstr (rc real=$real_rc translated=$tr_rc)"
		echo "----- real -----"; printf '%s\n' "$real_out" | head -6
		echo "----- translated -----"; printf '%s\n' "$tr_out" | head -6
	fi
}

for ((n = 0; n < FUZZ_N; n++)); do
	args=()
	nflags=$((RANDOM % 3)) # 0-2 flags
	for ((i = 0; i < nflags; i++)); do
		args+=("${FLAGS[$((RANDOM % ${#FLAGS[@]}))]}")
	done

	pat="${PATTERNS[$((RANDOM % ${#PATTERNS[@]}))]}"

	# occasionally add a second -e pattern (multi-pattern OR semantics)
	if [ $((RANDOM % 5)) -eq 0 ]; then
		args+=(-e "${PATTERNS[$((RANDOM % ${#PATTERNS[@]}))]}")
	fi

	# recursive targets only when the command actually recurses; a bare
	# directory operand without -r makes real grep error, which the
	# translation now faithfully reproduces via the fallback.
	if is_recursive "${args[@]:+${args[@]}}"; then
		target="${DIRS[$((RANDOM % ${#DIRS[@]}))]}"
	else
		case "${FILES[$((RANDOM % ${#FILES[@]}))]}" in
		MYFILE) target='my file.txt' ;;
		*) target="${FILES[$((RANDOM % ${#FILES[@]}))]}" ;;
		esac
	fi

	run_parts grep "${args[@]:+${args[@]}}" "$pat" $target
done

# --- find -> rg --files fuzz ---
FIND_NAMEFLAGS=("-name" "-iname")
FIND_GLOBS=('*.txt' '*.md' '*.log' '*' 'f1*' 'nested*' 'x*.txt' '*e*' 'secret*')
FIND_ROOTS=(. sub .hidden f1.txt 'sub .hidden')

for ((n = 0; n < FUZZ_N / 4; n++)); do
	fargs=(-type f)
	if [ $((RANDOM % 2)) -eq 0 ]; then
		fargs+=(-maxdepth $((RANDOM % 3 + 1)))
	fi
	fargs+=("${FIND_NAMEFLAGS[$((RANDOM % 2))]}")
	fargs+=("${FIND_GLOBS[$((RANDOM % ${#FIND_GLOBS[@]}))]}")
	# occasionally a second -o -name clause
	if [ $((RANDOM % 3)) -eq 0 ]; then
		fargs+=(-o -name "${FIND_GLOBS[$((RANDOM % ${#FIND_GLOBS[@]}))]}")
	fi
	run_parts find "${fargs[@]}" ${FIND_ROOTS[$((RANDOM % ${#FIND_ROOTS[@]}))]}
done

echo
echo "seed=$SEED pass=$pass fail=$fail (grep cases=$FUZZ_N, find cases=$((FUZZ_N / 4)))"
rm -rf "$FIX"
[ "$fail" -eq 0 ]
