import Foundation

enum ProcessError: LocalizedError {
    case failed(exitCode: Int32, stderr: String)
    case binaryNotFound(path: String)

    var errorDescription: String? {
        switch self {
        case .failed(let code, let stderr):
            return "Process exited with code \(code): \(stderr)"
        case .binaryNotFound(let path):
            return "Binary not found at: \(path)"
        }
    }
}

struct ProcessOutput {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Thread-safe data accumulator for collecting process output without pipe deadlock
private final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []

    func append(_ data: Data) {
        lock.lock()
        chunks.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        let result = chunks.reduce(Data(), +)
        lock.unlock()
        return result
    }
}

/// Thread-safe line buffer for parsing process output
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ str: String, lineHandler: (String) -> Void) {
        lock.lock()
        buffer += str
        // Parse complete lines (newline-delimited)
        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
            buffer = String(buffer[newlineRange.upperBound...])
            lock.unlock()
            lineHandler(line)
            lock.lock()
        }
        // Also handle \r for yt-dlp progress lines
        while let crRange = buffer.range(of: "\r") {
            let line = String(buffer[buffer.startIndex..<crRange.lowerBound])
            buffer = String(buffer[crRange.upperBound...])
            if !line.isEmpty {
                lock.unlock()
                lineHandler(line)
                lock.lock()
            }
        }
        lock.unlock()
    }

    func flush(lineHandler: (String) -> Void) {
        lock.lock()
        let remaining = buffer
        buffer = ""
        lock.unlock()
        if !remaining.isEmpty {
            lineHandler(remaining)
        }
    }
}

final class ProcessRunner {

    /// Run a process and collect all output at once.
    /// Supports Task cancellation — the subprocess is killed if the Task is cancelled.
    /// Uses readabilityHandler to drain pipes in real-time, preventing deadlock
    /// when output exceeds the pipe buffer (~64KB).
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> ProcessOutput {
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw ProcessError.binaryNotFound(path: executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Accumulate data using readabilityHandler to avoid pipe buffer deadlock
        let stdoutAccumulator = DataAccumulator()
        let stderrAccumulator = DataAccumulator()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutAccumulator.append(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrAccumulator.append(data)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { _ in
                    // Stop reading handlers
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    // Read any remaining data in the pipe
                    let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingOut.isEmpty { stdoutAccumulator.append(remainingOut) }
                    if !remainingErr.isEmpty { stderrAccumulator.append(remainingErr) }

                    let stdout = String(data: stdoutAccumulator.data, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrAccumulator.data, encoding: .utf8) ?? ""

                    continuation.resume(returning: ProcessOutput(
                        exitCode: process.terminationStatus,
                        stdout: stdout,
                        stderr: stderr
                    ))
                }

                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Run a process with line-by-line stdout streaming.
    /// Supports Task cancellation — the subprocess is killed if the Task is cancelled.
    static func runStreaming(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw ProcessError.binaryNotFound(path: executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lineBuffer = LineBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let str = String(data: data, encoding: .utf8) else { return }
            lineBuffer.append(str, lineHandler: onOutput)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    lineBuffer.flush(lineHandler: onOutput)
                    continuation.resume(returning: proc.terminationStatus)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Run a process with line-by-line stderr streaming (for tools like demucs.cpp that output progress to stderr).
    /// Supports Task cancellation — the subprocess is killed if the Task is cancelled.
    static func runStreamingStderr(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onStderrLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw ProcessError.binaryNotFound(path: executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lineBuffer = LineBuffer()

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let str = String(data: data, encoding: .utf8) else { return }
            lineBuffer.append(str, lineHandler: onStderrLine)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    lineBuffer.flush(lineHandler: onStderrLine)
                    continuation.resume(returning: proc.terminationStatus)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Run a process streaming both stdout and stderr line-by-line.
    /// Supports Task cancellation — the subprocess is killed if the Task is cancelled.
    static func runStreamingBoth(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onStdoutLine: @escaping @Sendable (String) -> Void,
        onStderrLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw ProcessError.binaryNotFound(path: executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = LineBuffer()
        let stderrBuffer = LineBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let str = String(data: data, encoding: .utf8) else { return }
            stdoutBuffer.append(str, lineHandler: onStdoutLine)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let str = String(data: data, encoding: .utf8) else { return }
            stderrBuffer.append(str, lineHandler: onStderrLine)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    stdoutBuffer.flush(lineHandler: onStdoutLine)
                    stderrBuffer.flush(lineHandler: onStderrLine)
                    continuation.resume(returning: proc.terminationStatus)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Cancel a running process
    static func terminate(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
    }
}
