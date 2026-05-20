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
git stack help                                            Show help
git stack --version                                       Show version
```

### Merging a stack

`git stack merge` merges the bottom-most open PR. Add `--all` to merge the entire stack bottom-up. Each child PR is retargeted to `main` before the next merge.

Three strategies:

| Strategy | Flag | Best for |
|----------|------|----------|
| Merge commit | `--merge` (default) | Stacks — preserves SHAs, no child rebasing needed |
| Rebase | `--rebase` | Linear history — rewrites SHAs, children rebased automatically |
| Squash | `--squash` | Single-commit PRs — same tradeoffs as rebase |

**Important:** Never use `gh pr merge --delete-branch` with stacked PRs. GitHub's auto-retarget is a repo setting, not guaranteed. Deleting a base branch can auto-close child PRs irrecoverably.

## Bundling in downstream repos

Consumer repos (like [claude-stacked-prs](https://github.com/zcaceres/claude-stacked-prs) and [gemini-stacked-prs](https://github.com/zcaceres/gemini-stacked-prs)) bundle a copy of `bin/git-stack` and symlink it during install. To update the bundled copy to the latest release:

```bash
curl -fsSL https://github.com/zcaceres/git-stack/releases/latest/download/git-stack \
  -o bin/git-stack && chmod +x bin/git-stack
```

This keeps each consumer repo self-contained — no runtime dependency on this repo.

## Development setup

```bash
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
git tag v0.2.0
git push origin v0.2.0
```

CI creates a GitHub Release with `bin/git-stack` as a downloadable asset. The release workflow validates that the tag matches `VERSION` in the script.

## Used by

- [claude-stacked-prs](https://github.com/zcaceres/claude-stacked-prs) — Claude Code hooks and commands for stacked PRs
- [gemini-stacked-prs](https://github.com/zcaceres/gemini-stacked-prs) — Gemini CLI hooks and commands for stacked PRs

## License

MIT
