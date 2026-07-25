// DictionaryWindow — the personal dictionary editor (§). One term per line: proper nouns,
// jargon, names the user wants spelled correctly (e.g. "Wispr Flow", "Addisuna", "Lyle").
// Saved to the store's `custom_vocabulary`; the terms are joined into a whisper initial_prompt
// that biases the refined decode. Plain, focused, one job — a text area and Save.

import AppKit

/// Fold the stored, one-per-line vocabulary into a single prompt phrase for whisper. A comma
/// list of terms is enough to bias spelling without over-constraining the decode; whitespace
/// and blank lines are cleaned so the prompt stays tight.
enum Vocabulary {
    static func prompt(from text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

final class DictionaryWindowController: NSWindowController, NSWindowDelegate {
    /// Called with the raw multi-line text when the user saves.
    var onSave: ((String) -> Void)?
    private let textView = NSTextView()

    convenience init(initial: String, onSave: @escaping (String) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Personal Dictionary"
        self.init(window: window)
        self.onSave = onSave
        window.delegate = self
        buildUI(initial: initial)
        window.center()
    }

    private func buildUI(initial: String) {
        guard let content = window?.contentView else { return }

        let heading = NSTextField(labelWithString: "Words Cadence should spell your way")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let sub = NSTextField(wrappingLabelWithString:
            "One per line — names, brands, jargon. Cadence favors these spellings when it hears "
            + "something close (e.g. “Wispr Flow”, “Addisuna”, “Lyle”).")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor

        textView.string = initial
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false  // straight quotes in terms
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"  // Esc
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"  // Return
        save.bezelColor = BrandColor.green
        save.contentTintColor = .white

        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [heading, sub, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttons.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    @objc private func save() {
        onSave?(textView.string)
        window?.close()
    }

    @objc private func cancel() {
        window?.close()
    }
}
