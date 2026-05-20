#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GIT_STACK="$PROJECT_ROOT/bin/git-stack"

load "$PROJECT_ROOT/node_modules/bats-support/load.bash"
load "$PROJECT_ROOT/node_modules/bats-assert/load.bash"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export HOME="$TEST_TMPDIR"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/.gitconfig"

  mkdir -p "$TEST_TMPDIR/mock-bin"
  export PATH="$TEST_TMPDIR/mock-bin:$PROJECT_ROOT/bin:$PATH"

  mkdir -p "$TEST_TMPDIR/repo"
  cd "$TEST_TMPDIR/repo"
  git init -b main >/dev/null 2>&1
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "initial" > init.txt
  git add init.txt
  git commit -m "initial commit" >/dev/null 2>&1
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# Source git-stack functions without running the dispatcher.
# Usage: run_fn <function_name> [args...]
run_fn() {
  local fn="$1"; shift
  local fn_source
  fn_source=$(sed -n '1,/^# --- Dispatcher ---/p' "$GIT_STACK")
  bash -c "$fn_source"$'\n'"$fn \"\$@\"" -- "$@"
}

# Create a branch with stack-parent metadata and a commit.
create_stack_branch() {
  local name="$1" parent="$2"
  git checkout "$parent" >/dev/null 2>&1
  git checkout -b "$name" >/dev/null 2>&1
  git config "branch.$name.stack-parent" "$parent"
  git config "branch.$name.gh-merge-base" "$parent"
  echo "content for $name" > "$name.txt"
  git add "$name.txt"
  git commit -m "add $name" >/dev/null 2>&1
}

# Build a linear stack: main → b1 → b2 → ...
# Leaves HEAD on the last branch.
create_linear_stack() {
  local parent="main"
  for branch in "$@"; do
    create_stack_branch "$branch" "$parent"
    parent="$branch"
  done
}

# Create a bare origin and push main to it.
setup_bare_origin() {
  git init --bare "$TEST_TMPDIR/origin.git" >/dev/null 2>&1
  git remote add origin "$TEST_TMPDIR/origin.git"
  git push -u origin main >/dev/null 2>&1
}

# Write a custom gh mock script.
# Usage: mock_gh "body of script"
# The body is written literally (no expansion).
# All invocations are logged to $TEST_TMPDIR/gh-calls.log.
mock_gh() {
  local body="$1"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/gh-calls.log"\n' "$TEST_TMPDIR" > "$TEST_TMPDIR/mock-bin/gh"
  printf '%s\n' "$body" >> "$TEST_TMPDIR/mock-bin/gh"
  chmod +x "$TEST_TMPDIR/mock-bin/gh"
}

# Convenience: create a gh mock that returns canned PR JSON for `pr list`
# and succeeds silently for pr create/edit/merge/view.
# Usage: mock_gh_with_prs '<json array>'
mock_gh_with_prs() {
  local json="$1"
  cat > "$TEST_TMPDIR/mock-bin/gh" <<MOCK_EOF
#!/usr/bin/env bash
echo "\$*" >> "$TEST_TMPDIR/gh-calls.log"
case "\$1:\$2" in
  pr:list)
    cat <<'JSON_EOF'
$json
JSON_EOF
    ;;
  pr:create)
    echo "https://github.com/test/test/pull/99"
    ;;
  pr:edit)
    ;;
  pr:merge)
    ;;
  pr:view)
    echo '{"baseRefName":"main"}'
    ;;
  auth:status)
    ;;
esac
exit 0
MOCK_EOF
  chmod +x "$TEST_TMPDIR/mock-bin/gh"
  # Shadow sleep so merge tests don't wait
  cat > "$TEST_TMPDIR/mock-bin/sleep" <<'SLEEP_EOF'
#!/usr/bin/env bash
exit 0
SLEEP_EOF
  chmod +x "$TEST_TMPDIR/mock-bin/sleep"
}

