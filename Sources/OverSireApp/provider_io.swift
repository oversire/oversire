import Foundation
import OverSireCore
import OverSireSync

// The real I/O behind the adapters: URLSession, Process and the Keychain.

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    /// The caller sees each redirect. A token then does not go to an other host.
    static let noRedirects = URLSessionTransport(session: URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil))

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: request) } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw ProviderError.transport("No HTTP answer") }
        return (data, http)
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

struct ProcessRunner: CommandRunner {
    let environment: [String: String]?   // nil keeps the environment of the app

    init(environment: [String: String]? = nil) { self.environment = environment }

    func run(_ exe: String, _ args: [String], stdin: Data?, timeout: Duration) async throws -> CommandOutput {
        let secs = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(with: Result { try runSync(exe, args, stdin: stdin, timeout: secs) })
            }
        }
    }

    // Blocks the caller. Terminates the process after the timeout, and kills it 1 s later.
    func runSync(_ exe: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval? = nil) throws -> CommandOutput {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        if let environment { proc.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let inPipe = stdin.map { _ in Pipe() }
        if let inPipe { proc.standardInput = inPipe } else { proc.standardInput = FileHandle.nullDevice }
        try proc.run()
        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard proc.isRunning else { return }
                proc.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                }
            }
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
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CommandOutput(status: proc.terminationStatus, stdout: outData, stderr: err)
    }
}

struct KeychainSecrets: SecretReader {
    let service: String

    func secret(_ key: String) -> String? { SecretStore(service: service).get(key) }
}

/// The cloud socket over URLSessionWebSocketTask.
struct URLSessionWebSockets: WebSocketConnecting {
    func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        let socket = URLSessionWebSocket(task: URLSession.shared.webSocketTask(with: request))
        socket.task.resume()
        // A ping waits for the handshake, so a bad token fails here.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            socket.task.sendPing { e in e.map { c.resume(throwing: socket.mapped($0)) } ?? c.resume() }
        }
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
