import AppKit
import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import Foundation

@MainActor
final class MixerController: ObservableObject {
    @Published private(set) var processes: [AudioProcess] = []
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var selectedDeviceID: AudioObjectID = kAudioObjectUnknown
    @Published private(set) var systemVolume: Double = 0
    @Published private(set) var systemMuted = false
    @Published private(set) var canAdjustSystemVolume = false
    @Published private(set) var usesSoftwareOutputVolume = false
    @Published var errorMessage: String?

    private var volumes: [String: Double]
    private var lastAudibleVolumes: [String: Double]
    private var sessions: [AudioObjectID: ProcessTapSession] = [:]
    private var activeProcesses: [AudioProcess] = []
    private var keepVisibleUntil: Date = .distantPast
    private var softwareRefreshTimer: Timer?
    private var panelVisible = false
    private var failedTapIDs: Set<AudioObjectID> = []
    private let defaults = UserDefaults.standard
    private let volumesKey = "rememberedVolumes"
    private let audibleVolumesKey = "lastAudibleVolumes"
    private let softwareVolumesKey = "softwareOutputVolumes"
    private let softwareMutesKey = "softwareOutputMutes"
    private let propertyQueue = DispatchQueue.main
    private let volumeFeedback = VolumeFeedbackPlayer()
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var outputPropertyListener: AudioObjectPropertyListenerBlock?
    private var observedOutputDevice = AudioObjectID(kAudioObjectUnknown)

    init() {
        volumes = defaults.dictionary(forKey: volumesKey) as? [String: Double] ?? [:]
        lastAudibleVolumes = defaults.dictionary(forKey: audibleVolumesKey) as? [String: Double] ?? [:]
        refresh()
        installDefaultOutputListener()
    }

