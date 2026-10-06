import Foundation
import PDFKit
import Quartz

nonisolated enum CompressionLevel: String, CaseIterable, Identifiable {
    case low = "Light"
    case medium = "Balanced"
    case high = "Maximum"
    case extreme = "Extreme"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .low: "Best quality (200 dpi images)"
        case .medium: "Good quality (144 dpi images)"
        case .high: "Smaller file (96 dpi images)"
        case .extreme: "Smallest file (72 dpi, low quality)"
        }
    }

    var resolution: Int {
        switch self {
        case .low: 200
        case .medium: 144
        case .high: 96
        case .extreme: 72
        }
    }

    var jpegQuality: Double {
        switch self {
        case .low: 0.8
        case .medium: 0.6
        case .high: 0.4
        case .extreme: 0.25
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

struct CompressionOptions {
    var level: CompressionLevel = .medium
    /// Re-renders every page as a JPEG image. Often much smaller, but text is no longer selectable.
    var flatten = false
    /// Only used when flattening.
    var grayscale = false
}

struct CompressionResult {
    let originalSize: Int64
    let newSize: Int64
    /// False when nothing beat the original and it was copied instead.
    let keptCompressed: Bool
}

nonisolated enum PDFCompressor {
    /// Tries the selected approach and keeps the smallest result. If nothing beats the
    /// original file, the original is copied unchanged.
    static func compress(source: URL, destination: URL, options: CompressionOptions) throws -> CompressionResult {
        guard let document = PDFDocument(url: source) else { throw CompressionError.cannotOpen }
        if document.isLocked { throw CompressionError.locked }

        let fm = FileManager.default
        let originalSize = fileSize(source)
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        var candidates: [URL] = []
        func attempt(_ name: String, _ work: (URL) -> Bool) {
            let url = temp.appendingPathComponent(name)
            if work(url) { candidates.append(url) }
        }

        if options.flatten {
            attempt("flat.pdf") { flatten(document, to: $0, options: options) }
        } else {
            attempt("filter.pdf") { url in
                let filter = QuartzFilter(properties: filterProperties(for: options.level))
                let writeOptions: [PDFDocumentWriteOption: Any] = [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter as Any]
                return document.write(to: url, withOptions: writeOptions)
            }
            // A plain re-save sometimes shrinks files whose images are already small.
            attempt("plain.pdf") { document.write(to: $0) }
        }
        if candidates.isEmpty { throw CompressionError.cannotWrite }

        let best = candidates.min { fileSize($0) < fileSize($1) }!
        let bestSize = fileSize(best)
        try? fm.removeItem(at: destination)
        if bestSize >= originalSize {
            try fm.copyItem(at: source, to: destination)
            return CompressionResult(originalSize: originalSize, newSize: originalSize, keptCompressed: false)
        }
        try fm.copyItem(at: best, to: destination)
        return CompressionResult(originalSize: originalSize, newSize: bestSize, keptCompressed: true)
    }

    /// Renders each page to a JPEG at the level's resolution and builds a new PDF from the images.
    private static func flatten(_ document: PDFDocument, to url: URL, options: CompressionOptions) -> Bool {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { return false }
        var firstBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return false }

        let scale = CGFloat(options.level.resolution) / 72
        let colorSpace = options.grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = options.grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var ok = true
            autoreleasepool {
                let bounds = page.bounds(for: .cropBox)
                // `bounds` ignores page rotation, but `draw` applies it.
                let sideways = page.rotation % 180 != 0
                let pageSize = sideways ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
                let width = max(Int((pageSize.width * scale).rounded()), 1)
                let height = max(Int((pageSize.height * scale).rounded()), 1)
                guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else { ok = false; return }
                bitmap.setFillColor(gray: 1, alpha: 1)
                bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
                bitmap.scaleBy(x: scale, y: scale)
                if !sideways { bitmap.translateBy(x: -bounds.origin.x, y: -bounds.origin.y) }
                page.draw(with: .cropBox, to: bitmap)

                guard let image = bitmap.makeImage(), let jpeg = jpegData(image, quality: options.level.jpegQuality),
                      let provider = CGDataProvider(data: jpeg as CFData),
                      let jpegImage = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                              intent: .defaultIntent) else { ok = false; return }

                var box = CGRect(origin: .zero, size: pageSize)
                let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
                pdf.beginPDFPage(pageInfo)
                pdf.draw(jpegImage, in: box)
                pdf.endPDFPage()
            }
            if !ok { return false }
        }
        pdf.closePDF()
        return true
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
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
