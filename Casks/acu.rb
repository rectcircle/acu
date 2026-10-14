cask "acu" do
  version "0.1.7"
  sha256 "bfb4db6897316e120e77aeaa95498ed33391b4739bec4c1afc2d82f6ee71b739"

  url "https://github.com/rectcircle/acu/releases/download/v#{version}/ACU-0.1.7-macos-universal.tar.gz"
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