    deinit {
        softwareRefreshTimer?.invalidate()
        if let defaultOutputListener {
            var address = Self.defaultOutputAddress()
            AudioObjectRemovePropertyListenerBlock(CoreAudioSystem.system, &address,
                                                   propertyQueue, defaultOutputListener)
        }
        if let outputPropertyListener, observedOutputDevice != kAudioObjectUnknown {
            for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
                var address = Self.outputAddress(selector)
                AudioObjectRemovePropertyListenerBlock(observedOutputDevice, &address,
                                                       propertyQueue, outputPropertyListener)
            }
        }
    }

    func volume(for process: AudioProcess) -> Double {
        volumes[process.storageKey] ?? 1
    }

    func isMuted(_ process: AudioProcess) -> Bool {
        volume(for: process) <= 0.0001
    }

    func setVolume(_ value: Double, for process: AudioProcess) {
        let value = min(max(value, 0), 1)
        volumes[process.storageKey] = value
        if value > 0.0001 { lastAudibleVolumes[process.storageKey] = value }
        persist()
        if let current = activeProcesses.first(where: { $0.id == process.id }) {
            failedTapIDs.subtract(current.objectIDs)
            apply(value, to: current)
        }
        objectWillChange.send()
    }

    func toggleMute(for process: AudioProcess) {
        if isMuted(process) {
            setVolume(lastAudibleVolumes[process.storageKey] ?? 1, for: process)
        } else {
            lastAudibleVolumes[process.storageKey] = max(volume(for: process), 0.05)
            setVolume(0, for: process)
        }
    }

    func chooseDevice(_ id: AudioObjectID) {
        guard id != selectedDeviceID else { return }
        do {
            try CoreAudioSystem.setDefaultOutputDevice(id)
            keepVisibleUntil = Date().addingTimeInterval(4)
            selectedDeviceID = id
            sessions.removeAll()
            failedTapIDs.removeAll()
            refresh()
        } catch {
            show(error)
        }
    }

    func setSystemVolume(_ value: Double) {
        guard canAdjustSystemVolume else { return }
        systemVolume = min(max(value, 0), 1)
        if usesSoftwareOutputVolume {
            if systemMuted && systemVolume > 0 { systemMuted = false }
            persistSoftwareOutput()
            failedTapIDs.removeAll()
            updateAllGains()
            updateSoftwareRefreshTimer()
            return
        }
        do {
            try CoreAudioSystem.setOutputVolume(Float(systemVolume), device: selectedDeviceID)
            if systemMuted && systemVolume > 0 {
                try CoreAudioSystem.setOutputMuted(false, device: selectedDeviceID)
                systemMuted = false
            }
        } catch { show(error) }
    }

    /// Plays the same feedback sound macOS uses for volume keys, honoring
    /// System Settings › Sound › "Play feedback when volume is changed".
    func playVolumeFeedback(volume: Double = 1) {
        // Standard defaults include the global domain, where this setting lives.
        let enabled = defaults.object(forKey: "com.apple.sound.beep.feedback") as? Int ?? 1
        guard enabled != 0, volume > 0.0001 else { return }
        // Our own process is never tapped, so apply the software output level here.
        let level = volume * (usesSoftwareOutputVolume ? (systemMuted ? 0 : systemVolume) : 1)
        guard level > 0.0001 else { return }
        volumeFeedback.play(volume: Float(min(max(level, 0), 1)))
    }

    func toggleSystemMute() {
        if usesSoftwareOutputVolume {
            systemMuted.toggle()
            persistSoftwareOutput()
            failedTapIDs.removeAll()
            updateAllGains()
            updateSoftwareRefreshTimer()
            return
        }
        do {
            try CoreAudioSystem.setOutputMuted(!systemMuted, device: selectedDeviceID)
            systemMuted.toggle()
        } catch { show(error) }
    }

    func openSoundSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func refresh() {
        do {
            let newDevices = try CoreAudioSystem.outputDevices()
            let defaultID = try CoreAudioSystem.defaultOutputDeviceID()
            let deviceChanged = selectedDeviceID != kAudioObjectUnknown && selectedDeviceID != defaultID
            devices = newDevices
            selectedDeviceID = defaultID
            let hasNativeVolume = CoreAudioSystem.canSetOutputVolume(defaultID)
            usesSoftwareOutputVolume = !hasNativeVolume && newDevices.contains { $0.id == defaultID }
            canAdjustSystemVolume = hasNativeVolume || usesSoftwareOutputVolume
            if usesSoftwareOutputVolume {
                let uid = newDevices.first { $0.id == defaultID }?.uid ?? ""
                systemVolume = (defaults.dictionary(forKey: softwareVolumesKey) as? [String: Double])?[uid] ?? 1
                systemMuted = (defaults.dictionary(forKey: softwareMutesKey) as? [String: Bool])?[uid] ?? false
            } else {
                systemVolume = Double(CoreAudioSystem.outputVolume(defaultID) ?? 0)
                systemMuted = CoreAudioSystem.outputMuted(defaultID) ?? false
            }
            if deviceChanged {
                keepVisibleUntil = Date().addingTimeInterval(4)
                sessions.removeAll()
                failedTapIDs.removeAll()
            }
            observeOutputDevice(defaultID)
            refreshProcesses()
            updateSoftwareRefreshTimer()
        } catch {
            show(error)
        }
    }

    func refreshProcesses() {
        do {
            let processIDs = try CoreAudioSystem.processObjectIDs()
            let newProcesses = try CoreAudioSystem.processes(objectIDs: processIDs)
            let activeIDs = Set(newProcesses.flatMap(\.objectIDs))
            sessions = sessions.filter { activeIDs.contains($0.key) }
            failedTapIDs.formIntersection(activeIDs)
            activeProcesses = newProcesses
            let visibleProcesses: [AudioProcess]
            if Date() < keepVisibleUntil {
                let newKeys = Set(newProcesses.map(\.id))
                visibleProcesses = (newProcesses + processes.filter { !newKeys.contains($0.id) })
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } else {
                visibleProcesses = newProcesses
            }
            if processes != visibleProcesses { processes = visibleProcesses }
            restoreRememberedSessions()
        } catch {
            show(error)
        }
    }

    func quit() {
        softwareRefreshTimer?.invalidate()
        sessions.removeAll()
        NSApplication.shared.terminate(nil)
    }

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        updateSoftwareRefreshTimer()
    }

    private var selectedDevice: AudioOutputDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    private func apply(_ volume: Double, to process: AudioProcess) {
        let effectiveGain = volume * (usesSoftwareOutputVolume ? (systemMuted ? 0 : systemVolume) : 1)
        if effectiveGain >= 0.9999 {
            // Returning to 100% destroys the tap so audio resumes its native route.
            for id in process.objectIDs { sessions.removeValue(forKey: id) }
            return
        }

        guard let selectedDevice else {
            show(AudioHardwareError.unavailable("No output device is available."))
            return
        }

        for id in process.objectIDs {
            if failedTapIDs.contains(id) { continue }
            if let session = sessions[id] {
                session.setGain(Float(effectiveGain))
                continue
            }
            do {
                sessions[id] = try ProcessTapSession(
                    processID: id,
                    outputDevice: selectedDevice,
                    gain: Float(effectiveGain)
                )
            } catch {
                if usesSoftwareOutputVolume {
                    failedTapIDs.insert(id)
                } else {
                    volumes[process.storageKey] = 1
                    persist()
                }
                for objectID in process.objectIDs { sessions.removeValue(forKey: objectID) }
                show(error)
                return
            }
        }
    }

    private func restoreRememberedSessions() {
        for process in activeProcesses where
            (volume(for: process) < 0.9999 || (usesSoftwareOutputVolume && (systemMuted || systemVolume < 0.9999))) &&
            process.objectIDs.contains(where: { sessions[$0] == nil && !failedTapIDs.contains($0) }) {
            apply(volume(for: process), to: process)
        }
    }

    private func updateAllGains() {
        for process in activeProcesses { apply(volume(for: process), to: process) }
    }

    private func persistSoftwareOutput() {
        guard let uid = selectedDevice?.uid else { return }
        var volumes = defaults.dictionary(forKey: softwareVolumesKey) as? [String: Double] ?? [:]
        var mutes = defaults.dictionary(forKey: softwareMutesKey) as? [String: Bool] ?? [:]
        volumes[uid] = systemVolume
        mutes[uid] = systemMuted
        defaults.set(volumes, forKey: softwareVolumesKey)
        defaults.set(mutes, forKey: softwareMutesKey)
    }

    private func updateSoftwareRefreshTimer() {
        let needsMonitoring = !panelVisible && usesSoftwareOutputVolume && (systemMuted || systemVolume < 0.9999)
        if needsMonitoring && softwareRefreshTimer == nil {
            softwareRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshProcesses() }
            }
        } else if !needsMonitoring {
            softwareRefreshTimer?.invalidate()
            softwareRefreshTimer = nil
        }
    }

    private func persist() {
        defaults.set(volumes, forKey: volumesKey)
        defaults.set(lastAudibleVolumes, forKey: audibleVolumesKey)
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    nonisolated private static func defaultOutputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func installDefaultOutputListener() {
        var address = Self.defaultOutputAddress()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(CoreAudioSystem.system, &address,
                                               propertyQueue, listener) == noErr {
            defaultOutputListener = listener
        }
    }

    private func observeOutputDevice(_ id: AudioObjectID) {
        guard observedOutputDevice != id else { return }
        if let outputPropertyListener, observedOutputDevice != kAudioObjectUnknown {
            for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
                var address = Self.outputAddress(selector)
                AudioObjectRemovePropertyListenerBlock(observedOutputDevice, &address,
                                                       propertyQueue, outputPropertyListener)
            }
        }
        observedOutputDevice = id
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshOutputState() }
        }
        var installed = false
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.outputAddress(selector)
            if AudioObjectAddPropertyListenerBlock(id, &address, propertyQueue, listener) == noErr {
                installed = true
            }
        }
        outputPropertyListener = installed ? listener : nil
    }

    private func refreshOutputState() {
        guard let defaultID = try? CoreAudioSystem.defaultOutputDeviceID() else { return }
        if defaultID != selectedDeviceID {
            refresh()
            return
        }
        guard !usesSoftwareOutputVolume else { return }
        if let volume = CoreAudioSystem.outputVolume(defaultID) {
            let newValue = Double(volume)
            if abs(systemVolume - newValue) > 0.0001 { systemVolume = newValue }
        }
        if let muted = CoreAudioSystem.outputMuted(defaultID), systemMuted != muted {
            systemMuted = muted
        }
    }

}

/// Plays the macOS volume feedback sound off the main thread. The first playback
/// initializes the audio output (~200 ms), which would otherwise freeze the UI,
/// so the player is loaded and prepared in the background at launch.
private final class VolumeFeedbackPlayer: @unchecked Sendable {
    private static let url = URL(fileURLWithPath:
        "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff")
    private let queue = DispatchQueue(label: "VolumeMixer.feedback", qos: .userInitiated)
    private var player: AVAudioPlayer?

    init() {
        queue.async { [self] in _ = preparedPlayer() }
    }

    func play(volume: Float) {
        queue.async { [self] in
            guard let player = preparedPlayer() else { return }
            player.stop()
            player.currentTime = 0
            player.volume = volume
            player.play()
        }
    }

    private func preparedPlayer() -> AVAudioPlayer? {
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: Self.url)
            player?.prepareToPlay()
        }
        return player
    }
}
