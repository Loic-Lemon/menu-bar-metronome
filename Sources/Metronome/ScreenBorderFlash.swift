import AppKit
import QuartzCore

/// Transparent, click-through overlays; only the edge glow is drawn.
@MainActor
final class ScreenBorderFlash {
    private var panels: [NSPanel] = []
    private var screenFrames: [NSRect] = []

    func pulse(bpm: Double) {
        let screens = NSScreen.screens
        if panels.isEmpty || screenFrames != screens.map(\.frame) {
            stop()
            screenFrames = screens.map(\.frame)
            panels = screens.map { screen in
                let panel = NSPanel(
                    contentRect: screen.frame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.isReleasedWhenClosed = false
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.level = .screenSaver
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

                let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.wantsLayer = true
                let glow = CAShapeLayer()
                glow.frame = view.bounds
                // Keep the solid stroke outside the screen; only its broad feather is visible.
                glow.path = CGPath(rect: view.bounds.insetBy(dx: -6, dy: -6), transform: nil)
                glow.fillColor = nil
                glow.strokeColor = NSColor.white.cgColor
                glow.lineWidth = 12
                glow.shadowPath = glow.path?.copy(
                    strokingWithWidth: glow.lineWidth,
                    lineCap: .square, lineJoin: .miter, miterLimit: 10
                )
                glow.shadowColor = NSColor.white.cgColor
                glow.shadowOpacity = 1
                glow.shadowRadius = 48
                glow.shadowOffset = .zero
                glow.opacity = 0
                view.layer?.addSublayer(glow)
                panel.contentView = view
                panel.orderFrontRegardless()
                return panel
            }
        }

        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for panel in panels {
            guard let glow = panel.contentView?.layer?.sublayers?.first else { continue }
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0, reducedMotion ? 0.35 : 0.85, 0]
            animation.keyTimes = [0, 0.22, 1]
            animation.duration = Self.pulseDuration(bpm: bpm)
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut)
            ]
            glow.add(animation, forKey: "beat")
        }
    }

    // Leave a dark gap between beats, even at the maximum tempo.
    nonisolated static func pulseDuration(bpm: Double) -> TimeInterval {
        min(0.28, 60 / bpm * 0.8)
    }

    func stop() {
        for panel in panels { panel.close() }
        panels.removeAll()
        screenFrames.removeAll()
    }
}
