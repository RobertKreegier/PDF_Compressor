import Foundation
import PDFKit
import Quartz

nonisolated enum CompressionLevel: String, CaseIterable, Identifiable {
    case low = "Light"
    case medium = "Balanced"
    case high = "Maximum"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .low: "Best quality (200 dpi images)"
        case .medium: "Good quality (144 dpi images)"
        case .high: "Smallest file (96 dpi images)"
        }
    }

    fileprivate var resolution: Int {
        switch self {
        case .low: 200
        case .medium: 144
        case .high: 96
        }
    }

    fileprivate var jpegQuality: Double {
        switch self {
        case .low: 0.8
        case .medium: 0.6
        case .high: 0.4
        }
    }
}

enum CompressionError: LocalizedError {
    case cannotOpen
    case locked
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .cannotOpen: "The file couldn't be opened as a PDF."
        case .locked: "The PDF is password protected."
        case .cannotWrite: "The compressed PDF couldn't be written."
        }
    }
}

struct CompressionResult {
    let originalSize: Int64
    let newSize: Int64
    /// False when compression made the file larger and the original was copied instead.
    let keptCompressed: Bool
}

nonisolated enum PDFCompressor {
    /// Compresses `source` into `destination` using a Quartz filter that downsamples
    /// and JPEG-recompresses images. Text, vectors and links are left untouched.
    /// If the result would be larger than the original, the original is copied instead.
    static func compress(source: URL, destination: URL, level: CompressionLevel) throws -> CompressionResult {
        guard let document = PDFDocument(url: source) else { throw CompressionError.cannotOpen }
        if document.isLocked { throw CompressionError.locked }

        let filter = QuartzFilter(properties: filterProperties(for: level))
        let options: [PDFDocumentWriteOption: Any] = [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter as Any]
        guard document.write(to: destination, withOptions: options) else { throw CompressionError.cannotWrite }

        let originalSize = fileSize(source)
        let newSize = fileSize(destination)
        if newSize >= originalSize {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            return CompressionResult(originalSize: originalSize, newSize: originalSize, keptCompressed: false)
        }
        return CompressionResult(originalSize: originalSize, newSize: newSize, keptCompressed: true)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return Int64(size ?? 0)
    }

    private static func filterProperties(for level: CompressionLevel) -> [AnyHashable: Any] {
        [
            "Name": "Compress \(level.rawValue)",
            "FilterType": 1,
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "ImageCompression": "ImageJPEGCompress",
                        "Compression Quality": level.jpegQuality,
                        "ImageScaleSettings": [
                            "ImageResolution": level.resolution,
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": 2400,
                            "ImageSizeMin": 0,
                        ],
                    ],
                ],
            ],
        ]
    }
}
