#!/usr/bin/env bats

setup() {
  load test_helper/setup
  setup
}

teardown() {
  teardown
}

# --- slugify ---

@test "slugify lowercases and replaces spaces" {
  run run_fn slugify "Add User Authentication"
  assert_success
  assert_output "add-user-authentication"
}

@test "slugify replaces special characters with hyphens" {
  run run_fn slugify 'fix: handle $pecial chars!@#'
  assert_success
  assert_output "fix-handle-pecial-chars"
}

@test "slugify collapses consecutive hyphens" {
  run run_fn slugify "too---many   spaces"
  assert_success
  assert_output "too-many-spaces"
}

@test "slugify strips leading and trailing hyphens" {
  run run_fn slugify "--leading-trailing--"
  assert_success
  assert_output "leading-trailing"
}

@test "slugify truncates to 60 characters" {
  local long_input
  long_input=$(printf 'a%.0s' {1..100})
  run run_fn slugify "$long_input"
  assert_success
  [ "${#output}" -eq 60 ]
}

@test "slugify returns empty for all-symbol input" {
  run run_fn slugify '!!!@@@###'
  assert_success
  assert_output ""
}

# --- trunk_branch ---

@test "trunk_branch returns main when main exists" {
  run run_fn trunk_branch
  assert_success
  assert_output "main"
}

@test "trunk_branch returns master when only master exists" {
  cd "$TEST_TMPDIR"
  rm -rf repo
  mkdir repo && cd repo
  git init -b master >/dev/null 2>&1
  git config user.name "Test" && git config user.email "t@t.com"
  echo x > x.txt && git add x.txt && git commit -m "init" >/dev/null 2>&1

  run run_fn trunk_branch
  assert_success
  assert_output "master"
}

@test "trunk_branch dies when neither main nor master exist" {
  cd "$TEST_TMPDIR"
  rm -rf repo
  mkdir repo && cd repo
  git init -b develop >/dev/null 2>&1
  git config user.name "Test" && git config user.email "t@t.com"
  echo x > x.txt && git add x.txt && git commit -m "init" >/dev/null 2>&1

  run run_fn trunk_branch
  assert_failure
  assert_output --partial "could not detect trunk branch"
}

# --- config helpers ---

@test "get_stack_parent returns empty when no parent set" {
  run get_stack_parent main
  assert_success
  assert_output ""
}

@test "set_stack_parent and get_stack_parent round-trip" {
  git checkout -b feat >/dev/null 2>&1
  run_fn set_stack_parent feat main

  run get_stack_parent feat
  assert_success
  assert_output "main"

  # Also verify gh-merge-base key
  run git config --get branch.feat.gh-merge-base
  assert_success
  assert_output "main"
}

@test "unset_stack_parent removes both config keys" {
  git checkout -b feat >/dev/null 2>&1
  run_fn set_stack_parent feat main
  run_fn unset_stack_parent feat

  run git config --get branch.feat.stack-parent
  assert_failure

  run git config --get branch.feat.gh-merge-base
  assert_failure
}

# --- stack traversal ---

@test "walk_to_root returns linear stack in root-first order" {
  create_linear_stack feat-a feat-b feat-c

  run run_fn walk_to_root feat-c
  assert_success
  local lines
  IFS=$'\n' read -rd '' -a lines <<< "$output" || true
  [ "${lines[0]}" = "main" ]
  [ "${lines[1]}" = "feat-a" ]
  [ "${lines[2]}" = "feat-b" ]
  [ "${lines[3]}" = "feat-c" ]
}

@test "walk_to_root returns just the branch when no parent" {
  run run_fn walk_to_root main
  assert_success
  assert_output "main"
}

@test "walk_to_root detects cycle and dies" {
  git checkout -b cycle-a >/dev/null 2>&1
  echo a > a.txt && git add a.txt && git commit -m a >/dev/null 2>&1
  git checkout -b cycle-b >/dev/null 2>&1
  echo b > b.txt && git add b.txt && git commit -m b >/dev/null 2>&1

  git config branch.cycle-a.stack-parent cycle-b
  git config branch.cycle-b.stack-parent cycle-a

  run run_fn walk_to_root cycle-a
  assert_failure
  assert_output --partial "cycle detected"
}

@test "find_children lists direct children only" {
  create_stack_branch feat-a main
  create_stack_branch feat-b feat-a
  create_stack_branch feat-c main

  run run_fn find_children main
  assert_success
  assert_output --partial "feat-a"
  assert_output --partial "feat-c"
  refute_output --partial "feat-b"
}

@test "find_children returns empty when no children" {
  run run_fn find_children main
  assert_success
  [ -z "$(echo "$output" | tr -d '[:space:]')" ]
}

@test "walk_descendants returns DFS order" {
  create_stack_branch feat-a main
  create_stack_branch feat-b feat-a
  create_stack_branch feat-c feat-a

  run run_fn walk_descendants main
  assert_success
  assert_output --partial "feat-a"
  assert_output --partial "feat-b"
  assert_output --partial "feat-c"

  # feat-a must appear before its children
  local a_line b_line c_line
  a_line=$(echo "$output" | grep -n "feat-a" | head -1 | cut -d: -f1)
  b_line=$(echo "$output" | grep -n "feat-b" | head -1 | cut -d: -f1)
  c_line=$(echo "$output" | grep -n "feat-c" | head -1 | cut -d: -f1)
  [ "$a_line" -lt "$b_line" ]
  [ "$a_line" -lt "$c_line" ]
}

@test "full_stack returns complete stack from any branch" {
  create_linear_stack feat-a feat-b
  git checkout feat-a >/dev/null 2>&1

  run run_fn full_stack
  assert_success
  assert_output --partial "main"
  assert_output --partial "feat-a"
  assert_output --partial "feat-b"
}

@test "stack_to_current returns root-to-current only" {
  create_linear_stack feat-a feat-b feat-c
  git checkout feat-b >/dev/null 2>&1

  run run_fn stack_to_current
  assert_success
  assert_output --partial "main"
  assert_output --partial "feat-a"
  assert_output --partial "feat-b"
  refute_output --partial "feat-c"
}

# --- require_not_detached ---

@test "require_not_detached fails on detached HEAD" {
  git checkout --detach HEAD >/dev/null 2>&1
  run run_fn require_not_detached
  assert_failure
  assert_output --partial "HEAD is detached"
}

# --- dispatcher ---

@test "version flag prints version" {
  run git-stack --version
  assert_success
  assert_output --partial "git stack v"
}

@test "help flag shows usage" {
  run git-stack --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "create"
  assert_output --partial "log"
  assert_output --partial "submit"
  assert_output --partial "merge"
}

@test "no arguments shows usage" {
  run git-stack
  assert_success
  assert_output --partial "Usage:"
}

@test "unknown command dies" {
  run git-stack foobar
  assert_failure
  assert_output --partial "unknown command: foobar"
}
