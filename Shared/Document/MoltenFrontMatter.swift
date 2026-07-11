import Foundation

/// YAML front matter protection. The Crepe editor has no front-matter node —
/// fed raw, it would render the `---` fence as a thematic break and the YAML
/// as body text, then SERIALIZE that mangling back to disk. The shell splits
/// the block off before the editor sees the text and splices it back on every
/// save. The split is BYTE-FAITHFUL: `join(split(x)) == x` for every input —
/// the body keeps its own leading blank lines, CRLF endings survive, and no
/// separator is ever invented.
enum MoltenFrontMatter {
    /// Splits leading front matter from body. The opening `---` must be the
    /// very first line; the block ends at the next `---`/`...` line (CRLF
    /// tolerated). Unterminated fences are body — guessing a boundary risks
    /// swallowing real content.
    static func split(_ text: String) -> (frontMatter: String, body: String) {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") || text == "---" else {
            return ("", text)
        }
        // Split on \n only: CR stays attached to the line and is preserved in
        // the reassembled front matter; the closer check trims it away.
        let lines = text.components(separatedBy: "\n")
        var closeIndex: Int?
        for index in 1..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" || trimmed == "..." {
                closeIndex = index
                break
            }
        }
        guard let closeIndex else {
            return ("", text)
        }
        let hasTrailingContent = closeIndex + 1 < lines.count
        let frontMatter = lines[0...closeIndex].joined(separator: "\n") + (hasTrailingContent ? "\n" : "")
        let body = hasTrailingContent ? lines[(closeIndex + 1)...].joined(separator: "\n") : ""
        return (frontMatter, body)
    }

    /// Pure concatenation — split never removed anything between the parts,
    /// so nothing may be invented here.
    static func join(frontMatter: String, body: String) -> String {
        frontMatter + body
    }
}
