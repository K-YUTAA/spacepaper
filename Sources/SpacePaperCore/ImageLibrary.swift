import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct CatalogSettings: Equatable {
    public let seedAssetIDs: [String]
    public let includeBuiltIns: Bool
    public let folders: [String]
    public init(seedAssetIDs: [String], includeBuiltIns: Bool, folders: [String]) {
        self.seedAssetIDs = seedAssetIDs; self.includeBuiltIns = includeBuiltIns; self.folders = folders
    }
}

public struct CatalogUnavailable: Error, LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private struct InvalidImage: Error {}

/// Access only on the controller's serial image queue. Catalog changes are transactional.
public final class ImageLibrary {
    public private(set) var assets: [String: WallpaperAsset] = [:]
    public private(set) var warnings: [String] = []
    public let directory: URL
    private var cachedSources: [String: (Date?, Int?, String)] = [:]
    private let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "avif", "bmp"]
    public init(directory: URL) { self.directory = directory }

    public func reload(settings: CatalogSettings) throws {
        var next: [String: WallpaperAsset] = [:]
        var messages: [String] = []
        for id in settings.seedAssetIDs {
            let file = directory.appendingPathComponent("\(id).jpg")
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw CatalogUnavailable(message: "保存した壁紙を読めないため、割り当ての更新を待機しています。")
            }
            next[id] = WallpaperAsset(id: id, path: file.path, name: "以前の壁紙")
        }
        var sources: [URL] = []
        if settings.includeBuiltIns {
            let folder = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
            do {
                sources += try FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    .filter { extensions.contains($0.pathExtension.lowercased()) }
            } catch { throw CatalogUnavailable(message: "Mac標準の画像フォルダを読めないため待機しています。") }
        }
        for path in settings.folders {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: path) else { throw unavailable(folder) }
            var readFailed = false
            guard let iterator = FileManager.default.enumerator(at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in readFailed = true; return false }) else {
                throw unavailable(folder)
            }
            var files: [URL] = []
            for case let file as URL in iterator {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                    readFailed = true; break
                }
                if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                if values.isRegularFile == true && extensions.contains(file.pathExtension.lowercased()) { files.append(file) }
            }
            guard !readFailed, FileManager.default.isReadableFile(atPath: path) else { throw unavailable(folder) }
            if files.count > 5000 { messages.append("\(folder.lastPathComponent): 最初の5000画像を使用") }
            sources += files.sorted { $0.path < $1.path }.prefix(5000)
        }
        for file in sources {
            guard FileManager.default.isReadableFile(atPath: file.path) else { throw unavailable(file.deletingLastPathComponent()) }
            do {
                let asset = try autoreleasepool { try importImage(file) }
                next[asset.id] = asset
            } catch is InvalidImage {
                messages.append("読み込めない画像: \(file.lastPathComponent)")
            } catch { throw CatalogUnavailable(message: "画像の読み込みに失敗したため、予約を維持して待機しています: \(file.lastPathComponent)") }
        }
        // Neither a partial source listing nor an interrupted read replaces the last good catalog.
        assets = next
        warnings = messages
    }

    private func unavailable(_ folder: URL) -> CatalogUnavailable {
        CatalogUnavailable(message: "画像フォルダ「\(folder.lastPathComponent)」を読めないため、予約を維持して待機しています。")
    }

    public func importImage(_ source: URL) throws -> WallpaperAsset {
        let id = try inspect(source, persist: true)
        return WallpaperAsset(id: id, path: directory.appendingPathComponent("\(id).jpg").path,
                              name: source.deletingPathExtension().lastPathComponent)
    }

    /// Fingerprinting is read-only: inspecting an unrelated wallpaper creates no JPEG.
    public func identity(_ source: URL?) -> String? {
        guard let source = source else { return nil }
        return try? autoreleasepool { try inspect(source, persist: false) }
    }

    private func inspect(_ source: URL, persist: Bool) throws -> String {
        guard source.isFileURL else { throw InvalidImage() }
        if source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
           FileManager.default.isReadableFile(atPath: source.path) {
            let id = source.deletingPathExtension().lastPathComponent
            if id.count == 64 && id.allSatisfy({ $0.isHexDigit }) { return id }
        }
        let values = try source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        if let known = cachedSources[source.path], known.0 == values.contentModificationDate, known.1 == values.fileSize,
           !persist || FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(known.2).jpg").path) { return known.2 }
        guard (values.fileSize ?? 0) < 150_000_000,
              let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else { throw InvalidImage() }
        let color = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let bytes = context.data else { throw InvalidImage() }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let id = SHA256.hash(data: Data(bytes: bytes, count: 64 * 64 * 4)).map { String(format: "%02x", $0) }.joined()
        if persist {
            let target = directory.appendingPathComponent("\(id).jpg")
            if !FileManager.default.fileExists(atPath: target.path) {
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw InvalidImage() }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw InvalidImage() }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try (data as Data).write(to: target, options: .atomic)
            }
        }
        cachedSources[source.path] = (values.contentModificationDate, values.fileSize, id)
        return id
    }
}
