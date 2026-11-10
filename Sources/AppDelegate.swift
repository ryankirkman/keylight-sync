import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let camera = CameraMonitor()
    private let lights = KeyLightManager()

    private let lightStatus = NSMenuItem()
    private let manual = NSMenuItem()
    private let brightnessRow = SliderRow(
        title: "Brightness", range: KeyLightManager.brightnessRange, step: 1) { "\($0)%" }
    /// The light speaks mireds; the slider works in kelvin, warm on the left.
    private let temperatureRow = SliderRow(
        title: "Temperature", range: 2900...7000, step: 50) { "\($0) K" }

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
        lights.onUpdate = { [weak self] in
            self?.updateIcon()
            self?.updateLightItems()
        }
        brightnessRow.onChange = { [weak self] in self?.lights.adjust(brightness: $0) }
        temperatureRow.onChange = { [weak self] kelvin in
            self?.lights.adjust(temperature: Int((1_000_000 / Double(kelvin)).rounded()))
        }

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
        cancelPendingOff()
        if on {
            lights.setAll(on: true)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.lights.setAll(on: false) }
            offDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + offDelay, execute: work)
        }
    }

    /// Drops a delayed "off" that hasn't fired yet. Anything that decides the light's state
    /// anew (camera back on, a manual toggle, sync switched off) must call this first.
    private func cancelPendingOff() {
        offDebounce?.cancel()
        offDebounce = nil
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

    /// Shows the light's state in the menu: status line, on/off item and sliders. Also runs
    /// while the menu is open, when the read started by opening it comes back.
    private func updateLightItems() {
        let known = !lights.lights.isEmpty
        if known {
            let names = lights.lights.map(\.name).joined(separator: ", ")
            switch lights.lastKnownOn {
            case true?: lightStatus.title = "\(names): On"
            case false?: lightStatus.title = "\(names): Off"
            case nil: lightStatus.title = "\(names): —"
            }
        } else {
            lightStatus.title = "Light: searching…"
        }
        let manualOn = lights.lastKnownOn != true
        manual.title = manualOn ? "Turn Light On" : "Turn Light Off"
        manual.isEnabled = known
        manual.representedObject = manualOn

        brightnessRow.show(lights.brightness, enabled: known)
        temperatureRow.show(
            lights.temperature.map { Int((1_000_000 / Double($0)).rounded()) }, enabled: known)
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

        lightStatus.isEnabled = false
        menu.addItem(lightStatus)

        menu.addItem(.separator())

        let sync = NSMenuItem(
            title: "Sync Light to Camera", action: #selector(toggleAutoSync), keyEquivalent: "")
        sync.target = self
        sync.state = autoSync ? .on : .off
        menu.addItem(sync)

        manual.action = #selector(toggleLight)
        manual.target = self
        menu.addItem(manual)

        updateLightItems()
        for row in [brightnessRow, temperatureRow] {
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
        }

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

        let login = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

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
        cancelPendingOff()
        if autoSync {
            // Adopt the current camera state immediately.
            lights.setAll(on: camera.isCameraOn)
        }
    }

    @objc private func toggleLight(_ sender: NSMenuItem) {
        cancelPendingOff()
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
