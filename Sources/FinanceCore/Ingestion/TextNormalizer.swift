import Foundation

public enum TextNormalizer {
    private static let digitMap: [Character: Character] = {
        var m: [Character: Character] = [:]
        let arabicIndic = Array("٠١٢٣٤٥٦٧٨٩")
        let persian = Array("۰۱۲۳۴۵۶۷۸۹")
        for i in 0..<10 {
            let d = Character(String(i))
            m[arabicIndic[i]] = d
            m[persian[i]] = d
        }
        m["٫"] = "."   // Arabic decimal separator
        m["٬"] = ","   // Arabic thousands separator
        m["،"] = ","   // Arabic comma
        return m
    }()

    /// Converts Arabic-Indic digits and separators to ASCII; strips bidi control marks.
    public static func normalizeDigits(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for ch in s {
            if let mapped = digitMap[ch] { out.append(mapped); continue }
            if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
               (0x200E...0x200F).contains(scalar.value) || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) || scalar.value == 0x061C {
                continue
            }
            out.append(ch)
        }
        return out
    }

    /// Parses "1,234.50", "1234.5", "1 234,50"-free inputs into Decimal. Returns nil on failure.
    public static func parseAmount(_ raw: String) -> Decimal? {
        var s = normalizeDigits(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: ",", with: "")
        s = s.replacingOccurrences(of: " ", with: "")
        s = s.replacingOccurrences(of: "\u{00A0}", with: "")
        var negative = false
        if s.hasPrefix("-") { negative = true; s.removeFirst() }
        if s.hasPrefix("(") && s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              s.filter({ $0 == "." }).count <= 1 else { return nil }
        guard let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return negative ? -d : d
    }

    /// Stable merchant key: lowercase, ASCII digits, no punctuation, no store numbers / city suffixes.
    public static func merchantKey(_ raw: String) -> String {
        var s = normalizeDigits(raw).lowercased()
        // Common acquirer prefixes
        for prefix in ["sq *", "sq*", "pos ", "pos*", "apl*", "apple pay ", "paypal *", "pp*"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        let allowed = CharacterSet.letters.union(.whitespaces)
        s = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        // Drop generic location / legal tokens
        let stop: Set<String> = ["ksa", "sa", "saudi", "arabia", "riyadh", "jeddah", "dammam", "khobar", "makkah",
                                 "madinah", "co", "ltd", "llc", "est", "company", "branch", "store", "the",
                                 "الرياض", "جدة", "الدمام", "الخبر", "مكة", "المدينة", "شركة", "مؤسسة", "فرع"]
        let tokens = s.split(separator: " ").map(String.init).filter { !$0.isEmpty && !stop.contains($0) }
        return tokens.joined(separator: " ")
    }

    /// Token-set similarity in 0…1.
    public static func similarity(_ a: String?, _ b: String?) -> Double {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return 0 }
        let ka = merchantKey(a), kb = merchantKey(b)
        if ka == kb { return 1 }
        if ka.contains(kb) || kb.contains(ka) { return 0.85 }
        let ta = Set(ka.split(separator: " ")), tb = Set(kb.split(separator: " "))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }

    public static func titleCaseMerchant(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // Keep Arabic as-is; title-case Latin all-caps names.
        if trimmed.unicodeScalars.contains(where: { $0.value >= 0x0600 && $0.value <= 0x06FF }) { return trimmed }
        if trimmed == trimmed.uppercased() { return trimmed.capitalized }
        return trimmed
    }
}

/// Parses dates from bank messages and statements in the Riyadh time zone.
public struct DateParser: Sendable {
    public let timeZone: TimeZone

    public init(timeZone: TimeZone) { self.timeZone = timeZone }

    private static let datePatterns: [(regex: String, order: [Character])] = [
        (#"(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})"#, ["y", "m", "d"]),
        (#"(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})"#, ["d", "m", "y"]),
        (#"(\d{1,2})[-/.](\d{1,2})[-/.](\d{2})(?!\d)"#, ["d", "m", "y"])
    ]

    /// Returns (date, hasTime). Two-digit years are 20yy. Ambiguous yy/mm/dd is not supported on purpose.
    public func parse(_ text: String) -> (Date, Bool)? {
        let s = TextNormalizer.normalizeDigits(text)
        var comps = DateComponents()
        comps.timeZone = timeZone
        var found = false
        var dateEnd: String.Index?
        for p in Self.datePatterns {
            guard let re = try? NSRegularExpression(pattern: p.regex),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            var vals: [Character: Int] = [:]
            for (i, key) in p.order.enumerated() {
                guard let r = Range(m.range(at: i + 1), in: s), let v = Int(s[r]) else { continue }
                vals[key] = v
            }
            guard var y = vals["y"], let mo = vals["m"], let d = vals["d"], (1...12).contains(mo), (1...31).contains(d) else { continue }
            if y < 100 { y += 2000 }
            comps.year = y; comps.month = mo; comps.day = d
            found = true
            dateEnd = Range(m.range, in: s)?.upperBound
            break
        }
        // Month-name formats, e.g. "12 Jan 2025" / "12-JAN-25"
        if !found, let re = try? NSRegularExpression(pattern: #"(\d{1,2})[\s-]([A-Za-z]{3})[A-Za-z]*[\s-,]*(\d{2,4})"#),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let dR = Range(m.range(at: 1), in: s), let monR = Range(m.range(at: 2), in: s), let yR = Range(m.range(at: 3), in: s) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            if let mi = months.firstIndex(of: s[monR].lowercased()), let d = Int(s[dR]), var y = Int(s[yR]) {
                if y < 100 { y += 2000 }
                comps.year = y; comps.month = mi + 1; comps.day = d
                found = true
                dateEnd = Range(m.range, in: s)?.upperBound
            }
        }
        guard found else { return nil }
        var hasTime = false
        let tail = dateEnd.map { String(s[$0...]) } ?? s
        let timeRe = try! NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm|AM|PM|ص|م)?"#)
        for src in [tail, s] {
            guard let m = timeRe.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)),
                  let hR = Range(m.range(at: 1), in: src), let miR = Range(m.range(at: 2), in: src),
                  var h = Int(src[hR]), let mi = Int(src[miR]), h < 24, mi < 60 else { continue }
            if let apR = Range(m.range(at: 4), in: src) {
                let ap = src[apR].lowercased()
                if (ap == "pm" || ap == "م") && h < 12 { h += 12 }
                if (ap == "am" || ap == "ص") && h == 12 { h = 0 }
            }
            comps.hour = h; comps.minute = mi
            if let sR = Range(m.range(at: 3), in: src), let sec = Int(src[sR]) { comps.second = sec }
            hasTime = true
            break
        }
        if !hasTime { comps.hour = 12 } // date-only: anchor at noon to avoid TZ day shifts
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard let date = cal.date(from: comps) else { return nil }
        return (date, hasTime)
    }
}
