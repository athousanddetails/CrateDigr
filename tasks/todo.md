# YoutubeWav - Task Tracker

## Completed
- [x] Project structure and directory layout
- [x] Models: DownloadItem, AudioFormat, AudioSettings, DownloadStatus
- [x] Services: ProcessRunner, BundledBinaryManager, YTDLPService, FFmpegService
- [x] Utilities: URLValidator with filename sanitization
- [x] DownloadManager: queue, pipeline, concurrency control
- [x] UI: ContentView, SidebarView, QueueItemRow, NewDownloadView, FormatPickerView, OutputFolderPicker, SettingsView, StatusBadge
- [x] Drag-and-drop URL support
- [x] yt-dlp arm64 binary (35MB) downloaded and bundled
- [x] ffmpeg arm64 binary (47MB) downloaded and bundled
- [x] SPM Package.swift configured
- [x] Release build passing (arm64)

## To Open in Xcode
1. Install xcodegen: `brew install xcodegen`
2. Run: `xcodegen generate` in the project root
3. Open `YoutubeWav.xcodeproj`

## Future Improvements
- [ ] App icon design
- [ ] Playlist support (optional)
- [ ] Drag-and-drop reordering in queue
- [ ] Notification when downloads complete
- [ ] Auto-update yt-dlp binary
- [ ] Menu bar download status indicator
