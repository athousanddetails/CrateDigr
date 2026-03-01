import SwiftUI

struct SettingsView: View {
    @AppStorage(AppConstants.defaultFormatKey) private var defaultFormat: String = AudioFormat.wav.rawValue
    @AppStorage(AppConstants.defaultSampleRateKey) private var defaultSampleRate: Int = AudioSettings.SampleRate.rate44100.rawValue
    @AppStorage(AppConstants.defaultBitDepthKey) private var defaultBitDepth: Int = AudioSettings.BitDepth.bit16.rawValue
    @AppStorage(AppConstants.defaultMP3BitrateKey) private var defaultBitrate: Int = AudioSettings.MP3Bitrate.kbps320.rawValue
    @AppStorage(AppConstants.maxConcurrentKey) private var maxConcurrent: Int = AppConstants.defaultMaxConcurrent
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared

    @State private var ytdlpVersion = "..."
    @State private var ffmpegVersion = "..."
    @State private var denoVersion = "..."
    @State private var updateStatus = ""
    @State private var isCheckingUpdate = false
    @State private var isUpdating = false
    @State private var latestVersion: String?
    @State private var denoUpdateStatus = ""
    @State private var isCheckingDenoUpdate = false
    @State private var isUpdatingDeno = false
    @State private var latestDenoVersion: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            audioTab
                .tabItem {
                    Label("Audio", systemImage: "speaker.wave.2")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 380)
    }

    private var generalTab: some View {
        Form {
            Section("Default Format") {
                Picker("Format", selection: $defaultFormat) {
                    ForEach(AudioFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Default Quality") {
                Picker("Sample Rate", selection: $defaultSampleRate) {
                    ForEach(AudioSettings.SampleRate.allCases) { rate in
                        Text(rate.displayName).tag(rate.rawValue)
                    }
                }

                Picker("Bit Depth", selection: $defaultBitDepth) {
                    ForEach(AudioSettings.BitDepth.allCases) { depth in
                        Text(depth.displayName).tag(depth.rawValue)
                    }
                }

                Picker("MP3 Bitrate", selection: $defaultBitrate) {
                    ForEach(AudioSettings.MP3Bitrate.allCases) { bitrate in
                        Text(bitrate.displayName).tag(bitrate.rawValue)
                    }
                }
            }

            Section("Downloads") {
                Stepper("Concurrent Downloads: \(maxConcurrent)", value: $maxConcurrent, in: 1...4)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Audio Output Tab

    private var audioTab: some View {
        Form {
            Section("Output Device") {
                Picker("Device", selection: Binding(
                    get: { audioDeviceManager.selectedDeviceUID.isEmpty ? "system_default" : audioDeviceManager.selectedDeviceUID },
                    set: { newValue in
                        audioDeviceManager.selectDevice(uid: newValue)
                    }
                )) {
                    Text("System Default").tag("system_default")
                    Divider()
                    ForEach(audioDeviceManager.outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()

                Text("Select the audio output device for the Sampler. Changing this will route playback to the selected interface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(action: {
                    audioDeviceManager.refreshDevices()
                }) {
                    Label("Refresh Devices", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            audioDeviceManager.refreshDevices()
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.tv")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Crate Digr")
                .font(.title)
                .fontWeight(.bold)

            Text("YouTube Audio Downloader & Sampler")
                .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("yt-dlp:")
                        .fontWeight(.medium)
                    Text(ytdlpVersion)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("deno:")
                        .fontWeight(.medium)
                    Text(denoVersion)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("ffmpeg:")
                        .fontWeight(.medium)
                    Text(ffmpegVersion)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.caption)

            // yt-dlp update section
            VStack(spacing: 6) {
                if let latest = latestVersion, latest != ytdlpVersion {
                    Button(action: performUpdate) {
                        Label("Update yt-dlp to \(latest)", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isUpdating)
                } else {
                    Button(action: checkForUpdate) {
                        Label("Check for yt-dlp Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isCheckingUpdate || isUpdating)
                }

                if !updateStatus.isEmpty {
                    Text(updateStatus)
                        .font(.caption2)
                        .foregroundStyle(updateStatus.contains("failed") || updateStatus.contains("Error") ? .red : .secondary)
                        .multilineTextAlignment(.center)
                }
            }

            // deno update section
            VStack(spacing: 6) {
                if let latest = latestDenoVersion, latest != denoVersion {
                    Button(action: performDenoUpdate) {
                        Label("Update deno to \(latest)", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isUpdatingDeno)
                } else {
                    Button(action: checkForDenoUpdate) {
                        Label("Check for deno Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isCheckingDenoUpdate || isUpdatingDeno)
                }

                if !denoUpdateStatus.isEmpty {
                    Text(denoUpdateStatus)
                        .font(.caption2)
                        .foregroundStyle(denoUpdateStatus.contains("failed") || denoUpdateStatus.contains("Error") ? .red : .secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()
        }
        .padding()
        .task {
            ytdlpVersion = await BundledBinaryManager.ytdlpVersion()
            denoVersion = await BundledBinaryManager.denoVersion()
            ffmpegVersion = await BundledBinaryManager.ffmpegVersion()
        }
    }

    // MARK: - Update Functions

    private func checkForUpdate() {
        isCheckingUpdate = true
        updateStatus = "Checking..."
        Task {
            let result = await BundledBinaryManager.isYtdlpUpdateAvailable()
            isCheckingUpdate = false
            if result.available {
                latestVersion = result.latestVersion
                updateStatus = "Update available: \(result.latestVersion)"
            } else {
                updateStatus = "Already up to date (\(result.currentVersion))"
            }
        }
    }

    private func performUpdate() {
        isUpdating = true
        Task {
            do {
                try await BundledBinaryManager.updateYtdlp { status in
                    Task { @MainActor in
                        updateStatus = status
                    }
                }
                ytdlpVersion = await BundledBinaryManager.ytdlpVersion()
                latestVersion = nil
                updateStatus = "Updated successfully to \(ytdlpVersion)"
            } catch {
                updateStatus = "Update failed: \(error.localizedDescription)"
            }
            isUpdating = false
        }
    }

    private func checkForDenoUpdate() {
        isCheckingDenoUpdate = true
        denoUpdateStatus = "Checking..."
        Task {
            let result = await BundledBinaryManager.isDenoUpdateAvailable()
            isCheckingDenoUpdate = false
            if result.available {
                latestDenoVersion = result.latestVersion
                denoUpdateStatus = "Update available: \(result.latestVersion)"
            } else {
                denoUpdateStatus = "Already up to date (\(result.currentVersion))"
            }
        }
    }

    private func performDenoUpdate() {
        isUpdatingDeno = true
        Task {
            do {
                try await BundledBinaryManager.updateDeno { status in
                    Task { @MainActor in
                        denoUpdateStatus = status
                    }
                }
                denoVersion = await BundledBinaryManager.denoVersion()
                latestDenoVersion = nil
                denoUpdateStatus = "Updated successfully to \(denoVersion)"
            } catch {
                denoUpdateStatus = "Update failed: \(error.localizedDescription)"
            }
            isUpdatingDeno = false
        }
    }
}
