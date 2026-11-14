/// An instant with millisecond precision, written as a UTC RFC 3339 timestamp with a `Z` offset
/// (`defs.json#/$defs/timestamp`). The fraction is omitted when it is zero, otherwise three digits.
public struct Timestamp: Hashable, Comparable, Sendable, CustomStringConvertible, JSONRepresentable {
    public let millisecondsSinceEpoch: Int64

    public init(millisecondsSinceEpoch: Int64) { self.millisecondsSinceEpoch = millisecondsSinceEpoch }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.millisecondsSinceEpoch < rhs.millisecondsSinceEpoch }

    public func adding(milliseconds: Int64) -> Timestamp {
        Timestamp(millisecondsSinceEpoch: millisecondsSinceEpoch + milliseconds)
    }

    public var description: String {
        let millisecondsPerDay: Int64 = 86_400_000
        let days = millisecondsSinceEpoch.floorDivided(by: millisecondsPerDay)
        let ofDay = millisecondsSinceEpoch - days * millisecondsPerDay
        let (year, month, day) = Self.civilDate(daysSinceEpoch: days)
        let seconds = ofDay / 1000
        var text = "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T"
        text += "\(pad(seconds / 3600, 2)):\(pad(seconds / 60 % 60, 2)):\(pad(seconds % 60, 2))"
        if ofDay % 1000 != 0 { text += ".\(pad(ofDay % 1000, 3))" }
        return text + "Z"
    }

    public var jsonValue: JSONValue { .string(description) }

    /// Howard Hinnant's `civil_from_days`: proleptic Gregorian date of a day count from 1970-01-01.
    private static func civilDate(daysSinceEpoch: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let shifted = daysSinceEpoch + 719_468
        let era = shifted.floorDivided(by: 146_097)
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

private func pad(_ value: Int64, _ width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
}

extension Int64 {
    fileprivate func floorDivided(by divisor: Int64) -> Int64 {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}
