// OverlayHUD — the non-activating pill (§12.1). Phase-1 spine version: fixed
// bottom-center placement, state glyph + live level bar + local/cloud chip. Caret-anchored
// placement and the expanding text panel come later; the §12.1 invariant honored now is
// that it NEVER takes focus from the target field (non-activating panel, mouse-transparent).

import AppKit

public final class OverlayHUD {
    private let panel: NSPanel
    private let glyphLabel = NSTextField(labelWithString: "")
    private let levelLabel = NSTextField(labelWithString: "")
    private let chipLabel = NSTextField(labelWithString: "")
    private var fadeWork: DispatchWorkItem?

    private static let bars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    private var levelHistory = String(repeating: "▁", count: 10)

    public init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let blur = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        glyphLabel.font = .systemFont(ofSize: 16)
        levelLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        levelLabel.textColor = .secondaryLabelColor
        chipLabel.font = .systemFont(ofSize: 11, weight: .medium)
        chipLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [glyphLabel, levelLabel, chipLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel.contentView = blur
    }

    /// Main thread only. state = ipc State snake_case; chip = "local"/"cloud" or nil.
    public func show(state: String, chip: String?) {
        fadeWork?.cancel()
        fadeWork = nil
        let glyph: String
        switch state {
        case "listening": glyph = "🎤 listening"
        case "thinking": glyph = "✦ thinking"
        case "inserting": glyph = "↳ inserting"
        case "done": glyph = "✓ done"
        case "cancelled": glyph = "✕ cancelled"
        case "error": glyph = "⚠︎ saved to clipboard"
        case "disabled": glyph = "⏸ off here"
        default: glyph = state
        }
        glyphLabel.stringValue = glyph
        chipLabel.stringValue = chip == "cloud" ? "☁︎ cloud" : "🔒 local"
        if state != "listening" {
            levelHistory = String(repeating: "▁", count: 10)
            levelLabel.stringValue = ""
        }
        position()
        panel.alphaValue = 1
        panel.orderFrontRegardless() // never activates, never steals focus (AC-36)
    }

    /// Main thread only. Rolling mini-waveform: the §12.2 "mic is hearing you" trust signal.
    public func setLevel(_ level: Float) {
        let idx = min(Self.bars.count - 1, max(0, Int(level * Float(Self.bars.count))))
        levelHistory.removeFirst()
        levelHistory.append(Self.bars[idx])
        levelLabel.stringValue = levelHistory
    }

    /// §12.2 DONE: hold 400–700 ms, then fade.
    public func scheduleFade(after delay: TimeInterval = 0.55) {
        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.panel.animator().alphaValue = 0
            } completionHandler: {
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func hide() {
        fadeWork?.cancel()
        panel.orderOut(nil)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: f.midX - size.width / 2, y: f.minY + 96))
    }
}
