cask "acu" do
  version "0.1.4"
  sha256 "ebaf0a3e1403b84e15c30fb09fdfea245981c1e3ac47d424175eff7b603f9954"

  url "https://github.com/rectcircle/acu/releases/download/v#{version}/ACU.tar.gz"
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
