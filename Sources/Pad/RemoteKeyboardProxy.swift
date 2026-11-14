import UIKit

/// Uses Apple's keyboard and composition engine without copying remote field contents to iPad.
final class RemoteKeyboardProxy: UITextView, UITextViewDelegate {
    var committedText: ((String) -> Void)?
    var deleteRemote: (() -> Void)?
    var hardwareBegan: ((Set<UIPress>, UIPressesEvent?) -> Void)?
    var hardwareEnded: ((Set<UIPress>, UIPressesEvent?) -> Void)?
    private let sentinel = "\u{200B}"
    private var clearing = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1), textContainer: nil)
        delegate = self; backgroundColor = .clear; textColor = .clear; tintColor = .clear
        alpha = 0.01; isAccessibilityElement = false; isScrollEnabled = false
        autocorrectionType = .no; autocapitalizationType = .none
        smartQuotesType = .no; smartDashesType = .no; smartInsertDeleteType = .no
        spellCheckingType = .no
        inputAssistantItem.leadingBarButtonGroups = []; inputAssistantItem.trailingBarButtonGroups = []
        resetComposition()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// No three-finger undo/copy/paste gestures of iPadOS's own: three-finger swipes belong to the Mac here.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    func resetComposition() {
        clearing = true; text = sentinel; selectedRange = NSRange(location: sentinel.utf16.count, length: 0); clearing = false
    }
    func textViewDidChange(_ textView: UITextView) { flushCommittedText() }
    override func unmarkText() { super.unmarkText(); flushCommittedText() }
    override func insertText(_ text: String) { super.insertText(text); flushCommittedText() }
    override func deleteBackward() {
        if markedTextRange != nil || text != sentinel { super.deleteBackward() }
        else { deleteRemote?() }
    }
    private func flushCommittedText() {
        guard !clearing, markedTextRange == nil else { return }
        let value = text ?? ""
        let committed = value.hasPrefix(sentinel) ? String(value.dropFirst()) : value
        if !committed.isEmpty { committedText?(committed) }
        resetComposition()
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let physical = Set(presses.filter { $0.key != nil })
        if !physical.isEmpty { hardwareBegan?(physical, event) }
        let other = presses.subtracting(physical)
        if !other.isEmpty { super.pressesBegan(other, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let physical = Set(presses.filter { $0.key != nil })
        if !physical.isEmpty { hardwareEnded?(physical, event) }
        let other = presses.subtracting(physical)
        if !other.isEmpty { super.pressesEnded(other, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { pressesEnded(presses, with: event) }
}
