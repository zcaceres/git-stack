# git-stack

Lightweight stacked PR manager. Single bash script. Requires only `git` and [`gh`](https://cli.github.com/).

Stack parent relationships are stored in `git config` (`branch.<name>.stack-parent`). No external services, no auth beyond `gh auth login`.

## Install

**Quick install (from latest release):**

```bash
mkdir -p ~/.local/bin
curl -fsSL https://github.com/zcaceres/git-stack/releases/latest/download/git-stack \
  -o ~/.local/bin/git-stack && chmod +x ~/.local/bin/git-stack
```

Make sure `~/.local/bin` is on your `PATH`.

**From source:**

```bash
git clone https://github.com/zcaceres/git-stack.git ~/git-stack
ln -sf ~/git-stack/bin/git-stack ~/.local/bin/git-stack
```

## Usage

```
git stack create [<branch-name>] [-m "message"]          Create a stacked branch
git stack log                                             Show the current stack
git stack submit                                          Push & create/update PRs
git stack merge [--all] [--rebase|--squash] [--dry-run]   Merge PRs bottom-up
git stack sync [--no-push]                                Sync stack onto updated trunk
git stack help                                            Show help
git stack --version                                       Show version
```

### Syncing a stack

`git stack sync` rebases the current stack onto the latest trunk (e.g., after a separate PR merges into `main`). It uses `git rebase --onto` internally, so each branch replays only its own unique commits — no redundant conflicts from ancestor commits being replayed at every layer.

Add `--no-push` to rebase locally without force-pushing.

### Merging a stack

`git stack merge` merges the bottom-most open PR. Add `--all` to merge the entire stack bottom-up. Each child PR is retargeted to `main` before the next merge.

Three strategies:

| Strategy | Flag | Best for |
|----------|------|----------|
| Merge commit | `--merge` (default) | Stacks — preserves SHAs, no child rebasing needed |
| Rebase | `--rebase` | Linear history — rewrites SHAs, children rebased automatically |
| Squash | `--squash` | Single-commit PRs — same tradeoffs as rebase |

**Important:** Never use `gh pr merge --delete-branch` with stacked PRs. GitHub's auto-retarget is a repo setting, not guaranteed. Deleting a base branch can auto-close child PRs irrecoverably.

#### If `merge --all` stops partway

`merge --all` lands one PR at a time, so a failure midway leaves the PRs below it already merged. Remote drift, a rebase conflict, or a push rejection all abort at that point by design — continuing would push a branch built on a stale base.

Nothing is lost. Resolve the reported cause, then re-run `git stack merge --all` **from the top of the stack**: it re-reads open PRs from GitHub, so already-merged ones drop out of the list and it resumes from the first one still open.

```bash
git checkout <top-branch>
git stack merge --all --squash    # same flags as the run that stopped
```

The checkout matters for `--rebase` and `--squash`. Those strategies check out each branch as they go, and an abort skips the step that returns you to where you started — so you're left mid-stack. `merge --all` only walks from trunk up to the branch you have checked out, so re-running from there sees just the PR it already merged and stops with:

```
error: no open PRs found in the stack
```

while the PRs above it are still open. The default `--merge` strategy never switches branches, so `HEAD` is already correct there.

Before re-running, confirm the remaining PRs point where you expect:

```bash
gh pr list --author @me --json number,baseRefName,state \
  -q '.[] | "\(.number) \(.baseRefName) \(.state)"'
```

A child whose parent merged should read `main`. If one still names a deleted or merged branch, retarget it before resuming:

```bash
gh pr edit <PR> --base main
```

## Bundling in downstream repos

Consumer repos (like [claude-stacked-prs](https://github.com/zcaceres/claude-stacked-prs) and [gemini-stacked-prs](https://github.com/zcaceres/gemini-stacked-prs)) bundle a copy of `bin/git-stack` and symlink it during install. To update the bundled copy to the latest release:

```bash
curl -fsSL https://github.com/zcaceres/git-stack/releases/latest/download/git-stack \
  -o bin/git-stack && chmod +x bin/git-stack
```

This keeps each consumer repo self-contained — no runtime dependency on this repo.

## Development setup

Requires [`jq`](https://jqlang.github.io/jq/) on your PATH, in addition to the runtime dependencies. The `gh` mocks reimplement `--jq` by shelling out to it. `git stack` itself never calls `jq` — `gh` has its own implementation built in — so this is a test-only requirement.

```bash
brew install jq          # or your platform's package manager
bun install
git config core.hooksPath .githooks
```

This installs the BATS test framework and enables the pre-push hook, which runs the full test suite before every push. Tests use sandboxed git repos and mock `gh`, so no GitHub access is needed.

To run tests manually:

```bash
./node_modules/.bin/bats test/
```

## Releasing

1. Bump `VERSION` in `bin/git-stack`
2. Commit and push to main
3. Tag and push:

```bash
git tag v0.3.0
git push origin v0.3.0
```

CI creates a GitHub Release with `bin/git-stack` as a downloadable asset. The release workflow validates that the tag matches `VERSION` in the script.

## Used by

- [claude-stacked-prs](https://github.com/zcaceres/claude-stacked-prs) — Claude Code hooks and commands for stacked PRs
- [gemini-stacked-prs](https://github.com/zcaceres/gemini-stacked-prs) — Gemini CLI hooks and commands for stacked PRs

## License

MIT
