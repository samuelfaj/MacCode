import Foundation

/// Finds Mac file paths a user typed into a message, so a Bot that runs in its
/// Linux VM can receive copies. Typing the path is the user's consent.
public enum MacPathReferences {
    /// Largest file copied without asking again.
    public static let maxFileBytes: Int64 = 200 * 1024 * 1024

    /// Existing regular files under `home` referenced in `text`, in order, deduplicated.
    /// Paths may contain spaces; the longest existing candidate wins. Finder names
    /// with U+202F/U+00A0 match a typed regular space.
    public static func files(
        in text: String,
        home: String,
        fileManager: FileManager = .default
    ) -> [URL] {
        let homeURL = URL(fileURLWithPath: home).standardizedFileURL
        let homePrefix = homeURL.path.hasSuffix("/") ? homeURL.path : homeURL.path + "/"
        var found: [URL] = []
        for line in text.components(separatedBy: .newlines) {
            for start in starts(in: line, homePrefix: homePrefix) {
                // Paths longer than 512 characters are not worth probing word by word.
                let tail = String(line[start...].prefix(512))
                guard let url = longestExisting(tail, home: homeURL, fileManager: fileManager),
                      url.path.hasPrefix(homePrefix),
                      !found.contains(url) else { continue }
                found.append(url)
            }
        }
        return found
    }

    private static func starts(in line: String, homePrefix: String) -> [String.Index] {
        var result: [String.Index] = []
        var index = line.startIndex
        while index < line.endIndex {
            let rest = line[index...]
            if rest.hasPrefix(homePrefix) || rest.hasPrefix("/Users/") || rest.hasPrefix("~/") {
                let boundary = index == line.startIndex
                    || " \t\"'`(<[".contains(line[line.index(before: index)])
                if boundary { result.append(index) }
            }
            index = line.index(after: index)
        }
        return result
    }

    private static func longestExisting(_ tail: String, home: URL, fileManager: FileManager) -> URL? {
        var cuts: [String.Index] = [tail.endIndex]
        var index = tail.startIndex
        while index < tail.endIndex {
            if isSpace(tail[index]) { cuts.append(index) }
            index = tail.index(after: index)
        }
        for cut in cuts.sorted(by: >) {
            var candidate = String(tail[..<cut])
            while let last = candidate.last, ".,;:!?)\"'`>]".contains(last) {
                if let url = resolve(candidate, home: home, fileManager: fileManager) { return url }
                candidate.removeLast()
            }
            if let url = resolve(candidate, home: home, fileManager: fileManager) { return url }
        }
        return nil
    }

    private static func resolve(_ raw: String, home: URL, fileManager: FileManager) -> URL? {
        guard !raw.isEmpty else { return nil }
        let path = raw.hasPrefix("~/") ? home.path + "/" + raw.dropFirst(2) : raw
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if isRegularFile(url, fileManager: fileManager) { return url }
        // Typed "1.58.25 PM.png" vs Finder's "1.58.25\u{202F}PM.png".
        let parent = url.deletingLastPathComponent()
        let wanted = normalized(url.lastPathComponent)
        guard let names = try? fileManager.contentsOfDirectory(atPath: parent.path),
              let match = names.first(where: { normalized($0) == wanted }) else { return nil }
        let matched = parent.appendingPathComponent(match)
        return isRegularFile(matched, fileManager: fileManager) ? matched : nil
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }

    private static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\u{202F}" || character == "\u{00A0}" || character == "\t"
    }

    static func normalized(_ name: String) -> String {
        String(name.map { isSpace($0) ? " " : $0 }).precomposedStringWithCanonicalMapping
    }

    /// The Mac file a Bot's file request names: an absolute path, or a quoted
    /// file name found in Desktop, Downloads or Documents. Nil when unsure.
    public static func requestedFile(in reason: String, home: String, fileManager: FileManager = .default) -> URL? {
        if let direct = files(in: reason, home: home, fileManager: fileManager).first { return direct }
        let quoted = reason.components(separatedBy: CharacterSet(charactersIn: "'\"`\u{2018}\u{2019}\u{201C}\u{201D}"))
            .enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            .filter { !$0.contains("/") && ($0 as NSString).pathExtension.count > 0 }
        let homeURL = URL(fileURLWithPath: home)
        for name in quoted {
            for folder in ["Desktop", "Downloads", "Documents"] {
                let url = homeURL.appendingPathComponent(folder).appendingPathComponent(name)
                if let match = resolve(url.path, home: homeURL, fileManager: fileManager) { return match }
            }
        }
        return nil
    }

    /// Prompt line naming where each copied file now lives in the VM.
    public static func copiedNote(_ pairs: [(mac: String, guest: String)], skipped: [String]) -> String? {
        var lines = pairs.map { "- \($0.mac) -> \($0.guest)" }
        lines += skipped.map { "- \($0) (not copied; ask with bot_request_user_action kind file if you need it)" }
        guard !lines.isEmpty else { return nil }
        return "Mac files named in the user's message were copied into this VM (use the VM path):\n" + lines.joined(separator: "\n")
    }
}
