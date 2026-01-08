---
yatl_version: 1
title: Virtual Monorepo for epithet-ssh Projects
id: cnfj57dx
created: 2026-01-07T03:36:22.716193Z
updated: 2026-01-08T04:24:28.198474Z
author: Brian McCallister
priority: medium
tags:
- planning
---

# Virtual Monorepo for epithet-ssh Projects

## Chosen Approach

Create a **coordination repo** (`epithet-ssh/dev` or similar) with Makefile targets that:
1. Ensure all sibling repos are checked out
2. Build/test across repos using local binaries
3. Coordinate releases and downstream updates

This preserves epithet-aws as a template repo while solving the testing/release coordination problem.

## Problem Statement

Four related projects need coordinated releases:
- **epithet** (Go) - core binary, v0.6.0
- **epithet-aws** (Terraform) - template repo, pins epithet version
- **epithet-macos** (Swift) - bundles epithet binary, v0.2.0
- **homebrew-tap** - Formula for epithet + Cask for macos app

Pain points: forgetting downstream updates, version drift, testing across projects.

**Constraint:** epithet-aws is a template repo - users clone it and merge upstream. Moving to true monorepo would break this pattern.

## Current Dependencies

```
epithet (releases)
    ├── epithet-aws/Makefile (EPITHET_VERSION)
    ├── epithet-macos/Resources/epithet (bundled binary)
    └── homebrew-tap/Formula/epithet.rb (version + 4 SHA256s)

epithet-macos (releases)
    └── homebrew-tap/Casks/epithet-agent-mac.rb (version + SHA256)
```

---

## Option 1: True Monorepo

Merge all repos into a single repository.

**Structure:**
```
epithet-ssh/
├── cmd/epithet/        (Go - CLI)
├── pkg/                (Go - libraries)
├── macos/              (Swift - menubar app)
├── aws/                (Terraform - Lambda deployment)
├── homebrew/           (Homebrew formulas)
└── Makefile            (unified release)
```

**Pros:**
- Single source of truth for versions
- Atomic commits across all projects
- Easy to test changes that span projects
- One CI/CD pipeline
- No version drift possible

**Cons:**
- Mixed languages (Go, Swift, Terraform) in one repo
- Larger clone size
- More complex CI (needs Go, Swift, Terraform toolchains)
- Contributors must clone everything
- Homebrew taps typically want their own repo

**Best for:** Small teams, tightly coupled projects, you're the main/only maintainer

---

## Option 2: Cascading CI Automation

Keep separate repos, use GitHub Actions to trigger downstream updates.

**How it works:**
1. Release epithet → GitHub Action creates PRs in epithet-aws, homebrew-tap
2. PRs auto-compute SHA256 hashes
3. Merge PRs to complete cascade
4. epithet-macos release → PR to homebrew-tap Casks

**Implementation:**
- `epithet/.github/workflows/release.yml` triggers `repository_dispatch` to downstream repos
- Downstream repos have workflows that receive dispatch, compute new version/hashes, create PR

**Pros:**
- Repos stay independent
- Automated hash computation
- PRs provide review opportunity
- Can still do manual releases if needed
- Familiar GitHub workflow

**Cons:**
- More CI complexity to set up initially
- Cross-repo tokens/permissions needed
- Cascading failures if one step breaks
- Testing coordination still manual

**Best for:** Open source projects, multiple maintainers, want PR-based review

---

## Option 3: Local Release Script

Keep separate repos, create a local tool that orchestrates releases.

**How it works:**
```bash
# In epithet repo after tagging:
./scripts/release-cascade.sh v0.7.0

# Script does:
# 1. Wait for GitHub release artifacts to be available
# 2. Download and compute SHA256 hashes
# 3. Update epithet-aws/Makefile
# 4. Update homebrew-tap/Formula/epithet.rb
# 5. Create commits (or PRs via gh cli)
```

