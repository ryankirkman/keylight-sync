import AppKit
import ServiceManagement

// Used by `make uninstall`: login-item registration lives with the system,
// not in the bundle, so only the app itself can remove it.
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

// `KeyLightSync --register-login-item`: same as ticking "Launch at Login" in the menu.
if CommandLine.arguments.contains("--register-login-item") {
    do {
        try SMAppService.mainApp.register()
        print("Launch at Login: on")
    } catch {
        print("Couldn't turn on Launch at Login: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
