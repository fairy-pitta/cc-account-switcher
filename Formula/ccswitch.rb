class Ccswitch < Formula
  desc "Multi-account switcher for Claude Code"
  homepage "https://github.com/ming86/cc-account-switcher"
  url "https://github.com/ming86/cc-account-switcher/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"

  depends_on "jq"
  depends_on "bash" => "4.4"

  def install
    bin.install "ccswitch.sh" => "ccswitch"

    # Install shell completions if they exist
    bash_completion.install Dir["completions/*.bash"]
    zsh_completion.install Dir["completions/_*"]
    fish_completion.install Dir["completions/*.fish"]

    # Install plugins
    (share/"ccswitch/plugins").install Dir["plugins/*"] if Dir["plugins/*"].any?
  end

  def caveats
    <<~EOS
      To enable shell integration, add to your shell profile:

        Bash (~/.bashrc):
          source "$(brew --prefix)/bin/ccswitch" --shell-init bash 2>/dev/null

        Zsh (~/.zshrc):
          source "$(brew --prefix)/bin/ccswitch" --shell-init zsh 2>/dev/null

        Fish (~/.config/fish/config.fish):
          source "$(brew --prefix)/bin/ccswitch" --shell-init fish 2>/dev/null
    EOS
  end

  test do
    system "#{bin}/ccswitch", "--help"
  end
end
