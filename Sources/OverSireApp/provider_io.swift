import Foundation
import OverSireCore
import OverSireSync

// The real I/O behind the adapters: URLSession, Process and the Keychain.

/// One log line for each HTTP request and each command. A success that only reads is verbose: Debug detail keeps it.
/// No headers, no bodies, no URL query, no stdin.
struct IOLog {
    var sink: any LogSink = AppLog()

    func request(_ r: URLRequest, status: Int?, ms: Int, body: Data? = nil, error: String? = nil) {
        let method = r.httpMethod ?? "GET"
        let path = r.url.map { $0.path.isEmpty ? "/" : $0.path } ?? "?"
        let failed = error != nil || (status ?? 0) >= 400
        var msg = [method, path, status.map(String.init)].compactMap { $0 }.joined(separator: " ")
        if let id = r.value(forHTTPHeaderField: DaemonClient.requestID) { msg += " id=\(id)" }
        if let error {
            msg += ": " + error
        } else if failed, let body, !body.isEmpty {
            msg += ": " + Self.excerpt(String(decoding: body.prefix(1024), as: UTF8.self))
        }
        let host = r.url.map { u in (u.host ?? "") + (u.port.map { ":\($0)" } ?? "") }
        var e = LogEntry(level: failed ? .warn : .ok, area: .net, job: "HTTP", host: host, message: msg, ms: ms)
        e.verbose = !failed && method == "GET"
        sink.write(e)
    }

    func command(_ exe: String, _ args: [String], status: Int32?, ms: Int, stderr: String = "", error: String? = nil) {
        let name = (exe as NSString).lastPathComponent
        let shown = args.prefix(12).map { $0.count > 80 ? $0.prefix(77) + "…" : $0 } + (args.count > 12 ? ["…"] : [])
        let failed = error != nil || status != 0
        var msg = ([name] + shown).joined(separator: " ")
        if let error { msg += ": " + error } else if let status, status != 0 { msg += ": exit \(status)" }
        var e = LogEntry(level: failed ? .warn : .ok, area: .cmd, job: name, message: msg, ms: ms)
        e.exit = status.map(Int.init)
        if failed, !stderr.isEmpty { e.outputTail = String(stderr.suffix(300)) }
        e.verbose = !failed
        sink.write(e)
    }

    static func excerpt(_ s: String, _ n: Int = 300) -> String {
        let one = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return one.count > n ? one.prefix(n - 1) + "…" : one
    }

    static func ms(since t0: Date) -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    var log = IOLog()

    init(session: URLSession = .shared) { self.session = session }

    /// The caller sees each redirect. A token then does not go to an other host.
    static let noRedirects = URLSessionTransport(session: URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil))

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let t0 = Date()
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: request) } catch {
            log.request(request, status: nil, ms: IOLog.ms(since: t0), error: error.localizedDescription)
            throw ProviderError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw ProviderError.transport("No HTTP answer") }
        log.request(request, status: http.statusCode, ms: IOLog.ms(since: t0), body: data)
        return (data, http)
    }
}

