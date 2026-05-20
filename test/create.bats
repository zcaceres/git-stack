#!/usr/bin/env bats

setup() {
  load test_helper/setup
  setup
}

teardown() {
  teardown
}

@test "create with explicit branch name creates branch and sets parent" {
  run git-stack create my-feature
  assert_success
  assert_output --partial "my-feature"
  assert_output --partial "main"

  [ "$(current_branch)" = "my-feature" ]
  [ "$(get_stack_parent my-feature)" = "main" ]
  [ "$(git config --get branch.my-feature.gh-merge-base)" = "main" ]
}

@test "create with -m derives branch name and commits" {
  echo "new content" > new.txt
  git add new.txt

  run git-stack create -m "Add login form"
  assert_success

  [ "$(current_branch)" = "add-login-form" ]
  [ "$(get_stack_parent add-login-form)" = "main" ]

  # Verify the commit was made
  run git log --oneline -1
  assert_output --partial "Add login form"
}

@test "create with both name and -m uses explicit name" {
  echo "stuff" > stuff.txt
  git add stuff.txt

  run git-stack create custom-name -m "Some message"
  assert_success

  [ "$(current_branch)" = "custom-name" ]

  run git log --oneline -1
  assert_output --partial "Some message"
}

@test "create with -m but no staged changes warns" {
  run git-stack create -m "Empty commit attempt"
  assert_success

  [ "$(current_branch)" = "empty-commit-attempt" ]
  assert_output --partial "no staged changes"
}

@test "create fails with no arguments" {
  run git-stack create
  assert_failure
  assert_output --partial "provide a branch name or -m"
}

@test "create fails if branch already exists" {
  git branch existing >/dev/null 2>&1

  run git-stack create existing
  assert_failure
  assert_output --partial "already exists"
  [ "$(current_branch)" = "main" ]
}

@test "create fails on detached HEAD" {
  git checkout --detach HEAD >/dev/null 2>&1

  run git-stack create some-branch
  assert_failure
  assert_output --partial "HEAD is detached"
}

@test "create stacks on non-trunk branch" {
  create_stack_branch feat-a main

  run git-stack create feat-b
  assert_success

  [ "$(current_branch)" = "feat-b" ]
  [ "$(get_stack_parent feat-b)" = "feat-a" ]
}

@test "create --help shows usage" {
  run git-stack create --help
  assert_success
  assert_output --partial "Usage:"
}

@test "create rejects unknown flags" {
  run git-stack create --invalid
  assert_failure
  assert_output --partial "unknown flag"
}

@test "create outside git repo fails" {
  cd "$TEST_TMPDIR"

  run git-stack create foo
  assert_failure
  assert_output --partial "not a git repository"
}
