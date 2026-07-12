import SwiftUI

/// Editable YAML front-matter sheet. Valid inputs: empty (removes the block)
/// or a well-formed fenced block with nothing after the closing fence —
/// MoltenFrontMatter.split is the single validity oracle, so what the sheet
/// accepts is exactly what the writer round-trips.
struct MoltenFrontMatterSheet: View {
    let initialText: String
    /// nil = cancelled.
    let completion: (String?) -> Void

    @State private var text: String
    @State private var validationFailed = false

    init(initialText: String, completion: @escaping (String?) -> Void) {
        self.initialText = initialText
        self.completion = completion
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("frontmatter.title"))
                .font(.headline)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            if validationFailed {
                Text(L10n.string("frontmatter.invalid"))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Text(L10n.string("frontmatter.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("common.cancel")) { completion(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("frontmatter.save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            completion("")
            return
        }
        // Normalize to exactly one trailing newline so the fence closes and
        // the body splice stays clean.
        let candidate = text.hasSuffix("\n") ? text : text + "\n"
        let parts = MoltenFrontMatter.split(candidate)
        guard !parts.frontMatter.isEmpty,
              parts.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationFailed = true
            return
        }
        completion(parts.frontMatter + parts.body)
    }
}
