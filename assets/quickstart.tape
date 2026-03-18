# VHS Demo: Getting Started with ccs
# Usage: vhs assets/quickstart.tape

Output assets/quickstart.gif
Set Shell "bash"
Set FontSize 15
Set Width 900
Set Height 500
Set Padding 15
Set TypingSpeed 40ms
Set Theme "Catppuccin Mocha"

# ── Hidden setup ────────────────────────────────────────────────
Hide
Type "source assets/demo-setup.sh > /dev/null 2>&1"
Enter
Sleep 1s

# Prepare second account login helper
Type `_switch_to_bob() { cat > "$HOME/.claude/.claude.json" << 'CONF'`
Enter
Type `{`
Enter
Type `  "oauthAccount": {`
Enter
Type `    "emailAddress": "bob@personal.dev",`
Enter
Type `    "accountUuid": "uuid-bob-002",`
Enter
Type `    "accessToken": "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwiZXhwIjoxNzc0MzAwODAwfQ.fakesig"`
Enter
Type `  },`
Enter
Type `  "someOtherSetting": true`
Enter
Type `}`
Enter
Type `CONF`
Enter
Type `chmod 600 "$HOME/.claude/.claude.json"`
Enter
Type `local fake_jwt="eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwiZXhwIjoxNzc0MzAwODAwfQ.fakesig"`
Enter
Type `"$HOME/.mock-bin/security" add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "{\"access_token\":\"$fake_jwt\",\"refresh_token\":\"rt-bob\"}"; }`
Enter
Sleep 0.5s

Type "clear"
Enter
Sleep 0.5s
Show

# ── Demo Start ──────────────────────────────────────────────────

Sleep 0.5s

# Step 1: Add first account
Type "# 1. Log into Claude Code with your first account, then save it"
Enter
Sleep 1s
Type "ccs add"
Enter
Sleep 1.5s

# Step 2: Add second account
Hide
Type "_switch_to_bob"
Enter
Sleep 0.5s
Type "clear"
Enter
Sleep 0.3s
Show

Type "# 2. Log out, log into your second account, then save it"
Enter
Sleep 1s
Type "ccs add"
Enter
Sleep 1.5s

# Step 3: List accounts
Type "# 3. See all your managed accounts"
Enter
Sleep 1s
Type "ccs ls"
Enter
Sleep 1.5s

# Step 4: Give them names
Type "# 4. Name them for easy switching"
Enter
Sleep 1s
Type "ccs profile 1 work"
Enter
Sleep 1s
Type "ccs profile 2 personal"
Enter
Sleep 1s
Type "ccs ls"
Enter
Sleep 1.5s

# Step 5: Switch!
Type "# 5. Switch between accounts"
Enter
Sleep 1s
Type "ccs to work --no-restart"
Enter
Sleep 1.5s
Type "ccs to personal --no-restart"
Enter
Sleep 1.5s

# Done
Type "# Done! Restart Claude Code after each switch."
Enter
Sleep 3s
