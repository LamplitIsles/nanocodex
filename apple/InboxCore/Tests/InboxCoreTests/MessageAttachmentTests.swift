import XCTest
import ImageIO
import CoreGraphics
@testable import InboxCore

final class MessageAttachmentTests: XCTestCase {
    func testImagePreparationOrientsResizesAndEmitsImagePrompt() throws {
        let prepared = try AttachmentPreparation.prepare(data: png(width: 2200, height: 1100, orientation: 6), name: "Camera.png", mediaType: "image/png")
        XCTAssertEqual(prepared.attachment.mediaType, "image/jpeg")
        XCTAssertLessThanOrEqual(prepared.attachment.byteCount, 160 * 1024)
        XCTAssertNotNil(UUID(uuidString: prepared.attachment.id))
        XCTAssertEqual(prepared.content.count, 1)
        XCTAssertEqual(prepared.content[0]["type"].string, "image")
        XCTAssertEqual(prepared.content[0]["detail"].string, "high")
        let bytes = try XCTUnwrap(Data(base64Encoded: String(prepared.content[0]["image_url"].string.dropFirst("data:image/jpeg;base64,".count))))
        XCTAssertEqual(bytes.count, prepared.attachment.byteCount)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 800)
        XCTAssertEqual(image.height, 1600, "Apply the source orientation before storing an upright JPEG")
    }

    func testUnsupportedSourcesAndUnsafeReferencesAreRejected() throws {
        XCTAssertThrowsError(try AttachmentPreparation.prepare(data: Data("not an image".utf8), name: "file.txt", mediaType: "text/plain"))
        XCTAssertThrowsError(try AttachmentPreparation.prepare(data: Data([0, 1, 2]), name: "bad.jpg", mediaType: "image/jpeg"))
        XCTAssertThrowsError(try AttachmentPreparation.prepare(data: Data(repeating: 0, count: AttachmentPreparation.maximumSourceBytes + 1), name: "huge.jpg", mediaType: "image/jpeg")) {
            XCTAssertEqual($0 as? AttachmentError, .sourceTooLarge)
        }
        for id in ["../outside", "", "not-a-uuid", "123456781234123412341234567890ab"] {
            XCTAssertThrowsError(try MessageAttachment(id: id, name: "photo.jpg", byteCount: 1))
        }
        XCTAssertThrowsError(try MessageAttachment(name: "../photo.jpg", byteCount: 1))
        XCTAssertThrowsError(try MessageAttachment(name: "photo.jpg", byteCount: AttachmentPreparation.maximumImageBytes + 1))
        let forged = Data(#"{"id":"../outside","name":"photo.jpg","mediaType":"image/jpeg","byteCount":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MessageAttachment.self, from: forged))
    }

    func testStorePersistsOnlyJPEGAndKeepsAccountsIsolated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentStore(scope: "account-one", rootDirectory: root)
        let other = try AttachmentStore(scope: "account-two", rootDirectory: root)
        let prepared = try AttachmentPreparation.prepare(data: png(), name: "photo.png", mediaType: "image/png")
        try store.save(prepared)
        let url = try store.url(for: prepared.attachment)
        XCTAssertEqual(url.lastPathComponent, prepared.attachment.id.lowercased() + ".jpg")
        XCTAssertEqual(try Data(contentsOf: url).count, prepared.attachment.byteCount)
        let restored = try AttachmentStore(scope: "account-one", rootDirectory: root)
        XCTAssertEqual(try restored.content(for: [prepared.attachment]), prepared.content)
        XCTAssertThrowsError(try other.content(for: [prepared.attachment]))
        let preserved = url.deletingLastPathComponent().appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: preserved)
        try store.prune(keeping: [prepared.attachment.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try store.prune(keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        try store.save(prepared)
        try store.remove(prepared.attachment)
        try store.remove(prepared.attachment)
        XCTAssertThrowsError(try store.content(for: [prepared.attachment]))
        for scope in ["", "../account-two", "/tmp", "account/one", "account\\one"] {
            XCTAssertThrowsError(try AttachmentStore(scope: scope, rootDirectory: root))
        }
    }

    func testStoreRejectsCorruptBytesAndLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentStore(scope: "account", rootDirectory: root)
        let prepared = try AttachmentPreparation.prepare(data: png(), name: "photo.png", mediaType: "image/png")
        try store.save(prepared)
        let url = try store.url(for: prepared.attachment)
        try Data(repeating: 0, count: prepared.attachment.byteCount).write(to: url)
        XCTAssertThrowsError(try store.content(for: [prepared.attachment]))
        XCTAssertThrowsError(try store.save(PreparedAttachment(attachment: prepared.attachment, content: [.string("not an image prompt")])))
        try FileManager.default.removeItem(at: url)
        let outside = root.appendingPathComponent("outside.jpg")
        try Data("preserve".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        XCTAssertThrowsError(try store.content(for: [prepared.attachment]))
        XCTAssertThrowsError(try store.save(prepared))
        XCTAssertThrowsError(try store.remove(prepared.attachment))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "preserve")
    }

    private func png(width: Int = 48, height: Int = 32, orientation: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
