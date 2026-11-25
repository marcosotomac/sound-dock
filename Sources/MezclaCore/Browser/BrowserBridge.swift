import Darwin
import Dispatch
public import Foundation
import MezclaBridgeShared
import os

public enum BrowserCommand: Sendable {
    case setVolume(AppVolume, for: BrowserTab.ID)
}

/// Accepts connections from browser bridges and keeps the list of tabs that make sound.
///
/// Browsers mix all their tabs into one audio stream before it reaches macOS, so per-tab volume has
/// to be applied inside the browser. The extension does that; this server is Mezcla's side of the link.
/// Like `MixerEngine`, it is an actor running on its own queue, and dispatch sources deliver socket
/// events on that queue, so they are already isolated.
public actor BrowserBridge {
    public nonisolated let snapshots: AsyncStream<BrowserSnapshot>

    private nonisolated let queue = DispatchSerialQueue(label: "dev.mezcla.browser-bridge", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private nonisolated let commandSink: AsyncStream<BrowserCommand>.Continuation
    private nonisolated let snapshotSink: AsyncStream<BrowserSnapshot>.Continuation
    private let commands: AsyncStream<BrowserCommand>

    private static let log = Logger(subsystem: "dev.mezcla", category: "browser-bridge")
    private let socketPath: String
    private var listener: Int32 = -1
    private var acceptSource: (any DispatchSourceRead)?
    private var connections: [ObjectIdentifier: BrowserConnection] = [:]
    private var messageBrowsers: [AppID: MessageBrowser] = [:]
    private var messageSenders: [AppID: @Sendable (Data) -> Void] = [:]
    private var expiryTask: Task<Void, Never>?
    /// A message-based browser that stops reporting (quit, extension disabled) is dropped after this.
    public static let messageBrowserTimeout: Duration = .seconds(45)
    private var commandTask: Task<Void, Never>?
    private var lastSnapshot = BrowserSnapshot.empty

    /// - Parameter socketPath: Where to listen; defaults to the path mezcla-bridge connects to.
    public init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? BridgeSocket.url.path
        (commands, commandSink) = AsyncStream.makeStream(of: BrowserCommand.self)
        (snapshots, snapshotSink) = AsyncStream.makeStream(of: BrowserSnapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        commandSink.finish()
        snapshotSink.finish()
    }

    public nonisolated func send(_ command: BrowserCommand) {
        commandSink.yield(command)
    }

    public func start() {
        guard listener < 0 else { return }
        do {
            listener = try BridgeSocket.listen(at: socketPath)
        } catch {
            Self.log.error("Browser bridge unavailable: \(error.description, privacy: .public)")
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.acceptConnections() }
        }
        source.resume()
        acceptSource = source

        commandTask = Task { [commands] in
            for await command in commands {
                handle(command)
            }
        }
    }

    // MARK: - Message-based browsers

    /// Registers a browser that talks through discrete messages instead of the socket (Safari).
    /// `send` delivers commands to its extension.
    public func registerMessageBrowser(_ appID: AppID, send: @escaping @Sendable (Data) -> Void) {
        messageSenders[appID] = send
    }

    /// Handles one message from a message-based browser, in the same JSON format as the socket.
    public func receive(_ message: Data, fromMessageBrowser appID: AppID) {
        guard let decoded = try? JSONDecoder().decode(BrowserBridgeMessage.Inbound.self, from: message) else { return }
        var browser = messageBrowsers[appID] ?? MessageBrowser(tabs: [], lastSeen: .now)
        browser.lastSeen = .now
        if decoded.type == "tabs" {
            browser.tabs = Self.tabs(from: decoded.tabs ?? [], appID: appID)
        }
        messageBrowsers[appID] = browser
        publish()
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let oldest = messageBrowsers.values.map(\.lastSeen).min() else { return }
        expiryTask = Task {
            try? await Task.sleep(until: oldest + Self.messageBrowserTimeout, clock: .continuous)
            guard !Task.isCancelled else { return }
            messageBrowsers = messageBrowsers.filter { .now - $0.value.lastSeen < Self.messageBrowserTimeout }
            publish()
            scheduleExpiry()
        }
    }

    // MARK: - Connections

    private func acceptConnections() {
        while true {
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { return } // EAGAIN: nothing more pending.
            BridgeSocket.configureConnection(descriptor)

            let connection = BrowserConnection(descriptor: descriptor, queue: queue)
            let key = ObjectIdentifier(connection)
            connection.onLines = { [weak self] lines in
                self?.assumeIsolated { $0.receive(lines, from: key) }
            }
            connection.onClose = { [weak self] in
                self?.assumeIsolated { $0.close(key) }
            }
            connections[key] = connection
            connection.resume()
        }
    }

    private func close(_ key: ObjectIdentifier) {
        connections[key]?.cancel()
        connections[key] = nil
        publish()
    }

    private func receive(_ lines: [Data], from key: ObjectIdentifier) {
        guard let connection = connections[key] else { return }
        let decoder = JSONDecoder()
        for line in lines {
            guard let message = try? decoder.decode(BrowserBridgeMessage.Inbound.self, from: line) else { continue }
            switch message.type {
            case "hello":
                connection.appID = message.app.map { AppID(rawValue: $0) }
            case "tabs":
                guard let appID = connection.appID else { continue }
                connection.tabs = Self.tabs(from: message.tabs ?? [], appID: appID)
            default:
                continue
            }
        }
        publish()
    }

    private func handle(_ command: BrowserCommand) {
        switch command {
        case let .setVolume(volume, id):
            let level = min(max(volume.level, 0), AppVolume.maximumBoostLevel)
            let message = BrowserBridgeMessage.SetVolume(
                tabId: id.tabID, level: level, gain: Double(VolumeCurve.gain(forLevel: level)), muted: volume.isMuted
            )
            guard let data = try? JSONEncoder().encode(message) else { return }
            if let connection = connections.values.first(where: { $0.appID == id.appID }) {
                connection.write(data + [0x0A])
            } else {
                messageSenders[id.appID]?(data)
            }
        }
    }

    private static func tabs(from wire: [BrowserBridgeMessage.Tab], appID: AppID) -> [BrowserTab] {
        wire.map { tab in
            BrowserTab(
                id: .init(appID: appID, tabID: tab.id),
                title: tab.title,
                url: tab.url.flatMap(URL.init(string:)),
                favicon: BrowserBridgeMessage.favicon(fromDataURL: tab.icon),
                isAudible: tab.audible,
                isMuted: tab.muted,
                level: min(max(tab.level, 0), AppVolume.maximumBoostLevel)
            )
        }
    }

    private func publish() {
        let connected = connections.values.filter { $0.appID != nil }
        let snapshot = BrowserSnapshot(
            connectedApps: Set(connected.compactMap(\.appID)).union(messageBrowsers.keys),
            tabs: connected.flatMap(\.tabs) + messageBrowsers.values.flatMap(\.tabs)
        )
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        snapshotSink.yield(snapshot)
    }
}

/// A browser that reports through discrete messages; considered gone once it stops reporting.
private struct MessageBrowser {
    var tabs: [BrowserTab]
    var lastSeen: ContinuousClock.Instant
}

/// One browser's bridge connection.
private final class BrowserConnection {
    var appID: AppID?
    var tabs: [BrowserTab] = []
    var onLines: (([Data]) -> Void)?
    var onClose: (() -> Void)?

    private let descriptor: Int32
    private let source: any DispatchSourceRead
    private var lines = LineBuffer()

    init(descriptor: Int32, queue: DispatchQueue) {
        self.descriptor = descriptor
        self.source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
    }

    func resume() {
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    func write(_ data: Data) {
        if !BridgeSocket.writeAll(descriptor, data) {
            onClose?()
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let received = read(descriptor, &chunk, chunk.count)
        guard received > 0 else {
            if received == 0 || (errno != EINTR && errno != EAGAIN) {
                onClose?()
            }
            return
        }
        let complete = lines.append(Data(chunk[..<received]))
        if !complete.isEmpty {
            onLines?(complete)
        }
    }
}
