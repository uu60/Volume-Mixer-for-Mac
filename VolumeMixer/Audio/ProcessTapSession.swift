import CoreAudio
import Foundation

@available(macOS 14.2, *)
final class ProcessTapSession {
    let processID: AudioObjectID
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var processor: OpaquePointer?
    private var isRunning = false

    init(processID: AudioObjectID, outputDevice: AudioOutputDevice, gain: Float) throws {
        self.processID = processID
        guard let processor = VMGainProcessorCreate(gain) else {
            throw AudioHardwareError.unavailable("Could not allocate the real-time gain processor.")
        }
        self.processor = processor

        do {
            // A multi-output/aggregate output can't be nested in our private aggregate device,
            // so play through its real sub-devices and tap the process as a stereo mixdown.
            let subDevices = CoreAudioSystem.playbackSubDevices(for: outputDevice)
            let description = subDevices == nil
                ? CATapDescription(processes: [processID], deviceUID: outputDevice.uid, stream: 0)
                : CATapDescription(stereoMixdownOfProcesses: [processID])
            let mainUID = subDevices?.mainUID ?? outputDevice.uid
            let subDeviceList: [[String: Any]] = (subDevices?.uids ?? [outputDevice.uid]).map { uid in
                [kAudioSubDeviceUIDKey: uid,
                 kAudioSubDeviceDriftCompensationKey: uid != mainUID]
            }
            description.name = "Volume Mixer \(processID)"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .muted

            try check(
                AudioHardwareCreateProcessTap(description, &tapID),
                operation: "Create process tap"
            )

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceUIDKey: "com.example.VolumeMixer.\(UUID().uuidString)",
                kAudioAggregateDeviceNameKey: "Volume Mixer Private Device",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: mainUID,
                kAudioAggregateDeviceSubDeviceListKey: subDeviceList,
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: description.uuid.uuidString]
                ],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]

            try check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &aggregateID
                ),
                operation: "Create private aggregate device"
            )

            var createdIOProc: AudioDeviceIOProcID?
            try check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &createdIOProc,
                    aggregateID,
                    DispatchQueue(label: "VolumeMixer.Audio.\(processID)", qos: .userInteractive)
                ) { [processor] _, inputData, _, outputData, _ in
                    VMGainProcessorProcess(processor, inputData, outputData)
                },
                operation: "Create audio callback"
            )
            guard let createdIOProc else {
                throw AudioHardwareError.unavailable("Core Audio did not return an audio callback.")
            }
            ioProcID = createdIOProc

            try check(
                AudioDeviceStart(aggregateID, createdIOProc),
                operation: "Start process audio"
            )
            isRunning = true
        } catch {
            tearDown()
            throw error
        }
    }

    func setGain(_ gain: Float) {
        guard let processor else { return }
        VMGainProcessorSetTarget(processor, min(max(gain, 0), 1))
    }

    deinit {
        tearDown()
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else { throw AudioHardwareError.status(status, operation) }
    }

    private func tearDown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            if isRunning { AudioDeviceStop(aggregateID, ioProcID) }
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        isRunning = false

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        if let processor {
            VMGainProcessorDestroy(processor)
            self.processor = nil
        }
    }
}
