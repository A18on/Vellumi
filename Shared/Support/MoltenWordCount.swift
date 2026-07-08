import Foundation

/// Mixed Chinese/English word counting: each CJK character counts as one word,
/// each run of latin letters/digits counts as one word. Matches how Chinese
/// writers reason about 字数 (same policy as MarkMac's status bar).
enum MoltenWordCount {
    static func count(_ text: String) -> Int {
        var cjkCount = 0
        var latinWordCount = 0
        var inLatinWord = false

        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjkCount += 1
                inLatinWord = false
            } else if isWordScalar(scalar) {
                if !inLatinWord {
                    latinWordCount += 1
                    inLatinWord = true
                }
            } else {
                inLatinWord = false
            }
        }
        return cjkCount + latinWordCount
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF,   // CJK unified + extension A
             0xF900...0xFAFF,   // compatibility ideographs
             0x3040...0x30FF,   // hiragana + katakana
             0xAC00...0xD7A3,   // hangul syllables
             0x20000...0x2FA1F: // extensions B+
            return true
        default:
            return false
        }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F:
            return true
        case 0xC0...0x24F: // latin-1 supplement + extended (café, naïve…)
            return true
        default:
            return false
        }
    }
}
