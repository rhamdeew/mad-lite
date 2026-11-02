import Foundation

public enum HexFormatter {
    public static func offset(_ value: Int, digits: Int = 5) -> String {
        let hex = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, digits - hex.count)) + hex
    }

    public static func byte(_ value: UInt8) -> String {
        let hex = String(value, radix: 16, uppercase: true)
        return hex.count == 1 ? "0" + hex : hex
    }

    /// Printable ASCII for the hex dump's text column; other bytes become ".".
    public static func asciiChar(_ value: UInt8) -> Character {
        (0x20...0x7E).contains(value) ? Character(UnicodeScalar(value)) : "."
    }

    /// Parses "6020", "0x6020" or "$6020" as hex.
    public static func parseOffset(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) } else if s.hasPrefix("$") { s.removeFirst() }
        return Int(s, radix: 16)
    }
}
