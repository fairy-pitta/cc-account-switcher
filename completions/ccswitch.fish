# Fish shell completions for ccswitch
#
# Installation:
#   Copy to the fish completions directory:
#     cp ccswitch.fish ~/.config/fish/completions/ccswitch.fish
#
#   Fish will automatically load completions from this directory.

# Helper: list account numbers and emails from sequence.json
function __ccswitch_accounts
    set -l sequence_file "$HOME/.claude-switch-backup/sequence.json"
    if test -f "$sequence_file"; and command -q jq
        jq -r '.accounts | to_entries[] | "\(.key)\t\(.value.email)"' "$sequence_file" 2>/dev/null
    end
end

# Helper: check if a specific command has already been given
function __ccswitch_needs_command
    set -l cmd (commandline -opc)
    for c in $cmd[2..-1]
        switch $c
            case '--add-account' '--remove-account' '--list' '--switch' '--switch-to' \
                 '--help' '--version' '--check' '--status' '--stats' \
                 '--set-dir-account' '--set-profile' '--interactive' '-i'
                return 1
        end
    end
    return 0
end

# Helper: check if a specific subcommand is active
function __ccswitch_using_command
    set -l cmd (commandline -opc)
    for c in $cmd[2..-1]
        if test "$c" = "$argv[1]"
            return 0
        end
    end
    return 1
end

# Disable file completions by default
complete -c ccswitch -f

# Commands (only when no command given yet)
complete -c ccswitch -n '__ccswitch_needs_command' -l add-account -d 'Add current account to managed accounts'
complete -c ccswitch -n '__ccswitch_needs_command' -l remove-account -d 'Remove account by number or email'
complete -c ccswitch -n '__ccswitch_needs_command' -l list -d 'List all managed accounts'
complete -c ccswitch -n '__ccswitch_needs_command' -l switch -d 'Rotate to next account in sequence'
complete -c ccswitch -n '__ccswitch_needs_command' -l switch-to -d 'Switch to specific account'
complete -c ccswitch -n '__ccswitch_needs_command' -l help -d 'Show help message'
complete -c ccswitch -n '__ccswitch_needs_command' -l version -d 'Show version information'
complete -c ccswitch -n '__ccswitch_needs_command' -l dry-run -d 'Preview changes without applying'
complete -c ccswitch -n '__ccswitch_needs_command' -l check -d 'Check account configuration health'
complete -c ccswitch -n '__ccswitch_needs_command' -l status -d 'Show current account status'
complete -c ccswitch -n '__ccswitch_needs_command' -l stats -d 'Show account usage statistics'
complete -c ccswitch -n '__ccswitch_needs_command' -l set-dir-account -d 'Associate directory with account'
complete -c ccswitch -n '__ccswitch_needs_command' -l set-profile -d 'Set profile name for account'
complete -c ccswitch -n '__ccswitch_needs_command' -l no-restart -d 'Skip Claude Code restart after switch'
complete -c ccswitch -n '__ccswitch_needs_command' -l interactive -d 'Interactive account selector'
complete -c ccswitch -n '__ccswitch_needs_command' -s i -d 'Interactive account selector'

# Account completions for commands that take account identifiers
complete -c ccswitch -n '__ccswitch_using_command --switch-to' -f -a '(__ccswitch_accounts)'
complete -c ccswitch -n '__ccswitch_using_command --remove-account' -f -a '(__ccswitch_accounts)'
complete -c ccswitch -n '__ccswitch_using_command --set-profile' -f -a '(__ccswitch_accounts)'

# Directory completion for --set-dir-account first arg, then account for second
complete -c ccswitch -n '__ccswitch_using_command --set-dir-account' -F -a '(__ccswitch_accounts)'
