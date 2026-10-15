cask "acu" do
  version "0.1.9"
  sha256 "6c7c13a44b347e99f60cfacad721985ed3ca04891d116c4e9e6b412d4230345a"

  url "https://github.com/rectcircle/acu/releases/download/v#{version}/ACU-0.1.9-macos-universal.tar.gz"
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
