import AppKit
import UniformTypeIdentifiers

/// An image attached to a user message. Held in memory only; written to the
/// request's owner-only workspace when a provider needs a file path.
struct ImageAttachment: Identifiable, Codable, Equatable {
    static let perMessage = 5
    /// Images resent with each request, newest last, so follow-ups can refer back.
    static let perRequest = 5
    static let maxDimension: CGFloat = 2000
    /// Claude rejects images above 5 MB; leave room for base64 growth.
    static let maxBytes = 3_500_000

    let id: UUID
    let data: Data
    let mediaType: String
    let pixelWidth: Int
    let pixelHeight: Int

    var fileExtension: String { mediaType == "image/jpeg" ? "jpg" : "png" }
    var image: NSImage? { NSImage(data: data) }

    /// Downscales to `maxDimension` on the long edge and encodes as PNG, falling
    /// back to JPEG when a photo is still too large.
    static func make(from source: NSImage) -> ImageAttachment? {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let longest = CGFloat(max(cg.width, cg.height))
        let scale = min(1, maxDimension / max(longest, 1))
        let width = max(1, Int((CGFloat(cg.width) * scale).rounded())), height = max(1, Int((CGFloat(cg.height) * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        if let png = bitmap.representation(using: .png, properties: [:]), png.count <= maxBytes {
            return ImageAttachment(id: UUID(), data: png, mediaType: "image/png", pixelWidth: width, pixelHeight: height)
        }
        for quality in [0.85, 0.7, 0.5] {
            if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= maxBytes {
                return ImageAttachment(id: UUID(), data: jpeg, mediaType: "image/jpeg", pixelWidth: width, pixelHeight: height)
            }
        }
        return nil
    }

    /// Images on a pasteboard or drag: image files first (Finder copies also carry
    /// the file's icon, which must not be attached instead), then raw image data.
    static func read(from pasteboard: NSPasteboard) -> [ImageAttachment] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true,
                                                             .urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls.compactMap { NSImage(contentsOf: $0) }.compactMap(make(from:))
        }
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return [] }
        guard let types = pasteboard.types, types.contains(where: { NSImage.imageTypes.contains($0.rawValue) }) else { return [] }
        return (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []).compactMap(make(from:))
    }

    /// A cheap check for drag feedback, without decoding anything.
    static func available(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true,
                                 .urlReadingContentsConformToTypes: [UTType.image.identifier]])
            || (!pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                && pasteboard.canReadObject(forClasses: [NSImage.self]))
    }

    /// The images sent with a request: the most recent `perRequest` across the
    /// conversation's user messages.
    static func recent(in messages: [ChatMessage]) -> [ImageAttachment] {
        Array(messages.filter { $0.role == "user" }.flatMap(\.images).suffix(perRequest))
    }

    /// Claude's stream-json input: one user message with the prompt and images.
    static func claudeInput(prompt: String, images: [ImageAttachment]) throws -> Data {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        content += images.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.data.base64EncodedString()]]
        }
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var data = try JSONSerialization.data(withJSONObject: line)
        data.append(0x0A)
        return data
    }

    /// My setup's images as files, so its session can hand one on (a Herdr agent, a task, a tool):
    /// Claude otherwise gets them only inside its prompt. Kept past the request, since an agent it
    /// starts reads them later, and dropped after `storeLifetime`.
    static var standardStore: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("QuickAsk/Images", isDirectory: true)
    }
    static let storeLifetime: TimeInterval = 7 * 24 * 3600

    /// Saves each image once, named by its id (owner-only), and returns their paths in order.
    static func store(_ images: [ImageAttachment], in directory: URL, now: Date = Date()) throws -> [String] {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for url in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > storeLifetime { try? manager.removeItem(at: url) }
        }
        return try images.map { image in
            let url = directory.appendingPathComponent("\(image.id.uuidString).\(image.fileExtension)")
            if !manager.fileExists(atPath: url.path) {
                try image.data.write(to: url, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            return url.path
        }
    }

    /// Writes images into the request workspace (owner-only) for Codex's `--image`.
    static func write(_ images: [ImageAttachment], to directory: URL) throws -> [String] {
        try images.enumerated().map { index, image in
            let url = directory.appendingPathComponent("image-\(index + 1).\(image.fileExtension)")
            try image.data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url.path
        }
    }
}
