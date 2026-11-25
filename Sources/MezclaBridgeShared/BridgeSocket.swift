import Darwin
public import Foundation

/// The private channel between Mezcla and its browser bridge: a Unix domain socket in the user's
/// Application Support folder, readable only by the user, carrying one JSON object per line.
public enum BridgeSocket {
    public struct Failure: Error, CustomStringConvertible {
        public let operation: String
        public let code: Int32

        public var description: String {
            "\(operation): \(String(cString: strerror(code)))"
        }
    }

    /// `~/Library/Application Support/Mezcla/bridge.sock`
    public static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Mezcla", directoryHint: .isDirectory).appending(path: "bridge.sock")
    }

    /// Creates a listening socket at `path`, replacing a stale one. Only the current user can connect.
    public static func listen(at path: String) throws(Failure) -> Int32 {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)

        let descriptor = try makeSocket()
        var address = try makeAddress(path)
        let bound = withSockaddr(&address) { bind(descriptor, $0, $1) }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 8) == 0 else {
            let failure = Failure(operation: "listen on \(path)", code: errno)
            close(descriptor)
            throw failure
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        return descriptor
    }

    /// Connects to the socket at `path`. Blocking; returns `nil` when nobody is listening.
    public static func connect(to path: String) -> Int32? {
        guard let descriptor = try? makeSocket(), var address = try? makeAddress(path) else { return nil }
        guard withSockaddr(&address, { Darwin.connect(descriptor, $0, $1) }) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Prepares an accepted connection: no SIGPIPE when the peer vanishes, closed across exec.
    public static func configureConnection(_ descriptor: Int32) {
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    /// Writes every byte, retrying on interruption. Returns `false` once the peer is gone.
    @discardableResult
    public static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    // MARK: Helpers

    private static func makeSocket() throws(Failure) -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(operation: "socket", code: errno) }
        configureConnection(descriptor)
        return descriptor
    }

    private static func makeAddress(_ path: String) throws(Failure) -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure(operation: "socket path too long", code: ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
            destination[bytes.count] = 0
        }
        return address
    }

    private static func withSockaddr<Result>(
        _ address: inout sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) -> Result {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}

/// Splits a byte stream into newline-terminated messages.
public struct LineBuffer {
    /// Protects against a peer that never sends a newline.
    public static let maximumLineLength = 4 << 20

    private var pending = Data()

    public init() {}

    /// Appends bytes and returns the complete lines they finish, without their newlines.
    public mutating func append(_ bytes: Data) -> [Data] {
        pending.append(bytes)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            pending.removeSubrange(pending.startIndex...newline)
        }
        if pending.count > Self.maximumLineLength {
            pending.removeAll()
        }
        return lines
    }
}
