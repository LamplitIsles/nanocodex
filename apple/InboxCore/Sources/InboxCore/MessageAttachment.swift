import Foundation
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
#endif

public struct MessageAttachment: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let mediaType: String
    public let byteCount: Int
    public let video: VideoAttachmentInfo?
    public var isVideo: Bool { video != nil }
    public var promptByteCount: Int { video?.promptByteCount ?? ((byteCount + 2) / 3) * 4 + 128 }

    public init(id: String = UUID().uuidString, name: String, mediaType: String = "image/jpeg", byteCount: Int, video: VideoAttachmentInfo? = nil) throws {
        guard Self.validID(id), !name.isEmpty, name.utf8.count <= 1024,
              !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (video == nil ? mediaType == "image/jpeg" && (1...AttachmentPreparation.maximumImageBytes).contains(byteCount)
               : ["video/mp4", "video/quicktime"].contains(mediaType) && byteCount > 0) else {
            throw AttachmentError.invalidReference
        }
        try video?.validate()
        self.id = id; self.name = name; self.mediaType = mediaType; self.byteCount = byteCount; self.video = video
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      mediaType: values.decode(String.self, forKey: .mediaType), byteCount: values.decode(Int.self, forKey: .byteCount),
                      video: values.decodeIfPresent(VideoAttachmentInfo.self, forKey: .video))
    }

    static func validID(_ id: String) -> Bool {
        UUID(uuidString: id)?.uuidString.lowercased() == id.lowercased()
    }
}

public struct PreparedAttachment: Equatable, Sendable {
    public let attachment: MessageAttachment
    public let content: [JSON]
    public init(attachment: MessageAttachment, content: [JSON]) {
        self.attachment = attachment; self.content = content
    }
}

public enum AttachmentError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedImage, sourceTooLarge, imageTooLarge, invalidReference, invalidScope, unavailable
    public var errorDescription: String? {
        switch self {
        case .unsupportedImage: return "Choose a supported still image, such as a JPEG, PNG, or HEIC photo."
        case .sourceTooLarge: return "Choose an image smaller than 25 MB."
        case .imageTooLarge: return "This image could not fit the attachment limit. Choose a smaller image."
        case .invalidReference: return "This attachment is invalid. Remove it and add it again."
        case .invalidScope: return "Sign in before attaching media."
        case .unavailable: return "This attachment is no longer available. Remove it and add it again."
        }
    }
}

public enum AttachmentPreparation {
    public static let maximumSourceBytes = 25 * 1024 * 1024
    public static let maximumImageBytes = 160 * 1024
    public static let maximumPixelDimension = 1600
    static let dataURLPrefix = "data:image/jpeg;base64,"

    public static func prepare(url: URL) throws -> PreparedAttachment {
        guard url.isFileURL else { throw AttachmentError.unsupportedImage }
        #if os(iOS) || os(macOS)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        #endif
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw AttachmentError.unsupportedImage }
        guard (values.fileSize ?? maximumSourceBytes + 1) <= maximumSourceBytes else { throw AttachmentError.sourceTooLarge }
        return try prepare(data: Data(contentsOf: url, options: .mappedIfSafe), name: url.lastPathComponent, mediaType: "image/*")
    }

    public static func prepare(data: Data, name: String, mediaType: String) throws -> PreparedAttachment {
        guard data.count <= maximumSourceBytes else { throw AttachmentError.sourceTooLarge }
        guard !data.isEmpty, mediaType.lowercased().hasPrefix("image/") else { throw AttachmentError.unsupportedImage }
        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw AttachmentError.unsupportedImage }

        for dimension in [maximumPixelDimension, 1280, 1024, 800, 640] {
            let scale = min(1, CGFloat(dimension) / CGFloat(max(thumbnail.width, thumbnail.height)))
            let width = max(1, Int(CGFloat(thumbnail.width) * scale))
            let height = max(1, Int(CGFloat(thumbnail.height) * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw AttachmentError.unsupportedImage
            }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
            context.interpolationQuality = .high
            context.draw(thumbnail, in: rect)
            guard let image = context.makeImage() else { throw AttachmentError.unsupportedImage }
            for quality in [0.82, 0.68, 0.52, 0.38] {
                let bytes = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil) else {
                    throw AttachmentError.unsupportedImage
                }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw AttachmentError.unsupportedImage }
                if bytes.length <= maximumImageBytes {
                    let jpeg = bytes as Data
                    let attachment = try MessageAttachment(name: name, byteCount: jpeg.count)
                    return PreparedAttachment(attachment: attachment, content: [imageContent(jpeg)])
                }
            }
        }
        throw AttachmentError.imageTooLarge
        #else
        throw AttachmentError.unsupportedImage
        #endif
    }

    static func imageContent(_ data: Data) -> JSON {
        .object(["type": .string("image"), "image_url": .string(dataURLPrefix + data.base64EncodedString()), "detail": .string("high")])
    }

    static func validateJPEG(_ data: Data, attachment: MessageAttachment) throws {
        guard data.count == attachment.byteCount, data.count <= maximumImageBytes else { throw AttachmentError.invalidReference }
        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maximumPixelDimension).contains(width), (1...maximumPixelDimension).contains(height) else {
            throw AttachmentError.invalidReference
        }
        #else
        throw AttachmentError.unsupportedImage
        #endif
    }
}

