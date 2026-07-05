import AppKit
import Foundation

enum ImageMessagingError: LocalizedError {
    case unreadableImage(String)
    case unsupportedImage(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let path):
            "Cannot read image: \(path)"
        case .unsupportedImage(let path):
            "Unsupported image format: \(path)"
        }
    }
}

struct MessageImageReference: Identifiable, Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var filePath: String?
    var data: Data?
    var mimeType: String
    var displayName: String
    var size: Int64
    var sourceDescription: String?

    init(
        id: String = UUID().uuidString,
        filePath: String? = nil,
        data: Data? = nil,
        mimeType: String,
        displayName: String,
        size: Int64 = 0,
        sourceDescription: String? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.data = data
        self.mimeType = mimeType
        self.displayName = displayName
        self.size = size
        self.sourceDescription = sourceDescription
    }

    var imageData: Data? {
        if let data {
            return data
        }
        guard let filePath else {
            return nil
        }
        return try? Data(contentsOf: URL(fileURLWithPath: filePath))
    }

    var nsImage: NSImage? {
        imageData.flatMap(NSImage.init(data:))
    }

    var pixelSize: CGSize? {
        guard let image = nsImage else {
            return nil
        }
        if
            let representation = image.representations.max(by: {
                ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
            }), representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        guard image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        return image.size
    }

    var aspectRatio: CGFloat? {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return nil
        }
        return pixelSize.width / pixelSize.height
    }

    func claudeImageBlock() throws -> [String: Any] {
        guard let imageData else {
            throw ImageMessagingError.unreadableImage(filePath ?? displayName)
        }
        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": mimeType,
                "data": imageData.base64EncodedString()
            ]
        ]
    }

    static func fromAttachment(_ attachment: AttachmentChip) throws -> MessageImageReference {
        let url = URL(fileURLWithPath: attachment.path)
        let ext = url.pathExtension.lowercased()
        let rawData = try Data(contentsOf: url)
        if let mime = Self.nativeClaudeMimeType(forExtension: ext) {
            return MessageImageReference(
                filePath: url.path,
                data: rawData,
                mimeType: mime,
                displayName: attachment.name,
                size: attachment.size,
                sourceDescription: attachment.path
            )
        }
        guard
            let image = NSImage(data: rawData),
            let png = Self.pngData(from: image)
        else {
            throw ImageMessagingError.unsupportedImage(attachment.path)
        }
        return MessageImageReference(
            filePath: url.path,
            data: png,
            mimeType: "image/png",
            displayName: attachment.name,
            size: Int64(png.count),
            sourceDescription: attachment.path
        )
    }

    static func fromContentBlock(_ block: [String: Any]) -> MessageImageReference? {
        guard block["type"] as? String == "image" else {
            return nil
        }
        if
            let source = block["source"] as? [String: Any],
            let base64 = source["data"] as? String,
            let data = Data(base64Encoded: base64) {
            let mime = source["media_type"] as? String ?? source["mediaType"] as? String ?? "image/png"
            return MessageImageReference(
                data: data,
                mimeType: mime,
                displayName: "Image",
                size: Int64(data.count),
                sourceDescription: "base64"
            )
        }
        if
            let source = block["source"] as? [String: Any],
            let path = source["path"] as? String ?? source["file_path"] as? String ?? source["filePath"] as? String {
            return reference(fromSource: path)
        }
        if let source = block["source"] as? String {
            return reference(fromSource: source)
        }
        return nil
    }

    static func reference(fromSource source: String) -> MessageImageReference? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let path: String
        if trimmed.lowercased().hasPrefix("file://"), let url = URL(string: trimmed) {
            path = url.path
        } else {
            path = trimmed
        }
        guard isImagePath(path) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return MessageImageReference(
            filePath: url.path,
            data: nil,
            mimeType: nativeClaudeMimeType(forExtension: url.pathExtension.lowercased()) ?? "image/png",
            displayName: url.lastPathComponent.isEmpty ? "Image" : url.lastPathComponent,
            size: size,
            sourceDescription: source
        )
    }

    static func isImagePath(_ path: String) -> Bool {
        supportedImageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"
    ]

    private static func nativeClaudeMimeType(forExtension ext: String) -> String? {
        switch ext {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: nil
        }
    }

    static func pngData(from image: NSImage) -> Data? {
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

struct ClaudeUserMessageContent: Equatable, Sendable {
    var text: String = ""
    var images: [MessageImageReference] = []

    static let empty = ClaudeUserMessageContent()

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
    }

    func jsonContent() throws -> Any {
        guard !images.isEmpty else {
            return text
        }
        var blocks: [[String: Any]] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(["type": "text", "text": trimmed])
        }
        for image in images {
            blocks.append(try image.claudeImageBlock())
        }
        return blocks
    }
}

