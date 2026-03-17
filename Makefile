PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
BASH_COMPLETIONDIR ?= $(PREFIX)/share/bash-completion/completions
ZSH_COMPLETIONDIR ?= $(PREFIX)/share/zsh/site-functions
FISH_COMPLETIONDIR ?= $(PREFIX)/share/fish/vendor_completions.d

.PHONY: install uninstall test lint release help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

install: ## Install ccswitch to $(PREFIX)/bin
	@echo "Installing ccswitch to $(BINDIR)..."
	install -d $(BINDIR)
	install -m 755 ccswitch.sh $(BINDIR)/ccswitch
	@# Install bash completions if available
	@if ls completions/*.bash 1>/dev/null 2>&1; then \
		install -d $(BASH_COMPLETIONDIR); \
		install -m 644 completions/*.bash $(BASH_COMPLETIONDIR)/; \
	fi
	@# Install zsh completions if available
	@if ls completions/_* 1>/dev/null 2>&1; then \
		install -d $(ZSH_COMPLETIONDIR); \
		install -m 644 completions/_* $(ZSH_COMPLETIONDIR)/; \
	fi
	@# Install fish completions if available
	@if ls completions/*.fish 1>/dev/null 2>&1; then \
		install -d $(FISH_COMPLETIONDIR); \
		install -m 644 completions/*.fish $(FISH_COMPLETIONDIR)/; \
	fi
	@echo "Done. Run 'ccswitch --help' to get started."

uninstall: ## Remove installed files
	@echo "Uninstalling ccswitch..."
	rm -f $(BINDIR)/ccswitch
	rm -f $(BASH_COMPLETIONDIR)/ccswitch.bash
	rm -f $(ZSH_COMPLETIONDIR)/_ccswitch
	rm -f $(FISH_COMPLETIONDIR)/ccswitch.fish
	@echo "Done."

test: ## Run bats tests
	@if command -v bats >/dev/null 2>&1; then \
		bats test/; \
	else \
		echo "Error: bats-core is not installed."; \
		echo "Install with: brew install bats-core (macOS) or apt install bats (Linux)"; \
		exit 1; \
	fi

lint: ## Run shellcheck
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck ccswitch.sh; \
		echo "shellcheck passed."; \
	else \
		echo "Error: shellcheck is not installed."; \
		echo "Install with: brew install shellcheck (macOS) or apt install shellcheck (Linux)"; \
		exit 1; \
	fi

release: ## Create a release (usage: make release VERSION=x.y.z)
ifndef VERSION
	$(error VERSION is required. Usage: make release VERSION=x.y.z)
endif
	@echo "Preparing release v$(VERSION)..."
	@# Update version in ccswitch.sh
	sed -i.bak 's/^readonly VERSION=".*"/readonly VERSION="$(VERSION)"/' ccswitch.sh && rm -f ccswitch.sh.bak
	@# Update version in package.json
	sed -i.bak 's/"version": ".*"/"version": "$(VERSION)"/' package.json && rm -f package.json.bak
	git add ccswitch.sh package.json
	git commit -m "chore: bump version to $(VERSION)"
	git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	@echo "Release v$(VERSION) prepared. Push with: git push origin main --tags"
