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
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    let model = MetronomeModel()

    private nonisolated(unsafe) var clickOutsideMonitor: Any?

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

        button.image = NSImage(
            systemSymbolName: model.menuBarIconName,
            accessibilityDescription: "Metronome"
        )

        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        let contentView = AnyView(ContentView().environment(model))
        hostingController = NSHostingController(rootView: contentView)

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = hostingController
        fitPopoverSize()
    }

    private func fitPopoverSize() {
        let width = model.popoverDensity.width
        let fitting = hostingController.sizeThatFits(
            in: NSSize(width: width, height: .greatestFiniteMagnitude)
        )
        let newSize = NSSize(width: width, height: max(200, fitting.height))
        let animates = popover.animates
        popover.animates = false
        popover.contentSize = newSize
        popover.animates = animates
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
        withObservationTracking { _ = self.model.menuBarIconName } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statusItem.button?.image = NSImage(
                    systemSymbolName: self.model.menuBarIconName,
                    accessibilityDescription: "Metronome"
                )
                self.observeMenuBarIcon()
            }
        }
    }

    private func observePopoverLayout() {
        withObservationTracking {
            _ = self.model.popoverDensity
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
