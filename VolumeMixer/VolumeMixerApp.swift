import AppKit
import Combine
import SwiftUI

@main
struct VolumeMixerApp: App {
    @NSApplicationDelegateAdaptor(StatusBarDelegate.self) private var statusBar

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class StatusBarDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let controller = MixerController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let contextMenu = NSMenu()
    private var outsideClickMonitor: Any?
    private var iconSubscription: AnyCancellable?
    private var sizeSubscription: AnyCancellable?
    private var visibleRefreshTimer: Timer?
    private var refreshTick = 0
    private var displayedSymbol: String?
    private var pendingPopoverSize: NSSize?
    private let statusIconView = PassiveStatusIconView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.contentSize = NSSize(width: 290, height: 520)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MixerMenuView(controller: controller))

        if let button = statusItem.button {
            button.image = nil
            statusIconView.frame = button.bounds
            statusIconView.autoresizingMask = [.width, .height]
            statusIconView.imageScaling = .scaleProportionallyDown
            statusIconView.imageAlignment = .alignCenter
            button.addSubview(statusIconView)
            button.toolTip = "Volume Mixer"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let quit = NSMenuItem(title: "Quit Volume Mixer", action: #selector(quitClicked), keyEquivalent: "")
        quit.target = self
        contextMenu.addItem(quit)

        iconSubscription = controller.$systemVolume
            .combineLatest(controller.$systemMuted, controller.$selectedDeviceID, controller.$devices)
            .sink { [weak self] volume, muted, deviceID, devices in
                self?.updateStatusIcon(volume: volume, muted: muted,
                                       device: devices.first { $0.id == deviceID })
            }
        sizeSubscription = controller.$devices
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                guard let self else { return }
                let newSize = NSSize(width: 290, height: MixerMenuView.panelHeight(deviceCount: count))
                if self.popover.isShown {
                    self.pendingPopoverSize = newSize
                } else if self.popover.contentSize != newSize {
                    self.popover.contentSize = newSize
                }
            }
    }

    private static let headphoneSymbols: Set<String> = [
        "headphones", "earbuds", "airpods", "airpodspro", "airpodsmax",
    ]

    private func updateStatusIcon(volume: Double, muted: Bool, device: AudioOutputDevice?) {
        let symbol: String
        if let deviceSymbol = device?.symbolName, Self.headphoneSymbols.contains(deviceSymbol) {
            // Headphones keep their own icon (like the system), even when muted or at 0.
            symbol = deviceSymbol
        } else if muted || volume < 0.01 {
            symbol = "speaker.slash.fill"
        } else if volume < 0.34 {
            symbol = "speaker.wave.1.fill"
        } else if volume < 0.67 {
            symbol = "speaker.wave.2.fill"
        } else {
            symbol = "speaker.wave.3.fill"
        }
        applyStatusIcon(symbol)
    }

    private func applyStatusIcon(_ symbol: String) {
        guard displayedSymbol != symbol else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Volume Mixer")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        image?.isTemplate = true
        statusIconView.image = image
        displayedSymbol = symbol
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            contextMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            controller.refresh()
            popover.contentViewController?.view.layoutSubtreeIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                forceActiveAppearance(in: window)
            }
            controller.setPanelVisible(true)
            refreshTick = 0
            visibleRefreshTimer?.invalidate()
            visibleRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.popover.isShown else { return }
                    self.refreshTick += 1
                    if self.refreshTick.isMultiple(of: 4) {
                        self.controller.refresh()
                    } else {
                        self.controller.refreshProcesses()
                    }
                }
            }
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        }
    }

    /// Keeps the popover looking like a focused window without activating the app,
    /// so the previously frontmost app keeps keyboard focus.
    private func forceActiveAppearance(in window: NSWindow) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let effectView = view as? NSVisualEffectView {
                effectView.state = .active
            }
            stack.append(contentsOf: view.subviews)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        controller.setPanelVisible(false)
        visibleRefreshTimer?.invalidate()
        visibleRefreshTimer = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let pendingPopoverSize, popover.contentSize != pendingPopoverSize {
            popover.contentSize = pendingPopoverSize
        }
        pendingPopoverSize = nil
    }

    @objc private func quitClicked() {
        controller.quit()
    }
}

private final class PassiveStatusIconView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
