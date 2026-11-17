import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import CoreModel

final class OCRPerceptionTests: XCTestCase {
    func testNeedsOCRWhenOnlyTitleBarButtonsAndUnlabelledGroups() {
        let tree: [String: Any] = [
            "role": "AXWindow",
            "title": "Canvas",
            "children": [
                ["role": "AXButton", "subrole": "AXCloseButton", "description": "close button"],
                ["role": "AXButton", "description": "minimize"],
                ["role": "AXButton", "title": "Full Screen"],
                ["role": "AXGroup", "children": [["role": "AXGroup"]]],
            ],
        ]
        XCTAssertTrue(OCRPerception.needsOCR(uiTree: tree))
    }

    func testNeedsOCRFalseWithLabelledEnabledButton() {
        let tree: [String: Any] = [
            "role": "AXWindow",
            "children": [["role": "AXGroup", "children": [["role": "AXButton", "title": "Save"]]]],
        ]
        XCTAssertFalse(OCRPerception.needsOCR(uiTree: tree))
    }

    func testNeedsOCRIgnoresDisabledControl() {
        let tree: [String: Any] = [
            "role": "AXWindow",
            "children": [["role": "AXButton", "title": "Save", "enabled": false]],
        ]
        XCTAssertTrue(OCRPerception.needsOCR(uiTree: tree))
    }

    func testRecognizeFindsTextInUpperHalfWithTopLeftOrigin() async throws {
        let width = 800
        let height = 400
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hello World", attributes: attributes))
        // Core Graphics origin is bottom-left: y=280 draws the text near the top of the image.
        context.textPosition = CGPoint(x: 40, y: 280)
        CTLineDraw(line, context)
        let image = try XCTUnwrap(context.makeImage())

        let elements = try await OCRPerception.recognize(image)
        let hello = try XCTUnwrap(elements.first { $0.text.contains("Hello") })
        XCTAssertEqual(hello.id.hasPrefix("ocr_"), true)
        XCTAssertLessThan(hello.frame.midY, Double(height) / 2)
        XCTAssertGreaterThanOrEqual(hello.frame.minY, 0)
        let json = OCRPerception.jsonObject(elements)
        XCTAssertEqual(json.count, elements.count)
        XCTAssertEqual(json.first?["id"] as? String, "ocr_1")
    }
}
