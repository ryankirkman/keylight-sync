import Foundation
import CoreMediaIO

struct CameraDevice {
    let id: CMIOObjectID
    let uid: String
    let name: String
}

/// Watches CoreMediaIO for camera devices and reports when any watched camera
/// is in use by any application (event-driven, no polling).
final class CameraMonitor {
    /// Called on the main queue whenever the aggregate "camera in use" state changes.
    var onChange: ((Bool) -> Void)?
    /// Called on the main queue whenever the device list changes.
    var onDevicesChanged: (() -> Void)?

    private(set) var devices: [CameraDevice] = []
    private(set) var isCameraOn = false

    /// Device UID to watch; nil means any camera counts.
    var watchedUID: String? {
        didSet { evaluate() }
    }

    private var deviceListeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var systemListener: CMIOObjectPropertyListenerBlock?

    init() {
        listenForDeviceListChanges()
        refreshDevices()
        isCameraOn = anyWatchedDeviceRunning()
    }

    // MARK: - CMIO property helpers

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func deviceIDs() -> [CMIOObjectID] {
        var addr = address(kCMIOHardwarePropertyDevices)
        let systemID = CMIOObjectID(kCMIOObjectSystemObject)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemID, &addr, 0, nil, &dataSize) == 0,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(systemID, &addr, 0, nil, dataSize, &dataUsed, &ids) == 0
        else { return [] }
        return ids
    }

    private static func stringProperty(_ device: CMIOObjectID, _ selector: Int) -> String? {
        var addr = address(selector)
        guard CMIOObjectHasProperty(device, &addr) else { return nil }
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &addr, 0, nil, &dataSize) == 0 else { return nil }
        var dataUsed: UInt32 = 0
        var cfString: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            CMIOObjectGetPropertyData(device, &addr, 0, nil, dataSize, &dataUsed, ptr)
        }
        guard status == 0 else { return nil }
        return cfString?.takeRetainedValue() as String?
    }

    private static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var addr = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        guard CMIOObjectHasProperty(device, &addr) else { return false }
        var value: UInt32 = 0
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &dataUsed, &value)
        return status == 0 && value != 0
    }

    // MARK: - Listeners

    private func listenForDeviceListChanges() {
        var addr = Self.address(kCMIOHardwarePropertyDevices)
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
        }
        systemListener = block
        CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func refreshDevices() {
        let ids = Self.deviceIDs()

        devices = ids.map { id in
            CameraDevice(
                id: id,
                uid: Self.stringProperty(id, kCMIODevicePropertyDeviceUID) ?? "cmio-\(id)",
                name: Self.stringProperty(id, kCMIOObjectPropertyName) ?? "Camera \(id)")
        }

        // Remove listeners for departed devices.
        for (id, block) in deviceListeners where !ids.contains(id) {
            var addr = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, block)
            deviceListeners[id] = nil
        }

        // Add listeners for new devices.
        for id in ids where deviceListeners[id] == nil {
            var addr = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.evaluate()
            }
            if CMIOObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == 0 {
                deviceListeners[id] = block
            }
        }

        onDevicesChanged?()
        evaluate()
    }

    private func anyWatchedDeviceRunning() -> Bool {
        devices.contains { device in
            (watchedUID == nil || device.uid == watchedUID) && Self.isRunningSomewhere(device.id)
        }
    }

    /// Re-reads device state and fires onChange if the aggregate state flipped.
    func evaluate() {
        let on = anyWatchedDeviceRunning()
        guard on != isCameraOn else { return }
        isCameraOn = on
        onChange?(on)
    }
}
