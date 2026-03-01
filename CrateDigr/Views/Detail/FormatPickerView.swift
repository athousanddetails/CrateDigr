import SwiftUI

struct FormatPickerView: View {
    @Binding var format: AudioFormat
    @Binding var settings: AudioSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Format picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Format")
                    .font(.headline)

                Picker("Format", selection: $format) {
                    ForEach(AudioFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Format-specific settings
            VStack(alignment: .leading, spacing: 12) {
                Text("Quality")
                    .font(.headline)

                if format.supportsBitDepth {
                    HStack {
                        Text("Sample Rate")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Sample Rate", selection: $settings.sampleRate) {
                            ForEach(AudioSettings.SampleRate.allCases) { rate in
                                Text(rate.displayName).tag(rate)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 120)
                    }

                    HStack {
                        Text("Bit Depth")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Bit Depth", selection: $settings.bitDepth) {
                            ForEach(AudioSettings.BitDepth.allCases) { depth in
                                Text(depth.displayName).tag(depth)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }

                if format.supportsBitrate {
                    HStack {
                        Text("Sample Rate")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Sample Rate", selection: $settings.sampleRate) {
                            ForEach(AudioSettings.SampleRate.allCases) { rate in
                                Text(rate.displayName).tag(rate)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 120)
                    }

                    HStack {
                        Text("Bitrate")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Bitrate", selection: $settings.mp3Bitrate) {
                            ForEach(AudioSettings.MP3Bitrate.allCases) { bitrate in
                                Text(bitrate.displayName).tag(bitrate)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
            }
        }
    }
}
