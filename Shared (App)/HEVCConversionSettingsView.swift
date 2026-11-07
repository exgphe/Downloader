import SwiftUI

struct HEVCConversionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = HEVCConversionPreferences.load()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Download settings").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderless)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Toggle("Convert YouTube AV1 videos to HEVC", isOn: $settings.enabled)
                    Text("When enabled, AV1 video is converted after downloading. Other video codecs keep their original quality. Photos downloads may use a higher-resolution AV1 source.")
                        .font(.footnote).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Quality", selection: $settings.quality) {
                            Text("Smaller file").tag(HEVCQuality.compact)
                            Text("Balanced").tag(HEVCQuality.balanced)
                            Text("Higher quality").tag(HEVCQuality.high)
                        }.disabled(settings.customBitrate)
                        Picker("Maximum resolution", selection: $settings.resolution) {
                            Text("Original resolution").tag(HEVCResolution.original)
                            Text("1080p").tag(HEVCResolution.hd)
                            Text("2160p (4K)").tag(HEVCResolution.uhd)
                        }
                        Toggle("Set video bitrate manually", isOn: $settings.customBitrate)
                        if settings.customBitrate {
                            Stepper(value: $settings.bitrateMbps, in: 1...200) {
                                Text("Video bitrate: \(settings.bitrateMbps) Mbps")
                            }
                        }
                        Text("Quality presets choose a video bitrate from the output resolution and original frame rate. A higher bitrate usually increases quality and file size. The frame rate is preserved; resolution is never increased.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .disabled(!settings.enabled)
                    Text("HEVC conversion uses this device and re-encodes the video. Audio is copied without quality loss: Photos uses MP4 with AAC, and Files uses MKV. Conversion can take time and use battery power; keep Downloader open if background processing is interrupted.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Changes apply to new downloads from the app, share menu, and Shortcuts. Downloads already started keep their settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 310, idealWidth: 460, minHeight: 400)
        .onChange(of: settings) { settings in HEVCConversionPreferences.save(settings) }
    }
}
