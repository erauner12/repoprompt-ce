import AppKit

enum AgentSessionHandoffInstructionsEditorResult: Equatable {
    case copy(String)
    case cancel
}

typealias AgentSessionHandoffInstructionsEditorCompletion =
    (AgentSessionHandoffInstructionsEditorResult) -> Void

typealias AgentSessionHandoffInstructionsEditorPresenter = (
    _ initialInstructions: String,
    _ attachedTo: NSWindow,
    _ completion: @escaping AgentSessionHandoffInstructionsEditorCompletion
) -> Void

@MainActor
final class AgentSessionHandoffInstructionsEditorController: NSObject, NSTextViewDelegate {
    private weak var attachedWindow: NSWindow?
    private var alert: NSAlert?
    private var textView: NSTextView?
    private var countLabel: NSTextField?
    private var completion: AgentSessionHandoffInstructionsEditorCompletion?
    private var hasCompleted = false

    func present(
        initialInstructions: String,
        attachedTo window: NSWindow,
        completion: @escaping AgentSessionHandoffInstructionsEditorCompletion
    ) {
        guard self.completion == nil, !hasCompleted else { return }

        let alert = NSAlert()
        alert.messageText = "Handoff with Instructions"
        alert.informativeText = "This text is appended to this clipboard prompt only and does not change the saved default."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy Handoff")
        alert.addButton(withTitle: "Cancel")

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 225))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 45, width: 420, height: 180))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.string = initialInstructions
        textView.delegate = self
        textView.allowsUndo = true
        textView.isRichText = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        if #available(macOS 13.0, *) {
            textView.isAutomaticDataDetectionEnabled = false
        }
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Handoff instructions")
        scrollView.documentView = textView

        let countLabel = NSTextField(labelWithString: "")
        countLabel.frame = NSRect(x: 0, y: 0, width: 420, height: 36)
        countLabel.maximumNumberOfLines = 2
        countLabel.lineBreakMode = .byWordWrapping

        accessoryView.addSubview(scrollView)
        accessoryView.addSubview(countLabel)
        alert.accessoryView = accessoryView

        attachedWindow = window
        self.alert = alert
        self.textView = textView
        self.countLabel = countLabel
        self.completion = completion
        updateValidationState()

        alert.beginSheetModal(for: window) { [weak self] response in
            self?.sheetDidEnd(response)
        }
        window.makeFirstResponder(textView)
    }

    func cancel() {
        guard !hasCompleted else { return }
        let window = attachedWindow
        let sheet = alert?.window
        resolve(.cancel)
        if let window, let sheet, sheet.sheetParent === window {
            window.endSheet(sheet, returnCode: .abort)
        }
    }

    func textDidChange(_ notification: Notification) {
        _ = notification
        updateValidationState()
    }

    private func sheetDidEnd(_ response: NSApplication.ModalResponse) {
        guard !hasCompleted else { return }
        guard response == .alertFirstButtonReturn,
              let instructions = textView?.string,
              case .valid = AgentSessionHandoffInstructionsPolicy.validation(of: instructions)
        else {
            resolve(.cancel)
            return
        }
        resolve(.copy(instructions))
    }

    private func updateValidationState() {
        guard let instructions = textView?.string else { return }
        let maximum = AgentSessionHandoffInstructionsPolicy.maximumCharacterCount
        switch AgentSessionHandoffInstructionsPolicy.validation(of: instructions) {
        case let .valid(count):
            countLabel?.stringValue = "\(Self.localizedCount(count)) / \(Self.localizedCount(maximum)) characters"
            countLabel?.textColor = .secondaryLabelColor
            alert?.buttons.first?.isEnabled = true
        case let .tooLong(count, _):
            countLabel?.stringValue = "\(Self.localizedCount(count)) / \(Self.localizedCount(maximum)) characters — shorten the instructions before copying."
            countLabel?.textColor = .systemRed
            alert?.buttons.first?.isEnabled = false
        }
    }

    private func resolve(_ result: AgentSessionHandoffInstructionsEditorResult) {
        guard !hasCompleted else { return }
        hasCompleted = true
        let completion = completion
        self.completion = nil
        textView?.delegate = nil
        attachedWindow = nil
        alert = nil
        textView = nil
        countLabel = nil
        completion?(result)
    }

    private static func localizedCount(_ count: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }
}
