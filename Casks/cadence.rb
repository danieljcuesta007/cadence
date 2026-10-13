# Homebrew cask for Cadence.
#   brew tap danieljcuesta007/cadence https://github.com/danieljcuesta007/cadence
#   brew install --cask cadence
# qa/make-dmg.sh fills in version and sha256 for each release.
cask "cadence" do
  version "0.1.1"
  sha256 "0339cc5b72808d9927301f866f0cac16362c3d0113276fc8737c69231332ed0b"

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
    Your dictation history lives in ~/.cadence; uninstalling the app leaves it in place.
  EOS
end
