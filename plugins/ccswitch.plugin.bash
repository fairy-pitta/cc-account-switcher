# ccswitch plugin for Bash
#
# Installation:
#   Source in your .bashrc:
#     source /path/to/plugins/ccswitch.plugin.bash
#
#   The plugin will:
#   - Create a 'ccswitch' alias
#   - Load tab completions
#   - Add ccswitch_prompt_info() for use in PS1
#   - Hook into cd to detect directory-specific accounts

# --- Configuration ---

# Path to the ccswitch script (override in .bashrc before sourcing if needed)
: "${CCSWITCH_SCRIPT:=$(command -v ccswitch.sh 2>/dev/null || echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ccswitch.sh")}"

# Prompt cache TTL in seconds
: "${CCSWITCH_PROMPT_TTL:=30}"

# --- Alias ---

alias ccswitch="$CCSWITCH_SCRIPT"

# --- Completion ---

# Source bash completions if available
_ccswitch_plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ccswitch_completions_file="${_ccswitch_plugin_dir}/../completions/ccswitch.bash"
if [[ -f "$_ccswitch_completions_file" ]]; then
    source "$_ccswitch_completions_file"
fi
unset _ccswitch_plugin_dir _ccswitch_completions_file

# --- Prompt segment ---

# Cache variables
_ccswitch_prompt_cache=""
_ccswitch_prompt_cache_time=0

ccswitch_prompt_info() {
    local sequence_file="$HOME/.claude-switch-backup/sequence.json"
    local now
    now=$(date +%s)

    # Return cached value if still fresh
    if (( now - _ccswitch_prompt_cache_time < CCSWITCH_PROMPT_TTL )); then
        echo "$_ccswitch_prompt_cache"
        return
    fi

    # Update cache timestamp
    _ccswitch_prompt_cache_time=$now

    if [[ ! -f "$sequence_file" ]] || ! command -v jq >/dev/null 2>&1; then
        _ccswitch_prompt_cache=""
        return
    fi

    local active_num email profile display
    active_num=$(jq -r '.activeAccountNumber // empty' "$sequence_file" 2>/dev/null)
    if [[ -z "$active_num" ]]; then
        _ccswitch_prompt_cache=""
        return
    fi

    email=$(jq -r --arg n "$active_num" '.accounts[$n].email // empty' "$sequence_file" 2>/dev/null)
    profile=$(jq -r --arg n "$active_num" '.accounts[$n].profile // empty' "$sequence_file" 2>/dev/null)

    if [[ -n "$profile" ]]; then
        display="$profile"
    elif [[ -n "$email" ]]; then
        display="$email"
    else
        _ccswitch_prompt_cache=""
        return
    fi

    _ccswitch_prompt_cache="☁ ${display}"
    echo "$_ccswitch_prompt_cache"
}

# Example usage in PS1 (add to .bashrc after sourcing this plugin):
#   PS1='$(ccswitch_prompt_info) \u@\h:\w\$ '

# --- Directory account hook ---

_ccswitch_check_dir_account() {
    local dir="$PWD"
    local account_file=""

    # Walk up directory tree looking for .claude-account
    while [[ "$dir" != "/" ]]; do
        if [[ -f "${dir}/.claude-account" ]]; then
            account_file="${dir}/.claude-account"
            break
        fi
        dir="$(dirname "$dir")"
    done

    # Also check root
    if [[ -z "$account_file" ]] && [[ -f "/.claude-account" ]]; then
        account_file="/.claude-account"
    fi

    if [[ -z "$account_file" ]]; then
        return
    fi

    local target_account
    target_account=$(<"$account_file")
    target_account="${target_account%%[[:space:]]}"  # trim whitespace

    if [[ -z "$target_account" ]]; then
        return
    fi

    # Check if this is different from current active account
    local sequence_file="$HOME/.claude-switch-backup/sequence.json"
    if [[ ! -f "$sequence_file" ]] || ! command -v jq >/dev/null 2>&1; then
        return
    fi

    local active_num active_email
    active_num=$(jq -r '.activeAccountNumber // empty' "$sequence_file" 2>/dev/null)

    if [[ -n "$active_num" ]]; then
        active_email=$(jq -r --arg n "$active_num" '.accounts[$n].email // empty' "$sequence_file" 2>/dev/null)
    fi

    # Compare: target could be a number, email, or profile name
    if [[ "$target_account" == "$active_num" ]] || [[ "$target_account" == "$active_email" ]]; then
        return  # Already on the correct account
    fi

    # Check profile name match
    local active_profile
    active_profile=$(jq -r --arg n "${active_num}" '.accounts[$n].profile // empty' "$sequence_file" 2>/dev/null)
    if [[ "$target_account" == "$active_profile" ]]; then
        return
    fi

    echo ""
    echo "  Claude account for this directory: ${target_account}"
    echo "  Run 'ccswitch --switch-to ${target_account}' to switch."
    echo ""
}

# Override cd to add directory account detection
# Preserve any existing cd function/alias
if declare -f cd >/dev/null 2>&1; then
    eval "_ccswitch_original_$(declare -f cd)"
    cd() {
        _ccswitch_original_cd "$@" && _ccswitch_check_dir_account
    }
else
    cd() {
        builtin cd "$@" && _ccswitch_check_dir_account
    }
fi

# Also hook into PROMPT_COMMAND for initial shell load check
_ccswitch_prompt_hook_ran=false
_ccswitch_prompt_command_hook() {
    if [[ "$_ccswitch_prompt_hook_ran" == false ]]; then
        _ccswitch_prompt_hook_ran=true
        _ccswitch_check_dir_account
    fi
}

if [[ -z "$PROMPT_COMMAND" ]]; then
    PROMPT_COMMAND="_ccswitch_prompt_command_hook"
elif [[ "$PROMPT_COMMAND" != *"_ccswitch_prompt_command_hook"* ]]; then
    PROMPT_COMMAND="${PROMPT_COMMAND};_ccswitch_prompt_command_hook"
fi
