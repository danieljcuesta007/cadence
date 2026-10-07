// OverlayHUD — the non-activating pill (§12.1). Phase-1 spine version: fixed
// bottom-center placement, state glyph + live level bar + instant-pass partial text +
// local/cloud chip. Caret-anchored placement and the expanding text panel come later; the
// §12.1 invariant honored now is that it NEVER takes focus from the target field
// (non-activating panel, mouse-transparent).
//
// Layout contract: the panel sizes itself to its content on every state/partial change —
// a fixed width over-constrains the stack and AppKit resolves it by clipping a label
// (this is exactly how the level bars vanished on the first live run). The level label
// keeps a constant 10-glyph width while visible so per-chunk updates never relayout.
//
// While listening, the state glyph's dot is the ListeningOrb (SwiftUI, hosted). It is
// paused in every other state and after the fade, so it only draws while you dictate.

import AppKit
import SwiftUI

public final class OverlayHUD {
    private let panel: NSPanel
    private let content: NSVisualEffectView
    private let glyphLabel = NSTextField(labelWithString: "")
    private let orbModel = OrbModel()
    private let orbView: NSHostingView<ListeningOrb>
    private let levelLabel = NSTextField(labelWithString: "")
    private let partialLabel = NSTextField(labelWithString: "")
    private let chipLabel = NSTextField(labelWithString: "")
    private var fadeWork: DispatchWorkItem?

    private static let bars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    private var levelHistory = String(repeating: "▁", count: 10)

    public init() {
        orbView = NSHostingView(rootView: ListeningOrb(model: orbModel))
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

        content = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.material = .hudWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true

        glyphLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        levelLabel.font = monoFont
        // Rich green — the live "mic is hearing you" waveform, matched to the app icon's
        // peak bar so the brand's one accent color shows up wherever sound is visualized.
        // A brighter shade than the icon so it pops on the dark HUD material.
        levelLabel.textColor = NSColor(red: 0.36, green: 0.71, blue: 0.40, alpha: 1) // #5CB567
        partialLabel.font = .systemFont(ofSize: 13)
        partialLabel.lineBreakMode = .byTruncatingHead
        partialLabel.maximumNumberOfLines = 1
        chipLabel.font = .systemFont(ofSize: 11, weight: .medium)
        chipLabel.textColor = .secondaryLabelColor

        // Constant width while visible: the widest bar glyph x the 10-slot history.
        let barWidth = ("█" as NSString).size(withAttributes: [.font: monoFont]).width
        levelLabel.widthAnchor.constraint(equalToConstant: ceil(barWidth * 10)).isActive = true
        partialLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        levelLabel.isHidden = true
        partialLabel.isHidden = true
        orbView.translatesAutoresizingMaskIntoConstraints = false
        orbView.widthAnchor.constraint(equalToConstant: ListeningOrb.frameSize).isActive = true
        orbView.heightAnchor.constraint(equalToConstant: ListeningOrb.frameSize).isActive = true
        orbView.isHidden = true

        let stack = NSStackView(views: [orbView, glyphLabel, levelLabel, partialLabel, chipLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        // The orb's frame has ~1.75 pt of swell room each side; this keeps the visible gap
        // to "listening" what the old "● " had (~5 pt).
        stack.setCustomSpacing(3, after: orbView)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    /// Main thread only. state = ipc State snake_case; chip = "local"/"cloud" or nil.
    /// "idle" never renders — it dismisses (belt-and-braces; the router also maps it to a fade).
    public func show(state: String, chip: String?) {
        if state == "idle" {
            scheduleFade(after: 0)
            return
        }
        fadeWork?.cancel()
        fadeWork = nil
        let glyph: String
        switch state {
        case "listening": glyph = "listening"  // the orb is the dot
        case "thinking": glyph = "✦ thinking"
        case "inserting": glyph = "↳ inserting"
        case "done": glyph = "✓ done"
        case "cancelled": glyph = "✕ cancelled"
        case "error": glyph = "⚠︎ saved to clipboard"
        case "disabled": glyph = "‖ off here"
        default: glyph = state
        }
        glyphLabel.stringValue = glyph
        chipLabel.stringValue = chip == "cloud" ? "cloud" : "local"
        let listening = state == "listening"
        orbView.isHidden = !listening
        orbModel.paused = !listening
        if !listening { orbModel.level = 0 }
        if listening {
            levelHistory = String(repeating: "▁", count: 10)
            levelLabel.stringValue = levelHistory
            levelLabel.isHidden = false
            partialLabel.stringValue = ""
            partialLabel.isHidden = true
        } else {
            levelLabel.stringValue = ""
            levelLabel.isHidden = true
            // Keep the instant-pass text up while the refined pass runs (§12.3/ADR-0006).
            if state != "thinking" {
                partialLabel.stringValue = ""
                partialLabel.isHidden = true
            }
        }
        fitAndPosition()
        panel.alphaValue = 1
        panel.orderFrontRegardless() // never activates, never steals focus (AC-36)
    }

    /// Main thread only. Rolling mini-waveform: the §12.2 "mic is hearing you" trust signal.
    /// Never relayouts — the label keeps its constant 10-glyph width.
    public func setLevel(_ level: Float) {
        let idx = min(Self.bars.count - 1, max(0, Int(level * Float(Self.bars.count))))
        levelHistory.removeFirst()
        levelHistory.append(Self.bars[idx])
        levelLabel.stringValue = levelHistory
        guard !orbModel.paused else { return }
        // Fast attack, slow release, so the orb swells on a word and settles between them.
        // Publish only visible moves: each publish redraws the hosted SwiftUI view.
        let target = CGFloat(min(1, max(0, level)))
        let old = orbModel.level
        let next = target > old ? target : old * 0.85 + target * 0.15
        if abs(next - old) > 0.02 { orbModel.level = next }
    }

    /// Main thread only. Instant-pass text (§12.3): tail-anchored, head-truncated —
    /// during dictation the most recent words are the signal.
    public func setPartial(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        partialLabel.stringValue = t
        partialLabel.isHidden = t.isEmpty
        fitAndPosition()
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
                self.orbModel.paused = true
            }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func hide() {
        fadeWork?.cancel()
        panel.orderOut(nil)
        orbModel.paused = true
    }

    private func fitAndPosition() {
        let size = content.fittingSize
        panel.setContentSize(NSSize(width: max(size.width, 160), height: max(size.height, 36)))
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 96))
    }
}
