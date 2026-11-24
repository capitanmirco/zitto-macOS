import Foundation
import ZittoCore

/// Starts the Python worker (zitto/worker.py) and follows it: the equivalent of jobs.py.
///
/// Being a process of its own, it can be stopped at any time, the app never loads torch, and the
/// GPU memory is free again when it ends.
enum WorkerProcess {
    enum Failure: LocalizedError {
        case noPython

        var errorDescription: String? {
            "The separation needs Python with zitto installed. Run macos/scripts/setup-worker.sh once."
        }
    }

    static func start(_ arguments: [String]) throws -> (Process, Pipe, Pipe) {
        guard let python = Paths.python else {
            throw Failure.noPython
        }
        let process = Process()
        process.executableURL = python
        // -P: do not import from the folder the program was started in.
        process.arguments = ["-P", "-m", "zitto.worker"] + arguments
        var environment = Paths.environment
        environment["ZITTO_LIBRARY"] = Paths.library.path
        environment["ZITTO_MODELS_DIR"] = Paths.models.path
        environment["ZITTO_SETTINGS"] = Paths.settings.path
        environment["PATH"] = Paths.searchPath
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"  // what the GPU of a Mac cannot do, the CPU does
        if let source = Paths.source {
            environment["PYTHONPATH"] = source
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        return (process, output, errors)
    }

    /// Calls `each` with every event the process prints, on a thread of its own; returns at the end.
    static func follow(_ pipe: Pipe, _ each: (WorkerEvent) -> Void) {
        var splitter = LineSplitter()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            for line in splitter.feed(chunk) {
                if let event = WorkerEvent.parse(line) { each(event) }
            }
        }
        if let rest = splitter.finish(), let event = WorkerEvent.parse(rest) {
            each(event)
        }
    }

    /// Runs a short command of the worker (--info, --link, --add) in the background and gives
    /// its last event on the main thread.
    static func ask(_ arguments: [String], fallback: WorkerEvent, answer: @escaping (WorkerEvent) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var last = fallback
            do {
                let (process, output, errors) = try start(arguments)
                DispatchQueue.global(qos: .utility).async { _ = errors.fileHandleForReading.readDataToEndOfFile() }
                follow(output) { last = $0 }
                process.waitUntilExit()
            } catch {
                last = .error(text: error.localizedDescription)
            }
            DispatchQueue.main.async { answer(last) }
        }
    }
}

/// The worker that prepares the waiting songs. Gives its events on the main thread; the last
/// one is `.ended`.
///
/// `run` changes at each start and stop: events with another number are late ones, to ignore.
final class Work {
    private var process: Process?
    private(set) var run = 0
    private let onEvent: (Int, WorkerEvent) -> Void

    init(onEvent: @escaping (Int, WorkerEvent) -> Void) {
        self.onEvent = onEvent
    }

    var running: Bool {
        process != nil
    }

    func start() throws {
        guard process == nil else {
            return
        }
        let workdir = FileManager.default.temporaryDirectory.appendingPathComponent("zitto_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        let (child, output, errors) = try WorkerProcess.start([workdir.path])
        process = child
        run += 1
        let run = self.run
        let send = onEvent

        Thread.detachNewThread {
            WorkerProcess.follow(output) { event in DispatchQueue.main.async { send(run, event) } }
            child.waitUntilExit()
            try? FileManager.default.removeItem(at: workdir)
            let code = child.terminationStatus
            DispatchQueue.main.async { send(run, .ended(code: code)) }
        }
        // Percentages from the progress bars that the libraries draw on stderr.
        Thread.detachNewThread {
            let handle = errors.fileHandleForReading
            var last: Int? = nil
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    break
                }
                if let percent = lastPercent(chunk), percent != last {
                    last = percent
                    DispatchQueue.main.async { send(run, .progress(percent: percent)) }
                }
            }
        }
    }

    /// To be called when the `.ended` event is handled: from here it can start again.
    func ended() {
        process = nil
    }

    func stop() {
        let child = process
        process = nil
        run += 1
        if let child, child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
        }
    }
}
