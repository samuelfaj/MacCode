import Foundation

extension FilesViewModel {
    /// "CRLF" when the first line break is `\r\n`, else "LF". vscode: the status bar shows the document EOL.
    nonisolated static func detectLineEnding(_ text: String) -> String {
        var previousWasCR = false
        for byte in text.utf8 {
            if byte == 0x0A { return previousWasCR ? "CRLF" : "LF" }
            previousWasCR = byte == 0x0D
        }
        return "LF"
    }

    /// Status-bar label for the session encoding id (`utf-8`, `utf-16le`, `utf-16be`).
    var encodingLabel: String {
        switch encoding.lowercased() {
        case "utf-16le": return "UTF-16 LE"
        case "utf-16be": return "UTF-16 BE"
        case "utf-8": return "UTF-8"
        default: return encoding.uppercased()
        }
    }
}
