import Foundation

/// Uses production remuxing with externally generated local fixtures only.
@main
enum MediaRemuxSmoke {
    struct Failure: Error { let message: String }

    static func main() async throws {
        guard CommandLine.arguments.count == 5 else { throw Failure(message: "Expected video, audio, output and container") }
        let video = URL(fileURLWithPath: CommandLine.arguments[1])
        let audio = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        try await MediaRemux.combine([video, audio], into: output, container: CommandLine.arguments[4])
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw Failure(message: "The merged file is empty") }
        let invalidOutput = output.deletingLastPathComponent().appendingPathComponent("invalid-result.mp4")
        do {
            // The second input has no audio track: this must fail and remove
            // any incomplete output, while a later valid invocation succeeds.
            try await MediaRemux.combine([video, video], into: invalidOutput, container: "mp4")
            throw Failure(message: "A missing audio track unexpectedly succeeded")
        } catch let error as MediaSaveError {
            guard error.code == "mergeFailed", !FileManager.default.fileExists(atPath: invalidOutput.path) else {
                throw Failure(message: "Failed remux did not clean its output")
            }
        }
        print("Native packet remux completed: \(output.lastPathComponent), \(size) bytes.")
    }
}
