import Foundation

// From MarkMac (MIT, same author): serializes a Swift string as a JSON string
// literal, which is also a valid JavaScript string literal — the safe way to
// inject content into evaluateJavaScript when callAsyncJavaScript's argument
// marshalling isn't available (e.g. the card renderer's string-building APIs).
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
