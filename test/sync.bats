#!/usr/bin/env bats

setup() {
  load test_helper/setup
  setup
  setup_bare_origin
}

teardown() {
  teardown
}

# Helper: advance origin/main directly in the bare repo (simulates a merged PR
# on GitHub). This does NOT update the local origin/main tracking ref, so
# git-stack sync's fetch will see the change.
advance_trunk() {
  local prev_branch
  prev_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
  GIT_DIR="$TEST_TMPDIR/origin.git" git symbolic-ref HEAD refs/heads/main
  local tree current_main new_commit
  current_main=$(GIT_DIR="$TEST_TMPDIR/origin.git" git rev-parse refs/heads/main)
  # Create a new blob + tree on top of current main's tree
  local blob
  blob=$(echo "trunk update $(date +%s%N)" | GIT_DIR="$TEST_TMPDIR/origin.git" git hash-object -w --stdin)
  tree=$(echo -e "100644 blob $blob\ttrunk-update.txt" | GIT_DIR="$TEST_TMPDIR/origin.git" git mktree --missing)
  # Merge the new tree entry with the existing tree
  local base_tree
  base_tree=$(GIT_DIR="$TEST_TMPDIR/origin.git" git rev-parse "${current_main}^{tree}")
  tree=$(GIT_DIR="$TEST_TMPDIR/origin.git" bash -c '
    git ls-tree "$1" | grep -v "trunk-update.txt"
    echo "100644 blob '"$blob"'	trunk-update.txt"
  ' -- "$base_tree" | GIT_DIR="$TEST_TMPDIR/origin.git" git mktree)
  new_commit=$(echo "trunk update" | GIT_DIR="$TEST_TMPDIR/origin.git" \
    GIT_AUTHOR_NAME="Other" GIT_AUTHOR_EMAIL="other@test.com" \
    GIT_COMMITTER_NAME="Other" GIT_COMMITTER_EMAIL="other@test.com" \
    git commit-tree "$tree" -p "$current_main")
  GIT_DIR="$TEST_TMPDIR/origin.git" git update-ref refs/heads/main "$new_commit"
}

@test "sync rebases stack onto updated trunk" {
  create_linear_stack feat-a feat-b
  git push origin feat-a feat-b >/dev/null 2>&1
  advance_trunk
  git checkout feat-b >/dev/null 2>&1

  run git-stack sync
  assert_success
  assert_output --partial "synced 2 branch(es)"

  # Both branches should now be based on the new main tip
  local main_tip
  main_tip=$(git rev-parse origin/main)
  [ "$(git merge-base "$main_tip" feat-a)" = "$main_tip" ]
  [ "$(git merge-base "$main_tip" feat-b)" = "$main_tip" ]
}

@test "sync --no-push skips force-push" {
  create_linear_stack feat-a feat-b
  git push origin feat-a feat-b >/dev/null 2>&1

  local remote_a_before
  remote_a_before=$(git rev-parse origin/feat-a)

  advance_trunk
  git checkout feat-b >/dev/null 2>&1

  run git-stack sync --no-push
  assert_success

  # Remote should still have the old SHA
  git fetch origin feat-a >/dev/null 2>&1
  local remote_a_after
  remote_a_after=$(git rev-parse origin/feat-a)
  [ "$remote_a_before" = "$remote_a_after" ]
}

@test "sync reports up-to-date when trunk has not changed" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1

  run git-stack sync
  assert_success
  assert_output --partial "already up to date"
}

@test "sync handles 3-branch stack without commit duplication" {
  create_linear_stack feat-a feat-b feat-c
  git push origin feat-a feat-b feat-c >/dev/null 2>&1
  advance_trunk
  git checkout feat-c >/dev/null 2>&1

  run git-stack sync
  assert_success
  assert_output --partial "synced 3 branch(es)"

  # Each branch should have exactly 1 unique commit above its parent
  local count_a count_b count_c
  count_a=$(git rev-list origin/main..feat-a --count)
  count_b=$(git rev-list feat-a..feat-b --count)
  count_c=$(git rev-list feat-b..feat-c --count)
  [ "$count_a" -eq 1 ]
  [ "$count_b" -eq 1 ]
  [ "$count_c" -eq 1 ]
}

