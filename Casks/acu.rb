cask "acu" do
  version "0.1.11"
  sha256 "8a850a7fc4e7d2b2c65c0e5f62f482d1afc3f23245bfc2979cfcbe275daf6276"

  url "https://github.com/rectcircle/acu/releases/download/v#{version}/ACU-0.1.11-macos-universal.tar.gz"
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
