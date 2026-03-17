# Fish shell completions for ccs (Claude Code account switcher)
#
# Installation:
#   Copy to the fish completions directory:
#     cp ccswitch.fish ~/.config/fish/completions/ccs.fish
#
#   Fish will automatically load completions from this directory.

# Helper: list account numbers and emails from sequence.json
function __ccs_accounts
    set -l sequence_file "$HOME/.claude-switch-backup/sequence.json"
    if test -f "$sequence_file"; and command -q jq
        jq -r '.accounts | to_entries[] | "\(.key)\t\(.value.email)"' "$sequence_file" 2>/dev/null
    end
end

# Helper: check if a specific command has already been given
function __ccs_needs_command
    set -l cmd (commandline -opc)
    for c in $cmd[2..-1]
        switch $c
            case 'add' 'rm' 'ls' 'sw' 'to' 'profile' 'dir' 'auto' \
                 'check' 'status' 'stats' 'version' 'help'
                return 1
        end
    end
    return 0
end

# Helper: check if a specific subcommand is active
function __ccs_using_command
    set -l cmd (commandline -opc)
    for c in $cmd[2..-1]
        if test "$c" = "$argv[1]"
            return 0
        end
    end
    return 1
end

# Disable file completions by default
complete -c ccs -f

# Subcommands (only when no command given yet)
complete -c ccs -n '__ccs_needs_command' -a 'add' -d 'Add current account to managed accounts'
complete -c ccs -n '__ccs_needs_command' -a 'rm' -d 'Remove account by number or email'
complete -c ccs -n '__ccs_needs_command' -a 'ls' -d 'List all managed accounts'
complete -c ccs -n '__ccs_needs_command' -a 'sw' -d 'Rotate to next account in sequence'
complete -c ccs -n '__ccs_needs_command' -a 'to' -d 'Switch to specific account'
complete -c ccs -n '__ccs_needs_command' -a 'profile' -d 'Set profile name for account'
complete -c ccs -n '__ccs_needs_command' -a 'dir' -d 'Associate directory with account'
complete -c ccs -n '__ccs_needs_command' -a 'auto' -d 'Switch based on current directory'
complete -c ccs -n '__ccs_needs_command' -a 'check' -d 'Check account configuration health'
complete -c ccs -n '__ccs_needs_command' -a 'status' -d 'Show current account status'
complete -c ccs -n '__ccs_needs_command' -a 'stats' -d 'Show account usage statistics'
complete -c ccs -n '__ccs_needs_command' -a 'version' -d 'Show version information'
complete -c ccs -n '__ccs_needs_command' -a 'help' -d 'Show help message'

# Options
complete -c ccs -s n -l dry-run -d 'Preview changes without applying'
complete -c ccs -s r -l restart -d 'Restart Claude Code after switching'
complete -c ccs -l no-restart -d 'Skip Claude Code restart after switch'

# Account completions for commands that take account identifiers
complete -c ccs -n '__ccs_using_command to' -f -a '(__ccs_accounts)'
complete -c ccs -n '__ccs_using_command rm' -f -a '(__ccs_accounts)'
complete -c ccs -n '__ccs_using_command profile' -f -a '(__ccs_accounts)'

# Directory completion for dir first arg, then account for second
complete -c ccs -n '__ccs_using_command dir' -F -a '(__ccs_accounts)'
