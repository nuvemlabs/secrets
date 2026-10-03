class Secrets < Formula
  desc "OS-native secret storage for bash and zsh (Keychain, libsecret)"
  homepage "https://github.com/nuvemlabs/secrets"
  url "https://github.com/nuvemlabs/secrets.git", tag: "v1.1.1"
  license "MIT"
  head "https://github.com/nuvemlabs/secrets.git", branch: "main"

  def install
    ENV["PREFIX"] = prefix
    system "bash", "install.sh"
  end

  def caveats
    <<~EOS
      Load the library from your shell rc (~/.zshrc or ~/.bashrc):
        source "#{HOMEBREW_PREFIX}/lib/secrets/secrets.sh"
    EOS
  end

  test do
    help = shell_output("bash -c 'source #{lib}/secrets/secrets.sh && secret --help'")
    assert_match "Usage: secret", help
    assert_match "secrets-doctor", shell_output("#{bin}/secrets-doctor --help")
  end
end
