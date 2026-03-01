import Foundation
import CoreAudio
import AudioToolbox

/// Represents an audio output device
struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Manages audio output device enumeration, selection, and change notifications.
/// Uses CoreAudio to list output devices and set them on AVAudioEngine's output node.
@MainActor
final class AudioDeviceManager: ObservableObject {
    static let shared = AudioDeviceManager()

    @Published var outputDevices: [AudioOutputDevice] = []
    @Published var selectedDeviceUID: String = ""

    /// Notification posted when the selected device changes (SampleEngine listens for this)
    static let deviceChangedNotification = Notification.Name("AudioDeviceManager.deviceChanged")

    private var listenerRegistered = false

    private init() {
        refreshDevices()
        // Load persisted preference
        selectedDeviceUID = UserDefaults.standard.string(forKey: AppConstants.audioOutputDeviceKey) ?? ""
        registerDeviceChangeListener()
    }

    // MARK: - Device Enumeration

    /// Refresh the list of available output devices
    func refreshDevices() {
        outputDevices = Self.getOutputDevices()
    }

    /// Get all audio output devices using CoreAudio
    static func getOutputDevices() -> [AudioOutputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return [] }

        var outputDevices: [AudioOutputDevice] = []

        for deviceID in deviceIDs {
            // Check if this device has output channels
            guard hasOutputChannels(deviceID) else { continue }

            let name = getDeviceName(deviceID)
            let uid = getDeviceUID(deviceID)
            guard !name.isEmpty, !uid.isEmpty else { continue }

            outputDevices.append(AudioOutputDevice(id: deviceID, uid: uid, name: name))
        }

        return outputDevices
    }

    /// Check if a device has output channels
    private static func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }

        let bufferListData = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListData.deallocate() }

        var size = dataSize
        let getStatus = AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &size, bufferListData)
        guard getStatus == noErr else { return false }

        let bufferList = bufferListData.assumingMemoryBound(to: AudioBufferList.self).pointee
        // mNumberBuffers > 0 means it has output channels
        return bufferList.mNumberBuffers > 0
    }

    /// Get the display name of a device
    private static func getDeviceName(_ deviceID: AudioDeviceID) -> String {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef)
        guard status == noErr, let cfName = nameRef?.takeUnretainedValue() else { return "" }
        return cfName as String
    }

    /// Get the unique identifier of a device (for persistence)
    private static func getDeviceUID(_ deviceID: AudioDeviceID) -> String {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uidRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uidRef)
        guard status == noErr, let cfUID = uidRef?.takeUnretainedValue() else { return "" }
        return cfUID as String
    }

    /// Get the system default output device ID
    static func getDefaultOutputDeviceID() -> AudioDeviceID {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    // MARK: - Device Selection

    /// Select a device and persist the choice
    func selectDevice(uid: String) {
        selectedDeviceUID = uid
        UserDefaults.standard.set(uid, forKey: AppConstants.audioOutputDeviceKey)
        NotificationCenter.default.post(name: Self.deviceChangedNotification, object: nil)
    }

    /// Get the AudioDeviceID for the currently selected device (or system default)
    func resolvedDeviceID() -> AudioDeviceID? {
        if selectedDeviceUID.isEmpty || selectedDeviceUID == "system_default" {
            return nil  // nil means use system default
        }
        return outputDevices.first(where: { $0.uid == selectedDeviceUID })?.id
    }

    // MARK: - CoreAudio set device on AudioUnit

    /// Apply the selected output device to an AVAudioEngine's output node
    static func setOutputDevice(_ deviceID: AudioDeviceID, on audioUnit: AudioUnit) -> Bool {
        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }

    // MARK: - Device Change Listener

    private func registerDeviceChangeListener() {
        guard !listenerRegistered else { return }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            deviceChangeListenerProc,
            selfPtr
        )

        if status == noErr {
            listenerRegistered = true
        }
    }

    deinit {
        // Note: deinit won't be called on singleton, but good practice
        if listenerRegistered {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                deviceChangeListenerProc,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }
}

/// CoreAudio callback when device list changes (C function, outside class)
private func deviceChangeListenerProc(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let manager = Unmanaged<AudioDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
    Task { @MainActor in
        manager.refreshDevices()
    }
    return noErr
}
