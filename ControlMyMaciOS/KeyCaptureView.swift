import SwiftUI
import UIKit

/// Invisible first responder that summons the system keyboard and
/// reports what gets typed.
///
/// A `UIKeyInput` view rather than a `UITextField`: there is no text
/// document here, just a stream of characters heading for another
/// machine.
final class KeyCaptureUIView: UIView, UIKeyInput {

    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { true }   // so backspace always reaches us

    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onDeleteBackward?() }

    // Every "helpful" text behaviour is wrong when the destination is a
    // remote machine — smart quotes in particular would silently corrupt
    // anything you type into an editor or terminal.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
}

struct KeyCaptureView: UIViewRepresentable {
    @Binding var isActive: Bool
    let onText: (String) -> Void
    let onDeleteBackward: () -> Void

    func makeUIView(context: Context) -> KeyCaptureUIView {
        let view = KeyCaptureUIView()
        view.onText = onText
        view.onDeleteBackward = onDeleteBackward
        return view
    }

    func updateUIView(_ uiView: KeyCaptureUIView, context: Context) {
        if isActive, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isActive, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }
}
