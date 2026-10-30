# Homebrew cask for Cadence.
#   brew tap danieljcuesta007/cadence https://github.com/danieljcuesta007/cadence
#   brew install --cask cadence
# qa/make-dmg.sh fills in version and sha256 for each release.
cask "cadence" do
  version "0.1.3"
  sha256 "63e315ea93b98916ac648cd7b1d70ad8cfe885bdf94ba031f3dea38cf57c31c1"

  url "https://github.com/danieljcuesta007/cadence/releases/download/v#{version}/Cadence.dmg"
  name "Cadence"
  desc "On-device, offline push-to-talk dictation"
  homepage "https://cadence-dictation.pages.dev"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Cadence.app"

  caveats <<~EOS
    Cadence isn't notarized by Apple (that costs $99 a year, and Cadence is free).
    The first time you open it: System Settings > Privacy & Security > Open Anyway.
    No Open Anyway button? Run: xattr -dr com.apple.quarantine /Applications/Cadence.app
    Your dictation history lives in ~/.cadence; uninstalling the app leaves it in place.
  EOS
end