func composerUserMessageContent(_ text: String, attachments: [AttachmentChip]) throws -> ClaudeUserMessageContent {
    let imageAttachments = attachments.filter(\.isImage)
    let fileAttachments = attachments.filter { !$0.isImage }
    let payloadText = composerPayloadText(text, attachments: fileAttachments)
    let images = try imageAttachments.map(MessageImageReference.fromAttachment)
    return ClaudeUserMessageContent(text: payloadText, images: images)
}

extension ChatMessage {
    var imageAttachments: [AttachmentChip] {
        attachments.filter(\.isImage)
    }

    var nonImageAttachments: [AttachmentChip] {
        attachments.filter { !$0.isImage }
    }

    var displayImages: [MessageImageReference] {
        if !images.isEmpty {
            return deduplicatedImages(images)
        }
        return deduplicatedImages(imageReferences(from: imageAttachments))
    }

    var transcriptPreview: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let count = displayImages.count
        if count == 1 {
            return "[Image]"
        }
        if count > 1 {
            return "[\(count) images]"
        }
        return ""
    }
}

func imageReferences(from attachments: [AttachmentChip]) -> [MessageImageReference] {
    attachments.compactMap { attachment in
        guard attachment.isImage else {
            return nil
        }
        return try? MessageImageReference.fromAttachment(attachment)
    }
}

func cleanedTextAndInlineImages(from rawText: String) -> (text: String, images: [MessageImageReference]) {
    var text = rawText
    var images: [MessageImageReference] = []
    let pattern = #"\[Image:\s*source:\s*([^\]]+)\]"#
    if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
        let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        for match in matches.reversed() {
            if
                match.numberOfRanges >= 2,
                let sourceRange = Range(match.range(at: 1), in: text),
                let fullRange = Range(match.range(at: 0), in: text) {
                let source = String(text[sourceRange])
                if let image = MessageImageReference.reference(fromSource: source) {
                    images.insert(image, at: 0)
                    text.removeSubrange(fullRange)
                }
            }
        }
    }

    let lines = text.components(separatedBy: .newlines)
    var output: [String] = []
    var index = 0
    while index < lines.count {
        let line = lines[index]
        if line.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Attached files:") == .orderedSame {
            index += 1
            var remainingAttachedLines: [String] = []
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty else {
                    break
                }
                if let image = MessageImageReference.reference(fromSource: candidate) {
                    images.append(image)
                } else {
                    remainingAttachedLines.append(lines[index])
                }
                index += 1
            }
            if !remainingAttachedLines.isEmpty {
                output.append("Attached files:")
                output.append(contentsOf: remainingAttachedLines)
            }
            continue
        }
        output.append(line)
        index += 1
    }
    let withoutAttachmentMarkers = output.joined(separator: "\n")
    let withoutImagePlaceholders = removeClaudeImagePlaceholders(from: withoutAttachmentMarkers)
    return (collapseExcessBlankLines(withoutImagePlaceholders).trimmingCharacters(in: .whitespacesAndNewlines), deduplicatedImages(images))
}

struct ClaudeControlTranscriptEvent: Equatable, Sendable {
    enum Kind: String, Sendable {
        case command
        case interrupted
    }

    var kind: Kind
    var title: String
    var body: String
    var preview: String
}

func claudeControlTranscriptEvent(from value: Any?) -> ClaudeControlTranscriptEvent? {
    let raw = flattenedTextContent(from: value)
    let text = removeZeroWidthCharacters(raw)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        return nil
    }

    if let command = claudeCommandEvent(from: text) {
        return command
    }
    if let interruption = claudeInterruptionEvent(from: text) {
        return interruption
    }
    return nil
}

