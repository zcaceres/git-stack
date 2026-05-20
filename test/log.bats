#!/usr/bin/env bats

setup() {
  load test_helper/setup
  setup
}

teardown() {
  teardown
}

@test "log on trunk with no stack shows no stack" {
  # Remove gh from PATH so it doesn't interfere
  export PATH="$PROJECT_ROOT/bin:$TEST_TMPDIR/mock-bin:$PATH"
  mock_gh 'exit 1'

  run git-stack log
  assert_success
  assert_output --partial "no stack"
}

@test "log shows linear stack with branch names" {
  create_linear_stack feat-a feat-b
  mock_gh_with_prs '[]'

  run git-stack log
  assert_success
  assert_output --partial "main"
  assert_output --partial "feat-a"
  assert_output --partial "feat-b"
  assert_output --partial "you are here"
}

@test "log shows you are here on current branch in middle of stack" {
  create_linear_stack feat-a feat-b feat-c
  git checkout feat-a >/dev/null 2>&1
  mock_gh_with_prs '[]'

  run git-stack log
  assert_success

  # feat-a line should have the marker
  local feat_a_line
  feat_a_line=$(echo "$output" | grep "feat-a")
  echo "$feat_a_line" | grep -q "you are here"

  # feat-b and feat-c should not
  local feat_b_line
  feat_b_line=$(echo "$output" | grep "feat-b")
  ! echo "$feat_b_line" | grep -q "you are here"
}

@test "log displays PR numbers and states" {
  create_linear_stack feat-a feat-b
  mock_gh_with_prs '[{"number":42,"headRefName":"feat-a","state":"OPEN","title":"Add A","url":"https://github.com/test/test/pull/42"},{"number":43,"headRefName":"feat-b","state":"MERGED","title":"Add B","url":"https://github.com/test/test/pull/43"}]'

  run git-stack log
  assert_success
  assert_output --partial "#42"
  assert_output --partial "#43"
}

@test "log works without gh installed" {
  create_linear_stack feat-a
  rm -f "$TEST_TMPDIR/mock-bin/gh"
  export PATH="$(path_without_gh)"

  run git-stack log
  assert_success
  assert_output --partial "feat-a"
}

@test "log shows branching stacks" {
  create_stack_branch feat-a main
  create_stack_branch feat-b main

  mock_gh_with_prs '[]'

  run git-stack log
  assert_success
  assert_output --partial "feat-a"
  assert_output --partial "feat-b"
}

@test "log ls alias works" {
  create_linear_stack feat-a
  mock_gh_with_prs '[]'

  run git-stack ls
  assert_success
  assert_output --partial "feat-a"
}

@test "log handles gh failure gracefully" {
  create_linear_stack feat-a
  mock_gh 'exit 1'

  run git-stack log
  assert_success
  assert_output --partial "feat-a"
}
