cask "acu" do
  version "0.1.3"
  sha256 "15f63d3836d105bf2dd31dbace395ccc20a1ce00db66b3c3d8afae469e5d3ec7"

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
