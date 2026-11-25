import Darwin
import Foundation
import MezclaBridgeShared

// mezcla-bridge: the native messaging host a Chromium browser launches for the Mezcla extension.
//
// It relays messages between the extension (stdin/stdout, 32-bit length + JSON, per Chrome's native
// messaging protocol) and the Mezcla app (Unix socket, one JSON object per line). It tells Mezcla which
// browser it serves, so tabs appear under the right app. It stays alive while the browser keeps the
// port open and reconnects on its own when Mezcla starts later.

private let browser = BrowserIdentity.ofParentProcess()
private let output = NativeMessageWriter()
private let link = AppLink(socketPath: BridgeSocket.url.path, browser: browser, output: output)

link.start()

// The browser closes stdin when the extension disconnects; that is our cue to exit.
while let message = NativeMessageReader.next() {
    link.forward(message)
}
exit(0)

// MARK: - Browser identity

private struct BrowserIdentity {
    let bundleID: String
    let name: String

    /// The browser that launched us. Helpers and the main app share the outermost `.app`.
    static func ofParentProcess() -> BrowserIdentity {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return BrowserIdentity(bundleID: "unknown", name: "Browser") }
        let executable = String(decoding: buffer[..<Int(length)], as: UTF8.self)
        guard let range = executable.range(of: ".app/") else {
            return BrowserIdentity(bundleID: "exe:" + executable, name: (executable as NSString).lastPathComponent)
        }
        let appPath = String(executable[..<range.lowerBound]) + ".app"
        let name = FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
        return BrowserIdentity(bundleID: Bundle(path: appPath)?.bundleIdentifier ?? "exe:" + executable, name: name)
    }

    var helloMessage: Data {
        (try? JSONSerialization.data(withJSONObject: ["type": "hello", "app": bundleID, "browser": name])) ?? Data()
    }
}

// MARK: - Native messaging framing

private enum NativeMessageReader {
    /// Reads one message from stdin; `nil` at end of input.
    static func next() -> Data? {
        guard let header = read(count: 4) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard length > 0, length <= 64 << 20 else { return nil }
        return read(count: Int(length))
    }

    private static func read(count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress! + offset, count - offset) }
            if received > 0 {
                offset += received
            } else if received < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return data
    }
}

private final class NativeMessageWriter: @unchecked Sendable {
    private let lock = NSLock()
    private static let maximumLength = 1 << 20 // Chrome's limit for host → extension messages.

    func write(_ message: Data) {
        guard !message.isEmpty, message.count <= Self.maximumLength else { return }
        var length = UInt32(message.count)
        var frame = Data(bytes: &length, count: 4)
        frame.append(message)
        lock.withLock { _ = BridgeSocket.writeAll(STDOUT_FILENO, frame) }
    }
}

// MARK: - Link to Mezcla

/// Keeps one connection to Mezcla, re-establishing it whenever Mezcla quits or relaunches.
private final class AppLink: @unchecked Sendable {
    private let socketPath: String
    private let browser: BrowserIdentity
    private let output: NativeMessageWriter
    private let lock = NSLock()
    private var descriptor: Int32 = -1 // Guarded by `lock`.
    private var lastTabs: Data? // Guarded by `lock`; replayed after reconnecting.

    init(socketPath: String, browser: BrowserIdentity, output: NativeMessageWriter) {
        self.socketPath = socketPath
        self.browser = browser
        self.output = output
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                guard let connection = BridgeSocket.connect(to: socketPath) else {
                    Thread.sleep(forTimeInterval: 2)
                    continue
                }
                attach(connection)
                relayFromApp(connection)
                detach(connection)
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    /// Extension → Mezcla.
    func forward(_ message: Data) {
        lock.withLock {
            if isTabsMessage(message) {
                lastTabs = message
            }
            if descriptor >= 0 {
                BridgeSocket.writeAll(descriptor, message + [0x0A])
            }
        }
    }

    private func attach(_ connection: Int32) {
        lock.withLock {
            descriptor = connection
            BridgeSocket.writeAll(connection, browser.helloMessage + [0x0A])
            if let lastTabs {
                BridgeSocket.writeAll(connection, lastTabs + [0x0A])
            }
        }
        output.write(Data(#"{"type":"refresh"}"#.utf8)) // Ask the extension for a fresh report.
    }

    private func detach(_ connection: Int32) {
        lock.withLock {
            close(connection)
            descriptor = -1
        }
    }

    /// Mezcla → extension, until the connection closes.
    private func relayFromApp(_ connection: Int32) {
        var lines = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let received = read(connection, &chunk, chunk.count)
            if received > 0 {
                lines.append(Data(chunk[..<received])).forEach(output.write)
            } else if received < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func isTabsMessage(_ message: Data) -> Bool {
        let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any]
        return object?["type"] as? String == "tabs"
    }
}
