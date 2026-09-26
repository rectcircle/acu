cask "acu" do
  version :latest
  sha256 :no_check

  url "https://github.com/rectcircle/acu-helper/releases/latest/download/ACU.tar.gz"
  name "ACU"
  desc "Keep automation sessions active and protected"
  homepage "https://github.com/rectcircle/acu-helper"

  depends_on macos: :sequoia

  app "ACU.app"

  zap trash: "~/Library/Preferences/github.com.rectcircle.acu.plist"

  caveats <<~EOS
    ACU is ad-hoc signed and is not notarized by Apple. If macOS blocks the
    first launch, allow ACU under System Settings > Privacy & Security.
  EOS
end
