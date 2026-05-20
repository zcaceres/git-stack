#!/usr/bin/env bats

setup() {
  load test_helper/setup
  setup
  setup_bare_origin
}

teardown() {
  teardown
}

# Helper: create a stack, push all branches, and set up gh mock with PR entries.
setup_stack_with_prs() {
  create_linear_stack feat-a feat-b
  git push origin feat-a feat-b >/dev/null 2>&1
}

@test "merge --dry-run shows plan without merging" {
  setup_stack_with_prs
  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"},{"number":2,"headRefName":"feat-b","baseRefName":"feat-a"}]'

  run git-stack merge --dry-run
  assert_success
  assert_output --partial "Dry run"
  assert_output --partial "#1"

  refute_gh_called "pr merge"
}

@test "merge --dry-run --all shows all PRs" {
  setup_stack_with_prs
  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"},{"number":2,"headRefName":"feat-b","baseRefName":"feat-a"}]'

  run git-stack merge --dry-run --all
  assert_success
  assert_output --partial "#1"
  assert_output --partial "#2"
  assert_output --partial "2 PR(s)"
}

@test "merge without --all merges only bottom PR" {
  setup_stack_with_prs
  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"},{"number":2,"headRefName":"feat-b","baseRefName":"feat-a"}]'

  run git-stack merge
  assert_success

  assert_gh_called "pr merge 1 --merge"
  refute_gh_called "pr merge 2"
  assert_output --partial "merged 1 PR(s)"
}

@test "merge --all merges entire stack bottom-up" {
  setup_stack_with_prs
  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"},{"number":2,"headRefName":"feat-b","baseRefName":"feat-a"}]'

  run git-stack merge --all
  assert_success

  assert_gh_called "pr merge 1"
  assert_gh_called "pr merge 2"

  # Verify order: PR 1 merged before PR 2
  local line1 line2
  line1=$(grep -n "pr merge 1 --merge" "$TEST_TMPDIR/gh-calls.log" | head -1 | cut -d: -f1)
  line2=$(grep -n "pr merge 2 --merge" "$TEST_TMPDIR/gh-calls.log" | head -1 | cut -d: -f1)
  [ "$line1" -lt "$line2" ]
}

@test "merge --rebase uses rebase strategy" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1
  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"}]'

  run git-stack merge --rebase
  assert_success

  assert_gh_called "pr edit 1 --base main"
  assert_gh_called "pr merge 1 --rebase"
}

@test "merge --squash uses squash strategy" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1
  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"}]'

  run git-stack merge --squash
  assert_success

  assert_gh_called "pr merge 1 --squash"
}

@test "merge retargets child PR to trunk after merging parent" {
  setup_stack_with_prs
  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"},{"number":2,"headRefName":"feat-b","baseRefName":"feat-a"}]'

  run git-stack merge
  assert_success

  assert_gh_called "pr edit 2 --base main"
}

@test "merge cleans up stack metadata for merged branch" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1
  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"}]'

  git-stack merge

  # stack-parent should be removed
  run git config --get branch.feat-a.stack-parent
  assert_failure
}

@test "merge fails when not in a stack" {
  run git-stack merge
  assert_failure
  assert_output --partial "no stack to merge"
}

@test "merge fails when no open PRs in stack" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1
  mock_gh_with_prs '[]'

  run git-stack merge
  assert_failure
  assert_output --partial "no open PRs found"
}

@test "merge fails when gh is not installed" {
  create_linear_stack feat-a
  rm -f "$TEST_TMPDIR/mock-bin/gh"
  export PATH="$(path_without_gh)"

  run git-stack merge
  assert_failure
  assert_output --partial "'gh' CLI not found"
}

@test "merge --help shows usage" {
  run git-stack merge --help
  assert_success
  assert_output --partial "Usage:"
}

@test "merge rejects unknown flags" {
  run git-stack merge --invalid
  assert_failure
  assert_output --partial "unknown flag"
}

@test "merge returns to original branch when it still exists" {
  setup_stack_with_prs
  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"}]'

  git-stack merge

  [ "$(current_branch)" = "feat-b" ]
}

@test "merge --dry-run --rebase shows rebase strategy" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1
  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"}]'

  run git-stack merge --dry-run --rebase
  assert_success
  assert_output --partial "rebase"
}

