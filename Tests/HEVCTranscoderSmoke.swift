import Foundation

@main
enum HEVCTranscoderSmoke {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4 else { fatalError("input output container [height] [bitrate Mbps] [cancel]") }
        var settings = HEVCConversionSettings(enabled: true)
        if arguments.count > 4, arguments[4] == "1080" { settings.resolution = .hd }
        if arguments.count > 5, let bitrate = Int(arguments[5]) { settings.customBitrate = true; settings.bitrateMbps = bitrate }
        let task = Task {
            try await HEVCTranscoder.convert(URL(fileURLWithPath: arguments[1]), into: URL(fileURLWithPath: arguments[2]),
                                            container: arguments[3], settings: settings) { _ in }
        }
        if arguments.last == "cancel" {
            task.cancel()
            do { try await task.value; fatalError("Cancellation must fail") }
            catch is CancellationError {
                precondition(!FileManager.default.fileExists(atPath: arguments[2]), "Cancelled conversion must clean up output")
                print("Cancellation and cleanup verified")
            }
        } else {
            try await task.value
            print("In-process AV1 → HEVC conversion finished")
        }
    }
}
