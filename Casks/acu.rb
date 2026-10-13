cask "acu" do
  version "0.1.5"
  sha256 "1b3138cb876fd5edb11f71c8725dbedbc82442e161dc0e7773afebbf2bdbc124"

  url "https://github.com/rectcircle/acu/releases/download/v#{version}/ACU-0.1.5-macos-universal.tar.gz"
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
