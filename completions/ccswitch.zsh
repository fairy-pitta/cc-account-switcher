#compdef ccswitch ccswitch.sh
#
# Zsh completion for ccswitch
#
# Installation:
#   Option 1: Add the completions directory to your fpath in .zshrc (before compinit):
#     fpath=(/path/to/completions $fpath)
#     autoload -Uz compinit && compinit
#
#   Option 2: Copy to a directory already in your fpath:
#     cp ccswitch.zsh /usr/local/share/zsh/site-functions/_ccswitch
#     # or for user-local (create dir if needed):
#     mkdir -p ~/.zsh/completions
#     cp ccswitch.zsh ~/.zsh/completions/_ccswitch
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
        '--add-account:Add current account to managed accounts'
        '--remove-account:Remove account by number or email'
        '--list:List all managed accounts'
        '--switch:Rotate to next account in sequence'
        '--switch-to:Switch to specific account by number or email'
        '--help:Show help message'
        '--version:Show version information'
        '--dry-run:Preview changes without applying them'
        '--check:Check account configuration health'
        '--status:Show current account status'
        '--stats:Show account usage statistics'
        '--set-dir-account:Associate a directory with an account'
        '--set-profile:Set a profile name for an account'
        '--no-restart:Skip Claude Code restart after switching'
        '--interactive:Interactive account selector'
        '-i:Interactive account selector (short form)'
    )

    # If we already have a command, complete its arguments
    local cmd
    for (( i = 1; i < CURRENT; i++ )); do
        case "${words[$i]}" in
            --switch-to|--remove-account|--set-profile)
                cmd="${words[$i]}"
                break
                ;;
            --set-dir-account)
                cmd="${words[$i]}"
                break
                ;;
        esac
    done

    case "$cmd" in
        --switch-to|--remove-account|--set-profile)
            _ccswitch_accounts
            return
            ;;
        --set-dir-account)
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
