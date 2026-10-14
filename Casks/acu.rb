cask "acu" do
  version "0.1.6"
  sha256 "3b4e811f71ef7ffb07a6067d7812c2512af618a10edc92059af5d5cf75e9e54a"

  url "https://github.com/rectcircle/acu/releases/download/v#{version}/ACU-0.1.6-macos-universal.tar.gz"
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
