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
  ┌──┴──┐
  ▼     ▼
epithet-aws    epithet-macos (GitHub release)
(commit)            │
  │                 │
  └────────┬────────┘
           ▼
     homebrew-tap
     (commit)
```

All projects share the same version number.

## Prerequisites

```bash
brew install svu goreleaser gh
```

For macOS app notarization, copy `.envrc.example` to `.envrc` and fill in your Apple Developer credentials:

```bash
cp .envrc.example .envrc
# Edit .envrc with your credentials
direnv allow
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
# Build epithet and epithet-macos locally
make build-all

# Snapshot build (no release)
make snapshot
```

## Directory structure

```
packaging/
├── Makefile                      # Release automation
├── templates/
│   ├── epithet.rb.tmpl           # Homebrew formula template
│   └── epithet-agent-mac.rb.tmpl # Homebrew cask template
├── .envrc.example                # Credential template
├── .envrc                        # Your credentials (gitignored)
└── dist/                         # Build artifacts (gitignored)
```

## Sibling repos

This repo expects sibling checkouts:

```
epithet-ssh/
├── packaging/      # This repo
├── epithet/        # Core binary
├── epithet-macos/  # macOS app
├── epithet-aws/    # AWS deployment
└── homebrew-tap/   # Homebrew formulas
```
