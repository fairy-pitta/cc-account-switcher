# VHS Demo: Multi-Account Switcher for Claude Code
# Usage: vhs assets/demo.tape

Output assets/demo.gif
Set Shell "bash"
Set FontSize 15
Set Width 900
Set Height 550
Set Padding 15
Set TypingSpeed 40ms
Set Theme "Catppuccin Mocha"

# ── Hidden setup ────────────────────────────────────────────────
Hide
Type "source assets/demo-setup.sh > /dev/null 2>&1"
Enter
Sleep 1s
Type "clear"
Enter
Sleep 0.5s
Show

# ── Demo Start ──────────────────────────────────────────────────

Sleep 0.5s

# 1. Add first account (already logged in as alice)
Type "# 1. Save your current Claude Code account"
Enter
Sleep 1s
Type "ccs add"
Enter
Sleep 1.5s

# 2. List accounts
Type "ccs ls"
Enter
Sleep 1.5s

# 3. Switch to second account & add
Hide
Type "_switch_to_bob"
Enter
Sleep 0.5s
Type "clear"
Enter
Sleep 0.3s
Show

Type "# 2. Log into another account, then save it too"
Enter
Sleep 1s
Type "ccs add"
Enter
Sleep 1.5s

# 4. List — now shows two accounts
Type "ccs ls"
Enter
Sleep 1.5s

# 5. Name accounts with profiles
Type "# 3. Give accounts friendly names"
Enter
Sleep 1s
Type "ccs profile 1 work"
Enter
Sleep 1s
Type "ccs profile 2 personal"
Enter
Sleep 1s

# 6. List with profile names
Type "ccs ls"
Enter
Sleep 1.5s

# 7. Switch accounts
Type "# 4. Switch between accounts instantly"
Enter
Sleep 1s
Type "ccs sw --no-restart"
Enter
Sleep 1.5s

# 8. Switch by profile name
Type "ccs to personal --no-restart"
Enter
Sleep 1.5s

# 9. Status
Type "# 5. Check your account status"
Enter
Sleep 1s
Type "ccs status"
Enter
Sleep 2s

# 10. Health check
Type "ccs check"
Enter
Sleep 2.5s

# Closing
Type "# That's it! Run 'ccs help' for all commands."
Enter
Sleep 3s