extension URLSessionTransport: HTTPStreaming {
    /// Yields at each line end, so SSE events arrive without delay. The end of the read cancels the request.
    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let t0 = Date()
        let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, resp) = try await session.bytes(for: request) } catch {
            log.request(request, status: nil, ms: IOLog.ms(since: t0), error: error.localizedDescription)
            throw ProviderError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw ProviderError.transport("No HTTP answer") }
        log.request(request, status: http.statusCode, ms: IOLog.ms(since: t0))
        let stream = AsyncThrowingStream<Data, Error> { cont in
            let task = Task {
                var buf = Data()
                do {
                    for try await b in bytes {
                        buf.append(b)
                        if b == 0x0A || buf.count >= 16_384 {
                            cont.yield(buf)
                            buf.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buf.isEmpty { cont.yield(buf) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: Task.isCancelled ? CancellationError() : ProviderError.transport(error.localizedDescription))
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

struct ProcessRunner: CommandRunner {
    let environment: [String: String]?   // nil keeps the environment of the app
    var log = IOLog()

    init(environment: [String: String]? = nil) { self.environment = environment }

    func run(_ exe: String, _ args: [String], stdin: Data?, timeout: Duration) async throws -> CommandOutput {
        let secs = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let child = Child()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(with: Result { try runSync(exe, args, stdin: stdin, timeout: secs, child: child) })
                }
            }
        } onCancel: {
            child.cancel()
        }
    }

    /// The process of one run. A task cancel stops it.
    final class Child: @unchecked Sendable {
        private let lock = NSLock()
        private var proc: Process?
        private(set) var cancelled = false

        func cancel() {
            let p: Process? = lock.withLock {
                cancelled = true
                return proc
            }
            if let p { ProcessRunner.stop(p) }
        }

        /// False when the task was cancelled before the start.
        func attach(_ p: Process) -> Bool {
            lock.withLock {
                proc = p
                return !cancelled
            }
        }
    }

    /// Terminates the process, and kills it 1 s later.
    static func stop(_ proc: Process) {
        guard proc.isRunning else { return }
        proc.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
    }

    // Blocks the caller. Stops the process after the timeout.
    func runSync(_ exe: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval? = nil, child: Child? = nil) throws -> CommandOutput {
        if child?.cancelled == true { throw CancellationError() }
        let t0 = Date()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        if let environment { proc.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let inPipe = stdin.map { _ in Pipe() }
        if let inPipe { proc.standardInput = inPipe } else { proc.standardInput = FileHandle.nullDevice }
        do { try proc.run() } catch {
            log.command(exe, args, status: nil, ms: IOLog.ms(since: t0), error: error.localizedDescription)
            throw error
        }
        if let child, !child.attach(proc) { ProcessRunner.stop(proc) }
        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { ProcessRunner.stop(proc) }
        }
        // Read both pipes before the wait. A child that fills a 64 KB pipe buffer blocks waitUntilExit.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        proc.waitUntilExit()
        if child?.cancelled == true { throw CancellationError() }
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log.command(exe, args, status: proc.terminationStatus, ms: IOLog.ms(since: t0), stderr: err)
        return CommandOutput(status: proc.terminationStatus, stdout: outData, stderr: err)
    }
}

/// Plane tokens keep their old Keychain service. The secrets of other accounts share one service.
struct KeychainSecrets: SecretReader {
    func store(_ key: String) -> SecretStore {
        SecretStore(service: key.hasPrefix("PLANE_TOKEN_") ? "com.oversire.app.plane" : "com.oversire.app.accounts")
    }

    func secret(_ key: String) -> String? { store(key).get(key) }
    func set(_ key: String, _ value: String) { store(key).set(key, value) }
    func delete(_ key: String) { store(key).delete(key) }
}

/// The cloud socket over URLSessionWebSocketTask.
struct URLSessionWebSockets: WebSocketConnecting {
    var log = IOLog()

    func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        let t0 = Date()
        let socket = URLSessionWebSocket(task: URLSession.shared.webSocketTask(with: request))
        socket.task.resume()
        // A ping waits for the handshake, so a bad token fails here.
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                socket.task.sendPing { e in e.map { c.resume(throwing: socket.mapped($0)) } ?? c.resume() }
            }
        } catch {
            log.request(request, status: (socket.task.response as? HTTPURLResponse)?.statusCode, ms: IOLog.ms(since: t0), error: "\(error)")
            throw error
        }
        log.request(request, status: (socket.task.response as? HTTPURLResponse)?.statusCode ?? 101, ms: IOLog.ms(since: t0))
        return socket
    }
}

final class URLSessionWebSocket: WebSocketConnection, @unchecked Sendable {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) { self.task = task }

    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let s): return s
            case .data(let d): return String(decoding: d, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            throw mapped(error)
        }
    }

    func send(_ text: String) async throws {
        do { try await task.send(.string(text)) } catch { throw mapped(error) }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }

    // 4001: the cloud removed this Mac.
    func mapped(_ error: Error) -> ProviderError {
        if task.closeCode.rawValue == 4001 || (task.response as? HTTPURLResponse)?.statusCode == 401 { return .unauthorized }
        return .transport(error.localizedDescription)
    }
}
