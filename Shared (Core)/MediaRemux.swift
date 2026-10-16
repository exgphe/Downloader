import Foundation
import LocalAV

/// Copies compressed packets into a container. Video/audio are never re-encoded.
enum MediaRemux {
    private static let queue = DispatchQueue(label: "Downloader.local-remux", qos: .userInitiated)

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func combine(_ inputs: [URL], into output: URL, container: String) async throws {
        let cancellation = Cancellation()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try remux(inputs, output: output, container: container, cancellation: cancellation)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private final class Input {
        var context: UnsafeMutablePointer<AVFormatContext>?
        let packet: UnsafeMutablePointer<AVPacket>
        let inputIndex: Int
        let outputIndex: Int32
        var available = false

        init(url: URL, kind: AVMediaType, output: UnsafeMutablePointer<AVFormatContext>) throws {
            guard let allocated = av_packet_alloc() else { throw failure("Not enough memory to merge the video.") }
            packet = allocated
            var opened: UnsafeMutablePointer<AVFormatContext>?
            do {
                try check(avformat_open_input(&opened, url.path, nil, nil))
                guard let opened else { throw failure("The downloaded stream could not be opened.") }
                context = opened
                try check(avformat_find_stream_info(opened, nil))
                let indices = (0..<Int(opened.pointee.nb_streams)).filter {
                    opened.pointee.streams[$0]!.pointee.codecpar.pointee.codec_type == kind
                }
                guard let selected = indices.first, let stream = avformat_new_stream(output, nil) else {
                    throw failure("The downloaded video or audio track is missing.")
                }
                inputIndex = selected
                outputIndex = stream.pointee.index
                let source = opened.pointee.streams[selected]!
                try check(avcodec_parameters_copy(stream.pointee.codecpar, source.pointee.codecpar))
                stream.pointee.codecpar.pointee.codec_tag = 0
                stream.pointee.time_base = source.pointee.time_base
            } catch {
                avformat_close_input(&opened)
                var packet: UnsafeMutablePointer<AVPacket>? = allocated
                av_packet_free(&packet)
                throw error
            }
        }

        func read(_ cancellation: Cancellation) throws {
            available = false
            guard let context else { return }
            while true {
                if cancellation.cancelled { throw CancellationError() }
                let result = av_read_frame(context, packet)
                if result == -541478725 { return } // AVERROR_EOF
                try check(result)
                if packet.pointee.stream_index == Int32(inputIndex) { available = true; return }
                av_packet_unref(packet)
            }
        }

        var timeBase: AVRational { context!.pointee.streams[inputIndex]!.pointee.time_base }
        var timestamp: Int64 {
            packet.pointee.dts == Int64.min ? packet.pointee.pts : packet.pointee.dts
        }

        deinit {
            avformat_close_input(&context)
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&owned)
        }
    }

    private static func remux(_ inputs: [URL], output: URL, container: String, cancellation: Cancellation) throws {
        guard inputs.count == 2, ["mp4", "mkv"].contains(container) else {
            throw failure("This stream combination is not supported.")
        }
        var context: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&context, nil, container == "mp4" ? "mp4" : "matroska", output.path))
        guard let context else { throw failure("The output file could not be created.") }
        var completed = false
        defer {
            if context.pointee.pb != nil { avio_closep(&context.pointee.pb) }
            avformat_free_context(context)
            if !completed { try? FileManager.default.removeItem(at: output) }
        }
        let video = try Input(url: inputs[0], kind: AVMEDIA_TYPE_VIDEO, output: context)
        let audio = try Input(url: inputs[1], kind: AVMEDIA_TYPE_AUDIO, output: context)
        try check(avio_open(&context.pointee.pb, output.path, AVIO_FLAG_WRITE))
        try check(avformat_write_header(context, nil))
        let tracks = [video, audio]
        try tracks.forEach { try $0.read(cancellation) }
        while let next = tracks.filter(\.available).min(by: {
            av_compare_ts($0.timestamp, $0.timeBase, $1.timestamp, $1.timeBase) < 0
        }) {
            if cancellation.cancelled { throw CancellationError() }
            let target = context.pointee.streams[Int(next.outputIndex)]!
            av_packet_rescale_ts(next.packet, next.timeBase, target.pointee.time_base)
            next.packet.pointee.stream_index = next.outputIndex
            next.packet.pointee.pos = -1
            try check(av_interleaved_write_frame(context, next.packet))
            try next.read(cancellation)
        }
        try check(av_write_trailer(context))
        try check(avio_closep(&context.pointee.pb))
        completed = true
    }

    private static func failure(_ message: String) -> MediaSaveError {
        MediaSaveError(code: "mergeFailed", message: message)
    }

    private static func check(_ code: Int32) throws {
        guard code < 0 else { return }
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        throw failure("The video and audio could not be combined: \(String(cString: buffer))")
    }
}
