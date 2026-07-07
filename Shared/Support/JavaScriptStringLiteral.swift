import Foundation

// Borrowed from MarkMac (MIT, same author): serializes a Swift string as a
// JSON string literal, which is also a valid JavaScript string literal —
// the safe way to inject document content into evaluateJavaScript.
extension String {
    var javaScriptStringLiteral: String {
        guard let data = try? JSONSerialization.data(withJSONObject: [self], options: []),
              let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.first == "[",
              arrayLiteral.last == "]" else {
            return "\"\""
        }

        return String(arrayLiteral.dropFirst().dropLast())
    }
}
