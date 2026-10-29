# Homebrew cask for Cadence.
#   brew tap danieljcuesta007/cadence https://github.com/danieljcuesta007/cadence
#   brew install --cask cadence
# qa/make-dmg.sh fills in version and sha256 for each release.
cask "cadence" do
  version "0.1.2"
  sha256 "f6c33ee8cc0398ebef900e22953b1ccb17c13285d63b9018faa19fbcdad35721"

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