/// Like a local image prompt, retain a small file and create the data URL only
/// when sending. Drafts and queued messages store only MessageAttachment metadata.
public struct AttachmentStore: Sendable {
    let directory: URL

    public init(scope: String) throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try self.init(scope: scope, rootDirectory: support.appendingPathComponent("InboxAttachments", isDirectory: true))
    }

    init(scope: String, rootDirectory: URL) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !scope.isEmpty, scope.utf8.count <= 128, !scope.hasPrefix("."), !scope.contains(".."),
              scope.unicodeScalars.allSatisfy(allowed.contains) else { throw AttachmentError.invalidScope }
        directory = rootDirectory.appendingPathComponent(scope, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AttachmentError.invalidScope }
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    public func save(_ prepared: PreparedAttachment) throws {
        let content = prepared.content
        guard content.count == 1, content[0]["type"].string == "image", content[0]["detail"].string == "high",
              content[0]["image_url"].string.hasPrefix(AttachmentPreparation.dataURLPrefix),
              let bytes = Data(base64Encoded: String(content[0]["image_url"].string.dropFirst(AttachmentPreparation.dataURLPrefix.count))) else {
            throw AttachmentError.invalidReference
        }
        try AttachmentPreparation.validateJPEG(bytes, attachment: prepared.attachment)
        let destination = try fileURL(for: prepared.attachment.id)
        #if os(iOS)
        try bytes.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try bytes.write(to: destination, options: .atomic)
        #endif
    }

    public func content(for attachments: [MessageAttachment]) throws -> [JSON] {
        try attachments.flatMap { attachment -> [JSON] in
            if attachment.isVideo { return try videoContent(for: attachment) }
            let location = try url(for: attachment)
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize == attachment.byteCount else { throw AttachmentError.invalidReference }
            let bytes = try Data(contentsOf: location, options: .mappedIfSafe)
            try AttachmentPreparation.validateJPEG(bytes, attachment: attachment)
            return [AttachmentPreparation.imageContent(bytes)]
        }
    }

    public func url(for attachment: MessageAttachment) throws -> URL {
        let location = try fileURL(for: attachment.id, extension: attachment.isVideo ? attachment.mediaType == "video/mp4" ? "mp4" : "mov" : "jpg")
        guard FileManager.default.fileExists(atPath: location.path) else { throw AttachmentError.unavailable }
        return location
    }

    public func remove(_ attachment: MessageAttachment) throws {
        for ext in attachment.isVideo ? ["jpg", "mp4", "mov", "json"] : ["jpg"] {
            let location = try fileURL(for: attachment.id, extension: ext)
            if FileManager.default.fileExists(atPath: location.path) { try FileManager.default.removeItem(at: location) }
        }
    }

    public func prune(keeping ids: Set<String>) throws {
        guard ids.allSatisfy(MessageAttachment.validID) else { throw AttachmentError.invalidReference }
        let retained = Set(ids.map { $0.lowercased() })
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let id = file.deletingPathExtension().lastPathComponent
            guard ["jpg", "mp4", "mov", "json"].contains(file.pathExtension), MessageAttachment.validID(id), !retained.contains(id.lowercased()) else { continue }
            try FileManager.default.removeItem(at: try fileURL(for: id, extension: file.pathExtension))
        }
    }

    func fileURL(for id: String, extension ext: String = "jpg") throws -> URL {
        guard MessageAttachment.validID(id), ["jpg", "mp4", "mov", "json"].contains(ext) else { throw AttachmentError.invalidReference }
        let location = directory.appendingPathComponent(id.lowercased() + "." + ext, isDirectory: false)
        if FileManager.default.fileExists(atPath: location.path),
           try location.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]).isRegularFile != true {
            throw AttachmentError.invalidReference
        }
        if (try? location.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw AttachmentError.invalidReference }
        return location
    }
}
