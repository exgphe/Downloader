import Foundation
import LocalAV

/// Decode AV1 in-process with dav1d, encode HEVC with VideoToolbox, and copy
/// compressed audio unchanged. No executable or network protocol is involved.
enum HEVCTranscoder {
    private static let queue = DispatchQueue(label: "Downloader.hevc-conversion", qos: .userInitiated)
    private static let eof: Int32 = -541478725
    private static let again: Int32 = -35 // AVERROR(EAGAIN) on Darwin.

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        func check() throws {
            lock.lock(); let cancelled = value; lock.unlock()
            if cancelled { throw CancellationError() }
        }
    }

    static func convert(_ input: URL, into output: URL, container: String,
                        settings: HEVCConversionSettings,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        let cancellation = Cancellation()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try run(input, output: output, container: container, settings: settings,
                                cancellation: cancellation, progress: progress)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private static func run(_ input: URL, output: URL, container: String,
                            settings: HEVCConversionSettings, cancellation: Cancellation,
                            progress: @escaping @Sendable (Double) -> Void) throws {
        try cancellation.check()
        guard input.isFileURL, output.isFileURL, input != output, ["mp4", "mkv"].contains(container) else {
            throw failure("The video conversion requires separate local input and output files.")
        }
        var source: UnsafeMutablePointer<AVFormatContext>?
        var replay: UnsafeMutablePointer<AVFormatContext>?
        var target: UnsafeMutablePointer<AVFormatContext>?
        var decoder: UnsafeMutablePointer<AVCodecContext>?
        var encoder: UnsafeMutablePointer<AVCodecContext>?
        var packet = av_packet_alloc()
        var encoded = av_packet_alloc()
        var frame = av_frame_alloc()
        var converted = av_frame_alloc()
        var scaler: UnsafeMutablePointer<SwsContext>?
        var completed = false
        defer {
            sws_freeContext(scaler)
            av_frame_free(&frame); av_frame_free(&converted)
            av_packet_free(&packet); av_packet_free(&encoded)
            avcodec_free_context(&decoder); avcodec_free_context(&encoder)
            avformat_close_input(&source)
            avformat_close_input(&replay)
            if let target {
                if target.pointee.pb != nil { avio_closep(&target.pointee.pb) }
                avformat_free_context(target)
            }
            if !completed { try? FileManager.default.removeItem(at: output) }
        }
        guard let packet, let encoded, let frame, let converted else {
            throw failure("Not enough memory to convert the video.")
        }
        try check(avformat_open_input(&source, input.path, nil, nil))
        guard let source else { throw failure("The downloaded video could not be opened.") }
        try check(avformat_find_stream_info(source, nil))
        let videoIndex = (0..<Int(source.pointee.nb_streams)).first {
            source.pointee.streams[$0]!.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
        }
        guard let videoIndex else { throw failure("The downloaded video track is missing.") }
        let video = source.pointee.streams[videoIndex]!
        guard video.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_AV1 else {
            throw failure("Only AV1 video is eligible for this HEVC conversion.")
        }
        guard let av1 = avcodec_find_decoder_by_name("libdav1d"),
              let hevc = avcodec_find_encoder_by_name("hevc_videotoolbox") else {
            throw failure("The built-in AV1/HEVC engine is unavailable. Rebuild and reinstall Downloader.")
        }
        decoder = avcodec_alloc_context3(av1)
        guard let decoder else { throw failure("The AV1 decoder could not be created.") }
        try check(avcodec_parameters_to_context(decoder, video.pointee.codecpar))
        decoder.pointee.pkt_timebase = video.pointee.time_base
        decoder.pointee.thread_count = 4
        try check(avcodec_open2(decoder, av1, nil))

        // Probe one decoded frame before opening the encoder: AV1 sequence headers
        // can set the bit depth and colour properties only when decoding starts.
        while true {
            try cancellation.check()
            let received = avcodec_receive_frame(decoder, frame)
            if received >= 0 { break }
            guard received == again else { try check(received); throw failure("The AV1 video contains no frames.") }
            let read = av_read_frame(source, packet)
            if read == eof { throw failure("The AV1 video contains no decodable frames.") }
            try check(read)
            if packet.pointee.stream_index == Int32(videoIndex) { try check(avcodec_send_packet(decoder, packet)) }
            av_packet_unref(packet)
        }
        let firstWidth = frame.pointee.width, firstHeight = frame.pointee.height
        let firstFormat = frame.pointee.format
        guard firstWidth > 0, firstHeight > 0,
              let descriptor = av_pix_fmt_desc_get(AVPixelFormat(rawValue: frame.pointee.format)) else {
            throw failure("The AV1 pixel format is unsupported.")
        }
        let tenBit = descriptor.pointee.comp.0.depth > 8
        let dimensions = settings.dimensions(width: Int(firstWidth), height: Int(firstHeight))
        var fps = av_guess_frame_rate(source, video, nil)
        if fps.num <= 0 || fps.den <= 0 { fps = AVRational(num: 30, den: 1) }
        encoder = avcodec_alloc_context3(hevc)
        guard let encoder else { throw failure("The HEVC encoder could not be created.") }
        encoder.pointee.width = Int32(dimensions.width)
        encoder.pointee.height = Int32(dimensions.height)
        encoder.pointee.pix_fmt = tenBit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12
        encoder.pointee.time_base = video.pointee.time_base
        encoder.pointee.framerate = fps
        encoder.pointee.sample_aspect_ratio = video.pointee.sample_aspect_ratio
        encoder.pointee.color_primaries = frame.pointee.color_primaries == AVCOL_PRI_UNSPECIFIED ? video.pointee.codecpar.pointee.color_primaries : frame.pointee.color_primaries
        encoder.pointee.color_trc = frame.pointee.color_trc == AVCOL_TRC_UNSPECIFIED ? video.pointee.codecpar.pointee.color_trc : frame.pointee.color_trc
        encoder.pointee.colorspace = frame.pointee.colorspace == AVCOL_SPC_UNSPECIFIED ? video.pointee.codecpar.pointee.color_space : frame.pointee.colorspace
        encoder.pointee.color_range = frame.pointee.color_range == AVCOL_RANGE_UNSPECIFIED ? video.pointee.codecpar.pointee.color_range : frame.pointee.color_range
        encoder.pointee.chroma_sample_location = frame.pointee.chroma_location
        encoder.pointee.bit_rate = settings.bitrate(width: dimensions.width, height: dimensions.height, frameRate: av_q2d(fps))
        encoder.pointee.max_b_frames = 0
        encoder.pointee.gop_size = Int32(min(600, max(1, av_q2d(fps) * 2)))
        try check(avformat_alloc_output_context2(&target, nil, container == "mp4" ? "mp4" : "matroska", output.path))
        guard let target, let videoOut = avformat_new_stream(target, nil) else { throw failure("The HEVC output could not be created.") }
        if target.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER != 0 { encoder.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER }
        try check(av_opt_set(encoder.pointee.priv_data, "profile", tenBit ? "main10" : "main", 0))
        try check(av_opt_set_int(encoder.pointee.priv_data, "allow_sw", 1, 0))
        try check(avcodec_open2(encoder, hevc, nil), message: "This device could not start HEVC encoding. Try a lower output resolution.")
        try check(avcodec_parameters_from_context(videoOut.pointee.codecpar, encoder))
        videoOut.pointee.time_base = encoder.pointee.time_base
        videoOut.pointee.avg_frame_rate = fps
        if container == "mp4" { videoOut.pointee.codecpar.pointee.codec_tag = 0x31637668 } // hvc1
        try check(av_dict_copy(&target.pointee.metadata, source.pointee.metadata, 0))
        try check(av_dict_copy(&videoOut.pointee.metadata, video.pointee.metadata, 0))
        var audioTracks: [Int32: UnsafeMutablePointer<AVStream>] = [:]
        for index in 0..<Int(source.pointee.nb_streams) {
            let stream = source.pointee.streams[index]!
            guard stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            if container == "mp4", stream.pointee.codecpar.pointee.codec_id != AV_CODEC_ID_AAC {
                throw failure("Photos conversion requires an AAC audio track. Download this video to Files instead.")
            }
            guard let copied = avformat_new_stream(target, nil) else { throw failure("The audio track could not be copied.") }
            try check(avcodec_parameters_copy(copied.pointee.codecpar, stream.pointee.codecpar))
            copied.pointee.codecpar.pointee.codec_tag = 0
            copied.pointee.time_base = stream.pointee.time_base
            try check(av_dict_copy(&copied.pointee.metadata, stream.pointee.metadata, 0))
            audioTracks[Int32(index)] = copied
        }
        try check(avio_open(&target.pointee.pb, output.path, AVIO_FLAG_WRITE))
        try check(avformat_write_header(target, nil))
        converted.pointee.width = encoder.pointee.width
        converted.pointee.height = encoder.pointee.height
        converted.pointee.format = encoder.pointee.pix_fmt.rawValue
        try check(av_frame_get_buffer(converted, 32))
        scaler = sws_getContext(firstWidth, firstHeight, AVPixelFormat(rawValue: frame.pointee.format),
                               encoder.pointee.width, encoder.pointee.height, encoder.pointee.pix_fmt,
                               Int32(SWS_BICUBIC.rawValue), nil, nil, nil)
        guard let scaler else { throw failure("The video pixel format could not be converted.") }
        let coefficients = sws_getCoefficients(encoder.pointee.colorspace.rawValue == 9 ? SWS_CS_BT2020 :
                                               (encoder.pointee.colorspace.rawValue == 1 ? SWS_CS_ITU709 : SWS_CS_DEFAULT))
        let fullRange: Int32 = encoder.pointee.color_range == AVCOL_RANGE_JPEG ? 1 : 0
        try check(sws_setColorspaceDetails(scaler, coefficients, fullRange, coefficients, fullRange, 0, 1 << 16, 1 << 16))
        let duration = video.pointee.duration > 0 ? Double(video.pointee.duration) * av_q2d(video.pointee.time_base) :
            Double(source.pointee.duration) / Double(AV_TIME_BASE)
        let startTime = video.pointee.start_time == Int64.min ? 0 : video.pointee.start_time
        var lastProgress = -1.0
        var writtenPackets = 0

        func drainEncoder() throws {
            while true {
                try cancellation.check()
                let result = avcodec_receive_packet(encoder, encoded)
                if result == again || result == eof { return }
                try check(result)
                av_packet_rescale_ts(encoded, encoder.pointee.time_base, videoOut.pointee.time_base)
                encoded.pointee.stream_index = videoOut.pointee.index
                try check(av_interleaved_write_frame(target, encoded))
                writtenPackets += 1
                av_packet_unref(encoded)
            }
        }
        func encodeFrame() throws {
            try cancellation.check()
            guard frame.pointee.width == firstWidth, frame.pointee.height == firstHeight, frame.pointee.format == firstFormat else {
                throw failure("Videos that change resolution or pixel format while playing cannot be converted yet.")
            }
            try check(av_frame_make_writable(converted))
            try check(av_frame_copy_props(converted, frame))
            converted.pointee.color_primaries = encoder.pointee.color_primaries
            converted.pointee.color_trc = encoder.pointee.color_trc
            converted.pointee.colorspace = encoder.pointee.colorspace
            converted.pointee.color_range = encoder.pointee.color_range
            let scaled = withUnsafePointer(to: frame.pointee.data) { data in
                data.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { sourceData in
                    withUnsafePointer(to: frame.pointee.linesize) { lines in
                        lines.withMemoryRebound(to: Int32.self, capacity: 8) { sourceLines in
                            withUnsafeMutablePointer(to: &converted.pointee.data) { outData in
                                outData.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self, capacity: 8) { destinationData in
                                    withUnsafePointer(to: converted.pointee.linesize) { outLines in
                                        outLines.withMemoryRebound(to: Int32.self, capacity: 8) { destinationLines in
                                            sws_scale(scaler, sourceData, sourceLines, 0, firstHeight, destinationData, destinationLines)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            try check(scaled)
            converted.pointee.pts = frame.pointee.best_effort_timestamp
            if converted.pointee.pts == Int64.min { throw failure("The video has no usable frame timestamps.") }
            try check(avcodec_send_frame(encoder, converted))
            try drainEncoder()
            if duration > 0 {
                let fraction = min(0.99, max(0, (Double(converted.pointee.pts) - Double(startTime)) * av_q2d(video.pointee.time_base) / duration))
                if fraction - lastProgress >= 0.01 { progress(fraction); lastProgress = fraction }
            }
            av_frame_unref(frame)
        }
        func drainDecoder() throws {
            while true {
                let result = avcodec_receive_frame(decoder, frame)
                if result == again || result == eof { return }
                try check(result)
                try encodeFrame()
            }
        }
        // Reopen after probing instead of seeking to the first video keyframe:
        // audio may begin earlier (including negative encoder-delay timestamps).
        av_frame_unref(frame)
        avcodec_flush_buffers(decoder)
        try check(avformat_open_input(&replay, input.path, nil, nil))
        guard let replay else { throw failure("The video could not be reopened for conversion.") }
        try check(avformat_find_stream_info(replay, nil))
        progress(0)
        while true {
            try cancellation.check()
            let read = av_read_frame(replay, packet)
            if read == eof { break }
            try check(read)
            if packet.pointee.stream_index == Int32(videoIndex) {
                try check(avcodec_send_packet(decoder, packet))
                try drainDecoder()
            } else if let audioOut = audioTracks[packet.pointee.stream_index] {
                let audio = source.pointee.streams[Int(packet.pointee.stream_index)]!
                av_packet_rescale_ts(packet, audio.pointee.time_base, audioOut.pointee.time_base)
                packet.pointee.stream_index = audioOut.pointee.index
                packet.pointee.pos = -1
                try check(av_interleaved_write_frame(target, packet))
            }
            av_packet_unref(packet)
        }
        try check(avcodec_send_packet(decoder, nil))
        try drainDecoder()
        try check(avcodec_send_frame(encoder, nil))
        try drainEncoder()
        try cancellation.check()
        guard writtenPackets > 0 else { throw failure("The conversion produced no video frames.") }
        try check(av_write_trailer(target))
        try check(avio_closep(&target.pointee.pb))
        completed = true
        progress(1)
    }

    private static func failure(_ message: String) -> MediaSaveError {
        MediaSaveError(code: "conversionFailed", message: message)
    }
    private static func check(_ result: Int32, message: String = "The AV1 video could not be converted to HEVC.") throws {
        guard result < 0 else { return }
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(result, &buffer, buffer.count)
        throw failure("\(message) \(String(cString: buffer))")
    }
}
