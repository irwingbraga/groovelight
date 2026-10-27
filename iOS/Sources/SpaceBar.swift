import SwiftUI
import UIKit

// The space bar plays and pauses in every view, as on the Mac. A SwiftUI shortcut cannot do it: lists and scroll views
// take the space to scroll down a page (a system behavior that comes before the app's shortcuts), so the window's root
// controller gets a key command that comes first. Screens presented over it (Now Playing, sheets) pass it on.

extension View {
    /// Space plays and pauses while this window is in front; in a text field it still types a space.
    func spaceBarPlaysAndPauses(_ toggle: @escaping @MainActor () -> Void) -> some View {
        background(SpaceBarInstaller(toggle: toggle))
    }
}

@MainActor
private enum SpaceBar {
    static var toggle: (@MainActor () -> Void)?
    static weak var firstResponder: UIResponder?
}

private struct SpaceBarInstaller: UIViewRepresentable {
    let toggle: @MainActor () -> Void

    func makeUIView(context: Context) -> InstallerView {
        SpaceBar.toggle = toggle
        return InstallerView()
    }

    func updateUIView(_ view: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let action = #selector(UIViewController.groovelightSpaceBar)
            guard let root = window?.rootViewController, root.keyCommands?.contains(where: { $0.action == action }) != true else { return }
            let command = UIKeyCommand(input: " ", modifierFlags: [], action: action)
            command.wantsPriorityOverSystemBehavior = true
            root.addKeyCommand(command)
        }
    }
}

extension UIViewController {
    @objc func groovelightSpaceBar() {
        SpaceBar.firstResponder = nil
        UIApplication.shared.sendAction(#selector(UIResponder.groovelightCaptureFirstResponder), to: nil, from: nil, for: nil)
        // Typing (the search field, a playlist's name): the space is text.
        if let input = SpaceBar.firstResponder, input is UITextField || input is UITextView {
            (input as? UIKeyInput)?.insertText(" ")
        } else {
            SpaceBar.toggle?()
        }
    }
}

extension UIResponder {
    @objc fileprivate func groovelightCaptureFirstResponder() {
        SpaceBar.firstResponder = self
    }
}