# Like mock_gh_with_prs but pr merge simulates what GitHub actually does:
# creates a NEW squash commit on main with a DIFFERENT SHA than the branch.
# This is critical because the --onto rebase boundary only matters when the
# merged commits have different SHAs on main vs the original branch.
#
# Tests must write a PR-number→branch mapping to $TEST_TMPDIR/pr-branches.txt.
# Usage:
#   printf "1:feat-a\n2:feat-b\n" > "$TEST_TMPDIR/pr-branches.txt"
#   mock_gh_with_merge '<json array>'
mock_gh_with_merge() {
  local json="$1"
  cat > "$TEST_TMPDIR/mock-bin/gh" <<MOCK_EOF
#!/usr/bin/env bash
echo "\$*" >> "$TEST_TMPDIR/gh-calls.log"
case "\$1:\$2" in
  pr:list)
    cat <<'JSON_EOF'
$json
JSON_EOF
    ;;
  pr:create)
    echo "https://github.com/test/test/pull/99"
    ;;
  pr:edit)
    ;;
  pr:merge)
    pr_num="\$3"
    branch=\$(sed -n "s/^\${pr_num}://p" "$TEST_TMPDIR/pr-branches.txt" 2>/dev/null)
    if [ -n "\$branch" ]; then
      export GIT_DIR="$TEST_TMPDIR/origin.git"
      branch_tip=\$(git rev-parse "refs/heads/\$branch" 2>/dev/null)
      current_main=\$(git rev-parse refs/heads/main 2>/dev/null)
      if [ -n "\$branch_tip" ] && [ -n "\$current_main" ]; then
        # Create a new squash commit: same tree as the branch tip, but
        # parented on current main. This produces a NEW SHA (different
        # from any commit in the branch), just like GitHub's squash merge.
        new_commit=\$(echo "squash merge \$branch" | \\
          GIT_AUTHOR_NAME="GitHub" GIT_AUTHOR_EMAIL="noreply@github.com" \\
          GIT_COMMITTER_NAME="GitHub" GIT_COMMITTER_EMAIL="noreply@github.com" \\
          git commit-tree "\${branch_tip}^{tree}" -p "\$current_main")
        git update-ref refs/heads/main "\$new_commit"
      fi
      unset GIT_DIR
    fi
    ;;
  pr:view)
    echo '{"baseRefName":"main"}'
    ;;
  auth:status)
    ;;
esac
exit 0
MOCK_EOF
  chmod +x "$TEST_TMPDIR/mock-bin/gh"
  cat > "$TEST_TMPDIR/mock-bin/sleep" <<'SLEEP_EOF'
#!/usr/bin/env bash
exit 0
SLEEP_EOF
  chmod +x "$TEST_TMPDIR/mock-bin/sleep"
}

# Build a PATH that excludes gh but keeps system binaries.
path_without_gh() {
  local result=""
  local p
  while IFS= read -rd: p || [[ -n "$p" ]]; do
    [[ -z "$p" ]] && continue
    [[ -x "$p/gh" ]] && continue
    result="${result:+$result:}$p"
  done <<< "$PATH"
  echo "$result"
}

# Assert that gh was called with args matching a substring.
assert_gh_called() {
  local substr="$1"
  if [[ ! -f "$TEST_TMPDIR/gh-calls.log" ]]; then
    fail "gh was never called (no log file), expected call matching: $substr"
  fi
  grep -qF "$substr" "$TEST_TMPDIR/gh-calls.log" || \
    fail "expected gh call matching '$substr', got:"$'\n'"$(cat "$TEST_TMPDIR/gh-calls.log")"
}

# Assert that gh was NOT called with args matching a substring.
refute_gh_called() {
  local substr="$1"
  if [[ ! -f "$TEST_TMPDIR/gh-calls.log" ]]; then
    return 0
  fi
  if grep -qF "$substr" "$TEST_TMPDIR/gh-calls.log"; then
    fail "unexpected gh call matching '$substr', got:"$'\n'"$(cat "$TEST_TMPDIR/gh-calls.log")"
  fi
}

# Shorthand for reading stack-parent config.
get_stack_parent() {
  git config --get "branch.$1.stack-parent" 2>/dev/null || true
}

# Get current branch name.
current_branch() {
  git symbolic-ref --short HEAD 2>/dev/null
}
