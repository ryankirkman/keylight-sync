import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let camera = CameraMonitor()
    private let lights = KeyLightManager()

    /// When on, the light follows the camera automatically.
    private var autoSync = UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSync, forKey: "autoSync") }
    }

    /// Pending delayed "turn light off" so brief camera off/on flaps don't flicker the light.
    private var offDebounce: DispatchWorkItem?

    /// How long the camera must stay off before the light is turned off.
    private var offDelay = UserDefaults.standard.object(forKey: "offDelay") as? TimeInterval ?? 0 {
        didSet { UserDefaults.standard.set(offDelay, forKey: "offDelay") }
    }
    private static let offDelayChoices: [(label: String, seconds: TimeInterval)] = [
        ("None", 0), ("1.5 seconds", 1.5), ("5 seconds", 5),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.menu = menu

        camera.watchedUID = UserDefaults.standard.string(forKey: "watchedUID")
        camera.onChange = { [weak self] on in self?.cameraStateChanged(on) }
        lights.onUpdate = { [weak self] in self?.updateIcon() }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification,
            object: nil)

        // If the camera is already on at launch, sync up. (Deliberately do NOT
        // force the light off at launch — it may be on for unrelated reasons.)
        if autoSync && camera.isCameraOn {
            lights.setAll(on: true)
        }
        lights.refreshState()
        updateIcon()
    }

    @objc private func didWake() {
        // Device state can change across sleep without listener callbacks firing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.camera.evaluate()
            self?.lights.refreshState()
        }
    }

    // MARK: - Sync logic

    private func cameraStateChanged(_ on: Bool) {
        updateIcon()
        guard autoSync else { return }
        offDebounce?.cancel()
        offDebounce = nil
        if on {
            lights.setAll(on: true)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.lights.setAll(on: false) }
            offDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + offDelay, execute: work)
        }
    }

    private func updateIcon() {
        let symbol: String
        if lights.lights.isEmpty {
            symbol = "lightbulb.slash"
        } else if lights.lastKnownOn == true {
            symbol = "lightbulb.fill"
        } else {
            symbol = "lightbulb"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "KeyLight Sync")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        lights.refreshState()

        let cameraStatus = NSMenuItem(
            title: camera.isCameraOn ? "Camera: In Use" : "Camera: Idle",
            action: nil, keyEquivalent: "")
        cameraStatus.isEnabled = false
        menu.addItem(cameraStatus)

        let lightTitle: String
        if lights.lights.isEmpty {
            lightTitle = "Light: searching…"
        } else {
            let names = lights.lights.map(\.name).joined(separator: ", ")
            switch lights.lastKnownOn {
            case true?: lightTitle = "\(names): On"
            case false?: lightTitle = "\(names): Off"
            case nil: lightTitle = "\(names): —"
            }
        }
        let lightStatus = NSMenuItem(title: lightTitle, action: nil, keyEquivalent: "")
        lightStatus.isEnabled = false
        menu.addItem(lightStatus)

        menu.addItem(.separator())

        let sync = NSMenuItem(
            title: "Sync Light to Camera", action: #selector(toggleAutoSync), keyEquivalent: "")
        sync.target = self
        sync.state = autoSync ? .on : .off
        menu.addItem(sync)

        let manualOn = lights.lastKnownOn != true
        let manual = NSMenuItem(
            title: manualOn ? "Turn Light On" : "Turn Light Off",
            action: #selector(toggleLight), keyEquivalent: "")
        manual.target = self
        manual.isEnabled = !lights.lights.isEmpty
        manual.representedObject = manualOn
        menu.addItem(manual)

        menu.addItem(.separator())

        let watchMenu = NSMenu()
        let all = NSMenuItem(title: "Any Camera", action: #selector(pickCamera(_:)), keyEquivalent: "")
        all.target = self
        all.state = camera.watchedUID == nil ? .on : .off
        watchMenu.addItem(all)
        for device in camera.devices {
            let item = NSMenuItem(title: device.name, action: #selector(pickCamera(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = camera.watchedUID == device.uid ? .on : .off
            watchMenu.addItem(item)
        }
        let watch = NSMenuItem(title: "Watch Camera", action: nil, keyEquivalent: "")
        watch.submenu = watchMenu
        menu.addItem(watch)

        let delayMenu = NSMenu()
        for choice in Self.offDelayChoices {
            let item = NSMenuItem(
                title: choice.label, action: #selector(pickOffDelay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.seconds
            item.state = offDelay == choice.seconds ? .on : .off
            delayMenu.addItem(item)
        }
        let delay = NSMenuItem(title: "Turn Off Delay", action: nil, keyEquivalent: "")
        delay.submenu = delayMenu
        menu.addItem(delay)

        if #available(macOS 13.0, *) {
            let login = NSMenuItem(
                title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())
        let about = NSMenuItem(
            title: "KeyLight Sync \(appVersion) (\(appCommit))", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit KeyLight Sync", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleAutoSync() {
        autoSync.toggle()
        if autoSync {
            // Adopt the current camera state immediately.
            lights.setAll(on: camera.isCameraOn)
        }
    }

    @objc private func toggleLight(_ sender: NSMenuItem) {
        lights.setAll(on: sender.representedObject as? Bool ?? true)
    }

    @objc private func pickOffDelay(_ sender: NSMenuItem) {
        offDelay = sender.representedObject as? TimeInterval ?? 0
    }

    @objc private func pickCamera(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String
        camera.watchedUID = uid
        UserDefaults.standard.set(uid, forKey: "watchedUID")
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
