import Foundation
import ImageIO
import UniformTypeIdentifiers

// These checks never request Photos access or modify the photo library.
@main
enum NativeMediaValidationTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks = 0
        func expect(_ value: Bool, _ label: String) {
            checks += 1
            precondition(value, label)
        }
        // ImageIO creates a real PNG fixture, avoiding opaque binary test assets.
        let rgb = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                space: rgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = context.makeImage()!
        let png = directory.appendingPathComponent("original.download")
        let destination = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        expect(CGImageDestinationFinalize(destination), "Fixture image encoded")
        let originalData = try Data(contentsOf: png)
        let typedPNG = try NativePhotoSaver.validatedFile(png, kind: .image, mimeType: "image/png")
        expect(typedPNG.pathExtension == "png", "ImageIO determines file extension")
        expect(try Data(contentsOf: typedPNG) == originalData, "Compatible images preserve original bytes")
        let source = CGImageSourceCreateWithURL(typedPNG as CFURL, nil)!
        let converted = try NativePhotoSaver.convertedJPEG(source: source, file: directory.appendingPathComponent("alternate.download"))
        let jpegSource = CGImageSourceCreateWithURL(converted as CFURL, nil)!
        expect(CGImageSourceGetType(jpegSource) as String? == UTType.jpeg.identifier, "Fallback conversion creates a JPEG")
        let properties = CGImageSourceCopyPropertiesAtIndex(jpegSource, 0, nil) as! [CFString: Any]
        expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 2, "Conversion preserves dimensions")
        let invalid = directory.appendingPathComponent("response.download")
        try Data("<html>Not a media file</html>".utf8).write(to: invalid)
        let invalidCases: [(MediaKind, String)] = [(.image, "image/jpeg"), (.video, "video/mp4"), (.image, "text/html"), (.video, "text/html")]
        for (kind, mime) in invalidCases {
            do {
                _ = try NativePhotoSaver.validatedFile(invalid, kind: kind, mimeType: mime)
                preconditionFailure("Invalid file accepted as \(kind.rawValue)")
            } catch let error as MediaSaveError {
                expect(error.code == "invalidMedia", "Invalid media gets an actionable error")
            }
        }
        // A synthetic source advertises excessive dimensions; conversion must reject before decoding.
        let oversized = directory.appendingPathComponent("oversized.download")
        let largeContext = CGContext(data: nil, width: 8_193, height: 1, bitsPerComponent: 8, bytesPerRow: 8_193 * 4,
                                     space: rgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let largeDestination = CGImageDestinationCreateWithURL(oversized as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(largeDestination, largeContext.makeImage()!, nil)
        expect(CGImageDestinationFinalize(largeDestination), "Oversized fixture encoded")
        do {
            _ = try NativePhotoSaver.convertedJPEG(source: CGImageSourceCreateWithURL(oversized as CFURL, nil)!, file: oversized)
            preconditionFailure("Unbounded image conversion accepted")
        } catch let error as MediaSaveError {
            expect(error.code == "unsupportedImage", "Oversized conversion rejected before pixel decode")
        }
        print("Native media validation: \(checks) checks passed.")
    }
}
