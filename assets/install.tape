# VHS Demo: Installing ccs
# Usage: vhs assets/install.tape

Output assets/install.gif
Set Shell "bash"
Set FontSize 15
Set Width 900
Set Height 450
Set Padding 15
Set TypingSpeed 40ms
Set Theme "Catppuccin Mocha"

# ── Hidden setup ────────────────────────────────────────────────
Hide

# Create isolated environment with mock curl
Type `DEMO_HOME="$(mktemp -d /tmp/ccs-install-XXXXXX)" && export HOME="$DEMO_HOME" && MOCK_BIN="$DEMO_HOME/.mock-bin" && mkdir -p "$MOCK_BIN" "$HOME/.local/bin" && export PATH="$HOME/.local/bin:$MOCK_BIN:$PATH" && REAL_CCS="$(pwd)/ccswitch.sh"`
Enter
Sleep 0.5s

# Create mock curl that copies the real script
Type `printf '#!/bin/bash\nfor a in "$@"; do case "$a" in -o) shift; OUT="$1"; shift ;; -*) shift ;; *) shift ;; esac; done\nsleep 0.5\ncp "'"$REAL_CCS"'" "$OUT"\n' > "$MOCK_BIN/curl" && chmod +x "$MOCK_BIN/curl"`
Enter
Sleep 0.3s

# Mock bash version
Type `printf '#!/bin/bash\nif [[ "$1" == "--version" ]]; then echo "GNU bash, version 5.2.0(1)-release"; exit 0; fi\nexec /bin/bash "$@"\n' > "$MOCK_BIN/bash" && chmod +x "$MOCK_BIN/bash"`
Enter
Sleep 0.3s

Type "clear"
Enter
Sleep 0.5s
Show

# ── Demo Start ──────────────────────────────────────────────────

Sleep 0.5s

# Install via curl
Type "# Install ccs with a single command"
Enter
Sleep 1s
Type `curl -fsSL https://raw.githubusercontent.com/fairy-pitta/cc-account-switcher/main/ccswitch.sh -o ~/.local/bin/ccs`
Enter
Sleep 2s
Type "chmod +x ~/.local/bin/ccs"
Enter
Sleep 1s

# Verify installation
Type "ccs version"
Enter
Sleep 1.5s

Type "ccs help"
Enter
Sleep 4s
