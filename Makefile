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
#   epithet -> {epithet-aws, epithet-macos} -> homebrew-tap
#
# Requires:
#   - svu (go install github.com/caarlos0/svu/v3@latest)
#   - goreleaser (brew install goreleaser)
#   - gh CLI (brew install gh) - authenticated
#   - .envrc with Apple credentials (for notarization)

# Sibling repo paths.
EPITHET_DIR = ../epithet
MACOS_DIR = ../epithet-macos
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
MACOS_DMG = dist/EpithetAgent-$(V).dmg

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
ifndef TEAM_ID
	$(error TEAM_ID is not set. Run: direnv allow)
endif
ifndef DEVELOPER_ID
	$(error DEVELOPER_ID is not set. Run: direnv allow)
endif
ifndef APP_PASSWORD
	$(error APP_PASSWORD is not set. Run: direnv allow)
endif
ifndef APPLE_ID
	$(error APPLE_ID is not set. Run: direnv allow)
endif

# Test the release pipeline without pushing tags, releases, or commits.
.PHONY: release-test
release-test:
	@echo "=== Testing release pipeline ==="
	$(eval TEST_V := 0.0.0-test)
	$(eval TEST_DIST := dist/test)
	@# Step 1: Run epithet tests
	@echo "=== [1/6] Testing epithet ==="
	$(MAKE) -C $(EPITHET_DIR) test
	@# Step 2: Build with goreleaser snapshot (no tag required)
	@echo "=== [2/6] Building epithet (snapshot) ==="
	cd $(EPITHET_DIR) && goreleaser release --snapshot --clean
	mkdir -p $(TEST_DIST)
	cp $(EPITHET_DIR)/dist/epithet_*_*.tar.gz $(TEST_DIST)/
	cp $(EPITHET_DIR)/dist/checksums.txt $(TEST_DIST)/
	@# Step 3: Build macOS DMG (unsigned - skip notarization for test)
	@echo "=== [3/6] Building epithet-macos DMG (unsigned) ==="
	mkdir -p $(MACOS_DIR)/Resources
	tar -xzf $$(ls $(TEST_DIST)/epithet_*_darwin_arm64.tar.gz | head -1) -C $(MACOS_DIR)/Resources/
	$(MAKE) -C $(MACOS_DIR) bundle-release
	hdiutil create -volname "EpithetAgent" -srcfolder $(MACOS_DIR)/.build/EpithetAgent.app \
		-ov -format UDZO $(TEST_DIST)/EpithetAgent.dmg
	@# Step 4: Generate homebrew formulas (to test dir, not real location)
	@echo "=== [4/6] Generating homebrew formulas ==="
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
	@SHA_DMG=$$(shasum -a 256 $(TEST_DIST)/EpithetAgent.dmg | cut -d' ' -f1) && \
	sed -e "s/{{VERSION}}/$(TEST_V)/g" \
	    -e "s/{{SHA_DMG}}/$$SHA_DMG/g" \
	    templates/epithet-agent-mac.rb.tmpl > $(TEST_DIST)/epithet-agent-mac.rb
	@# Step 5: Validate homebrew formula syntax
	@echo "=== [5/6] Validating homebrew formula syntax ==="
	ruby -c $(TEST_DIST)/epithet.rb
	ruby -c $(TEST_DIST)/epithet-agent-mac.rb
	@# Step 6: Summary
	@echo "=== [6/6] Release test complete ==="
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

# epithet-macos: build app with darwin_arm64 binary, sign, notarize, create dmg, GitHub release.
$(MACOS_DMG): $(EPITHET_CHECKSUMS)
	@echo "=== Releasing epithet-macos v$(V) ==="
	mkdir -p $(MACOS_DIR)/Resources
	tar -xzf $(EPITHET_DIST)/epithet_$(V)_darwin_arm64.tar.gz -C $(MACOS_DIR)/Resources/
	$(MAKE) -C $(MACOS_DIR) dmg-signed
	cp $(MACOS_DIR)/.build/EpithetAgent.dmg $(MACOS_DMG)
	cd $(MACOS_DIR) && git tag -a v$(V) -m "v$(V)"
	cd $(MACOS_DIR) && git push origin v$(V)
	gh release create v$(V) $(MACOS_DMG) --repo epithet-ssh/epithet-macos --title "v$(V)"
	@echo "=== epithet-macos v$(V) released ==="

# epithet-aws: update pinned version.
.PHONY: epithet-aws
epithet-aws: $(EPITHET_CHECKSUMS)
	@echo "=== Updating epithet-aws to v$(V) ==="
	sed -i '' 's/^EPITHET_VERSION := v.*/EPITHET_VERSION := v$(V)/' $(AWS_DIR)/Makefile
	cd $(AWS_DIR) && git add Makefile && git commit -m "Update epithet to v$(V)"
	@echo "=== epithet-aws updated ==="

# homebrew-tap: generate Formula + Cask from templates.
.PHONY: homebrew-tap
homebrew-tap: $(EPITHET_CHECKSUMS) $(MACOS_DMG) epithet-aws
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
	@# Generate Cask from template
	@SHA_DMG=$$(shasum -a 256 $(MACOS_DMG) | cut -d' ' -f1) && \
	sed -e "s/{{VERSION}}/$(V)/g" \
	    -e "s/{{SHA_DMG}}/$$SHA_DMG/g" \
	    templates/epithet-agent-mac.rb.tmpl > $(HOMEBREW_DIR)/Casks/epithet-agent-mac.rb && \
	echo "  DMG:          $$SHA_DMG"
	@echo "=== Auditing homebrew formulas ==="
	brew audit --strict epithet-ssh/tap/epithet
	brew audit --strict --cask epithet-ssh/tap/epithet-agent-mac
	cd $(HOMEBREW_DIR) && git add . && git commit -m "Update to v$(V)"
	@echo "=== homebrew-tap updated ==="

# Dev/testing targets.
.PHONY: build build-macos build-all clean

build:
	$(MAKE) -C $(EPITHET_DIR) build

build-macos:
	$(MAKE) -C $(MACOS_DIR) build

build-all: build build-macos
	@echo "=== All builds complete ==="

clean:
	rm -rf dist/

# Show current versions across all repos.
.PHONY: versions
versions:
	@echo "epithet:       $$(cd $(EPITHET_DIR) && git describe --tags --abbrev=0 2>/dev/null || echo 'no tags')"
	@echo "epithet-macos: $$(cd $(MACOS_DIR) && git describe --tags --abbrev=0 2>/dev/null || echo 'no tags')"
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
