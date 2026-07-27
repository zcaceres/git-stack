#!/usr/bin/env bats

setup() {
  load test_helper/setup
  setup
  setup_bare_origin
}

teardown() {
  teardown
}

@test "submit pushes branches and creates PRs" {
  create_linear_stack feat-a feat-b
  git push origin feat-a feat-b >/dev/null 2>&1 || true
  mock_gh_with_prs '[]'

  run git-stack submit
  assert_success
  assert_output --partial "stack submitted"

  assert_gh_called "pr create --head feat-a --base main"
  assert_gh_called "pr create --head feat-b --base feat-a"
}

@test "submit retargets existing PR when base changed" {
  create_linear_stack feat-a feat-b
  git push origin feat-a feat-b >/dev/null 2>&1 || true
  mock_gh_with_prs '[{"number":5,"headRefName":"feat-b","baseRefName":"main"}]'

  run git-stack submit
  assert_success

  assert_gh_called "pr edit 5 --base feat-a"
}

@test "submit skips PR creation when PR exists with correct base" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1 || true
  mock_gh_with_prs '[{"number":10,"headRefName":"feat-a","baseRefName":"main"}]'

  run git-stack submit
  assert_success
  assert_output --partial "already targets"

  refute_gh_called "pr create"
  refute_gh_called "pr edit"
}

@test "submit fails when not in a stack" {
  run git-stack submit
  assert_failure
  assert_output --partial "no stack to submit"
}

@test "submit only pushes root-to-current, not siblings" {
  create_linear_stack feat-a feat-b
  create_stack_branch feat-c feat-a
  git checkout feat-b >/dev/null 2>&1
  git push origin feat-a feat-b feat-c >/dev/null 2>&1 || true
  mock_gh_with_prs '[]'

  run git-stack submit
  assert_success

  assert_gh_called "pr create --head feat-a --base main"
  assert_gh_called "pr create --head feat-b --base feat-a"
  refute_gh_called "feat-c"
}

@test "submit fails when gh is not installed" {
  create_linear_stack feat-a
  rm -f "$TEST_TMPDIR/mock-bin/gh"
  export PATH="$(path_without_gh)"

  run git-stack submit
  assert_failure
  assert_output --partial "'gh' CLI not found"
}

@test "submit --draft creates draft PRs" {
  create_linear_stack feat-a feat-b
  git push origin feat-a feat-b >/dev/null 2>&1 || true
  mock_gh_with_prs '[]'

  run git-stack submit --draft
  assert_success

  assert_gh_called "pr create --head feat-a --base main --fill --draft"
  assert_gh_called "pr create --head feat-b --base feat-a --fill --draft"
}

@test "submit does not create draft PRs by default" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1 || true
  mock_gh_with_prs '[]'

  run git-stack submit
  assert_success

  assert_gh_called "pr create --head feat-a --base main"
  refute_gh_called "--draft"
}

@test "submit rejects unknown flags" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1 || true
  mock_gh_with_prs '[]'

  run git-stack submit --bogus
  assert_failure
  assert_output --partial "unknown flag"
}

@test "submit push alias works" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1 || true
  mock_gh_with_prs '[]'

  run git-stack push
  assert_success
  assert_gh_called "pr create"
}

@test "submit refuses to push over unseen remote commits" {
  create_linear_stack feat-a
  git push -u origin feat-a >/dev/null 2>&1
  mock_gh_with_prs '[]'

  # Simulate a teammate pushing to origin/feat-a after our last fetch.
  export GIT_DIR="$TEST_TMPDIR/origin.git"
  tip=$(git rev-parse refs/heads/feat-a)
  new_commit=$(echo "teammate work" | git commit-tree "${tip}^{tree}" -p "$tip")
  git update-ref refs/heads/feat-a "$new_commit"
  unset GIT_DIR

  run git-stack submit
  assert_failure
  assert_output --partial "remote drift"
  refute_gh_called "pr create"
}

@test "submit reports the achieved push count" {
  create_linear_stack feat-a feat-b
  git push origin feat-a feat-b >/dev/null 2>&1 || true
  mock_gh_with_prs '[]'

  run git-stack submit
  assert_success
  assert_output --partial "2 branches pushed"
}

@test "submit refuses remote commits even after a background fetch" {
  create_linear_stack feat-a
  git push -u origin feat-a >/dev/null 2>&1
  mock_gh_with_prs '[]'

  # Teammate pushes to origin/feat-a...
  export GIT_DIR="$TEST_TMPDIR/origin.git"
  tip=$(git rev-parse refs/heads/feat-a)
  new_commit=$(echo "teammate work" | git commit-tree "${tip}^{tree}" -p "$tip")
  git update-ref refs/heads/feat-a "$new_commit"
  unset GIT_DIR

  # ...and a background fetch (IDE, status check) updates our tracking ref
  # BEFORE submit snapshots it — the drift check alone can't see this.
  git fetch origin >/dev/null 2>&1

  run git-stack submit
  assert_failure
  assert_output --partial "push rejected"
  refute_gh_called "pr create"

  # The teammate's commit must survive on the remote.
  export GIT_DIR="$TEST_TMPDIR/origin.git"
  [ "$(git rev-parse refs/heads/feat-a)" = "$new_commit" ]
  unset GIT_DIR
}
