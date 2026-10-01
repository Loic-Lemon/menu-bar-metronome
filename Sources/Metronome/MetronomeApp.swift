import SwiftUI
import AppKit

struct MetronomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { }
            .commands {
                CommandGroup(replacing: .appTermination) {
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    // ponytail: cache symbol images — they were re-allocated on the main thread on
    // every beat flash, competing with the popover open/close animation.
    private static let iconImages: [String: NSImage] = {
        let symbolSize = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let normal = NSImage(systemSymbolName: "metronome", accessibilityDescription: "Metronome")!
            .withSymbolConfiguration(symbolSize)!
        let filled = NSImage(systemSymbolName: "metronome.fill", accessibilityDescription: "Metronome")!
            .withSymbolConfiguration(symbolSize)!
        return [
            "metronome": normal,
            "metronome.fill": filled,
            "metronome.flipped": mirrored(normal),
            "metronome.fill.flipped": mirrored(filled),
        ]
    }()

    private static func mirrored(_ image: NSImage) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: image.size.width, yBy: 0)
        transform.scaleX(by: -1, yBy: 1)
        transform.concat()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        result.unlockFocus()
        result.isTemplate = image.isTemplate
        return result
    }

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    let model = MetronomeModel()

    private nonisolated(unsafe) var clickOutsideMonitor: Any?
    private var lastCloseAt: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        observeMenuBarIcon()
        observePopoverLayout()
        setupClickOutsideMonitor()
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 24)
        guard let button = statusItem.button else { return }

        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown

        button.image = Self.iconImages[model.menuBarIconName]

        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        let contentView = AnyView(ContentView().environment(model))
        hostingController = NSHostingController(rootView: contentView)

        popover = NSPopover()
        popover.behavior = .transient
        // Instant open/close: the native fade dropped frames and the transient
        // auto-close (mouse-down) + performClose (mouse-up) double-fire made it worse.
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = hostingController
        fitPopoverSize()
    }

    private func fitPopoverSize() {
        let width: CGFloat = 280
        let fitting = hostingController.sizeThatFits(
            in: NSSize(width: width, height: .greatestFiniteMagnitude)
        )
        let newSize = NSSize(width: width, height: max(200, fitting.height))
        popover.contentSize = newSize
    }

    private func setupClickOutsideMonitor() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.popover.isShown else { return }
            if let button = self.statusItem.button,
               let buttonWindow = button.window {
                let buttonScreenFrame = buttonWindow.convertToScreen(
                    button.convert(button.bounds, to: nil)
                )
                if buttonScreenFrame.contains(event.locationInWindow) { return }
            }
            self.model.popoverVisible = false
            self.popover.performClose(event)
        }
    }

    private func observeMenuBarIcon() {
        withObservationTracking {
            _ = self.model.menuBarIconName
            _ = self.model.menuBarPointerFlipped
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let button = self.statusItem.button else { return }
                let suffix = self.model.menuBarPointerFlipped ? ".flipped" : ""
                button.image = Self.iconImages[self.model.menuBarIconName + suffix]
                self.observeMenuBarIcon()
            }
        }
    }

    private func observePopoverLayout() {
        withObservationTracking {
            _ = self.model.showSettings
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fitPopoverSize()
                self.observePopoverLayout()
            }
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        model.popoverVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverVisible = false
        model.showSettings = false
        lastCloseAt = ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Actions

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        let isSecondary = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))

        if isSecondary {
            if popover.isShown {
                model.popoverVisible = false
                popover.performClose(sender)
            }
            showMenu(for: sender)
        } else {
            if popover.isShown {
                model.popoverVisible = false
                popover.performClose(sender)
            } else {
                // ponytail: 250ms dead-zone — transient popovers can auto-close on this
                // click's mouse-down; without it the mouse-up instantly reopens.
                guard ProcessInfo.processInfo.systemUptime - lastCloseAt >= 0.25 else { return }
                fitPopoverSize()
                model.popoverVisible = true
                popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    private func showMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let aboutItem = NSMenuItem(
            title: "About Menu Bar Metronome",
            action: #selector(openGitHub),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.midX, y: 0),
            in: button
        )
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/loic-lemon/menu-bar-metronome")!)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
