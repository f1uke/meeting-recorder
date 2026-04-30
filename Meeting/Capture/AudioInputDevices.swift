import Foundation
import CoreAudio

/// One audio input device discovered via Core Audio HAL.
///
/// `id` is the runtime `AudioObjectID` — unstable across reboots / device
/// hot-plug. `uid` is the device's stable identifier string (returned by
/// `kAudioDevicePropertyDeviceUID`) — that's what we persist in
/// UserDefaults so a saved selection survives unplugging and replugging.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let manufacturer: String?
    let isDefault: Bool
}

enum AudioInputDevices {
    /// Returns all audio devices that expose at least one input stream,
    /// with the system default device flagged. Empty array on HAL failure.
    static func enumerate() -> [AudioInputDevice] {
        let defaultUID = systemDefaultInputUID()
        let ids = allDeviceIDs()
        return ids.compactMap { id -> AudioInputDevice? in
            guard hasInputStreams(deviceID: id) else { return nil }
            guard let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName)
            else { return nil }
            let manufacturer = stringProperty(
                deviceID: id, selector: kAudioObjectPropertyManufacturer
            )
            return AudioInputDevice(
                id: id,
                uid: uid,
                name: name,
                manufacturer: manufacturer,
                isDefault: uid == defaultUID
            )
        }
    }

    /// Lookup by stable UID. Returns nil if the device isn't connected
    /// right now — caller should fall back to the system default.
    static func find(uid: String) -> AudioInputDevice? {
        enumerate().first { $0.uid == uid }
    }

    /// UID of whichever input device the system has set as default. Used
    /// to flag "(System default)" in the picker.
    static func systemDefaultInputUID() -> String? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { return nil }
        return stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    // MARK: - Private HAL helpers

    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &ids
        )
        return status == noErr ? ids : []
    }

    /// True iff `deviceID` reports at least one channel in `kAudioDevicePropertyStreams`
    /// scoped to input. That's the standard "is this an input device?" check.
    private static func hasInputStreams(deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard sizeStatus == noErr, size > 0 else { return false }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(
            capacity: Int(size) / MemoryLayout<AudioBufferList>.stride + 1
        )
        defer { bufferList.deallocate() }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList)
        guard status == noErr else { return false }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard sizeStatus == noErr, size > 0 else { return nil }

        // CFString is a reference type — taking `&cfString` directly forms
        // a raw pointer to an object reference and Swift correctly warns.
        // Routing through `Unmanaged<CFString>?` is the canonical fix and
        // gives explicit control over the Core Foundation retain count.
        var cfString: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfString)
        guard status == noErr, let cfString else { return nil }
        return cfString.takeRetainedValue() as String
    }
}
