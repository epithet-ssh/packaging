# Unified release automation for epithet-ssh projects.
#
# Usage:
#   make release                 - auto-detect version from commits (default)
#   make release VERSION=patch   - bump patch version
#   make release VERSION=minor   - bump minor version
#   make release VERSION=major   - bump major version
#   make release VERSION=1.2.3   - explicit version
#   make release-test            - test full pipeline without pushing anything
#   make snapshot                - local build without release
#   make build-all               - local build for testing
#
# Dependency chain:
#   epithet -> epithet-aws -> homebrew-tap
#
# Requires:
#   - svu (go install github.com/caarlos0/svu/v3@latest)
#   - goreleaser (brew install goreleaser)
#   - gh CLI (brew install gh) - authenticated

# Sibling repo paths.
EPITHET_DIR = ../epithet
AWS_DIR = ../epithet-aws
HOMEBREW_DIR = ../homebrew-tap

# Version resolution: accepts 'next', 'patch', 'minor', 'major', or explicit version.
# Default to 'next' which auto-detects from conventional commits.
VERSION ?= next

# Strip leading 'v' from svu output so we can add it where needed.
ifeq ($(VERSION),next)
  V := $(shell cd $(EPITHET_DIR) && svu next 2>/dev/null | sed 's/^v//' || echo "0.0.0")
else ifeq ($(VERSION),patch)
  V := $(shell cd $(EPITHET_DIR) && svu patch | sed 's/^v//')
else ifeq ($(VERSION),minor)
  V := $(shell cd $(EPITHET_DIR) && svu minor | sed 's/^v//')
else ifeq ($(VERSION),major)
  V := $(shell cd $(EPITHET_DIR) && svu major | sed 's/^v//')
else
  # Explicit version - strip leading 'v' if provided.
  V := $(shell echo "$(VERSION)" | sed 's/^v//')
endif

# Artifact paths.
EPITHET_DIST = dist/epithet-$(V)
EPITHET_CHECKSUMS = $(EPITHET_DIST)/checksums.txt

# Top-level release target.
.PHONY: release
release: check-env homebrew-tap
	@echo "=== Release v$(V) complete ==="

# Verify required environment variables are set.
.PHONY: check-env
check-env:
ifndef GITHUB_TOKEN
	$(error GITHUB_TOKEN is not set. Run: export GITHUB_TOKEN=$$(gh auth token))
endif

# Test the release pipeline without pushing tags, releases, or commits.
.PHONY: release-test
release-test:
	@echo "=== Testing release pipeline ==="
	$(eval TEST_V := 0.0.0-test)
	$(eval TEST_DIST := dist/test)
	@# Step 1: Run epithet tests
	@echo "=== [1/4] Testing epithet ==="
	$(MAKE) -C $(EPITHET_DIR) test
	@# Step 2: Build with goreleaser snapshot (no tag required)
	@echo "=== [2/4] Building epithet (snapshot) ==="
	cd $(EPITHET_DIR) && goreleaser release --snapshot --clean
	mkdir -p $(TEST_DIST)
	cp $(EPITHET_DIR)/dist/epithet_*_*.tar.gz $(TEST_DIST)/
	cp $(EPITHET_DIR)/dist/checksums.txt $(TEST_DIST)/
	@# Step 3: Generate homebrew formula (to test dir, not real location)
	@echo "=== [3/4] Generating homebrew formula ==="
	@SHA_DARWIN_ARM64=$$(grep darwin_arm64 $(TEST_DIST)/checksums.txt | cut -d' ' -f1) && \
	SHA_DARWIN_AMD64=$$(grep darwin_amd64 $(TEST_DIST)/checksums.txt | cut -d' ' -f1) && \
	SHA_LINUX_ARM64=$$(grep linux_arm64 $(TEST_DIST)/checksums.txt | cut -d' ' -f1) && \
	SHA_LINUX_AMD64=$$(grep linux_amd64 $(TEST_DIST)/checksums.txt | cut -d' ' -f1) && \
	sed -e "s/{{VERSION}}/$(TEST_V)/g" \
	    -e "s/{{SHA_DARWIN_ARM64}}/$$SHA_DARWIN_ARM64/g" \
	    -e "s/{{SHA_DARWIN_AMD64}}/$$SHA_DARWIN_AMD64/g" \
	    -e "s/{{SHA_LINUX_ARM64}}/$$SHA_LINUX_ARM64/g" \
	    -e "s/{{SHA_LINUX_AMD64}}/$$SHA_LINUX_AMD64/g" \
	    templates/epithet.rb.tmpl > $(TEST_DIST)/epithet.rb
	@# Step 4: Validate homebrew formula syntax
	@echo "=== [4/4] Validating homebrew formula syntax ==="
	ruby -c $(TEST_DIST)/epithet.rb
	@# Summary
	@echo "=== Release test complete ==="
	@echo "Artifacts in $(TEST_DIST)/:"
	@ls -la $(TEST_DIST)/
	@echo ""
	@echo "No tags pushed, no releases created, no commits made."
	@echo "Run 'make release' when ready for real release."

