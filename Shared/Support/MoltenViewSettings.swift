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

    // MARK: - Typography (Preferences ▸ 排印)

    /// "default" (theme's own stack) | "serif" | "sans".
    static var fontScheme: String {
        get { UserDefaults.standard.string(forKey: "Vellumi.fontScheme") ?? "default" }
        set { UserDefaults.standard.set(newValue, forKey: "Vellumi.fontScheme"); broadcast() }
    }

    /// 0 = theme default; otherwise 1.2…2.2.
    static var lineHeight: Double {
        get { UserDefaults.standard.double(forKey: "Vellumi.lineHeight") }
        set { UserDefaults.standard.set(newValue, forKey: "Vellumi.lineHeight"); broadcast() }
    }

    /// Paragraph spacing in em; 0 = theme default.
    static var paragraphSpacing: Double {
        get { UserDefaults.standard.double(forKey: "Vellumi.paragraphSpacing") }
        set { UserDefaults.standard.set(newValue, forKey: "Vellumi.paragraphSpacing"); broadcast() }
    }

    /// Editor column width in px; 0 = default 760.
    static var lineWidth: Double {
        get { UserDefaults.standard.double(forKey: "Vellumi.lineWidth") }
        set { UserDefaults.standard.set(newValue, forKey: "Vellumi.lineWidth"); broadcast() }
    }

    static var smartPunctuation: Bool {
        get { UserDefaults.standard.bool(forKey: "Vellumi.smartPunctuation") }
        set { UserDefaults.standard.set(newValue, forKey: "Vellumi.smartPunctuation"); broadcast() }
    }

    private static var pendingBroadcast: DispatchWorkItem?

    /// Re-applies the current settings to every open document's editor.
    /// Trailing-throttled: preference sliders fire per tick, and each apply is
    /// an evaluateJavaScript round trip per open document — coalesce to 10/s.
    static func broadcast() {
        pendingBroadcast?.cancel()
        let work = DispatchWorkItem {
            for case let document as MoltenDocument in NSDocumentController.shared.documents {
                document.editorViewController?.applyStoredViewSettings()
            }
        }
        pendingBroadcast = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
