import AppKit

/// Global editor view settings (zoom, spellcheck, typewriter/focus modes),
/// persisted in UserDefaults and broadcast to every open document's editor.
/// Deliberately app-wide, not per-document — matching Preferences semantics.
@MainActor
enum MoltenViewSettings {
    private static let zoomKey = "Vellumi.editorZoom"
    private static let spellcheckKey = "Vellumi.spellcheck"
    private static let typewriterKey = "Vellumi.typewriter"
    private static let focusModeKey = "Vellumi.focusMode"

    static let zoomRange: ClosedRange<Double> = 0.5...3.0
    private static let zoomStep = 1.1

    static var zoom: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: zoomKey)
            return stored == 0 ? 1.0 : stored.clamped(to: zoomRange)
        }
        set {
            UserDefaults.standard.set(newValue.clamped(to: zoomRange), forKey: zoomKey)
            broadcast()
        }
    }

    static func zoomIn() { zoom *= zoomStep }
    static func zoomOut() { zoom /= zoomStep }
    static func resetZoom() { zoom = 1.0 }

    static var spellcheck: Bool {
        get { UserDefaults.standard.bool(forKey: spellcheckKey) }
        set { UserDefaults.standard.set(newValue, forKey: spellcheckKey); broadcast() }
    }

    static var typewriter: Bool {
        get { UserDefaults.standard.bool(forKey: typewriterKey) }
        set { UserDefaults.standard.set(newValue, forKey: typewriterKey); broadcast() }
    }

    static var focusMode: Bool {
        get { UserDefaults.standard.bool(forKey: focusModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: focusModeKey); broadcast() }
    }

    /// Re-applies the current settings to every open document's editor.
    static func broadcast() {
        for case let document as MoltenDocument in NSDocumentController.shared.documents {
            document.editorViewController?.applyStoredViewSettings()
        }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
