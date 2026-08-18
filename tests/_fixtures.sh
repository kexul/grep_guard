#!/bin/bash
# Make the shared fixture tree in $1.
# Contents are designed to exercise: recursion, hidden dirs, .gitignore
# independence, spaces in names, empty files, zero-match counts, context.

make_fixtures() {
	local FIX="$1"
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
-DASH line
EOF

	printf 'TODO nested\nplain\n' > "$FIX/sub/nested.log"
	printf 'TODO hidden\n' > "$FIX/.hidden/secret.txt"
	printf 'TODO space\n' > "$FIX/my file.txt"
	: > "$FIX/empty.txt"
	printf 'TODO\nzz\n' > "$FIX/pats.txt"
	# a .gitignore that must NOT affect either implementation
	printf 'ignored.txt\n' > "$FIX/.gitignore"
	printf 'TODO ignored\n' > "$FIX/ignored.txt"
}