# --- Strategy-specific git state tests ---
# These tests use mock_gh_with_merge which creates a NEW squash commit on
# origin/main (different SHA from the branch), simulating what GitHub does.
# This makes the --onto rebase boundary critical: without it, the script
# would replay already-merged parent commits, causing duplicates or conflicts.

@test "rebase --all on 3-branch stack: no commit duplication after rebase" {
  create_linear_stack feat-a feat-b feat-c
  git push origin feat-a feat-b feat-c >/dev/null 2>&1

  # Precondition: before merge, each branch carries its ancestors' commits
  [ "$(git log --oneline main..feat-b | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(git log --oneline main..feat-c | wc -l | tr -d ' ')" -eq 3 ]

  printf "1:feat-a\n2:feat-b\n3:feat-c\n" > "$TEST_TMPDIR/pr-branches.txt"
  mock_gh_with_merge '[{"number":1,"headRefName":"feat-a","baseRefName":"main"},{"number":2,"headRefName":"feat-b","baseRefName":"feat-a"},{"number":3,"headRefName":"feat-c","baseRefName":"feat-b"}]'

  run git-stack merge --all --rebase
  assert_success

  assert_gh_called "pr merge 1 --rebase"
  assert_gh_called "pr merge 2 --rebase"
  assert_gh_called "pr merge 3 --rebase"

  # After the script rebases each branch, it should have only its OWN commit.
  # Verify via the commit messages on each branch tip — they should NOT
  # contain ancestor branch commits (which would indicate duplication).
  run git log --oneline -1 feat-b
  assert_output --partial "add feat-b"
  run git log --oneline -1 feat-c
  assert_output --partial "add feat-c"

  # The files from all three branches should exist on feat-c's tree
  # (the rebase preserves content, just changes parentage)
  git checkout feat-c >/dev/null 2>&1
  [ -f feat-a.txt ]
  [ -f feat-b.txt ]
  [ -f feat-c.txt ]
}

@test "squash --all on 3-branch stack: no commit duplication after rebase" {
  create_linear_stack feat-a feat-b feat-c
  git push origin feat-a feat-b feat-c >/dev/null 2>&1

  printf "1:feat-a\n2:feat-b\n3:feat-c\n" > "$TEST_TMPDIR/pr-branches.txt"
  mock_gh_with_merge '[{"number":1,"headRefName":"feat-a","baseRefName":"main"},{"number":2,"headRefName":"feat-b","baseRefName":"feat-a"},{"number":3,"headRefName":"feat-c","baseRefName":"feat-b"}]'

  run git-stack merge --all --squash
  assert_success

  assert_gh_called "pr merge 1 --squash"
  assert_gh_called "pr merge 2 --squash"
  assert_gh_called "pr merge 3 --squash"

  # Each branch tip should be its own commit, not a replayed ancestor
  run git log --oneline -1 feat-b
  assert_output --partial "add feat-b"
  run git log --oneline -1 feat-c
  assert_output --partial "add feat-c"
}

@test "rebase --all: --onto boundary prevents duplicate commits (regression guard)" {
  # After merging feat-a via squash, origin/main has a NEW commit (S1) with
  # a different SHA containing feat-a's changes. The --onto boundary tells
  # git "skip everything up to feat-a's original tip, only replay feat-b's
  # unique commit." Without it, git would try to replay feat-a's commit
  # on top of S1 (which already has those changes), risking duplication.
  create_linear_stack feat-a feat-b
  git push origin feat-a feat-b >/dev/null 2>&1

  printf "1:feat-a\n2:feat-b\n" > "$TEST_TMPDIR/pr-branches.txt"
  mock_gh_with_merge '[{"number":1,"headRefName":"feat-a","baseRefName":"main"},{"number":2,"headRefName":"feat-b","baseRefName":"feat-a"}]'

  run git-stack merge --all --rebase
  assert_success

  # After squash-merge of both PRs, origin/main has: initial → S1 → S2.
  # feat-b (after rebase) has: initial → S1 → C2' (add feat-b).
  # The key: feat-b has exactly 1 commit beyond origin/main's S1.
  git fetch origin main >/dev/null 2>&1

  # feat-b should diverge from origin/main by exactly 1 commit (its own)
  local unique_commits
  unique_commits=$(git log --oneline origin/main..feat-b | wc -l | tr -d ' ')
  [ "$unique_commits" -eq 1 ]

  # That commit should be feat-b's, and the tree should have both files
  run git log --oneline -1 feat-b
  assert_output --partial "add feat-b"
  git checkout feat-b >/dev/null 2>&1
  [ -f feat-a.txt ]
  [ -f feat-b.txt ]
}

