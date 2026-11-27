import SwiftUI

struct MixerMenuView: View {
    @ObservedObject var controller: MixerController
    @State private var hoveredDeviceID: UInt32?
    @State private var hoveredProcessID: String?
    @State private var isSettingsHovered = false
    @State private var isRefreshHovered = false

    static func panelHeight(deviceCount: Int) -> CGFloat {
        333 + CGFloat(deviceCount) * 29
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            outputSection
            Divider()
            HStack {
                Text("Apps").font(.headline)
                Spacer()
                Button { controller.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 23, height: 23)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(RefreshButtonStyle(isHovered: isRefreshHovered))
                .onHover { isRefreshHovered = $0 }
                .help("Refresh apps")
            }
            .padding(.horizontal, 14)
            .padding(.top, 7)
            ScrollView {
                if controller.processes.isEmpty {
                    Text("No apps are playing audio")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 170, alignment: .center)
                } else {
                    processList
                }
            }
            .scrollIndicators(.visible)
            .frame(height: 170)
            Divider()
            Button("Sound Settings…") { controller.openSoundSettings() }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSettingsHovered ? Color.primary.opacity(0.09) : .clear)
                )
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
                .onHover { isSettingsHovered = $0 }
        }
        .frame(width: 290, height: Self.panelHeight(deviceCount: controller.devices.count))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .alert("Volume Mixer", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sound").font(.headline)
            HStack(spacing: 8) {
                Button { controller.toggleSystemMute() } label: {
                    Image(systemName: controller.systemMuted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(controller.canAdjustSystemVolume ? Color.primary : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .allowsHitTesting(controller.canAdjustSystemVolume)
                .help(controller.systemMuted ? "Unmute output" : "Mute output")
                NativeOutputSlider(value: systemVolumeBinding,
                                   isEnabled: controller.canAdjustSystemVolume)
                    .frame(height: 20)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(controller.canAdjustSystemVolume ? Color.primary : Color.secondary.opacity(0.5))
            }
        }
        .padding(14)
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output").font(.headline)
                .padding(.leading, 4)
            VStack(spacing: 1) {
                    ForEach(controller.devices) { device in
                        Button { controller.chooseDevice(device.id) } label: {
                            HStack(spacing: 8) {
                                Group {
                                    if let url = device.iconURL, let icon = NSImage(contentsOf: url) {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .scaledToFit()
                                    } else {
                                        Image(systemName: device.symbolName)
                                            .resizable()
                                            .scaledToFit()
                                            .padding(3)
                                    }
                                }
                                .frame(width: 22, height: 22)
                                Text(device.name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(device.id == controller.selectedDeviceID
                                      ? Color.accentColor.opacity(0.20)
                                      : (hoveredDeviceID == device.id ? Color.primary.opacity(0.09) : .clear))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(device.id == controller.selectedDeviceID
                                              ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
                        )
                        .onHover { hoveredDeviceID = $0 ? device.id : nil }
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var processList: some View {
        LazyVStack(spacing: 2) {
            ForEach(controller.processes) { process in
                processRow(process)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func processRow(_ process: AudioProcess) -> some View {
        HStack(spacing: 8) {
            Group {
                if let icon = process.icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .scaledToFit()
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(process.name)
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int((controller.volume(for: process) * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .offset(y: 2)
                Slider(value: volumeBinding(for: process), in: 0...1)
            }

            Button {
                controller.toggleMute(for: process)
            } label: {
                Image(systemName: controller.isMuted(process) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(controller.isMuted(process) ? "Unmute" : "Mute")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(hoveredProcessID == process.id ? 0.09 : 0.035))
        )
        .onHover { hoveredProcessID = $0 ? process.id : nil }
    }

    private var systemVolumeBinding: Binding<Double> {
        Binding(
            get: { controller.systemVolume },
            set: { controller.setSystemVolume($0) }
        )
    }

    private func volumeBinding(for process: AudioProcess) -> Binding<Double> {
        Binding(
            get: { controller.volume(for: process) },
            set: { controller.setVolume($0, for: process) }
        )
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )
    }
}

private struct RefreshButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.18)
                          : (isHovered ? Color.primary.opacity(0.10) : .clear))
            )
    }
}

private struct NativeOutputSlider: NSViewRepresentable {
    @Binding var value: Double
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: 0, maxValue: 1,
                              target: context.coordinator,
                              action: #selector(Coordinator.valueChanged(_:)))
        slider.isEnabled = isEnabled
        slider.controlSize = .regular
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.isEnabled = isEnabled
        if abs(slider.doubleValue - value) > 0.0001 {
            slider.doubleValue = value
        }
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) { self.value = value }

        @objc func valueChanged(_ slider: NSSlider) {
            value.wrappedValue = slider.doubleValue
        }
    }
}
