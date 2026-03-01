# YoutubeWav - Lessons Learned

## Swift/SPM
- SPM uses `Bundle.module` for resource access, not `Bundle.main`. Always use `#if SWIFT_PACKAGE` guard.
- `Task { [weak self] in await self?.method() }` returns `Task<()?, Never>` not `Task<Void, Never>`. Avoid `[weak self]` in `@MainActor` class Tasks, or use explicit types.
- Mutable `var` captured in `@Sendable` closures triggers Swift 6 warnings. Use a thread-safe wrapper class marked `@unchecked Sendable` with NSLock.

## Binary Bundling
- evermeet.cx ffmpeg builds are x86_64. Use osxexperts.net for arm64 builds.
- yt-dlp `yt-dlp_macos` is a universal binary (works on both architectures).
