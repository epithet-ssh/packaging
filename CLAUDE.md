# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project overview

This is the release orchestration repo for epithet-ssh projects. It coordinates releases across:

- **epithet** - Core Go binary (goreleaser)
- **epithet-macos** - macOS menubar app (Swift)
- **epithet-aws** - AWS Lambda deployment template (Terraform)
- **homebrew-tap** - Homebrew formulas and casks

All projects share unified versioning driven from the epithet repo.

## Task management

Use `yatl` (Yet Another Task List) for task tracking, not TodoWrite.

```bash
yatl new "Task description"
yatl start <id>
yatl log <id> "progress"
yatl close <id> --reason "..."
yatl list
```

## Version control policy

Do NOT create commits. The user handles all git operations.

You may:
- View history (`git log`, `git status`, `git diff`)
- Stage files for review (`git add`)

You must NOT:
- Create commits (`git commit`)
- Push changes (`git push`)

## Key files

- `Makefile` - All release automation
- `templates/epithet.rb.tmpl` - Homebrew formula template
- `templates/epithet-agent-mac.rb.tmpl` - Homebrew cask template
- `.envrc` - Apple notarization credentials (gitignored)
- `.envrc.example` - Template for credentials

## Makefile targets

| Target | Description |
|--------|-------------|
| `make release` | Full release (auto-detect version) |
| `make release VERSION=patch` | Bump patch version |
| `make release VERSION=minor` | Bump minor version |
| `make release VERSION=major` | Bump major version |
| `make release-test` | Test pipeline without side effects |
| `make snapshot` | Local build only |
| `make versions` | Show versions across all repos |
| `make next-version` | Show what next version would be |
| `make clean` | Remove dist/ |

## Release flow

1. `make release` (or with VERSION=)
2. Tests epithet (`make test`)
3. Tags and releases epithet via goreleaser
4. Builds epithet-macos DMG, tags and releases
5. Updates epithet-aws Makefile (commit only, no tag)
6. Generates homebrew formulas from templates
7. Audits formulas with `brew audit --strict`
8. Commits to homebrew-tap

## Version management

Uses [svu](https://github.com/caarlos0/svu) for semantic versioning based on conventional commits in the epithet repo.

Commit prefixes:
- `fix:` → patch bump
- `feat:` → minor bump
- `feat!:` or `BREAKING CHANGE:` → major bump

## Prerequisites

- `svu` - `brew install svu`
- `goreleaser` - `brew install goreleaser`
- `gh` - GitHub CLI for releases
- Apple Developer credentials in `.envrc` for notarization
