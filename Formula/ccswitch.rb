# typed: false
# frozen_string_literal: true

class Ccswitch < Formula
  desc "Multi-account switcher for Claude Code"
  homepage "https://github.com/fairy-pitta/cc-account-switcher"
  url "https://github.com/fairy-pitta/cc-account-switcher/archive/refs/tags/v0.3.0.tar.gz"
  sha256 "bf83d5a17411c1a178279239f5c771425c7e21a79672e9093d54812f857a9c7f"
  license "MIT"

  depends_on "jq"

  def install
    bin.install "ccswitch.sh" => "ccs"
  end

  test do
    system "#{bin}/ccs", "version"
  end
end
