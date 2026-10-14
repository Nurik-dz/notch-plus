cask "notch-plus" do
  version "0.2"
  sha256 "def3e7bf3a8a70a63fb9a7046a552d3feaca58109f56786292b9fffc1760f7c3"

  url "https://github.com/Nurik-dz/notch-plus/releases/download/v#{version}/Notch-Plus-#{version}.dmg"
  name "Notch+"
  desc "Small island in the Mac notch: Claude Code approvals, messages, a player and a shelf"
  homepage "https://notch-plus.pages.dev/"

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Notch+.app"

  # Notch+ is signed ad-hoc and not notarized (the developer is not able to enroll in the Apple Developer Program),
  # so this removes the quarantine flag that would otherwise make macOS block the first launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Notch+.app"]
  end

  zap trash: [
    "~/Library/Application Support/NotchPlus",
    "~/Library/Preferences/com.nurik.NotchPlus.plist",
  ]

  caveats <<~EOS
    Notch+ is not notarized by Apple. This cask clears the quarantine flag for you.
    Open Notch+, then in Settings connect Claude Code and give it Full Disk Access
    so it can read notifications and Messages.
  EOS
end