private func claudeCommandEvent(from text: String) -> ClaudeControlTranscriptEvent? {
    guard
        text.hasPrefix("<command-name>"),
        let rawCommand = text.betweenXMLLikeTags("command-name")?.trimmingCharacters(in: .whitespacesAndNewlines),
        !rawCommand.isEmpty
    else {
        return nil
    }
    let command = rawCommand.hasPrefix("/") ? rawCommand : "/" + rawCommand
    let args = text.betweenXMLLikeTags("command-args")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let body = args.isEmpty ? "`\(command)`" : "`\(command)` \(args)"
    return ClaudeControlTranscriptEvent(
        kind: .command,
        title: "Claude Code Command",
        body: body,
        preview: command
    )
}

private func claudeInterruptionEvent(from text: String) -> ClaudeControlTranscriptEvent? {
    let normalized = text
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    switch normalized {
    case "[request interrupted by user]":
        return ClaudeControlTranscriptEvent(
            kind: .interrupted,
            title: "Interrupted",
            body: "User interrupted the request.",
            preview: "Interrupted"
        )
    case "[request interrupted by user for tool use]":
        return ClaudeControlTranscriptEvent(
            kind: .interrupted,
            title: "Interrupted",
            body: "User interrupted during tool use.",
            preview: "Interrupted"
        )
    default:
        return nil
    }
}

private func flattenedTextContent(from value: Any?) -> String {
    if let text = value as? String {
        return text
    }
    if let block = value as? [String: Any] {
        let type = block["type"] as? String ?? ""
        if type == "text", let text = block["text"] as? String {
            return text
        }
        if let nested = block["content"] {
            return flattenedTextContent(from: nested)
        }
        return ""
    }
    if let blocks = value as? [Any] {
        return blocks.map(flattenedTextContent).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    return ""
}

private func removeZeroWidthCharacters(_ text: String) -> String {
    let zeroWidthCharacters = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}")
    return String(text.unicodeScalars.filter { !zeroWidthCharacters.contains($0) })
}

private extension String {
    func betweenXMLLikeTags(_ tag: String) -> String? {
        guard
            let openRange = range(of: "<\(tag)>"),
            let closeRange = range(of: "</\(tag)>", range: openRange.upperBound ..< endIndex)
        else {
            return nil
        }
        return String(self[openRange.upperBound ..< closeRange.lowerBound])
    }
}

private func removeClaudeImagePlaceholders(from rawText: String) -> String {
    let zeroWidthCharacters = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}")
    let scalarFiltered = String(rawText.unicodeScalars.filter { !zeroWidthCharacters.contains($0) })
    guard let regex = try? NSRegularExpression(pattern: #"\[\s*(?:Image|图片)\s*#?\s*\d+\s*\]"#, options: [.caseInsensitive]) else {
        return scalarFiltered
    }
    let nsRange = NSRange(scalarFiltered.startIndex ..< scalarFiltered.endIndex, in: scalarFiltered)
    return regex.stringByReplacingMatches(in: scalarFiltered, options: [], range: nsRange, withTemplate: "")
}

func deduplicatedImages(_ images: [MessageImageReference]) -> [MessageImageReference] {
    var seen = Set<String>()
    var result: [MessageImageReference] = []
    for image in images {
        let key: String
        if let data = image.data {
            key = "data:\(data.count):\(data.prefix(64).base64EncodedString())"
        } else if let filePath = image.filePath {
            key = "file:" + URL(fileURLWithPath: filePath).standardizedFileURL.path
        } else if let description = image.sourceDescription, !description.isEmpty, description != "base64" {
            key = "source:" + description
        } else {
            key = image.id
        }
        guard seen.insert(key).inserted else {
            continue
        }
        result.append(image)
    }
    return result
}

private func collapseExcessBlankLines(_ text: String) -> String {
    let lines = text.components(separatedBy: .newlines)
    var output: [String] = []
    var blankCount = 0
    for line in lines {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blankCount += 1
            if blankCount <= 2 {
                output.append(line)
            }
        } else {
            blankCount = 0
            output.append(line)
        }
    }
    return output.joined(separator: "\n")
}
