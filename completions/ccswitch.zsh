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

# Global flags — accepted in any position, so they are offered wherever the word
# being completed starts with a dash, and after a subcommand's own arguments.
_ccswitch_options() {
    local -a options
    options=(
        '-n:Show what would happen without making changes'
        '--dry-run:Show what would happen without making changes'
        '-r:Restart Claude Code after switching'
        '--restart:Restart Claude Code after switching'
        '--no-restart:Skip restart prompt after switching'
        "--resume:Switch, then resume this directory's conversation"
        '--fork-session:With --resume, fork into a new session (default)'
        '--no-fork-session:With --resume, continue the same session'
        '--allow-root:Allow running as root'
    )
    _describe -o 'option' options
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
        'resume-mode:Show or set how --resume relaunches (fork|same)'
        'check:Verify backup integrity (JSON, permissions, keychain)'
        'status:Show current account, token expiry, last switch'
        'stats:Show per-account usage statistics'
        'rate-check:Check if usage exceeds rate limit threshold'
        'rate-setup:Install/remove PreToolUse hook for auto-switch'
        'run:Run a command, auto-switch + retry on rate limit'
        'version:Show version information'
        'help:Show help message'
    )

    # Flags come before, between, or after a subcommand's arguments.
    if [[ "${words[CURRENT]}" == -* ]]; then
        _ccswitch_options
        return
    fi

    # If we already have a command, complete its arguments
    local cmd i
    for (( i = 1; i < CURRENT; i++ )); do
        case "${words[$i]}" in
            to|--switch-to|rm|--remove-account|profile|--set-profile)
                cmd="${words[$i]}"
                break
                ;;
            dir|--set-dir-account|resume-mode|run)
                cmd="${words[$i]}"
                break
                ;;
        esac
    done

    # Position of the word being completed, counted from the command itself
    local arg_pos=$(( CURRENT - i ))

    case "$cmd" in
        to|--switch-to|rm|--remove-account)
            # A single account identifier; anything further is a global flag.
            if (( arg_pos == 1 )); then
                _ccswitch_accounts
            else
                _ccswitch_options
            fi
            return
            ;;
        profile|--set-profile)
            # <account> <name> — the profile name is free-form, so offer nothing.
            (( arg_pos == 1 )) && _ccswitch_accounts
            return
            ;;
        run)
            local -a run_opts
            run_opts=(
                '--max-attempts:Cap total attempts (default: number of accounts)'
                '--limit-threshold:Usage% for the secondary limit check (default 95)'
                '--timeout:Per-attempt deadline in seconds (kills the child)'
                '--no-proactive:Skip the pre-run usage check'
                '--no-stdin:Do not read stdin; feed the child /dev/null'
            )
            _describe 'option' run_opts
            return
            ;;
        resume-mode)
            if (( arg_pos == 1 )); then
                _values 'resume mode' \
                    'fork[Fork the conversation into a new session]' \
                    'same[Continue the existing session]'
            fi
            return
            ;;
        dir|--set-dir-account)
            if (( arg_pos == 1 )); then
                _ccswitch_directories
            elif (( arg_pos == 2 )); then
                _ccswitch_accounts
            fi
            return
            ;;
    esac

    _describe 'command' commands
}

_ccswitch "$@"
