cask "acu" do
  version "0.1.0"
  sha256 "c73e1eba8634d684308adeb2b8ac293602e20d5f2638949bf0107d7720766092"

  url "https://github.com/rectcircle/acu/releases/download/v#{version}/ACU.tar.gz"
  name "ACU"
  desc "Keep automation sessions active and protected"
  homepage "https://github.com/rectcircle/acu"

  depends_on macos: :sequoia

  app "ACU.app"

  zap trash: "~/Library/Preferences/github.com.rectcircle.acu.plist"

  caveats <<~EOS
    ACU is ad-hoc signed and is not notarized by Apple. Only use
    --no-quarantine if you trust this tap and its release artifacts.
  EOS
end
