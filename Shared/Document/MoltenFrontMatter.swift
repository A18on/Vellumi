import Foundation

/// YAML front matter protection. The Crepe editor has no front-matter node —
/// fed raw, it would render the `---` fence as a thematic break and the YAML
/// as body text, then SERIALIZE that mangling back to disk. Instead the shell
/// splits the block off before the editor sees the text and splices it back
/// on every save, byte-for-byte. (In-editor front-matter editing is a later
/// milestone; never corrupting it comes first.)
enum MoltenFrontMatter {
    /// Splits leading front matter from body. The opening `---` must be the
    /// very first line; the block ends at the next `---`/`...` line.
    static func split(_ text: String) -> (frontMatter: String, body: String) {
        guard text.hasPrefix("---\n") || text == "---" || text.hasPrefix("---\r\n") else {
            return ("", text)
        }
        let lines = text.components(separatedBy: "\n")
        var closeIndex: Int?
        for index in 1..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                closeIndex = index
                break
            }
        }
        guard let closeIndex else {
            // Unterminated fence: treat as body — guessing a boundary risks
            // swallowing real content.
            return ("", text)
        }
        let frontMatter = lines[0...closeIndex].joined(separator: "\n") + "\n"
        var body = lines[(closeIndex + 1)...].joined(separator: "\n")
        // Swallow the single conventional blank line after the fence; join()
        // restores it.
        if body.hasPrefix("\n") {
            body.removeFirst()
        }
        return (frontMatter, body)
    }

    /// Recombines for writing: front matter (already newline-terminated) +
    /// one blank separator line + body.
    static func join(frontMatter: String, body: String) -> String {
        guard !frontMatter.isEmpty else { return body }
        return frontMatter + "\n" + body
    }
}
