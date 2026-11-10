import CoreModel
import AppKit
import Foundation

public enum DroppedFilePaths {
    private static let fileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        fileNamesType
    ]

    static func paths(from pasteboard: NSPasteboard) -> [String] {
        var paths: [String] = []
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] {
            paths.append(contentsOf: urls.compactMap(\.path))
        }
        for type in [NSPasteboard.PasteboardType.fileURL, .URL] {
            if let value = pasteboard.string(forType: type),
               let url = URL(string: value),
               url.isFileURL {
                paths.append(url.path)
            }
        }
        if let names = pasteboard.propertyList(forType: fileNamesType) as? [String] {
            paths.append(contentsOf: names)
        }
        return paths.reduce(into: []) { unique, path in
            if !unique.contains(path) { unique.append(path) }
        }
    }

    static func canReadFileDrop(from pasteboard: NSPasteboard) -> Bool {
        if pasteboard.availableType(from: pasteboardTypes) != nil { return true }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: options)
    }

    static func terminalInputText(for paths: [String]) -> String {
        paths.map(shellEscaped).joined(separator: " ")
    }

    public static func composerInputText(for paths: [String]) -> String {
        paths.joined(separator: " ")
    }

    public static func appending(_ insertion: String, to text: String) -> String {
        guard !insertion.isEmpty else { return text }
        guard !text.isEmpty else { return insertion }
        return text.last?.isWhitespace == true ? text + insertion : text + " " + insertion
    }

    // PERF: terminalInputText maps shellEscaped over every dropped path; share
    // the shell-metacharacter CharacterSet instead of union-allocating per path.
    private static let shellSpecialCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "'\"\\$&;()[]{}<>*?!|`"))

    private static func shellEscaped(_ path: String) -> String {
        guard path.rangeOfCharacter(from: shellSpecialCharacters) != nil else {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
final class FilePathDropScrollView: NSScrollView {
    var onFileDrop: (([String]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(DroppedFilePaths.pasteboardTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(DroppedFilePaths.pasteboardTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = DroppedFilePaths.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        onFileDrop?(paths)
        return true
    }
}
