cask "acu" do
  version "0.1.10"
  sha256 "ddcab0f8514740684cf6e447905648795c7b75d603ba528d5a28b7f6ff3ff8da"

  url "https://github.com/rectcircle/acu/releases/download/v#{version}/ACU-0.1.10-macos-universal.tar.gz"
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
