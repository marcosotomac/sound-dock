/// Stable identity of an app across launches: its bundle identifier, or `exe:<path>` for command-line tools.
public struct AppID: RawRepresentable, Hashable, Comparable, Codable, CodingKeyRepresentable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static func < (lhs: AppID, rhs: AppID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { rawValue }
}
