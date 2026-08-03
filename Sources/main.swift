import AppKit
import ServiceManagement

// Used by `make uninstall`: login-item registration lives with the system,
// not in the bundle, so only the app itself can remove it.
if CommandLine.arguments.contains("--unregister-login-item") {
    if #available(macOS 13.0, *) {
        try? SMAppService.mainApp.unregister()
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