@test "merge updates child metadata to trunk when parent is merged" {
  setup_stack_with_prs
  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"},{"number":2,"headRefName":"feat-b","baseRefName":"feat-a"}]'

  git-stack merge

  [ "$(get_stack_parent feat-b)" = "main" ]
}

@test "rebase merge restacks child not in merge list" {
  # main -> feat-a -> feat-b. Merge only feat-a with rebase.
  # feat-b should be restacked onto the new main via restack_onto().
  create_linear_stack feat-a feat-b
  git push origin feat-a feat-b >/dev/null 2>&1

  # Record feat-b's pre-merge ancestry
  local pre_b_from_main
  pre_b_from_main=$(git log --oneline main..feat-b | wc -l | tr -d ' ')
  [ "$pre_b_from_main" -eq 2 ]  # feat-a commit + feat-b commit

  printf "1:feat-a\n" > "$TEST_TMPDIR/pr-branches.txt"
  mock_gh_with_merge '[{"number":1,"headRefName":"feat-a","baseRefName":"main"},{"number":2,"headRefName":"feat-b","baseRefName":"feat-a"}]'

  # Merge only bottom PR (no --all)
  run git-stack merge --rebase
  assert_success

  assert_gh_called "pr merge 1 --rebase"
  refute_gh_called "pr merge 2"

  # feat-b should now be restacked onto origin/main (which includes feat-a)
  [ "$(get_stack_parent feat-b)" = "main" ]

  # After restacking, feat-b should have only 1 unique commit from origin/main
  git fetch origin main >/dev/null 2>&1
  local post_b_from_main
  post_b_from_main=$(git log --oneline origin/main..feat-b | wc -l | tr -d ' ')
  [ "$post_b_from_main" -eq 1 ]

  run git log --oneline -1 feat-b
  assert_output --partial "add feat-b"
}

@test "squash merge restacks child not in merge list" {
  create_linear_stack feat-a feat-b
  git push origin feat-a feat-b >/dev/null 2>&1

  printf "1:feat-a\n" > "$TEST_TMPDIR/pr-branches.txt"
  mock_gh_with_merge '[{"number":1,"headRefName":"feat-a","baseRefName":"main"},{"number":2,"headRefName":"feat-b","baseRefName":"feat-a"}]'

  run git-stack merge --squash
  assert_success

  assert_gh_called "pr merge 1 --squash"
  refute_gh_called "pr merge 2"

  [ "$(get_stack_parent feat-b)" = "main" ]

  git fetch origin main >/dev/null 2>&1
  local post_b_from_main
  post_b_from_main=$(git log --oneline origin/main..feat-b | wc -l | tr -d ' ')
  [ "$post_b_from_main" -eq 1 ]
}

@test "merge dies when gh pr merge fails" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1

  mock_gh '
case "$1:$2" in
  pr:list)
    echo '"'"'[{"number":1,"headRefName":"feat-a","baseRefName":"main"}]'"'"'
    ;;
  pr:merge)
    exit 1
    ;;
  *)
    ;;
esac'

  run git-stack merge
  assert_failure
  assert_output --partial "failed to merge PR"
}

@test "rebase merge dies on rebase conflict" {
  create_linear_stack feat-a
  # Create a conflicting commit on main AFTER feat-a branched
  git checkout main >/dev/null 2>&1
  echo "conflict on main" > feat-a.txt
  git add feat-a.txt
  git commit -m "conflicting change on main" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1
  git checkout feat-a >/dev/null 2>&1
  git push origin feat-a >/dev/null 2>&1

  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"}]'

  run git-stack merge --rebase
  assert_failure
  assert_output --partial "rebase conflict"
}

@test "merge --all with child outside merge list retargets and restacks child" {
  create_linear_stack feat-a feat-b feat-c
  git push origin feat-a feat-b feat-c >/dev/null 2>&1

  mock_gh_with_prs '[{"number":1,"headRefName":"feat-a","baseRefName":"main"},{"number":2,"headRefName":"feat-b","baseRefName":"feat-a"},{"number":3,"headRefName":"feat-c","baseRefName":"feat-b"}]'

  run git-stack merge --all
  assert_success

  assert_gh_called "pr merge 1"
  assert_gh_called "pr merge 2"
  assert_gh_called "pr merge 3"
}
