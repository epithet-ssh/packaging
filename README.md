# epithet-ssh/packaging

Release orchestration for epithet-ssh projects.

## Overview

This repo coordinates releases across the epithet-ssh ecosystem:

```
make release
     │
     ▼
  epithet (goreleaser → GitHub release)
     │
     ├──────────┐
     ▼          ▼
epithet-aws    homebrew-tap
(commit)       (commit - formula)
```

**Note:** epithet-macos releases independently from its own repository with separate versioning.

## Prerequisites

```bash
brew install svu goreleaser gh
```

## Usage

### Test the release pipeline

```bash
make release-test
```

Runs the full pipeline without pushing tags, creating releases, or committing. Artifacts go to `dist/test/`.

### Release

```bash
# Auto-detect version from conventional commits
make release

# Explicit version bump
make release VERSION=patch   # 0.6.0 → 0.6.1
make release VERSION=minor   # 0.6.0 → 0.7.0
make release VERSION=major   # 0.6.0 → 1.0.0

# Explicit version number
make release VERSION=1.2.3
```

### Check versions

```bash
# Current versions across all repos
make versions

# What the next version would be
make next-version
```

### Local build

```bash
# Build epithet locally
make build

# Snapshot build (no release)
make snapshot
```

## Directory structure

```
packaging/
├── Makefile                      # Release automation
├── templates/
│   └── epithet.rb.tmpl           # Homebrew formula template
└── dist/                         # Build artifacts (gitignored)
```

## Sibling repos

This repo expects sibling checkouts:

```
epithet-ssh/
├── packaging/      # This repo
├── epithet/        # Core binary
├── epithet-aws/    # AWS deployment
└── homebrew-tap/   # Homebrew formulas
```

epithet-macos is developed and released independently - see [epithet-ssh/epithet-macos](https://github.com/epithet-ssh/epithet-macos) for details.