**Pros:**
- Simple to understand and debug
- Full manual control
- No CI complexity
- Works offline for local testing
- Can be run selectively

**Cons:**
- Must remember to run it
- Requires local checkouts of all repos
- No automation safety net

**Best for:** Solo maintainer who wants control, infrequent releases

---

## Option 4: Version Manifest File

Keep separate repos, use a shared version manifest that downstream repos read.

**How it works:**
1. Create `epithet-ssh/versions` repo with `versions.json`:
   ```json
   {
     "epithet": "0.7.0",
     "epithet-macos": "0.2.0",
     "hashes": {
       "epithet_0.7.0_darwin_arm64": "sha256:..."
     }
   }
   ```
2. Downstream repos CI pulls from manifest
3. epithet release updates manifest
4. Downstream repos auto-rebuild on manifest change

**Pros:**
- Single source of truth for versions
- Repos stay independent
- Can add/remove projects easily

**Cons:**
- Extra repo to maintain
- Build-time dependency on external file
- More moving parts

**Best for:** Larger ecosystems with many downstream consumers

---

## Implementation: Virtual Monorepo

Create `epithet-ssh/dev` repo (or use parent directory as untracked workspace) with a Makefile that orchestrates across sibling repos.

### Directory Structure

```
epithet-ssh/                    # Parent directory (workspace)
├── dev/                        # NEW: Coordination repo
│   ├── Makefile                # Orchestration targets
│   ├── scripts/
│   │   ├── ensure-repos.sh     # Clone/update sibling repos
│   │   ├── release.sh          # Coordinate releases
│   │   └── update-homebrew.sh  # Compute SHA256s, update formulas
│   └── README.md
├── epithet/                    # Existing
├── epithet-aws/                # Existing (stays template repo)
├── epithet-macos/              # Existing
└── homebrew-tap/               # Existing (symlink)
```

### Makefile Targets

```makefile
# dev/Makefile

REPOS = epithet epithet-aws epithet-macos
EPITHET_BIN = $(PWD)/../epithet/bin/epithet

# Ensure all repos are checked out
.PHONY: ensure-repos
ensure-repos:
	@./scripts/ensure-repos.sh

# Build epithet
.PHONY: build
build: ensure-repos
	$(MAKE) -C ../epithet build

# Test epithet-aws with local epithet binary
.PHONY: test-aws
test-aws: build
	cd ../epithet-aws && EPITHET_BIN=$(EPITHET_BIN) $(MAKE) test

# Build macos app with local epithet binary
.PHONY: build-macos
build-macos: build
	cp $(EPITHET_BIN) ../epithet-macos/Resources/epithet
	$(MAKE) -C ../epithet-macos build

# Build everything
.PHONY: build-all
build-all: build test-aws build-macos

# Release epithet and update downstream
.PHONY: release
release:
	@./scripts/release.sh $(VERSION)

# Update homebrew-tap after release
.PHONY: update-homebrew
update-homebrew:
	@./scripts/update-homebrew.sh $(VERSION)
```

### scripts/ensure-repos.sh

```bash
#!/bin/bash
set -e

PARENT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GITHUB_ORG="epithet-ssh"

repos=(epithet epithet-aws epithet-macos)

for repo in "${repos[@]}"; do
    if [ ! -d "$PARENT_DIR/$repo" ]; then
        echo "Cloning $repo..."
        git clone "https://github.com/$GITHUB_ORG/$repo.git" "$PARENT_DIR/$repo"
    else
        echo "$repo exists"
    fi
done

# homebrew-tap is a symlink, check it exists
if [ ! -L "$PARENT_DIR/homebrew-tap" ] && [ ! -d "$PARENT_DIR/homebrew-tap" ]; then
    echo "Warning: homebrew-tap not found"
fi
```

### scripts/release.sh

