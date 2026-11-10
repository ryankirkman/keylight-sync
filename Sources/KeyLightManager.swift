import Foundation

struct KeyLight: Codable, Equatable {
    let name: String
    let host: String
    let port: Int

    var baseURL: URL { URL(string: "http://\(host):\(port)/elgato/lights")! }
}

/// Discovers Elgato lights via Bonjour (_elg._tcp) and controls them over
/// their local HTTP API. Remembers the last known lights across launches so
/// control works even before discovery completes.
@MainActor
final class KeyLightManager: NSObject {
    /// Called on the main actor when the light list or known on/off state changes.
    var onUpdate: (() -> Void)?

    private(set) var lights: [KeyLight] = [] {
        didSet {
            if lights != oldValue {
                persist()
                onUpdate?()
            }
        }
    }

    /// Last on/off state we observed or commanded; nil until first contact, and again when
    /// a command couldn't be delivered and no light answers to say what it's doing.
    private(set) var lastKnownOn: Bool?

    /// Brightness in percent and colour temperature in mireds (1,000,000 / kelvin, the unit
    /// the light speaks), as last read from a light or set here; nil until first contact.
    private(set) var brightness: Int?
    private(set) var temperature: Int?
    static let brightnessRange = 3...100
    static let temperatureRange = 143...344   // 7000 K down to 2900 K

    /// Bumped by every brightness/temperature change, so a state read that started
    /// before it can't put the old values back.
    private var adjustments = 0
    /// Values changed but not yet sent, and whether the loop that sends them is running.
    private var pendingLevels: [String: Int] = [:]
    private var sendingLevels = false

    /// Bumped by every command. Retries and state reads that started before the newest
    /// command check it and give up, so they can't undo or misreport that command.
    private var generation = 0

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private let session: URLSession
    private static let defaultsKey = "knownLights"

    override init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        super.init()

        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([KeyLight].self, from: data) {
            lights = saved
        }

        browser.delegate = self
        browser.schedule(in: .main, forMode: .common)
        browser.searchForServices(ofType: "_elg._tcp.", inDomain: "local.")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(lights) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Control

    /// Turns every known light on or off. Retries each light a few times
    /// because the lights' HTTP server can be slow to accept connections.
    /// The new state is shown at once; if a light never takes the command, the
    /// state falls back to whatever the lights report (unknown if none answers).
    func setAll(on: Bool) {
        generation += 1
        let generation = generation
        lastKnownOn = on
        onUpdate?()
        for light in lights {
            Task {
                let delivered = await send(light: light, on: on, attempts: 3, generation: generation)
                guard !delivered, generation == self.generation else { return }
                lastKnownOn = nil
                onUpdate?()
                refreshState()
            }
        }
    }

    /// Sets brightness (percent) and/or colour temperature (mireds) on every known light,
    /// leaving on/off alone. Made to be called continuously from a slider: only the newest
    /// values are sent, one request per light at a time.
    func adjust(brightness: Int? = nil, temperature: Int? = nil) {
        adjustments += 1
        if let brightness {
            self.brightness = brightness.clamped(to: Self.brightnessRange)
            pendingLevels["brightness"] = self.brightness
        }
        if let temperature {
            self.temperature = temperature.clamped(to: Self.temperatureRange)
            pendingLevels["temperature"] = self.temperature
        }
        guard !sendingLevels, !pendingLevels.isEmpty else { return }
        sendingLevels = true
        Task {
            var delivered = true
            while !pendingLevels.isEmpty {
                let levels = pendingLevels
                pendingLevels = [:]
                delivered = true
                for light in lights where !(await put(levels, to: light)) {
                    delivered = false
                }
            }
            sendingLevels = false
            if !delivered { refreshState() }   // show what the lights really have
        }
    }

    /// Sends one state change to a light; true if the light accepted it.
    private func put(_ fields: [String: Int], to light: KeyLight) async -> Bool {
        var request = URLRequest(url: light.baseURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["numberOfLights": 1, "lights": [fields]])
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// False only when every attempt failed; a command dropped for a newer one counts as handled.
    private func send(light: KeyLight, on: Bool, attempts: Int, generation: Int) async -> Bool {
        for attempt in 1...attempts {
            guard generation == self.generation else { return true }   // a newer command took over
            if await put(["on": on ? 1 : 0], to: light) {
                return true
            }
            if attempt < attempts {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return generation != self.generation
    }

    /// Reads the actual on/off state, brightness and temperature from the first reachable light.
    func refreshState() {
        let generation = generation
        let adjustments = adjustments
        let lights = lights
        Task {
            for light in lights {
                guard let (data, _) = try? await session.data(from: light.baseURL),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let first = (json["lights"] as? [[String: Any]])?.first,
                      let on = first["on"] as? Int
                else { continue }
                // A command sent while this read was in flight knows better than the reply.
                if generation == self.generation {
                    lastKnownOn = (on != 0)
                }
                if adjustments == self.adjustments, !sendingLevels {
                    brightness = first["brightness"] as? Int ?? brightness
                    temperature = first["temperature"] as? Int ?? temperature
                }
                onUpdate?()
                return
            }
        }
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Bonjour

// Delegate callbacks arrive on the main run loop, where both are scheduled.
extension KeyLightManager: @preconcurrency NetServiceBrowserDelegate,
                           @preconcurrency NetServiceDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool) {
        resolving.append(service)
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 15)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { resolving.removeAll { $0 === sender } }
        guard let host = sender.hostName else { return }
        let light = KeyLight(name: sender.name, host: host, port: sender.port)
        if let index = lights.firstIndex(where: { $0.name == light.name }) {
            lights[index] = light
        } else {
            lights.append(light)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }

    // Deliberately ignore didRemove: mDNS drops are often transient, and the
    // persisted address remains the best guess for reaching the light.
}
