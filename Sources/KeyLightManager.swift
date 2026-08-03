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
final class KeyLightManager: NSObject {
    /// Called on the main queue when the light list or known on/off state changes.
    var onUpdate: (() -> Void)?

    private(set) var lights: [KeyLight] = [] {
        didSet {
            if lights != oldValue {
                persist()
                onUpdate?()
            }
        }
    }

    /// Last on/off state we observed or commanded; nil until first contact.
    private(set) var lastKnownOn: Bool?

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
    func setAll(on: Bool) {
        lastKnownOn = on
        onUpdate?()
        for light in lights {
            send(light: light, on: on, attemptsLeft: 3)
        }
    }

    private func send(light: KeyLight, on: Bool, attemptsLeft: Int) {
        var request = URLRequest(url: light.baseURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["numberOfLights": 1, "lights": [["on": on ? 1 : 0]]])

        session.dataTask(with: request) { [weak self] _, response, error in
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            if !ok && attemptsLeft > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.send(light: light, on: on, attemptsLeft: attemptsLeft - 1)
                }
            }
        }.resume()
    }

    /// Reads the actual on/off state from the first reachable light.
    func refreshState() {
        guard let light = lights.first else { return }
        session.dataTask(with: light.baseURL) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["lights"] as? [[String: Any]])?.first,
                  let on = first["on"] as? Int
            else { return }
            DispatchQueue.main.async {
                self?.lastKnownOn = (on != 0)
                self?.onUpdate?()
            }
        }.resume()
    }
}

// MARK: - Bonjour

extension KeyLightManager: NetServiceBrowserDelegate, NetServiceDelegate {
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
