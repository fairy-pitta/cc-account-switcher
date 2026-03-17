#!/usr/bin/env bash

# Interactive Account Selector for ccswitch
#
# Provides a user-friendly interactive interface for selecting
# which Claude Code account to switch to.
#
# Usage:
#   ./ccswitch-interactive.sh
#
# If fzf is installed, uses fuzzy finder for selection.
# Otherwise, falls back to a numbered menu.
#
# Can also be invoked via: ccswitch --interactive or ccswitch -i
# (requires the corresponding alias or wrapper)
#
# Dependencies:
#   - jq (required)
#   - fzf (optional, for fuzzy selection)
#   - ccswitch.sh (must be in PATH or same directory)

set -euo pipefail

# Resolve path to ccswitch.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CCSWITCH="${CCSWITCH_SCRIPT:-${SCRIPT_DIR}/ccswitch.sh}"

if [[ ! -x "$CCSWITCH" ]]; then
    echo "Error: ccswitch.sh not found at $CCSWITCH"
    echo "Set CCSWITCH_SCRIPT environment variable to the correct path."
    exit 1
fi

# Configuration
readonly SEQUENCE_FILE="$HOME/.claude-switch-backup/sequence.json"

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed."
    exit 1
fi

if [[ ! -f "$SEQUENCE_FILE" ]]; then
    echo "No accounts are managed yet."
    echo "Run 'ccswitch --add-account' to add your first account."
    exit 1
fi

# Build account list
build_account_list() {
    # Output format: "NUM | EMAIL | PROFILE | ACTIVE | ADDED"
    local active_num
    active_num=$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE")

    jq -r --arg active "$active_num" '
        .sequence[] as $num |
        .accounts["\($num)"] |
        [
            "\($num)",
            .email,
            (.profile // "-"),
            (if "\($num)" == $active then "*" else " " end),
            (.added // "-" | split("T")[0])
        ] | @tsv
    ' "$SEQUENCE_FILE"
}

# Format account line for display
format_account_line() {
    local num="$1" email="$2" profile="$3" active="$4" added="$5"
    local marker=""
    [[ "$active" == "*" ]] && marker=" (active)"
    local profile_str=""
    [[ "$profile" != "-" ]] && profile_str=" [${profile}]"

    printf "  %s: %s%s%s  (added %s)" "$num" "$email" "$profile_str" "$marker" "$added"
}

# Interactive selection with fzf
select_with_fzf() {
    local lines=()
    local active_num
    active_num=$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE")

    while IFS=$'\t' read -r num email profile active added; do
        local marker=""
        [[ "$active" == "*" ]] && marker=" (active)"
        local profile_str=""
        [[ "$profile" != "-" ]] && profile_str=" [${profile}]"
        lines+=("$(printf "%s\t%s%s%s\t(added %s)" "$num" "$email" "$profile_str" "$marker" "$added")")
    done < <(build_account_list)

    if [[ ${#lines[@]} -eq 0 ]]; then
        echo "No accounts found."
        exit 1
    fi

    local selected
    selected=$(printf '%s\n' "${lines[@]}" | fzf \
        --header="Select Claude Code account (ESC to cancel)" \
        --no-multi \
        --ansi \
        --height=~50% \
        --layout=reverse \
        --prompt="Account> " \
        --preview-window=hidden)

    if [[ -z "$selected" ]]; then
        echo "Selection cancelled."
        exit 0
    fi

    # Extract account number (first field)
    local account_num
    account_num=$(echo "$selected" | cut -f1)
    echo "$account_num"
}

# Interactive selection with numbered menu (fallback)
select_with_menu() {
    local -a nums=()
    local -a display_lines=()

    while IFS=$'\t' read -r num email profile active added; do
        nums+=("$num")
        local marker=""
        [[ "$active" == "*" ]] && marker=" (active)"
        local profile_str=""
        [[ "$profile" != "-" ]] && profile_str=" [${profile}]"
        display_lines+=("$(printf "%s: %s%s%s  (added %s)" "$num" "$email" "$profile_str" "$marker" "$added")")
    done < <(build_account_list)

    if [[ ${#nums[@]} -eq 0 ]]; then
        echo "No accounts found."
        exit 1
    fi

    echo "Select Claude Code account:"
    echo ""

    local i
    for i in "${!display_lines[@]}"; do
        echo "  ${display_lines[$i]}"
    done

    echo ""
    echo -n "Enter account number (or q to cancel): "
    read -r choice

    if [[ "$choice" == "q" || "$choice" == "Q" || -z "$choice" ]]; then
        echo "Selection cancelled."
        exit 0
    fi

    # Validate that the choice is a valid account number
    local valid=false
    for n in "${nums[@]}"; do
        if [[ "$choice" == "$n" ]]; then
            valid=true
            break
        fi
    done

    if [[ "$valid" != true ]]; then
        echo "Error: Invalid account number: $choice"
        exit 1
    fi

    echo "$choice"
}

# Main
main() {
    local selected_account

    if command -v fzf >/dev/null 2>&1; then
        selected_account=$(select_with_fzf)
    else
        selected_account=$(select_with_menu)
    fi

    # If we got a valid account number, switch to it
    if [[ -n "$selected_account" && "$selected_account" =~ ^[0-9]+$ ]]; then
        echo ""
        exec "$CCSWITCH" --switch-to "$selected_account"
    fi
}

main "$@"
