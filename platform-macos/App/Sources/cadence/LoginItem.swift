// Start at Login you can check, and that comes back if the system loses it.
//
// The 11 Oct 2026 audit reported the login item gone because `sfltool dumpbtm | grep` printed
// nothing — but dumpbtm needs an admin password and prints nothing without one. The item was
// registered all along, and SMAppService still reports it after a reinstall replaces the
// bundle. Two fixes follow: a status check that needs no admin, and the user's choice kept in
// the store (`start_at_login`) so a launch restores the registration if it ever is lost.
//
//   cadence login-item              status as the system reports it (no admin needed,
//                                   unlike `sfltool dumpbtm`)
//   cadence login-item --register   register this bundle (run from inside the .app)
//   cadence selftest-login          pins LoginItemPlan

import Foundation
import ServiceManagement

enum LoginItemPlan: Equatable {
    /// SMAppService.Status, reduced to what the decision needs (and constructible in tests).
    enum Status: Equatable {
        case enabled, notRegistered, requiresApproval, notFound
    }

    case nothing
    case register
    /// No choice stored yet, but the system says it is on: adopt that as the choice, so the
    /// next reinstall restores it.
    case remember(Bool)
    /// The user wants it, but macOS is waiting on System Settings › Login Items. Registering
    /// again cannot help; say so in the log instead.
    case awaitApproval

    /// `wanted`: the stored choice, nil if the user never toggled it since this shipped.
    static func decide(wanted: Bool?, status: Status) -> LoginItemPlan {
        switch (wanted, status) {
        case (nil, .enabled): return .remember(true)
        case (nil, _): return .nothing
        case (true, .enabled): return .nothing
        case (true, .requiresApproval): return .awaitApproval
        case (true, _): return .register
        // Off is never enforced: if the user turned it on in System Settings themselves,
        // that later choice wins over our stale one.
        case (false, _): return .nothing
        }
    }
}

extension LoginItemPlan.Status {
    init(_ s: SMAppService.Status) {
        switch s {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        default: self = .notRegistered
        }
    }
}

/// Launch-time reconcile. Only meaningful for a real .app bundle (dev `cadence run` can't
/// register), and never fatal — a failed register costs the login item, not the launch.
func reconcileLoginItem(store: HistoryStore?, log: (String) -> Void) {
    guard Bundle.main.bundlePath.hasSuffix(".app"), let store else { return }
    let status = LoginItemPlan.Status(SMAppService.mainApp.status)
    switch LoginItemPlan.decide(wanted: store.startAtLogin, status: status) {
    case .nothing:
        break
    case .remember(let on):
        store.setStartAtLogin(on)
        log("start at login: recorded existing registration (\(on ? "on" : "off"))")
    case .awaitApproval:
        log("start at login: waiting on approval in System Settings › Login Items")
    case .register:
        do {
            try SMAppService.mainApp.register()
            log("start at login: was lost, re-registered")
        } catch {
            log("start at login: re-register failed: \(error)")
        }
    }
}

func runLoginItemCommand(register: Bool) -> Int32 {
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
    let status = LoginItemPlan.Status(SMAppService.mainApp.status)
    print("\(Bundle.main.bundlePath): \(status)")
    return status == .enabled ? 0 : 1
}

func runLoginItemSelftest() -> Int32 {
    var failed = 0
    func check(_ name: String, _ got: LoginItemPlan, _ want: LoginItemPlan) {
        let ok = got == want
        if !ok { failed += 1 }
        print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": got \(got), want \(want)")")
    }
    typealias P = LoginItemPlan
    check("reinstall_dropped_it_reregisters", P.decide(wanted: true, status: .notRegistered), .register)
    check("not_found_reregisters", P.decide(wanted: true, status: .notFound), .register)
    check("already_on_does_nothing", P.decide(wanted: true, status: .enabled), .nothing)
    check("pending_approval_is_not_retried", P.decide(wanted: true, status: .requiresApproval), .awaitApproval)
    check("off_is_never_enforced", P.decide(wanted: false, status: .enabled), .nothing)
    check("off_stays_off", P.decide(wanted: false, status: .notRegistered), .nothing)
    check("unchosen_but_on_is_remembered", P.decide(wanted: nil, status: .enabled), .remember(true))
    check("unchosen_and_off_is_left_alone", P.decide(wanted: nil, status: .notRegistered), .nothing)
    return failed == 0 ? 0 : 1
}
