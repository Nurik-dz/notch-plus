import Foundation

/// Optional ffmpeg integration. Used for robust audio extraction from unusual
/// containers and for muxing toggleable caption tracks.
enum FFmpeg {
    private static let candidatePaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]

    static func locate() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs ffmpeg to completion. Both output pipes are drained continuously
    /// (a full pipe buffer would otherwise stall ffmpeg forever), progress is
    /// reported as seconds of output written, and cancelling the calling task
    /// terminates the process.
    static func run(_ arguments: [String], progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let path = locate() else {
            throw Failure(message: "ffmpeg isn't installed. Install it with \"brew install ffmpeg\" and try again.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        var fullArguments = ["-hide_banner", "-nostdin", "-y"]
        if progress != nil { fullArguments += ["-progress", "pipe:1", "-nostats"] }
        process.arguments = fullArguments + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)
        let exit = ExitSignal()
        process.terminationHandler = { _ in exit.fire() }
        try await withTaskCancellationHandler {
            try process.run()
            box.markStarted()

            async let errorLog = blocking { stderr.fileHandleForReading.readDataToEndOfFile() }
            async let progressDone: Void = blocking {
                let handle = stdout.fileHandleForReading
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    guard let progress else { continue }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex...newline)
                        // ffmpeg reports both keys in microseconds.
                        if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
                           let value = Double(line.split(separator: "=").last ?? "") {
                            progress(value / 1_000_000)
                        }
                    }
                }
            }
            let log = await errorLog
            _ = await progressDone
            await exit.wait()

            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                let text = String(decoding: log, as: UTF8.self)
                let tail = text.split(separator: "\n").suffix(4).joined(separator: "\n")
                throw Failure(message: "ffmpeg failed: \(tail.isEmpty ? "exit code \(process.terminationStatus)" : tail)")
            }
        } onCancel: {
            box.terminate()
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var started = false
        private var cancelled = false

        init(_ process: Process) { self.process = process }

        func markStarted() {
            lock.lock(); defer { lock.unlock() }
            started = true
            if cancelled { process.terminate() }
        }

        func terminate() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if started && process.isRunning { process.terminate() }
        }
    }
}

/// Resolves once a process has exited. Set as the process's termination
/// handler before it starts. Unlike waitUntilExit, it can't miss an exit that
/// happens while another thread is terminating the process.
final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fire() {
        lock.lock()
        fired = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Runs blocking work on a GCD thread so it never ties up the Swift
/// concurrency pool.
func blocking<T>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}
