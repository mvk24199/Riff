import Foundation

/// Helpers for walking InnerTube response trees.
///
/// We deliberately don't model the full schema — Google adds fields without
/// notice and a strict Codable model breaks every time. Instead we hand-walk
/// `[String: Any]` and pluck only the fields we care about. Missing/nil
/// values are tolerated; bad items are skipped, never thrown.
enum Parsing {
    /// Walk by string keys (or numeric indices into arrays).
    static func dig(_ root: Any?, _ path: [String]) -> Any? {
        path.reduce(root) { acc, key in
            if let dict = acc as? [String: Any] { return dict[key] }
            if let arr  = acc as? [Any], let idx = Int(key), arr.indices.contains(idx) { return arr[idx] }
            return nil
        }
    }

    static func string(_ root: Any?, _ path: String...) -> String? {
        dig(root, path) as? String
    }

    /// `{ runs: [{ text: ... }] }` concatenated into a single string.
    ///
    /// YT Music structures multi-segment text as:
    ///   `[{text: "Artist"}, {text: " • "}, {text: "Album"}]`
    /// — i.e. the separators are themselves runs. Joining with a
    /// non-empty separator double-stamps them ("Artist •  •  • Album");
    /// concatenation is what callers actually want.
    ///
    /// The optional `separator` parameter exists for the rare caller
    /// that's pulling a list of distinct runs (e.g. lyrics line list
    /// joined with "\n") and needs explicit control.
    static func runs(_ root: Any?, _ path: String..., separator: String = "") -> String? {
        guard let runs = dig(root, path + ["runs"]) as? [[String: Any]] else { return nil }
        let parts = runs.compactMap { $0["text"] as? String }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    static func array(_ root: Any?, _ path: String...) -> [[String: Any]]? {
        dig(root, path) as? [[String: Any]]
    }

    /// Highest-resolution thumbnail URL from `{ thumbnails: [{ url, width, height }] }`.
    static func thumbnailURL(_ container: [String: Any]?) -> URL? {
        guard let thumbs = container?["thumbnails"] as? [[String: Any]] else { return nil }
        return thumbs.last
            .flatMap { $0["url"] as? String }
            .flatMap { URL(string: $0) }
    }

    /// First non-nil result of `transform` over a `[[String: Any]]` array.
    static func firstMatch<T>(_ items: [[String: Any]]?, _ transform: ([String: Any]) -> T?) -> T? {
        items?.lazy.compactMap(transform).first
    }
}
