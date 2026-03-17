# Bash completion for ccs (Claude Code account switcher)
#
# Installation:
#   Option 1: Source directly in your .bashrc:
#     source /path/to/completions/ccswitch.bash
#
#   Option 2: Copy to bash-completion directory:
#     cp ccswitch.bash /etc/bash_completion.d/ccs
#     # or for user-local:
#     cp ccswitch.bash ~/.local/share/bash-completion/completions/ccs
#
#   Option 3: If using the plugin, completions are loaded automatically.

_ccswitch_get_accounts() {
    local sequence_file="$HOME/.claude-switch-backup/sequence.json"
    if [[ -f "$sequence_file" ]] && command -v jq >/dev/null 2>&1; then
        # Return account numbers and emails
        jq -r '.accounts | to_entries[] | "\(.key)\n\(.value.email)"' "$sequence_file" 2>/dev/null
    fi
}

_ccswitch_get_accounts_with_profiles() {
    local sequence_file="$HOME/.claude-switch-backup/sequence.json"
    if [[ -f "$sequence_file" ]] && command -v jq >/dev/null 2>&1; then
        jq -r '.accounts | to_entries[] | "\(.key)\n\(.value.email)\n\(.value.profile // empty)"' "$sequence_file" 2>/dev/null
    fi
}

_ccswitch() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # All available subcommands and options
    local commands="add rm ls sw to profile dir auto check status stats version help -n -r --dry-run --restart --no-restart"

    case "$prev" in
        to|--switch-to|rm|--remove-account|profile|--set-profile)
            # Complete with account numbers and emails
            local accounts
            accounts=$(_ccswitch_get_accounts_with_profiles)
            COMPREPLY=($(compgen -W "$accounts" -- "$cur"))
            return 0
            ;;
        dir|--set-dir-account)
            # First arg is a directory, second is account identifier
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                # Complete directories
                COMPREPLY=($(compgen -d -- "$cur"))
            elif [[ ${COMP_CWORD} -eq 3 ]]; then
                # Complete account numbers and emails
                local accounts
                accounts=$(_ccswitch_get_accounts)
                COMPREPLY=($(compgen -W "$accounts" -- "$cur"))
            fi
            return 0
            ;;
    esac

    # Default: complete commands
    COMPREPLY=($(compgen -W "$commands" -- "$cur"))

    return 0
}

# Register completion for both the command name and common aliases
complete -F _ccswitch ccs
complete -F _ccswitch ccswitch
complete -F _ccswitch ccswitch.sh
complete -F _ccswitch ./ccswitch.sh
