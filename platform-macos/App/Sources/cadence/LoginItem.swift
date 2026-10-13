// Is Start at Login really registered? Ask the system, from inside the bundle.
//
// The 11 Oct 2026 audit reported the login item gone because `sfltool dumpbtm | grep` printed
// nothing — but dumpbtm needs an admin password and prints nothing without one. The item was
// registered all along, and SMAppService still reports it after a reinstall replaces the
// bundle. This is the check that needs no admin:
//
//   Cadence.app/Contents/MacOS/Cadence login-item              print status; exit 0 iff enabled
//   Cadence.app/Contents/MacOS/Cadence login-item --register   register this bundle first

import Foundation
import ServiceManagement

func runLoginItemCommand(register: Bool) -> Int32 {
    // SMAppService.mainApp means "the bundle this binary is in" — a bare dev binary has none.
    guard Bundle.main.bundlePath.hasSuffix(".app") else {
        print("not running from a .app bundle — run Cadence.app/Contents/MacOS/Cadence login-item")
        return 2
    }
    if register {
        do {
            try SMAppService.mainApp.register()
        } catch {
            print("register failed: \(error)")
            return 1
        }
    }
    let status: String
    switch SMAppService.mainApp.status {
    case .enabled: status = "enabled"
    case .requiresApproval: status = "requires approval (System Settings › Login Items)"
    case .notFound: status = "not found"
    default: status = "not registered"
    }
    print("\(Bundle.main.bundlePath): \(status)")
    return SMAppService.mainApp.status == .enabled ? 0 : 1
}
