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

/// A UTC instant read from the wire form of a timestamp: `YYYY-MM-DDTHH:MM:SS`, an optional
/// fraction of 1 to 9 digits, and a literal `Z`. Only a real instant parses: no month 13, no
/// hour 24, no February 30, no leap second, and no offset other than `Z`.
///
/// Shared by every reader of timestamps (the action log, the allowance file), so the rule lives
/// in one place.
struct UTCInstant: Hashable, Comparable, Sendable {
    let secondsSinceEpoch: Int64
    /// `0..<1_000_000_000`.
    let nanoseconds: Int64

    init?(rfc3339 text: String) {
        let utf8 = Array(text.utf8)
        guard (20...30).contains(utf8.count), utf8.last == UInt8(ascii: "Z") else { return nil }
        let separators: [(Int, UInt8)] = [
            (4, UInt8(ascii: "-")), (7, UInt8(ascii: "-")), (10, UInt8(ascii: "T")), (13, UInt8(ascii: ":")),
            (16, UInt8(ascii: ":")),
        ]
        guard separators.allSatisfy({ utf8[$0.0] == $0.1 }) else { return nil }
        func number(_ range: Range<Int>) -> Int64? {
            guard utf8[range].allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
            return utf8[range].reduce(0) { $0 * 10 + Int64($1 - UInt8(ascii: "0")) }
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
            let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
            (1...12).contains(month), (1...Self.daysIn(month: month, year: year)).contains(day),
            hour < 24, minute < 60, second < 60
        else { return nil }
        var nanoseconds: Int64 = 0
        if utf8.count > 20 {
            let fractionEnd = utf8.count - 1
            guard utf8[19] == UInt8(ascii: "."), fractionEnd > 20, let fraction = number(20..<fractionEnd) else {
                return nil
            }
            nanoseconds = fraction * Self.powerOfTen(9 - (fractionEnd - 20))
        } else if utf8[19] != UInt8(ascii: "Z") {
            return nil
        }
        let days = Self.daysSinceEpoch(year: year, month: month, day: day)
        self.secondsSinceEpoch = days * 86_400 + hour * 3600 + minute * 60 + second
        self.nanoseconds = nanoseconds
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.secondsSinceEpoch, lhs.nanoseconds) < (rhs.secondsSinceEpoch, rhs.nanoseconds)
    }

    /// The earliest whole millisecond not before this instant. For a clock that counts whole
    /// milliseconds, `now < instant` and `now >= instant` give the same answers against it as
    /// against the exact instant.
    var timestampRoundedUp: Timestamp {
        let wholeMilliseconds = nanoseconds / 1_000_000
        let carry: Int64 = nanoseconds % 1_000_000 == 0 ? 0 : 1
        return Timestamp(millisecondsSinceEpoch: secondsSinceEpoch * 1000 + wholeMilliseconds + carry)
    }

    /// Whether the instant falls on a whole millisecond.
    var isWholeMillisecond: Bool { nanoseconds % 1_000_000 == 0 }

    private static func daysIn(month: Int64, year: Int64) -> Int64 {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    private static func powerOfTen(_ exponent: Int) -> Int64 {
        (0..<exponent).reduce(1) { result, _ in result * 10 }
    }

    /// Howard Hinnant's `days_from_civil`: the inverse of ``Timestamp``'s `civil_from_days`.
    private static func daysSinceEpoch(year: Int64, month: Int64, day: Int64) -> Int64 {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
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
