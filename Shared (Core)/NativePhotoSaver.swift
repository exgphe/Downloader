import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

enum NativePhotoSaver {
    static var platform: String {
        #if os(macOS)
        return "macOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "iOS"
        #endif
    }

    static var authorizationName: String {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    static func authorize() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized || status == .limited else {
            #if os(macOS)
            let settings = "System Settings > Privacy & Security > Photos"
            #else
            let settings = "Settings > Privacy & Security > Photos"
            #endif
            throw MediaSaveError(code: status == .restricted ? "photosRestricted" : "photosDenied",
                                 message: "Photos access is \(status == .restricted ? "restricted" : "denied"). Allow Downloader to add photos in \(settings), then try again.")
        }
    }

    static func save(_ item: NativeMediaRequest) async throws {
        try await authorize()
        let download = try await MediaDownload.download(item)
        defer { try? FileManager.default.removeItem(at: download.directory) }
        try await saveFile(download.file, kind: item.kind, filename: item.filename, mimeType: download.mimeType)
    }

    static func saveFile(_ file: URL, kind: MediaKind, filename: String?, mimeType: String? = nil) async throws {
        try await authorize()
        let typedURL = try validatedFile(file, kind: kind, mimeType: mimeType)
        let options = PHAssetResourceCreationOptions()
        options.shouldMoveFile = false
        if let filename, !filename.isEmpty {
            options.originalFilename = ((filename as NSString).deletingPathExtension as NSString).appendingPathExtension(typedURL.pathExtension)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                creation.addResource(with: kind == .image ? .photo : .video, fileURL: typedURL, options: options)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MediaSaveError(code: "photosSaveFailed", message: "Photos could not save this \(kind.rawValue). \(error?.localizedDescription ?? "The media format may not be supported.")"))
                }
            }
        }
    }

    static func validatedFile(_ file: URL, kind: MediaKind, mimeType: String?) throws -> URL {
        let mime = mimeType?.lowercased() ?? ""
        let generic = mime.isEmpty || mime == "application/octet-stream" || mime == "binary/octet-stream"
        let suffix: String
        switch kind {
        case .image:
            guard generic || mime.hasPrefix("image/"),
                  let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) > 0,
                  let identifier = CGImageSourceGetType(source) as String? else {
                throw MediaSaveError(code: "invalidMedia", message: "The downloaded file is not a Photos-compatible image.")
            }
            // Core identifiers remain reliable when LaunchServices' type registry is unavailable
            // in an extension or command-line sandbox. Avoid dynamic UTType conformance queries.
            let compatibleExtensions = [UTType.jpeg.identifier: "jpg", UTType.png.identifier: "png",
                                        UTType.gif.identifier: "gif", UTType.heic.identifier: "heic",
                                        UTType.heif.identifier: "heif", UTType.tiff.identifier: "tiff"]
            if let preferred = compatibleExtensions[identifier] {
                suffix = preferred
            } else if ["org.webmproject.webp", "public.avif"].contains(identifier) {
                // Safari CDNs can negotiate WebP/AVIF, which Photos does not accept consistently.
                // Decode only bounded still images; retain original formats whenever PhotoKit accepts them.
                return try convertedJPEG(source: source, file: file)
            } else {
                throw MediaSaveError(code: "unsupportedImage", message: "The downloaded image format is not supported by Photos.")
            }
        case .video:
            guard generic || ["video/mp4", "video/quicktime", "video/x-m4v"].contains(mime) else {
                throw MediaSaveError(code: "invalidMedia", message: "The downloaded video is not an MP4 or QuickTime video.")
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 12) ?? Data()
            let box = header.count >= 8 ? String(data: header.subdata(in: 4..<8), encoding: .ascii) : nil
            guard ["ftyp", "moov", "mdat", "wide"].contains(box ?? "") else {
                throw MediaSaveError(code: "invalidMedia", message: "The downloaded file is not an MP4 or QuickTime video.")
            }
            suffix = mime == "video/quicktime" ? "mov" : "mp4"
        }
        let typed = file.deletingPathExtension().appendingPathExtension(suffix)
        if typed != file { try FileManager.default.moveItem(at: file, to: typed) }
        return typed
    }

    static func convertedJPEG(source: CGImageSource, file: URL) throws -> URL {
        guard CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0, height > 0, width <= 8_192, height <= 8_192, width * height <= 16_000_000 else {
            throw MediaSaveError(code: "unsupportedImage", message: "This image format requires conversion, but it is animated or exceeds the 16 megapixel conversion limit.")
        }
        let jpeg = file.deletingPathExtension().appendingPathExtension("jpg")
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width <= 8_192, image.height <= 8_192, image.width * image.height <= 16_000_000,
              let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MediaSaveError(code: "unsupportedImage", message: "This device cannot decode the downloaded image format.")
        }
        var metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        metadata[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaSaveError(code: "imageConversionFailed", message: "The image could not be converted to a Photos-compatible JPEG.")
        }
        return jpeg
    }
}
