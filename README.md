# Crate Digr

An OPEN SOURCE native macOS app for downloading YouTube audio, sampling, and AI stem separation. Built for music producers and crate diggers.

Totally Vibe Coded, so expect a bit of AI Slop lmao

**Apple Silicon only** | **macOS 14+** | **SwiftUI + SPM**

## Features

### Downloads
- Download audio from YouTube in WAV, AIFF, FLAC, or MP3
- Batch download — paste multiple URLs at once
- Configurable sample rate, bit depth, and bitrate
- Custom output filenames
- Drag & drop URL support

### Sampler
- Load and preview audio samples with waveform display
- Turntable-style varispeed playback (pitch/speed control)
- Beat loop with BPM detection and grid snapping
- Multi-key keyboard mapping for live playing
- Lo-Fi export (bit crush, sample rate reduction, noise)
- Chop samples and export slices
- Audio output device selection

### Stems (AI Separation)
- Separate any track into vocals, drums, bass, and other stems
- Powered by Demucs (Meta's AI model) running locally
- No cloud processing — everything stays on your machine

## Getting Started

### Prerequisites
- macOS 14.0+
- Apple Silicon Mac (M1/M2/M3/M4)
- Xcode Command Line Tools (`xcode-select --install`)

### Build from Source

```bash
# 1. Clone the repo
git clone https://github.com/YOUR_USERNAME/CrateDigr.git
cd CrateDigr

# 2. Download required binaries (~270MB)
bash setup-binaries.sh

# 3. Build
bash build-app.sh
```

### Download Compiled App
Check the [Releases](https://github.com/YOUR_USERNAME/CrateDigr/releases) page for pre-built `.app` bundles.

## Project Structure

```
CrateDigr/
├── App/                  # App entry point, constants
├── Models/               # Data models (AudioFormat, DownloadItem, etc.)
├── Services/             # Core services
│   ├── Sampler/          # Audio engine, sample playback
│   ├── YTDLPService      # YouTube download via yt-dlp
│   ├── DemucsService     # AI stem separation
│   └── AudioDeviceManager # CoreAudio device routing
├── ViewModels/           # Observable state management
├── Views/                # SwiftUI views
│   ├── Detail/           # Download views
│   ├── Sampler/          # Sampler tab views
│   ├── Stems/            # Stems tab views
│   └── Settings/         # App settings
├── Utilities/            # Helpers (ProcessRunner, etc.)
└── Resources/
    ├── Assets.xcassets   # App icon
    └── Binaries/         # yt-dlp, ffmpeg, deno, demucs (downloaded via setup script)
```

## Bundled Tools

These are downloaded by `setup-binaries.sh` and are **not** included in the git repo:

| Binary | Purpose | Source |
|--------|---------|--------|
| yt-dlp | YouTube audio extraction | [yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp) |
| ffmpeg | Audio format conversion | [evermeet.cx/ffmpeg](https://evermeet.cx/ffmpeg/) |
| deno | JavaScript runtime for yt-dlp | [denoland/deno](https://github.com/denoland/deno) |
| demucs_mt | AI stem separation | [CrazyNeil/OVern-demucs](https://github.com/CrazyNeil/OVern-demucs) |

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

## License

[MIT License](LICENSE)
