import Foundation

enum HeaderValue {
    enum Fault: Error, Hashable {
        case missing
        case malformed
    }

    private static let encodedPrefix = Array("=?base64?".utf8)
    private static let encodedSuffix = Array("?=".utf8)

    static func decode(_ values: [String]) throws(Fault) -> String {
        guard let raw = values.first else { throw .missing }
        guard values.count == 1 else { throw .malformed }
        let bytes = Array(raw.utf8)
        if bytes.starts(with: encodedPrefix), bytes.count >= encodedPrefix.count + encodedSuffix.count,
            bytes.suffix(encodedSuffix.count).elementsEqual(encodedSuffix)
        {
            let payload = bytes[encodedPrefix.count..<(bytes.count - encodedSuffix.count)]
            guard let data = Data(base64Encoded: Data(payload)),
                let text = String(validating: Array(data), as: UTF8.self)
            else { throw .malformed }
            return text
        }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) || $0 == 0x09 }) else { throw .malformed }
        return raw
    }

    static func isDate(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-") else { return false }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10), (1...12).contains(month)
        else { return false }
        let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...days[month - 1]).contains(day)
    }
}
