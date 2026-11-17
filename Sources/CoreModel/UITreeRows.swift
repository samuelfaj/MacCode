import Foundation

/// The accessibility tree as one short row per element. The nested JSON of a browser window runs
/// to tens of thousands of characters and pushes everything else out of a model's context.
enum UITreeRows {
    static let defaultMaxElements = 250
    static let maximumElements = NativeElementID.maximumNodes

    /// Layout wrappers that say nothing by themselves; their children are shown in their place.
    private static let wrappers: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXUnknown"]
    private static let quietActions: Set<String> = ["AXShowMenu", "AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI", "AXRaise"]

    private struct Node {
        let id: String
        let role: String
        let fields: [String: String]
        let actions: [String]
        let children: [Node]
        let truncated: Bool

        init(_ object: [String: Any]) {
            id = object["id"] as? String ?? ""
            role = object["role"] as? String ?? ""
            var fields: [String: String] = [:]
            for key in ["title", "description", "value", "identifier", "subrole"] {
                if let text = object[key] as? String, !text.isEmpty { fields[key] = text }
            }
            self.fields = fields
            actions = (object["actions"] as? [String] ?? []).filter { !UITreeRows.quietActions.contains($0) }
            children = (object["children"] as? [[String: Any]] ?? []).map(Node.init)
            truncated = object["truncated"] as? Bool == true
        }

        var isWrapper: Bool {
            UITreeRows.wrappers.contains(role) && ["title", "description", "value", "identifier"].allSatisfy { fields[$0] == nil }
        }

        func matches(_ needles: [String]) -> Bool {
            let haystack = ([role] + ["title", "description", "value", "identifier"].compactMap { fields[$0] }).joined(separator: "\n").lowercased()
            return needles.contains { haystack.contains($0) }
        }
    }

    /// `query` is a case-insensitive substring, with `a|b` for alternatives. Matching rows keep
    /// their ancestors and their ids. Returns nil when `tree` is not the serialized AX tree.
    static func render(tree: String, maxElements: Int = defaultMaxElements, query: String? = nil) -> String? {
        guard let data = tree.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["id"] != nil else { return nil }
        let needles = (query ?? "").lowercased().split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let limit = min(max(maxElements, 1), maximumElements)
        var rows: [String] = []
        var hidden = 0
        var cut = false

        func kept(_ node: Node) -> Bool {
            needles.isEmpty || node.matches(needles) || node.children.contains(where: kept)
        }
        func quoted(_ text: String) -> String {
            "\"" + String(text.prefix(80)).replacingOccurrences(of: "\n", with: " ") + (text.count > 80 ? "…" : "") + "\""
        }
        func visit(_ node: Node, depth: Int, parent: Node?) {
            if node.truncated { cut = true; return }
            guard kept(node) else { return }
            // A text row that only repeats its parent's label adds length and nothing else.
            let label = node.fields["value"] ?? node.fields["title"]
            let echo = node.role == "AXStaticText" && node.children.isEmpty && label != nil
                && [parent?.fields["title"], parent?.fields["description"]].contains(label)
            if echo { return }
            var next = depth
            if !node.isWrapper || parent == nil {
                next += 1
                if rows.count < limit {
                    var row = String(repeating: "  ", count: depth) + "- [\(node.id)] \(node.role)"
                    if let title = node.fields["title"] { row += " " + quoted(title) }
                    if let description = node.fields["description"], description != node.fields["title"] { row += " (" + String(description.prefix(80)) + ")" }
                    if let value = node.fields["value"], value != node.fields["title"] { row += " = " + quoted(value) }
                    if let identifier = node.fields["identifier"] { row += " #" + String(identifier.prefix(40)) }
                    if !node.actions.isEmpty { row += " [" + node.actions.map { $0.replacingOccurrences(of: "AX", with: "") }.joined(separator: ",") + "]" }
                    rows.append(row)
                } else {
                    hidden += 1
                }
            }
            for child in node.children { visit(child, depth: next, parent: node) }
        }
        visit(Node(object), depth: 0, parent: nil)

        var notes: [String] = []
        if hidden > 0 { notes.append("\(hidden) more element(s) not shown: pass query to narrow, or a larger max_elements") }
        if cut { notes.append("the window has more than \(NativeElementID.maximumNodes) elements; the rest were not read") }
        if rows.isEmpty, !needles.isEmpty { notes.append("no element matches the query") }
        return (rows + notes.map { "… " + $0 }).joined(separator: "\n")
    }

    /// Replaces the JSON after `ui_tree: ` in a get_ui_tree result, leaving the observation line
    /// before it and the `ocr:` line after it as they are.
    static func rewrite(result text: String, maxElements: Int, query: String?) -> String {
        guard let start = text.range(of: "\nui_tree: ") else { return text }
        let end = text.range(of: "\nocr: ", range: start.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
        guard let rows = render(tree: String(text[start.upperBound..<end]), maxElements: maxElements, query: query) else { return text }
        return String(text[..<start.lowerBound]) + "\nui_tree:\n" + rows + String(text[end...])
    }
}
