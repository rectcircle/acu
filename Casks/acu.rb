cask "acu" do
  version "0.1.3"
  sha256 "a89c97e979ad8c1df204d5dab63d208e97ecea9fab591ccd317bd287d27f00be"

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
