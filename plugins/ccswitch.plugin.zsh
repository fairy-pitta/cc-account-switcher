# ccswitch plugin for Zsh
#
# Installation:
#   Option 1: Source in your .zshrc:
#     source /path/to/plugins/ccswitch.plugin.zsh
#
#   Option 2: Oh My Zsh custom plugin:
#     mkdir -p ~/.oh-my-zsh/custom/plugins/ccswitch
#     cp ccswitch.plugin.zsh ~/.oh-my-zsh/custom/plugins/ccswitch/
#     cp ../completions/ccswitch.zsh ~/.oh-my-zsh/custom/plugins/ccswitch/_ccswitch
#     # Then add 'ccswitch' to plugins=() in .zshrc
#
#   Option 3: Zinit / Sheldon / Antidote:
#     Point your plugin manager at this repository/directory.

# --- Configuration ---

# Path to the ccswitch script (override in .zshrc if needed)
: "${CCSWITCH_SCRIPT:=$(command -v ccswitch.sh 2>/dev/null || echo "${0:A:h:h}/ccswitch.sh")}"

# Prompt cache TTL in seconds
: "${CCSWITCH_PROMPT_TTL:=30}"

# --- Alias ---

alias ccswitch="$CCSWITCH_SCRIPT"

# --- Completion ---

# Add completions directory to fpath if available
local _plugin_dir="${0:A:h}"
local _completions_dir="${_plugin_dir:h}/completions"
if [[ -d "$_completions_dir" ]]; then
    fpath=("$_completions_dir" $fpath)
fi

# --- Prompt segment ---

# Cache variables
typeset -g _ccswitch_prompt_cache=""
typeset -g _ccswitch_prompt_cache_time=0

ccswitch_prompt_info() {
    local sequence_file="$HOME/.claude-switch-backup/sequence.json"
    local now="${EPOCHSECONDS:-$(date +%s)}"

    # Return cached value if still fresh
    if (( now - _ccswitch_prompt_cache_time < CCSWITCH_PROMPT_TTL )); then
        echo "$_ccswitch_prompt_cache"
        return
    fi

    # Update cache timestamp regardless (avoid hammering on missing file)
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

# --- Directory account hook ---

_ccswitch_chpwd_hook() {
    local dir="$PWD"
    local account_file=""

    # Walk up directory tree looking for .claude-account
    while [[ "$dir" != "/" ]]; do
        if [[ -f "${dir}/.claude-account" ]]; then
            account_file="${dir}/.claude-account"
            break
        fi
        dir="${dir:h}"
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

    # Determine current active identifier (number and email)
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
        return  # Already on the correct account
    fi

    echo ""
    echo "  Claude account for this directory: ${target_account}"
    echo "  Run 'ccswitch --switch-to ${target_account}' to switch."
    echo ""
}

# Register the chpwd hook
autoload -Uz add-zsh-hook
add-zsh-hook chpwd _ccswitch_chpwd_hook
