import Foundation

/// An image reference inside a note's Markdown: `![alt](attachment:<uuid>)`.
public struct AttachmentReference: Equatable, Sendable {
    public var range: NSRange
    public var id: UUID
    public var alt: String

    static let pattern = try! NSRegularExpression(
        pattern: #"!\[([^\]\n]*)\]\(attachment:([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)"#
    )

    public static func token(id: UUID, alt: String = "image") -> String {
        let safeAlt = alt
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        return "![\(safeAlt)](attachment:\(id.uuidString))"
    }

    /// Every image reference in `text`, in order.
    public static func findAll(in text: String) -> [AttachmentReference] {
        let string = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap { match in
            guard let id = UUID(uuidString: string.substring(with: match.range(at: 2))) else { return nil }
            return AttachmentReference(range: match.range, id: id, alt: string.substring(with: match.range(at: 1)))
        }
    }
}

public enum ImageType {
    /// The image formats notes accept.
    public static let supportedMimeTypes = ["image/png", "image/jpeg", "image/heic"]

    /// Largest image accepted, in bytes.
    public static let maximumByteCount = 50 * 1024 * 1024

    public static func mimeType(forPathExtension pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic", "heif": return "image/heic"
        default: return nil
        }
    }

    public static func pathExtension(forMimeType mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/heic", "image/heif": return "heic"
        default: return "bin"
        }
    }

    /// Identifies PNG, JPEG and HEIC from their leading bytes.
    public static func sniffMimeType(_ data: Data) -> String? {
        let bytes = Array(data.prefix(12))
        if bytes.count >= 8, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return "image/png"
        }
        if bytes.count >= 3, Array(bytes[0..<3]) == [0xFF, 0xD8, 0xFF] {
            return "image/jpeg"
        }
        if bytes.count >= 12, Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] { // "ftyp"
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "mif1", "msf1", "heim", "heis"].contains(brand) {
                return "image/heic"
            }
        }
        return nil
    }
}
