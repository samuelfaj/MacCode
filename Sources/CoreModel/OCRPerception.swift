import CoreGraphics
import Foundation
import Vision

public struct OCRElement: Equatable, Sendable {
    public let id: String
    public let text: String
    public let confidence: Double
    /// Image pixel coordinates, top-left origin.
    public let frame: CGRect
}

public enum OCRPerception {
    public enum Level: Sendable {
        case fast
        case accurate
    }

    static let maxElements = 300

    private static let controlRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXTextField",
        "AXTextArea", "AXComboBox", "AXSlider", "AXLink", "AXCell", "AXRow",
    ]
    private static let titleBarSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
    ]
    private static let titleBarDescriptions: Set<String> = ["close", "minimize", "zoom", "full screen"]

    /// True when the tree has no enabled, labelled control of the app itself.
    public static func needsOCR(uiTree: [String: Any]) -> Bool {
        !hasLabelledControl(uiTree)
    }

    public static func recognize(
        _ image: CGImage,
        level: Level = .accurate
    ) async throws -> [OCRElement] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let width = Double(image.width)
        let height = Double(image.height)
        var found: [(text: String, confidence: Double, frame: CGRect)] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = observation.boundingBox
            let frame = CGRect(
                x: box.minX * width,
                y: (1 - box.maxY) * height,
                width: box.width * width,
                height: box.height * height
            )
            found.append((text, Double(candidate.confidence), frame))
        }
        found.sort {
            $0.frame.minY != $1.frame.minY ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        }
        return found.prefix(maxElements).enumerated().map { index, item in
            OCRElement(id: "ocr_\(index + 1)", text: item.text, confidence: item.confidence, frame: item.frame)
        }
    }

    public static func jsonObject(_ elements: [OCRElement]) -> [[String: Any]] {
        elements.map { element in
            [
                "id": element.id,
                "text": element.text,
                "confidence": element.confidence,
                "frame": [
                    "x": Double(element.frame.minX),
                    "y": Double(element.frame.minY),
                    "width": Double(element.frame.width),
                    "height": Double(element.frame.height),
                ],
            ]
        }
    }

    private static func hasLabelledControl(_ node: [String: Any]) -> Bool {
        if isLabelledEnabledControl(node) { return true }
        let children = node["children"] as? [[String: Any]] ?? []
        return children.contains(where: hasLabelledControl)
    }

    private static func isLabelledEnabledControl(_ node: [String: Any]) -> Bool {
        guard let role = node["role"] as? String, controlRoles.contains(role) else { return false }
        if (node["enabled"] as? Bool) == false { return false }
        if let subrole = node["subrole"] as? String, titleBarSubroles.contains(subrole) { return false }
        let title = trimmed(node["title"])
        let description = trimmed(node["description"])
        if role == "AXButton",
           titleBarDescriptions.contains(description.lowercased()) || titleBarDescriptions.contains(title.lowercased()) {
            return false
        }
        return !title.isEmpty || !description.isEmpty
    }

    private static func trimmed(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
