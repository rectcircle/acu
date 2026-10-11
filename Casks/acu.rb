cask "acu" do
  version "0.1.2"
  sha256 "2d883650b71069dbb20674ca9bc26779a453c1820c162b619f0c6a53e70a54dc"

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
