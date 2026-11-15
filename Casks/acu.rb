cask "acu" do
  version "0.1.12"
  sha256 "0877dd874d6ba7c767b8358030d4297642e24f6ce4dfd904f2a37a5b76647ce6"

  url "https://github.com/rectcircle/acu/releases/download/v#{version}/ACU-0.1.12-macos-universal.tar.gz"
  name "ACU"
  desc "Keep automation sessions active and protected"
  homepage "https://github.com/rectcircle/acu"

  depends_on macos: :sequoia

  app "ACU.app"

  zap trash: "~/Library/Preferences/github.com.rectcircle.acu.plist"

  caveats <<~EOS
    ACU is ad-hoc signed and is not notarized by Apple. If you trust this tap
    and its release artifacts, remove quarantine after installation with:
      /usr/bin/xattr -dr com.apple.quarantine /Applications/ACU.app
  EOS
end
