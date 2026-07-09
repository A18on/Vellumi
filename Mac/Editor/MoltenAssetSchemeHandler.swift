import Foundation
import WebKit

/// Serves the document folder's images to the sandboxed editor surface.
/// The WebContent process can't read the document's folder, so display-time
/// image srcs are rewritten to `molten-asset://asset/<relative path>` and this
/// handler — running in the app process with the folder's security scope —
/// returns the bytes. (Same pattern as MarkMac's preview asset handler.)
final class MoltenAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "molten-asset"
    static let host = "asset"

    /// The folder of the currently loaded document; updated by the editor VC.
    var documentDirectory: URL?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let directory = documentDirectory,
              let fileURL = Self.resolvedFileURL(for: requestURL, in: directory) else {
            urlSchemeTask.didFailWithError(Self.failure)
            return
        }

        MoltenFolderAccess.shared.ensureAccess(to: directory, interactive: false)
        guard let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(Self.failure)
            return
        }

        let response = URLResponse(
            url: requestURL,
            mimeType: Self.mimeType(forPathExtension: fileURL.pathExtension),
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    /// Maps `molten-asset://asset/<relative>` to a file inside `directory`,
    /// refusing traversal outside it.
    static func resolvedFileURL(for requestURL: URL, in directory: URL) -> URL? {
        guard requestURL.scheme == scheme, requestURL.host == host else { return nil }
        let relative = requestURL.path.removingPercentEncoding ?? requestURL.path
        let trimmed = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        guard !trimmed.isEmpty else { return nil }

        let candidate = directory.appendingPathComponent(trimmed).standardizedFileURL
        let base = directory.standardizedFileURL.path
        guard candidate.path == base || candidate.path.hasPrefix(base + "/") else {
            return nil // "../../etc/passwd" style traversal
        }
        return candidate
    }

    /// Rewrites document-relative <img src> values in exported/preview HTML to
    /// the molten-asset scheme so a card/preview web view (whose page URL is
    /// inside the app bundle) can load them through this handler.
    static func rewritingImageSources(in html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(<img\\b[^>]*?\\bsrc=\")([^\"]+)(\")",
            options: [.caseInsensitive]
        ) else {
            return html
        }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        var lastEnd = 0
        for match in matches {
            let whole = match.range
            result += ns.substring(with: NSRange(location: lastEnd, length: whole.location - lastEnd))
            let prefix = ns.substring(with: match.range(at: 1))
            let src = ns.substring(with: match.range(at: 2))
            let suffix = ns.substring(with: match.range(at: 3))
            result += prefix + rewrittenSource(src) + suffix
            lastEnd = whole.location + whole.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }

    private static func rewrittenSource(_ src: String) -> String {
        let lower = src.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:")
            || lower.hasPrefix("file:") || lower.hasPrefix("\(scheme):") || src.hasPrefix("/") {
            return src
        }
        let encoded = src.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? src
        return "\(scheme)://\(host)/\(encoded)"
    }

    private static let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)

    private static func mimeType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "heic": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        case "bmp": return "image/bmp"
        default: return "application/octet-stream"
        }
    }
}
