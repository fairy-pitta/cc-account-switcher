# Contributing to cc-account-switcher

Thank you for your interest in contributing! This guide will help you get started.

## Development Setup

### Prerequisites

- **Bash 4.0+** - the script requires modern bash features
- **jq** - JSON processor (`brew install jq` or `apt install jq`)
- **shellcheck** - static analysis for shell scripts (`brew install shellcheck` or `apt install shellcheck`)
- **bats-core** - Bash Automated Testing System (`brew install bats-core` or `apt install bats`)

### Getting Started

1. Fork the repository on GitHub
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/cc-account-switcher.git
   cd cc-account-switcher
   ```
3. Create a feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```

### Running Tests

```bash
# Run all tests
make test

# Run shellcheck linting
make lint

# Run both
make lint && make test
```

### Project Structure

```
ccswitch.sh          # Main script
test/                # Bats test files
completions/         # Shell completion scripts (bash, zsh, fish)
plugins/             # Plugin directory
bin/ccswitch         # Node.js wrapper for npm distribution
Formula/ccswitch.rb  # Homebrew formula
```

## Code Style

### Shell Script Guidelines

- All code must pass **shellcheck** without warnings
- Use `set -euo pipefail` at the top of scripts
- Use `local` for function variables
- Use `readonly` for constants
- Quote all variable expansions: `"$var"` not `$var`
- Use `[[ ]]` for conditionals (not `[ ]`)
- Function names: `snake_case` with verb prefix (e.g., `get_current_account`, `cmd_switch`)
- Command functions: prefix with `cmd_` (e.g., `cmd_list`, `cmd_switch`)

### Test Guidelines

- Test files go in the `test/` directory with `.bats` extension
- Test function naming: `test_<action>_<condition>_<expected_result>`
- Example:
  ```bash
  @test "test_show_usage_with_help_flag_prints_usage" {
    run ./ccswitch.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
  }
  ```

## Pull Request Process

1. **Branch naming**: Use `feature/<name>`, `fix/<name>`, or `refactor/<name>`
2. **Before submitting**:
   - Run `make lint` and fix any shellcheck warnings
   - Run `make test` and ensure all tests pass
   - Check bash syntax: `bash -n ccswitch.sh`
3. **PR description**: Explain what your change does and why
4. **Keep PRs focused**: One feature or fix per PR
5. **Commit messages**: Use conventional commit format:
   - `feat: add new feature`
   - `fix: correct issue with X`
   - `refactor: simplify account switching logic`
   - `test: add tests for account removal`
   - `docs: update installation instructions`

## Reporting Issues

When filing a bug report, please include:

- Your operating system (macOS, Linux distro, WSL version)
- Bash version (`bash --version`)
- jq version (`jq --version`)
- Steps to reproduce the issue
- Expected vs actual behavior
- Any error messages

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
