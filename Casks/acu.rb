cask "acu" do
  version "0.1.8"
  sha256 "3776352d58e19440c3107a504441c1addf72b33ac4bf25e78c330d89fb5f0951"

  url "https://github.com/rectcircle/acu/releases/download/v#{version}/ACU-0.1.8-macos-universal.tar.gz"
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
