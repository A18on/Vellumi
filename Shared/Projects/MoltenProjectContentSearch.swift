import Foundation

/// One matching line within a file (1-based line number, trimmed line text, and the match's range
/// in the whole-file string for a future jump-to-match).
struct MoltenProjectLineMatch: Equatable {
    let lineNumber: Int
    let lineText: String
    let matchRangeInFile: NSRange
}

/// A file that contains the query, with its matching lines.
struct MoltenProjectSearchResult: Identifiable, Equatable {
    let file: MoltenProjectFile
    let matches: [MoltenProjectLineMatch]
    var id: String { file.path }
    var matchCount: Int { matches.count }
}

/// Full-text "find in files" across a project's Markdown files. Pure line scanning split out from
/// the file IO so it's unit-testable; results are capped so a huge project can't blow up memory.
enum MoltenProjectContentSearch {
    static let maxMatchesPerFile = 50
    static let maxFiles = 1000

    /// Records the first match per line (one snippet per matching line). 1-based line numbers;
    /// `matchRangeInFile` offsets into `content`. Pure — no IO.
    static func lineMatches(
        in content: String,
        query: String,
        caseSensitive: Bool,
        maxMatches: Int = maxMatchesPerFile
    ) -> [MoltenProjectLineMatch] {
        guard !query.isEmpty else { return [] }
        let ns = content as NSString
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var results: [MoltenProjectLineMatch] = []
        var lineNumber = 0

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { substring, lineRange, _, stop in
            lineNumber += 1
            guard let line = substring else { return }
            let inLine = (line as NSString).range(of: query, options: options)
            guard inLine.location != NSNotFound else { return }
            let fileRange = NSRange(location: lineRange.location + inLine.location, length: inLine.length)
            results.append(MoltenProjectLineMatch(
                lineNumber: lineNumber,
                lineText: line.trimmingCharacters(in: .whitespaces),
                matchRangeInFile: fileRange
            ))
            if results.count >= maxMatches {
                stop.pointee = true
            }
        }
        return results
    }

    /// Reads and searches each file (decoding with the shared multi-encoding fallback). Skips files
    /// it can't read; returns only files with at least one match, in input order.
    static func search(
        query: String,
        files: [MoltenProjectFile],
        caseSensitive: Bool,
        fileManager: FileManager = .default
    ) -> [MoltenProjectSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [MoltenProjectSearchResult] = []
        for file in files.prefix(maxFiles) {
            guard let data = try? Data(contentsOf: file.url),
                  data.count <= MoltenDocument.maximumFileSize,
                  let content = try? MoltenDocument.decodeText(from: data) else {
                continue
            }
            let matches = lineMatches(in: content, query: trimmed, caseSensitive: caseSensitive)
            if !matches.isEmpty {
                results.append(MoltenProjectSearchResult(file: file, matches: matches))
            }
        }
        return results
    }
}