# Snapshot: local build without pushing tags or creating releases.
.PHONY: snapshot
snapshot:
	$(eval SNAP_V := $(shell cd $(EPITHET_DIR) && svu next | sed 's/^v//')-dev+$(shell date +%Y%m%d))
	@echo "=== Building snapshot $(SNAP_V) ==="
	cd $(EPITHET_DIR) && goreleaser release --snapshot --clean
	mkdir -p dist/epithet-$(SNAP_V)
	cp $(EPITHET_DIR)/dist/epithet_*_*.tar.gz dist/epithet-$(SNAP_V)/ 2>/dev/null || true
	cp $(EPITHET_DIR)/dist/checksums.txt dist/epithet-$(SNAP_V)/ 2>/dev/null || true
	@echo "=== Snapshot $(SNAP_V) built in dist/ ==="

# epithet: goreleaser builds all platforms + creates GitHub release.
$(EPITHET_CHECKSUMS):
	@echo "=== Testing epithet ==="
	$(MAKE) -C $(EPITHET_DIR) test
	@echo "=== Releasing epithet v$(V) ==="
	cd $(EPITHET_DIR) && git tag -a v$(V) -m "v$(V)"
	cd $(EPITHET_DIR) && git push origin v$(V)
	cd $(EPITHET_DIR) && goreleaser release --clean
	mkdir -p $(EPITHET_DIST)
	cp $(EPITHET_DIR)/dist/epithet_$(V)_*.tar.gz $(EPITHET_DIST)/
	cp $(EPITHET_DIR)/dist/checksums.txt $(EPITHET_CHECKSUMS)
	@echo "=== epithet v$(V) released ==="

# epithet-aws: update pinned version.
.PHONY: epithet-aws
epithet-aws: $(EPITHET_CHECKSUMS)
	@echo "=== Updating epithet-aws to v$(V) ==="
	sed -i '' 's/^EPITHET_VERSION := v.*/EPITHET_VERSION := v$(V)/' $(AWS_DIR)/Makefile
	cd $(AWS_DIR) && git add Makefile && git commit -m "Update epithet to v$(V)"
	cd $(AWS_DIR) && git push
	@echo "=== epithet-aws updated ==="

# homebrew-tap: generate Formula from template.
.PHONY: homebrew-tap
homebrew-tap: $(EPITHET_CHECKSUMS) epithet-aws
	@echo "=== Updating homebrew-tap to v$(V) ==="
	@# Generate Formula from template
	@SHA_DARWIN_ARM64=$$(grep darwin_arm64 $(EPITHET_CHECKSUMS) | cut -d' ' -f1) && \
	SHA_DARWIN_AMD64=$$(grep darwin_amd64 $(EPITHET_CHECKSUMS) | cut -d' ' -f1) && \
	SHA_LINUX_ARM64=$$(grep linux_arm64 $(EPITHET_CHECKSUMS) | cut -d' ' -f1) && \
	SHA_LINUX_AMD64=$$(grep linux_amd64 $(EPITHET_CHECKSUMS) | cut -d' ' -f1) && \
	sed -e "s/{{VERSION}}/$(V)/g" \
	    -e "s/{{SHA_DARWIN_ARM64}}/$$SHA_DARWIN_ARM64/g" \
	    -e "s/{{SHA_DARWIN_AMD64}}/$$SHA_DARWIN_AMD64/g" \
	    -e "s/{{SHA_LINUX_ARM64}}/$$SHA_LINUX_ARM64/g" \
	    -e "s/{{SHA_LINUX_AMD64}}/$$SHA_LINUX_AMD64/g" \
	    templates/epithet.rb.tmpl > $(HOMEBREW_DIR)/Formula/epithet.rb && \
	echo "  darwin_arm64: $$SHA_DARWIN_ARM64" && \
	echo "  darwin_amd64: $$SHA_DARWIN_AMD64" && \
	echo "  linux_arm64:  $$SHA_LINUX_ARM64" && \
	echo "  linux_amd64:  $$SHA_LINUX_AMD64"
	@echo "=== Auditing homebrew formula ==="
	brew audit --strict epithet-ssh/tap/epithet
	cd $(HOMEBREW_DIR) && git add Formula/epithet.rb && git commit -m "Update epithet to v$(V)"
	cd $(HOMEBREW_DIR) && git push
	@echo "=== homebrew-tap updated ==="

# Dev/testing targets.
.PHONY: build clean

build:
	$(MAKE) -C $(EPITHET_DIR) build

clean:
	rm -rf dist/

# Show current versions across all repos.
.PHONY: versions
versions:
	@echo "epithet:       $$(cd $(EPITHET_DIR) && git describe --tags --abbrev=0 2>/dev/null || echo 'no tags')"
	@echo "epithet-aws:   $$(grep '^EPITHET_VERSION' $(AWS_DIR)/Makefile | sed 's/.*:= *//')"
	@echo "homebrew-tap:  $$(grep 'version "' $(HOMEBREW_DIR)/Formula/epithet.rb | head -1 | sed 's/.*"\(.*\)".*/\1/')"

# Show what the next version would be.
.PHONY: next-version
next-version:
	@echo "Current: $$(cd $(EPITHET_DIR) && git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 'none')"
	@echo "Next:    $$(cd $(EPITHET_DIR) && svu next | sed 's/^v//')"
	@echo "Patch:   $$(cd $(EPITHET_DIR) && svu patch | sed 's/^v//')"
	@echo "Minor:   $$(cd $(EPITHET_DIR) && svu minor | sed 's/^v//')"
	@echo "Major:   $$(cd $(EPITHET_DIR) && svu major | sed 's/^v//')"
