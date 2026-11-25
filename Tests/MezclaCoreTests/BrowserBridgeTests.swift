import Darwin
import Foundation
import MezclaBridgeShared
import MezclaCore
import Testing

/// Collects messages sent to a message-based browser.
private final class Outbox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    func append(_ data: Data) { lock.withLock { storage.append(data) } }
    var messages: [Data] { lock.withLock { storage } }
}

/// Talks to a real `BrowserBridge` over a real Unix socket, the way mezcla-bridge does.
@Suite("BrowserBridge", .serialized)
struct BrowserBridgeTests {
    private let socketPath = FileManager.default.temporaryDirectory
        .appending(path: "mezcla-test-\(UUID().uuidString.prefix(8)).sock").path

    private func send(_ json: String, to descriptor: Int32) {
        BridgeSocket.writeAll(descriptor, Data((json + "\n").utf8))
    }

    private func nextSnapshot(_ iterator: inout AsyncStream<BrowserSnapshot>.Iterator, matching predicate: (BrowserSnapshot) -> Bool) async -> BrowserSnapshot? {
        while let snapshot = await iterator.next() {
            if predicate(snapshot) { return snapshot }
        }
        return nil
    }

    @Test func tabsReportedByABrowserAppearUnderThatBrowser() async throws {
        let bridge = BrowserBridge(socketPath: socketPath)
        await bridge.start()
        var snapshots = bridge.snapshots.makeAsyncIterator()

        let client = try #require(BridgeSocket.connect(to: socketPath))
        defer { close(client) }
        send(#"{"type":"hello","app":"net.imput.helium","browser":"Helium"}"#, to: client)
        send(#"{"type":"tabs","tabs":[{"id":7,"title":"Video A","url":"https://youtube.com/watch","icon":null,"audible":true,"muted":false,"level":0.4},{"id":9,"title":"Video B","url":null,"icon":"data:image/png;base64,iVBORw0KGgo=","audible":true,"muted":true,"level":1}]}"#, to: client)

        let snapshot = try #require(await nextSnapshot(&snapshots) { $0.tabs.count == 2 })
        #expect(snapshot.connectedApps == ["net.imput.helium"])
        let first = try #require(snapshot.tabs.first { $0.id.tabID == 7 })
        #expect(first.id.appID == "net.imput.helium")
        #expect(first.title == "Video A")
        #expect(first.level == 0.4)
        #expect(first.url?.host() == "youtube.com")
        let second = try #require(snapshot.tabs.first { $0.id.tabID == 9 })
        #expect(second.isMuted)
        #expect(second.favicon == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test func volumeChangesReachTheBrowserThatOwnsTheTab() async throws {
        let bridge = BrowserBridge(socketPath: socketPath)
        await bridge.start()
        var snapshots = bridge.snapshots.makeAsyncIterator()

        let client = try #require(BridgeSocket.connect(to: socketPath))
        defer { close(client) }
        send(#"{"type":"hello","app":"com.google.Chrome","browser":"Chrome"}"#, to: client)
        send(#"{"type":"tabs","tabs":[{"id":3,"title":"Music","url":null,"icon":null,"audible":true,"muted":false,"level":1}]}"#, to: client)
        _ = await nextSnapshot(&snapshots) { !$0.tabs.isEmpty }

        bridge.send(.setVolume(AppVolume(level: 0.25, isMuted: true), for: .init(appID: "com.google.Chrome", tabID: 3)))

        var buffer = [UInt8](repeating: 0, count: 1024)
        let received = read(client, &buffer, buffer.count)
        let line = try #require(String(bytes: buffer[..<max(received, 0)], encoding: .utf8))
        let message = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(message["type"] as? String == "set")
        #expect(message["tabId"] as? Int == 3)
        #expect(message["level"] as? Double == 0.25)
        #expect(message["gain"] as? Double == 0.0625) // Same square-law curve as app volumes.
        #expect(message["muted"] as? Bool == true)
    }

    @Test func disconnectingRemovesTheBrowsersTabs() async throws {
        let bridge = BrowserBridge(socketPath: socketPath)
        await bridge.start()
        var snapshots = bridge.snapshots.makeAsyncIterator()

        let client = try #require(BridgeSocket.connect(to: socketPath))
        send(#"{"type":"hello","app":"com.brave.Browser","browser":"Brave"}"#, to: client)
        send(#"{"type":"tabs","tabs":[{"id":1,"title":"Podcast","url":null,"icon":null,"audible":true,"muted":false,"level":1}]}"#, to: client)
        _ = await nextSnapshot(&snapshots) { !$0.tabs.isEmpty }

        close(client)
        let snapshot = try #require(await nextSnapshot(&snapshots) { $0.tabs.isEmpty })
        #expect(snapshot.connectedApps.isEmpty)
    }

    @Test func messageBasedBrowsersReportAndReceiveCommands() async throws {
        let bridge = BrowserBridge(socketPath: socketPath)
        await bridge.start()
        var snapshots = bridge.snapshots.makeAsyncIterator()
        let outbox = Outbox()
        await bridge.registerMessageBrowser("com.apple.Safari") { outbox.append($0) }

        let report = #"{"type":"tabs","tabs":[{"id":11,"title":"Podcast","url":"https://example.com","icon":null,"audible":true,"muted":false,"level":1}]}"#
        await bridge.receive(Data(report.utf8), fromMessageBrowser: "com.apple.Safari")
        let snapshot = try #require(await nextSnapshot(&snapshots) { !$0.tabs.isEmpty })
        #expect(snapshot.connectedApps == ["com.apple.Safari"])
        #expect(snapshot.tabs.first?.id == .init(appID: "com.apple.Safari", tabID: 11))

        bridge.send(.setVolume(AppVolume(level: 1.5), for: .init(appID: "com.apple.Safari", tabID: 11)))
        for _ in 0..<50 where outbox.messages.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = try #require(outbox.messages.first)
        let message = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(message["tabId"] as? Int == 11)
        #expect(message["level"] as? Double == 1.5)
        #expect(message["gain"] as? Double == 2.25)
    }

    @Test func linesSplitAcrossReadsAreReassembled() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data(#"{"a":"#.utf8)).isEmpty)
        let lines = buffer.append(Data("1}\n{\"b\":2}\n{\"c\"".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
    }
}
