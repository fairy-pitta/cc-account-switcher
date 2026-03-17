#compdef ccs ccswitch ccswitch.sh
#
# Zsh completion for ccs (Claude Code account switcher)
#
# Installation:
#   Option 1: Add the completions directory to your fpath in .zshrc (before compinit):
#     fpath=(/path/to/completions $fpath)
#     autoload -Uz compinit && compinit
#
#   Option 2: Copy to a directory already in your fpath:
#     cp ccswitch.zsh /usr/local/share/zsh/site-functions/_ccs
#     # or for user-local (create dir if needed):
#     mkdir -p ~/.zsh/completions
#     cp ccswitch.zsh ~/.zsh/completions/_ccs
#     # then add to fpath in .zshrc: fpath=(~/.zsh/completions $fpath)
#
#   Option 3: If using the plugin, completions are loaded automatically.

_ccswitch_accounts() {
    local sequence_file="$HOME/.claude-switch-backup/sequence.json"
    local -a accounts
    if [[ -f "$sequence_file" ]] && (( $+commands[jq] )); then
        # Build array of "account_number:email" pairs for display
        local line
        while IFS=$'\t' read -r num email profile; do
            local desc="${email}"
            [[ -n "$profile" ]] && desc="${email} (${profile})"
            accounts+=("${num}:${desc}" "${email}")
        done < <(jq -r '.accounts | to_entries[] | [.key, .value.email, (.value.profile // "")] | @tsv' "$sequence_file" 2>/dev/null)
    fi
    _describe 'account' accounts
}

_ccswitch_directories() {
    _directories
}

_ccswitch() {
    local -a commands
    commands=(
        'add:Add current account to managed accounts'
        'rm:Remove account by number or email'
        'ls:List all managed accounts'
        'sw:Rotate to next account in sequence'
        'to:Switch to specific account by number, email, or profile'
        'profile:Set a friendly profile name for an account'
        'dir:Associate a directory with an account'
        'auto:Switch based on current directory mapping'
        'check:Verify backup integrity (JSON, permissions, keychain)'
        'status:Show current account, token expiry, last switch'
        'stats:Show per-account usage statistics'
        'version:Show version information'
        'help:Show help message'
    )

    # If we already have a command, complete its arguments
    local cmd
    for (( i = 1; i < CURRENT; i++ )); do
        case "${words[$i]}" in
            to|--switch-to|rm|--remove-account|profile|--set-profile)
                cmd="${words[$i]}"
                break
                ;;
            dir|--set-dir-account)
                cmd="${words[$i]}"
                break
                ;;
        esac
    done

    case "$cmd" in
        to|--switch-to|rm|--remove-account|profile|--set-profile)
            _ccswitch_accounts
            return
            ;;
        dir|--set-dir-account)
            # Position after the command itself
            local arg_pos=$(( CURRENT - i ))
            if [[ $arg_pos -eq 1 ]]; then
                _ccswitch_directories
            elif [[ $arg_pos -eq 2 ]]; then
                _ccswitch_accounts
            fi
            return
            ;;
    esac

    _describe 'command' commands
}

_ccswitch "$@"
