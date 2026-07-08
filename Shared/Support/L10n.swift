import Foundation

/// Thin wrapper over NSLocalizedString so call sites stay short and every
/// user-visible string goes through the en/zh-Hans catalogs.
enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