```bash
#!/bin/bash
set -e

VERSION="$1"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

PARENT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== Releasing epithet $VERSION ==="

# 1. Tag and release epithet
cd "$PARENT_DIR/epithet"
git tag "$VERSION"
git push origin "$VERSION"
echo "Pushed tag $VERSION, waiting for goreleaser..."

# 2. Wait for release artifacts (poll GitHub API)
echo "Waiting for release artifacts..."
while ! gh release view "$VERSION" --json assets -q '.assets | length' | grep -q '[1-9]'; do
    sleep 10
done

# 3. Update downstream
"$(dirname "$0")/update-downstream.sh" "$VERSION"
```

### scripts/update-homebrew.sh

```bash
#!/bin/bash
set -e

VERSION="${1#v}"  # Strip leading 'v' if present
PARENT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== Updating homebrew-tap for $VERSION ==="

# Download and hash each platform binary
declare -A HASHES
for arch in darwin_arm64 darwin_amd64 linux_arm64 linux_amd64; do
    url="https://github.com/epithet-ssh/epithet/releases/download/v${VERSION}/epithet_${VERSION}_${arch}.tar.gz"
    echo "Fetching $arch..."
    hash=$(curl -sL "$url" | shasum -a 256 | cut -d' ' -f1)
    HASHES[$arch]=$hash
done

# Update Formula/epithet.rb
cd "$PARENT_DIR/homebrew-tap"
# ... sed or ruby script to update version and hashes ...

echo "Updated homebrew-tap/Formula/epithet.rb"
echo "Review and commit manually, or: git add -A && git commit -m 'Update epithet to $VERSION'"
```

### Modifications to Existing Repos

**epithet-aws/Makefile** - add LOCAL_EPITHET support:
```makefile
# At top of Makefile
ifdef EPITHET_BIN
    # Use provided binary (for dev/testing)
else
    # Existing download logic
    EPITHET_VERSION := v0.5.2
    # ... download-binary target ...
endif
```

**epithet-macos/Makefile** - similar pattern for Resources/epithet

---

### Workflow

**Development (testing cross-repo changes):**
```bash
cd dev
make test-aws      # Builds epithet, tests with epithet-aws
make build-macos   # Builds epithet, builds macos app
```

**Release:**
```bash
cd dev
make release VERSION=v0.7.0
# Tags epithet, waits for artifacts, updates downstream repos
```

**Manual downstream update (if needed):**
```bash
cd dev
make update-homebrew VERSION=v0.7.0
```

---

### Trade-offs

**What we get:**
- Cross-repo testing with `make test-aws`
- Automated release cascade
- Repos stay independent
- epithet-aws remains a template repo

**What we don't get:**
- Atomic commits (changes are separate commits per repo)
- Guaranteed version consistency (requires discipline)

Good enough for solo maintainer. Can evolve later if needed.

---
# Log: 2026-01-07T03:36:22Z Brian McCallister

Created task.

---
# Log: 2026-01-07T03:36:33Z Brian McCallister

Added plan to task description

---
# Log: 2026-01-08T03:56:44Z Brian McCallister

Implemented Makefile in packaging repo with release automation

---
# Log: 2026-01-08T04:08:24Z Brian McCallister

Added svu version management and conventional commits documentation

---
# Log: 2026-01-08T04:13:25Z Brian McCallister

Added pre-release testing: epithet tests before tagging, homebrew audit before committing

---
# Log: 2026-01-08T04:16:10Z Brian McCallister

Switched to template-based homebrew formula generation

---
# Log: 2026-01-08T04:19:02Z Brian McCallister

Confirmed: epithet-aws stays evergreen (no tags), only epithet and epithet-macos get tagged releases

---
# Log: 2026-01-08T04:21:56Z Brian McCallister

Moved Apple notarization credentials to packaging/.envrc, added .gitignore

---
# Log: 2026-01-08T04:24:28Z Brian McCallister

Added make release-test to exercise full pipeline without side effects
