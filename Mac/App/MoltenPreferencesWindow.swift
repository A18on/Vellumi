import AppKit
import SwiftUI

/// Preferences (⌘,) — the one place every persisted option lives. Values are
/// stored in UserDefaults via @AppStorage; side effects (restyling open
/// editors, flipping NSApp.appearance) run in onChange so the panel stays a
/// dumb view over the same keys the menus use.
@MainActor
final class MoltenPreferencesWindowController: NSWindowController {
    static let shared = MoltenPreferencesWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("prefs.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: MoltenPreferencesView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }
}

struct MoltenPreferencesView: View {
    @AppStorage("Vellumi.appearanceMode") private var appearanceMode = 0
    @AppStorage("Vellumi.editorTheme") private var editorTheme = "frame"
    @AppStorage("Vellumi.editorZoom") private var editorZoom = 1.0
    @AppStorage("Vellumi.spellcheck") private var spellcheck = false
    @AppStorage("Vellumi.typewriter") private var typewriter = false
    @AppStorage("Vellumi.focusMode") private var focusMode = false
    @AppStorage("Vellumi.wordGoal") private var wordGoal = 0
    @AppStorage("Vellumi.smartPunctuation") private var smartPunctuation = false
    @AppStorage("Vellumi.fontScheme") private var fontScheme = "default"
    @AppStorage("Vellumi.lineHeight") private var lineHeight = 0.0
    @AppStorage("Vellumi.paragraphSpacing") private var paragraphSpacing = 0.0
    @AppStorage("Vellumi.lineWidth") private var lineWidth = 0.0

    @AppStorage("Vellumi.imageFolderName") private var imageFolderName = "assets"
    @State private var draftsFolderName = MoltenPreferencesView.currentDraftsFolderName()

    var body: some View {
        Form {
            Section(L10n.string("prefs.section.appearance")) {
                Picker(L10n.string("menu.appearance"), selection: $appearanceMode) {
                    Text(L10n.string("appearance.system")).tag(0)
                    Text(L10n.string("appearance.light")).tag(1)
                    Text(L10n.string("appearance.dark")).tag(2)
                }
                .onChange(of: appearanceMode) { mode in
                    MoltenAppearance.apply(mode: MoltenAppearance.Mode(rawValue: mode) ?? .system)
                }

                Picker(L10n.string("menu.theme"), selection: $editorTheme) {
                    Text(L10n.string("theme.frame")).tag("frame")
                    Text(L10n.string("theme.nord")).tag("nord")
                    Text(L10n.string("theme.classic")).tag("classic")
                }
                .onChange(of: editorTheme) { _ in
                    for case let document as MoltenDocument in NSDocumentController.shared.documents {
                        document.editorViewController?.applyStoredTheme()
                    }
                }

                HStack {
                    Slider(value: $editorZoom, in: MoltenViewSettings.zoomRange) {
                        Text(L10n.string("prefs.zoom"))
                    }
                    Text(String(format: "%.0f%%", editorZoom * 100))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: editorZoom) { _ in MoltenViewSettings.broadcast() }
            }

            Section(L10n.string("prefs.section.typography")) {
                Picker(L10n.string("prefs.fontScheme"), selection: $fontScheme) {
                    Text(L10n.string("prefs.fontScheme.default")).tag("default")
                    Text(L10n.string("prefs.fontScheme.serif")).tag("serif")
                    Text(L10n.string("prefs.fontScheme.sans")).tag("sans")
                }
                .onChange(of: fontScheme) { _ in MoltenViewSettings.broadcast() }

                typographySlider(
                    L10n.string("prefs.lineHeight"),
                    value: $lineHeight,
                    range: 1.2...2.2,
                    display: lineHeight == 0 ? L10n.string("prefs.themeDefault") : String(format: "%.1f", lineHeight)
                )
                typographySlider(
                    L10n.string("prefs.paragraphSpacing"),
                    value: $paragraphSpacing,
                    range: 0.2...2.0,
                    display: paragraphSpacing == 0 ? L10n.string("prefs.themeDefault") : String(format: "%.1f em", paragraphSpacing)
                )
                typographySlider(
                    L10n.string("prefs.lineWidth"),
                    value: $lineWidth,
                    range: 560...1080,
                    display: lineWidth == 0 ? L10n.string("prefs.lineWidth.adaptive") : String(format: "%.0f px", lineWidth)
                )
                Button(L10n.string("prefs.typography.reset")) {
                    lineHeight = 0
                    paragraphSpacing = 0
                    lineWidth = 0
                    fontScheme = "default"
                    MoltenViewSettings.broadcast()
                }
            }

            Section(L10n.string("prefs.section.editing")) {
                Toggle(L10n.string("prefs.smartPunctuation"), isOn: $smartPunctuation)
                    .onChange(of: smartPunctuation) { _ in MoltenViewSettings.broadcast() }
                    .help(L10n.string("prefs.smartPunctuation.help"))
                Toggle(L10n.string("menu.typewriter"), isOn: $typewriter)
                    .onChange(of: typewriter) { _ in MoltenViewSettings.broadcast() }
                Toggle(L10n.string("menu.focusMode"), isOn: $focusMode)
                    .onChange(of: focusMode) { _ in MoltenViewSettings.broadcast() }
                Toggle(L10n.string("menu.spellcheck"), isOn: $spellcheck)
                    .onChange(of: spellcheck) { _ in MoltenViewSettings.broadcast() }

                HStack {
                    Text(L10n.string("prefs.wordGoal"))
                    TextField("", value: $wordGoal, format: .number)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                    Text(L10n.string("prefs.wordGoal.unit"))
                        .foregroundStyle(.secondary)
                }
                .help(L10n.string("prefs.wordGoal.help"))
                .onChange(of: wordGoal) { _ in
                    NotificationCenter.default.post(name: .moltenWordGoalChanged, object: nil)
                }
            }

            Section(L10n.string("prefs.section.files")) {
                HStack {
                    Text(L10n.string("prefs.imageFolder"))
                    Spacer()
                    TextField("assets", text: $imageFolderName)
                        .frame(width: 140)
                        .multilineTextAlignment(.trailing)
                }
                .help(L10n.string("prefs.imageFolder.help"))

                HStack {
                    Text(L10n.string("prefs.draftsFolder"))
                    Spacer()
                    Text(draftsFolderName ?? L10n.string("prefs.draftsFolder.none"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(L10n.string("prefs.draftsFolder.configure")) {
                        (NSDocumentController.shared as? MoltenDocumentController)?
                            .configureDraftsFolder(nil)
                        draftsFolderName = Self.currentDraftsFolderName()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func typographySlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        HStack {
            Slider(value: value, in: range) { Text(title) }
                .onChange(of: value.wrappedValue) { _ in MoltenViewSettings.broadcast() }
            Text(display)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private static func currentDraftsFolderName() -> String? {
        (NSDocumentController.shared as? MoltenDocumentController)?
            .draftsStore.resolveFolderURL()?.lastPathComponent
    }
}

extension Notification.Name {
    /// Posted when the word-count goal changes so status bars refresh.
    static let moltenWordGoalChanged = Notification.Name("MoltenWordGoalChanged")
}
