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

@test "submit push alias works" {
  create_linear_stack feat-a
  git push origin feat-a >/dev/null 2>&1 || true
  mock_gh_with_prs '[]'

  run git-stack push
  assert_success
  assert_gh_called "pr create"
}
