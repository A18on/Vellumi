import Foundation
import UniformTypeIdentifiers

enum MarkdownImageCardTheme: String, CaseIterable, Identifiable {
    case aurora
    case cream
    case dark
    case forest
    case minimal
    case sunset

    var id: String { rawValue }

    var titleKey: String {
        "export.image.theme.\(rawValue)"
    }
}

enum MarkdownImageCardSizePreset: String, CaseIterable, Identifiable {
    case story
    case portrait
    case iphonePlus

    var id: String { rawValue }

    var pixelSize: MarkdownImageCardPixelSize {
        switch self {
        case .story:
            return MarkdownImageCardPixelSize(width: 1080, height: 1920)
        case .portrait:
            return MarkdownImageCardPixelSize(width: 1080, height: 1350)
        case .iphonePlus:
            return MarkdownImageCardPixelSize(width: 1242, height: 2208)
        }
    }

    var titleKey: String {
        switch self {
        case .story:
            return "export.image.size.story"
        case .portrait:
            return "export.image.size.portrait"
        case .iphonePlus:
            return "export.image.size.iphonePlus"
        }
    }
}

struct MarkdownImageCardPixelSize: Equatable {
    let width: Int
    let height: Int
}

enum MarkdownImageCardFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png:
            return "png"
        case .jpeg:
            return "jpg"
        }
    }

    var contentType: UTType {
        switch self {
        case .png:
            return .png
        case .jpeg:
            return .jpeg
        }
    }

    var titleKey: String {
        switch self {
        case .png:
            return "export.image.format.png"
        case .jpeg:
            return "export.image.format.jpeg"
        }
    }
}

enum MarkdownImageCardOutputMode: String, CaseIterable, Identifiable {
    case folder
    case zip

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .folder:
            return "export.image.output.folder"
        case .zip:
            return "export.image.output.zip"
        }
    }
}

enum MarkdownImageCardParagraphIndent: String, CaseIterable, Identifiable {
    case none
    case twoCharacters

    var id: String { rawValue }

    var cssValue: String {
        switch self {
        case .none:
            return "0em"
        case .twoCharacters:
            return "2em"
        }
    }

    var titleKey: String {
        switch self {
        case .none:
            return "export.image.paragraphIndent.none"
        case .twoCharacters:
            return "export.image.paragraphIndent.twoCharacters"
        }
    }
}

struct MarkdownImageCardExportRequest {
    let bodyHTML: String
    let documentURL: URL?
    let defaultBaseName: String
}

struct MarkdownImageCardRenderedPage: Equatable {
    let index: Int
    let data: Data
}

enum MarkdownImageCardExportError: LocalizedError, Equatable {
    case missingRendererResource
    case invalidDataURL
    case invalidBridgePayload

    var errorDescription: String? {
        switch self {
        case .missingRendererResource:
            return L10n.string("export.image.error.missingRenderer")
        case .invalidDataURL:
            return L10n.string("export.image.error.invalidData")
        case .invalidBridgePayload:
            return L10n.string("export.image.error.invalidBridgePayload")
        }
    }
}

enum MarkdownImageCardDataURL {
    static func decode(_ dataURL: String) throws -> Data {
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            throw MarkdownImageCardExportError.invalidDataURL
        }

        let header = dataURL[..<commaIndex].lowercased()
        guard header.hasPrefix("data:image/"),
              header.contains(";base64") else {
            throw MarkdownImageCardExportError.invalidDataURL
        }

        let payload = dataURL[dataURL.index(after: commaIndex)...]
        guard let data = Data(base64Encoded: String(payload)) else {
            throw MarkdownImageCardExportError.invalidDataURL
        }
        return data
    }
}

enum MarkdownImageCardFilenames {
    static func sanitizedBaseName(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "MarkMac-Card" : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.controlCharacters)
        let replaced = fallback.unicodeScalars
            .map { invalidCharacters.contains($0) ? "-" : String($0) }
            .joined()
        let sanitized = replaced
            .replacingOccurrences(of: #"[\s-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
        return sanitized.isEmpty ? "MarkMac-Card" : sanitized
    }

    static func singleFileName(baseName: String, format: MarkdownImageCardFormat) -> String {
        "\(sanitizedBaseName(from: baseName)).\(format.fileExtension)"
    }

    static func pageFileName(
        baseName: String,
        pageIndex: Int,
        pageCount: Int,
        format: MarkdownImageCardFormat
    ) -> String {
        let width = max(2, String(max(pageCount, 1)).count)
        let page = String(pageIndex + 1).leftPadded(toLength: width, with: "0")
        return "\(sanitizedBaseName(from: baseName))-\(page).\(format.fileExtension)"
    }

    static func zipFileName(baseName: String) -> String {
        "\(sanitizedBaseName(from: baseName)).zip"
    }
}

struct MarkdownImageCardZipWriter {
    struct File: Equatable {
        let path: String
        let data: Data
    }

    func archive(files: [File]) throws -> Data {
        var archive = Data()
        var centralDirectory = Data()

        for file in files {
            let nameData = Data(file.path.utf8)
            let checksum = CRC32.checksum(file.data)
            let localHeaderOffset = UInt32(archive.count)
            let size = UInt32(file.data.count)

            archive.appendUInt32(0x04034b50)
            archive.appendUInt16(20)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(checksum)
            archive.appendUInt32(size)
            archive.appendUInt32(size)
            archive.appendUInt16(UInt16(nameData.count))
            archive.appendUInt16(0)
            archive.append(nameData)
            archive.append(file.data)

            centralDirectory.appendUInt32(0x02014b50)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(checksum)
            centralDirectory.appendUInt32(size)
            centralDirectory.appendUInt32(size)
            centralDirectory.appendUInt16(UInt16(nameData.count))
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(0)
            centralDirectory.appendUInt32(localHeaderOffset)
            centralDirectory.append(nameData)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        let centralDirectorySize = UInt32(centralDirectory.count)
        archive.append(centralDirectory)
        archive.appendUInt32(0x06054b50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(UInt16(files.count))
        archive.appendUInt16(UInt16(files.count))
        archive.appendUInt32(centralDirectorySize)
        archive.appendUInt32(centralDirectoryOffset)
        archive.appendUInt16(0)
        return archive
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xedb88320
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xffff_ffff
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}

private extension String {
    func leftPadded(toLength length: Int, with character: Character) -> String {
        let paddingCount = max(0, length - count)
        return String(repeating: String(character), count: paddingCount) + self
    }
}
