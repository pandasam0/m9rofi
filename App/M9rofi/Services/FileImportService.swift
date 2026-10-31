import Foundation
import PDFKit
import UniformTypeIdentifiers
import CoreXLSX
import FinanceCore

/// Converts user-selected files into RawRecords. Everything runs on-device.
enum FileImportService {
    enum Kind { case csv, pdf, xlsx, email, text }

    struct Preview {
        var kind: Kind
        var result: StatementImportResult?
        var records: [RawRecord]
        var messages: [String]
    }

    static func kind(of url: URL) -> Kind {
        switch url.pathExtension.lowercased() {
        case "csv", "tsv": return .csv
        case "pdf": return .pdf
        case "xlsx", "xlsm": return .xlsx
        case "eml": return .email
        default: return .text
        }
    }

    /// `accountID` is required for statements (a statement belongs to one account).
    static func preview(url: URL, accountID: UUID?, settings: LedgerSettings, templates: [SMSTemplate]) throws -> Preview {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let importer = StatementImporter(timeZone: settings.timeZone)
        let k = kind(of: url)
        switch k {
        case .csv:
            guard let accountID else { return Preview(kind: k, result: nil, records: [], messages: ["اختر الحساب الذي يخصه الكشف"]) }
            let text = try readText(url)
            let r = importer.importCSV(text, accountID: accountID)
            return Preview(kind: k, result: r, records: r.records, messages: r.skippedRows.prefix(20).map { "سطر \($0.row): \($0.reason)" })
        case .pdf:
            guard let accountID else { return Preview(kind: k, result: nil, records: [], messages: ["اختر الحساب الذي يخصه الكشف"]) }
            guard let doc = PDFDocument(url: url) else { return Preview(kind: k, result: nil, records: [], messages: ["تعذر فتح ملف PDF"]) }
            if doc.isEncrypted && doc.isLocked { return Preview(kind: k, result: nil, records: [], messages: ["الملف محمي بكلمة مرور. افتحه وأعد حفظه بدونها."]) }
            var lines: [String] = []
            for i in 0..<doc.pageCount { lines += (doc.page(at: i)?.string ?? "").components(separatedBy: .newlines) }
            if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return Preview(kind: k, result: nil, records: [], messages: ["الملف صورة ممسوحة بدون نص. اطلب كشفاً إلكترونياً (CSV/Excel) من البنك."])
            }
            let r = importer.importPDFText(lines, accountID: accountID)
            var msgs = r.skippedRows.prefix(20).map { "سطر \($0.row): \($0.reason)" }
            let unknown = r.records.filter { $0.direction == nil }.count
            if unknown > 0 { msgs.insert("\(unknown) عمليات لم يُحدد اتجاهها وستظهر في قائمة المراجعة", at: 0) }
            return Preview(kind: k, result: r, records: r.records, messages: msgs)
        case .xlsx:
            guard let accountID else { return Preview(kind: k, result: nil, records: [], messages: ["اختر الحساب الذي يخصه الكشف"]) }
            let rows = try readXLSX(url)
            let r = importer.importRows(rows, accountID: accountID, source: .statementExcel)
            return Preview(kind: k, result: r, records: r.records, messages: r.skippedRows.prefix(20).map { "سطر \($0.row): \($0.reason)" })
        case .email:
            let m = EMLParser.parse(try readText(url))
            guard let rec = ReceiptParser.record(subject: m.subject, from: m.from, body: m.body, date: m.date ?? Date(), messageID: m.messageID) else {
                return Preview(kind: k, result: nil, records: [], messages: ["لم يُعثر على مبلغ إجمالي في الرسالة"])
            }
            return Preview(kind: k, result: nil, records: [rec], messages: [])
        case .text:
            // A text file of pasted bank messages separated by blank lines.
            let parser = SMSParser(timeZone: settings.timeZone, templates: templates)
            let blocks = try readText(url).components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var recs: [RawRecord] = []
            var ignored = 0
            for b in blocks {
                if case .record(let r) = parser.parse(text: b, sender: nil, receivedAt: Date()) { recs.append(r) } else { ignored += 1 }
            }
            return Preview(kind: k, result: nil, records: recs, messages: ignored > 0 ? ["تم تجاهل \(ignored) رسائل غير مالية"] : [])
        }
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        // Legacy Arabic Windows exports (CP1256)
        let cp1256 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))
        if let s = String(data: data, encoding: cp1256) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    static func readXLSX(_ url: URL) throws -> [[String]] {
        guard let file = XLSXFile(filepath: url.path) else { throw CocoaError(.fileReadCorruptFile) }
        let shared = try file.parseSharedStrings()
        guard let wb = try file.parseWorkbooks().first,
              let path = try file.parseWorksheetPathsAndNames(workbook: wb).first?.path else { return [] }
        let ws = try file.parseWorksheet(at: path)
        var rows: [[String]] = []
        for row in ws.data?.rows ?? [] {
            var out: [String] = []
            for cell in row.cells {
                let col = columnIndex(cell.reference.column.value)
                while out.count < col { out.append("") }
                var v = shared.flatMap { cell.stringValue($0) } ?? cell.value ?? ""
                // Excel stores dates as serial day numbers.
                if isDateColumn(col, rows), let serial = Double(v), serial > 20000, serial < 80000 {
                    v = isoDay(Date(timeIntervalSince1970: (serial - 25569) * 86400))
                }
                out.append(v)
            }
            rows.append(out)
        }
        return rows
    }

    private static func isDateColumn(_ col: Int, _ rows: [[String]]) -> Bool {
        rows.prefix(15).contains { col < $0.count && ($0[col].lowercased().contains("date") || $0[col].contains("تاريخ")) }
    }

    private static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func columnIndex(_ letters: String) -> Int {
        letters.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }
}
