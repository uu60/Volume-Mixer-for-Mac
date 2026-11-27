import AppKit
import AudioToolbox
import CoreAudio
import Foundation

struct AudioProcess: Identifiable, Equatable {
    let id: String
    let objectIDs: [AudioObjectID]
    let bundleID: String
    let name: String
    let icon: NSImage?

    var storageKey: String { id }

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.id == rhs.id && lhs.objectIDs == rhs.objectIDs && lhs.name == rhs.name
    }
}

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let iconURL: URL?
    let symbolName: String
}

enum AudioHardwareError: LocalizedError {
    case status(OSStatus, String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .status(status, operation):
            let code = status.fourCharacterCode
            return "\(operation) failed (\(code), \(status))."
        case let .unavailable(message):
            return message
        }
    }
}

extension OSStatus {
    var fourCharacterCode: String {
        let value = UInt32(bitPattern: self)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "OSStatus" }
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
}

enum CoreAudioSystem {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    @MainActor private static var ownerCache: [pid_t: (bundleID: String, name: String, icon: NSImage?)] = [:]

    static func processObjectIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return try arrayProperty(object: system, address: &address)
    }

    @MainActor static func processes(objectIDs ids: [AudioObjectID]) throws -> [AudioProcess] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier

        let audioObjects: [(id: AudioObjectID, pid: pid_t, bundleID: String, name: String, icon: NSImage?)] = ids.compactMap { objectID in
            guard let rawPID = try? uint32Property(
                object: objectID,
                selector: kAudioProcessPropertyPID
            ) else { return nil }
            let pid = pid_t(bitPattern: rawPID)
            guard pid != ownPID,
            let isRunning = try? uint32Property(
                object: objectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ), isRunning != 0 else { return nil }

            let running = NSRunningApplication(processIdentifier: pid)
            let bundleID = (try? stringProperty(
                object: objectID,
                selector: kAudioProcessPropertyBundleID
            )) ?? running?.bundleIdentifier ?? ""
            // Skip other Volume Mixer instances too (e.g. an installed copy plus an Xcode build);
            // otherwise each one taps the other's feedback sound and its tap IO shows up as an app.
            if let ownBundleID, bundleID == ownBundleID { return nil }
            let owner = owningApp(for: pid, running: running)
            return (objectID, pid, owner?.bundleID ?? bundleID,
                    owner?.name ?? running?.localizedName ?? (bundleID.isEmpty ? "Process \(pid)" : bundleID),
                    owner?.icon ?? running?.icon)
        }
        let groups = Dictionary(grouping: audioObjects) { object in
            object.bundleID.isEmpty ? "pid:\(object.pid)" : object.bundleID
        }
        return groups.map { key, members in
            let first = members[0]
            return AudioProcess(id: key, objectIDs: members.map(\.id).sorted(),
                                bundleID: first.bundleID, name: first.name, icon: first.icon)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @MainActor private static func owningApp(for pid: pid_t, running: NSRunningApplication?) -> (bundleID: String, name: String, icon: NSImage?)? {
        if let cached = ownerCache[pid] { return cached }
        var ancestorPID = pid
        var candidate = running
        for _ in 0..<8 {
            if let url = candidate?.bundleURL {
                let components = url.standardizedFileURL.pathComponents
                if let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) {
                    let appURL = URL(fileURLWithPath: NSString.path(withComponents: Array(components[0...appIndex])))
                    if let bundle = Bundle(url: appURL), let identifier = bundle.bundleIdentifier {
                        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                            ?? appURL.deletingPathExtension().lastPathComponent
                        let owner = (bundleID: identifier, name: name,
                                     icon: NSWorkspace.shared.icon(forFile: appURL.path))
                        if ownerCache.count > 500 { ownerCache.removeAll() }
                        ownerCache[pid] = owner
                        return owner
                    }
                }
            }
            var info = proc_bsdinfo()
            guard proc_pidinfo(ancestorPID, PROC_PIDTBSDINFO, 0, &info,
                               Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_ppid > 1 else { break }
            ancestorPID = pid_t(info.pbi_ppid)
            candidate = NSRunningApplication(processIdentifier: ancestorPID)
        }
        return nil
    }

    static func outputDevices() throws -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let ids: [AudioObjectID] = try arrayProperty(object: system, address: &address)

        return ids.compactMap { id in
            let transport = (try? uint32Property(object: id, selector: kAudioDevicePropertyTransportType)) ?? 0
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            let hasOutputStreams = AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &size) == noErr && size > 0
            guard (hasOutputStreams || transport == kAudioDeviceTransportTypeAirPlay),
                  let uid = try? stringProperty(object: id, selector: kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("com.example.VolumeMixer."),
                  let name = try? stringProperty(object: id, selector: kAudioObjectPropertyName)
            else { return nil }
            guard name != "Volume Mixer Private Device" else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name,
                                     iconURL: deviceIconURL(id), symbolName: deviceSymbol(transport: transport, name: name))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func deviceIconURL(_ device: AudioObjectID) -> URL? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIcon,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var icon: Unmanaged<CFURL>?
        var size = UInt32(MemoryLayout<CFURL?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &icon)
        guard status == noErr, let icon else { return nil }
        return icon.takeRetainedValue() as URL
    }

    private static func deviceSymbol(transport: UInt32, name: String) -> String {
        let lowerName = name.lowercased()
        // Older symbol names are used so they exist on macOS 14.
        if lowerName.contains("airpods max") { return "airpodsmax" }
        if lowerName.contains("airpods pro") { return "airpodspro" }
        if lowerName.contains("airpods") { return "airpods" }
        if lowerName.contains("earbuds") { return "earbuds" }
        if lowerName.contains("headphone") || lowerName.contains("headset") { return "headphones" }
        if lowerName.contains("macbook") || lowerName.contains("imac") { return "laptopcomputer" }
        if lowerName.contains("display") || lowerName.contains("monitor") { return "display" }
        if lowerName.contains("homepod") || lowerName == "home" { return "homepod.fill" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplay.audio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: return "hifispeaker.fill"
        case kAudioDeviceTransportTypeVirtual: return "speaker.wave.2.fill"
        default: return "speaker.wave.2.fill"
        }
    }

    static func defaultOutputDeviceID() throws -> AudioObjectID {
        try uint32Property(object: system, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func setDefaultOutputDevice(_ id: AudioObjectID) throws {
        try setUInt32Property(
            object: system,
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            value: id
        )
        // Alert sounds use a separate default and should follow the user's selection too.
        try? setUInt32Property(
            object: system,
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            value: id
        )
    }

    static func outputVolume(_ device: AudioObjectID) -> Float? {
        var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    static func canSetOutputVolume(_ device: AudioObjectID) -> Bool {
        var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr
            && settable.boolValue
    }

    static func setOutputVolume(_ value: Float, device: AudioObjectID) throws {
        var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = min(max(value, 0), 1)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
        guard status == noErr else { throw AudioHardwareError.status(status, "Change output volume") }
    }

    static func outputMuted(_ device: AudioObjectID) -> Bool? {
        var address = outputAddress(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr else { return nil }
        return mute != 0
    }

    static func setOutputMuted(_ muted: Bool, device: AudioObjectID) throws {
        var address = outputAddress(kAudioDevicePropertyMute)
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else { throw AudioHardwareError.status(status, "Change output mute") }
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32Property(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioHardwareError.status(status, "Read audio property") }
        return value
    }

    private static func setUInt32Property(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        value: UInt32
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableValue = value
        let status = AudioObjectSetPropertyData(
            object,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutableValue
        )
        guard status == noErr else { throw AudioHardwareError.status(status, "Change output device") }
    }

    private static func arrayProperty<T>(
        object: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) throws -> [T] {
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw AudioHardwareError.status(status, "Read audio list size") }
        precondition(MemoryLayout<T>.size == MemoryLayout<UInt32>.size)
        var values = [T](
            repeating: unsafeBitCast(UInt32(0), to: T.self),
            count: Int(size) / MemoryLayout<T>.size
        )
        guard !values.isEmpty else { return [] }
        status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { throw AudioHardwareError.status(status, "Read audio list") }
        return values
    }

    private static func stringProperty(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw AudioHardwareError.status(status, "Read audio name") }
        return value as String
    }
}