@test "sync fails on dirty worktree" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1
  echo "dirty" > dirty.txt
  git add dirty.txt

  run git-stack sync
  assert_failure
  assert_output --partial "dirty"
}

@test "sync fails when not in a stack" {
  git checkout main >/dev/null 2>&1

  run git-stack sync
  assert_failure
  assert_output --partial "no stack to sync"
}

@test "sync fails on detached HEAD" {
  git checkout --detach >/dev/null 2>&1

  run git-stack sync
  assert_failure
  assert_output --partial "detached"
}

@test "sync returns to original branch after completion" {
  create_linear_stack feat-a feat-b
  git push origin feat-a feat-b >/dev/null 2>&1
  advance_trunk
  git checkout feat-a >/dev/null 2>&1

  run git-stack sync
  assert_success
  [ "$(current_branch)" = "feat-a" ]
}

@test "sync --help shows usage" {
  run git-stack sync --help
  assert_success
  assert_output --partial "Usage:"
}

@test "sync rejects unknown flags" {
  run git-stack sync --bad
  assert_failure
  assert_output --partial "unknown flag"
}

@test "sync handles branching (non-linear) stacks" {
  create_linear_stack feat-a feat-b
  # Add a sibling branch off feat-a
  create_stack_branch feat-c feat-a
  git push origin feat-a feat-b feat-c >/dev/null 2>&1
  advance_trunk
  git checkout feat-b >/dev/null 2>&1

  run git-stack sync
  assert_success

  # All three branches should be based on new main
  local main_tip
  main_tip=$(git rev-parse origin/main)
  [ "$(git merge-base "$main_tip" feat-a)" = "$main_tip" ]
  [ "$(git merge-base "$main_tip" feat-b)" = "$main_tip" ]
  [ "$(git merge-base "$main_tip" feat-c)" = "$main_tip" ]
}

@test "sync only touches the current stack when multiple stacks exist" {
  # Stack 1: main -> aaa-other -> aaa-child
  create_linear_stack aaa-other aaa-child
  # Stack 2: main -> zzz-mine -> zzz-child
  create_stack_branch zzz-mine main
  create_stack_branch zzz-child zzz-mine
  git push origin aaa-other aaa-child zzz-mine zzz-child >/dev/null 2>&1

  local other_tip_before
  other_tip_before=$(git rev-parse origin/aaa-other)

  advance_trunk
  git checkout zzz-child >/dev/null 2>&1

  run git-stack sync
  assert_success
  assert_output --partial "synced 2 branch(es)"

  # Current stack should be rebased onto new main
  local main_tip
  main_tip=$(git rev-parse origin/main)
  [ "$(git merge-base "$main_tip" zzz-mine)" = "$main_tip" ]
  [ "$(git merge-base "$main_tip" zzz-child)" = "$main_tip" ]

  # Other stack should NOT have been touched
  git fetch origin aaa-other >/dev/null 2>&1
  local other_tip_after
  other_tip_after=$(git rev-parse origin/aaa-other)
  [ "$other_tip_before" = "$other_tip_after" ]
}

@test "sync works when run from middle of stack" {
  create_linear_stack feat-a feat-b feat-c
  git push origin feat-a feat-b feat-c >/dev/null 2>&1
  advance_trunk
  git checkout feat-b >/dev/null 2>&1

  run git-stack sync
  assert_success
  assert_output --partial "synced 3 branch(es)"
  [ "$(current_branch)" = "feat-b" ]

  # All branches rebased
  local main_tip
  main_tip=$(git rev-parse origin/main)
  [ "$(git merge-base "$main_tip" feat-a)" = "$main_tip" ]
  [ "$(git merge-base "$main_tip" feat-c)" = "$main_tip" ]
}
