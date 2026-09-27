import Foundation

/// Ordered-JSON model. The wire's `criteria` mappings are ORDERED dicts in
/// Python (option order is load-bearing for the argmax tie rule and for the
/// token sequence), so Foundation's unordered dictionaries are not enough:
/// every object is an array of (key, value) pairs preserving insertion order.
/// Python `json.dumps` compatibility (key order, ensure_ascii=False,
/// sort_keys where the Python side sorts) is required for byte-identical
/// decision-log lines and stable `chars_out` usage counts.
public indirect enum JSONValue: Equatable, Sendable, ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }

    /// Hand-written equality (synthesis is impossible: the object payload is
    /// an array of labeled tuples, which never conform to Equatable).
    /// Double compares with plain ==, matching Python list-comparison
    /// semantics on parsed JSON.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count
                && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    /// Ordered mapping: [(key, value)], duplicates last-wins on lookup.
    case object([(key: String, value: JSONValue)])

    // MARK: lookup / construction helpers

    public static func object(_ pairs: [String: JSONValue], order: [String]) -> JSONValue {
        .object(order.compactMap { k in pairs[k].map { (key: k, value: $0) } })
    }

    /// Ordered-object factory for literals: `obj("a", .string("x"), "b", .int(1))`
    /// keeps pairs in argument order (case-vs-func `.object` ambiguity in
    /// nested literals otherwise defeats type inference). Values are typed
    /// JSONValue so leading-dot shorthand works; keys pass via a string
    /// carrier case.
    public static func obj(_ parts: JSONValue...) -> JSONValue {
        var out: [(key: String, value: JSONValue)] = []
        out.reserveCapacity(parts.count / 2)
        var i = 0
        while i + 1 < parts.count {
            if case .string(let k) = parts[i] {
                out.append((key: k, value: parts[i + 1]))
            }
            i += 2
        }
        return .object(out)
    }

    public var objectPairs: [(key: String, value: JSONValue)]? {
        if case .object(let p) = self { return p }
        return nil
    }
    public var keys: [String]? { objectPairs?.map(\.key) }
    public var values: [JSONValue]? { objectPairs?.map(\.value) }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        for p in pairs.reversed() where p.key == key { return p.value }
        return nil
    }
    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    var isNull: Bool { if case .null = self { return true }; return false }
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        default: return nil
        }
    }
    /// Swift-side truthiness mirroring Python `bool(x)` for the values that
    /// reach the rails: null/false/0/""/[]/{} are false.
    var pythonTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0 && !d.isNaN
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    /// Int64 or Double; JSON booleans are NOT numbers for the §1 validators
    /// (Python `isinstance(v, bool)` exclusion), exposed separately.
    public var numberValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    public var intValue: Int? {
        switch self {
        case .int(let i): return Int(exactly: i) ?? (i > 0 ? .max : .min)
        case .double(let d): return d == d.rounded() && d.magnitude < 1e15 ? Int(d) : nil
        default: return nil
        }
    }

    // MARK: serialization (Python json.dumps compatible)

    /// Python `json.dumps(value, ensure_ascii=False)` byte length — the
    /// §1 state/response caps count CHARACTERS/bytes of that document.
    public static func jsonCharLen(_ v: JSONValue) -> Int { serialize(v, sortKeys: false).unicodeScalars.count }

    /// jsonCharLen without materializing the document (E2): counts exactly
    /// what `write` would emit — 1:1 per scalar except escapes (control
    /// chars \uXXXX = 6, others 1:1) and the ", "/": " separators.
    public static func charLen(_ v: JSONValue) -> Int {
        switch v {
        case .null: return 4
        case .bool(let b): return b ? 4 : 5
        case .int(let i): return String(i).unicodeScalars.count
        case .double(let d): return pyRepr(d).unicodeScalars.count
        case .string(let s):
            var n = 2   // quotes
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"", "\\", "\n", "\r", "\t", "\u{08}", "\u{0C}": n += 2
                default: n += scalar.value < 0x20 ? 6 : 1
                }
            }
            return n
        case .array(let a):
            var n = 2   // brackets
            for e in a { n += charLen(e) }
            return n + max(0, a.count - 1) * 2   // ", "
        case .object(let pairs):
            var n = 2   // braces
            for p in pairs { n += charLen(.string(p.key)) + 2 + charLen(p.value) }   // ": "
            return n + max(0, pairs.count - 1) * 2   // ", "
        }
    }

    /// serializeSorted(v).prefix(maxScalars) without building the whole
    /// document (E6): the engine slate only ever reads the first 900
    /// scalars of a ≤60 KB sorted dump; a big state used to serialize
    /// fully first. Exact: identical prefix to serializeSorted+prefix.
    ///
    /// ensure_ascii=TRUE semantics — combined_agent.py:109 is
    /// `json.dumps(state, sort_keys=True)[:900]` with Python DEFAULTS:
    /// separators (", ", ": ") AND non-ASCII escaped to \uXXXX (non-BMP
    /// via UTF-16 surrogate pairs). The wire-response writer (serialize)
    /// is ensure_ascii=False; this one is NOT. Caught by the object-state
    /// differential probe (中/emoji state diverged Swift vs Python model
    /// input).
    public static func serializeSortedPrefix(_ v: JSONValue, maxScalars: Int) -> String {
        var out = ""
        out.reserveCapacity(min(maxScalars + 16, 1024))
        var budget = maxScalars
        writeBounded(v, to: &out, sortKeys: true, sep: (", ", ": "), budget: &budget)
        return out
    }

    private static func writeBounded(_ v: JSONValue, to out: inout String, sortKeys: Bool,
                                     sep: (String, String), budget: inout Int) {
        if budget <= 0 { return }
        switch v {
        case .null: emit("null", to: &out, &budget)
        case .bool(let b): emit(b ? "true" : "false", to: &out, &budget)
        case .int(let i): emit(String(i), to: &out, &budget)
        case .double(let d): emit(pyRepr(d), to: &out, &budget)
        case .string(let s): writeStringBounded(s, to: &out, budget: &budget)
        case .array(let a):
            emit("[", to: &out, &budget)
            for (i, e) in a.enumerated() {
                if budget <= 0 { break }
                if i > 0 { emit(sep.0, to: &out, &budget) }
                writeBounded(e, to: &out, sortKeys: sortKeys, sep: sep, budget: &budget)
            }
            if budget > 0 { emit("]", to: &out, &budget) }
        case .object(let pairs):
            var ps = pairs
            if sortKeys { ps.sort { $0.key < $1.key } }
            emit("{", to: &out, &budget)
            for (i, p) in ps.enumerated() {
                if budget <= 0 { break }
                if i > 0 { emit(sep.0, to: &out, &budget) }
                writeStringBounded(p.key, to: &out, budget: &budget)
                emit(sep.1, to: &out, &budget)
                writeBounded(p.value, to: &out, sortKeys: sortKeys, sep: sep, budget: &budget)
            }
            if budget > 0 { emit("}", to: &out, &budget) }
        }
    }

    private static func emit(_ s: String, to out: inout String, _ budget: inout Int) {
        for scalar in s.unicodeScalars {
            if budget <= 0 { return }
            out.unicodeScalars.append(scalar)
            budget -= 1
        }
    }

    private static func writeStringBounded(_ s: String, to out: inout String, budget: inout Int) {
        emit("\"", to: &out, &budget)
        for scalar in s.unicodeScalars {
            if budget <= 0 { return }
            switch scalar {
            case "\"": emit("\\\"", to: &out, &budget)
            case "\\": emit("\\\\", to: &out, &budget)
            case "\n": emit("\\n", to: &out, &budget)
            case "\r": emit("\\r", to: &out, &budget)
            case "\t": emit("\\t", to: &out, &budget)
            case "\u{08}": emit("\\b", to: &out, &budget)
            case "\u{0C}": emit("\\f", to: &out, &budget)
            default:
                if scalar.value < 0x20 {
                    emit(String(format: "\\u%04x", scalar.value), to: &out, &budget)
                } else if scalar.value < 0x7F {
                    // ensure_ascii=True: ASCII printable passes through.
                    out.unicodeScalars.append(scalar); budget -= 1
                } else if scalar.value <= 0xFFFF {
                    // BMP non-ASCII (incl. DEL 0x7F): \uXXXX (6 chars).
                    emit(String(format: "\\u%04x", scalar.value), to: &out, &budget)
                } else {
                    // Non-BMP: UTF-16 surrogate pair, two \u escapes (12
                    // chars) — exactly Python's ensure_ascii encoding.
                    let v = scalar.value - 0x10000
                    let hi = 0xD800 + (v >> 10)
                    let lo = 0xDC00 + (v & 0x3FF)
                    emit(String(format: "\\u%04x\\u%04x", hi, lo), to: &out, &budget)
                }
            }
        }
        emit("\"", to: &out, &budget)
    }

    public static func serialize(_ v: JSONValue, sortKeys: Bool = false) -> String {
        serialize(v, sortKeys: sortKeys, separators: (", ", ": "))
    }

    /// Python json.dumps separators: (item, key-value). Compact dumps use
    /// (",", ":"); the default pretty form uses (", ", ": ").
    public static func serialize(_ v: JSONValue, sortKeys: Bool, separators: (String, String)) -> String {
        var out = ""
        out.reserveCapacity(64)
        write(v, to: &out, sortKeys: sortKeys, sep: separators)
        return out
    }

    public static func serializeSorted(_ v: JSONValue) -> String { serialize(v, sortKeys: true) }

    /// Python `json.dumps(v, sort_keys=True)` with DEFAULTS — ensure_ascii
    /// TRUE (\uXXXX escapes, UTF-16 surrogate pairs for non-BMP),
    /// separators (", ", ": "). This is the combined_agent.py:109 wire
    /// (NOT the response wire, which is ensure_ascii=False). Full
    /// materialization; the bounded `serializeSortedPrefix` is its
    /// O(cap) twin and this is its naive differential oracle.
    public static func serializeAsciiSorted(_ v: JSONValue) -> String {
        var out = ""
        out.reserveCapacity(64)
        writeAscii(v, to: &out)
        return out
    }

    private static func writeAscii(_ v: JSONValue, to out: inout String) {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += pyRepr(d)
        case .string(let s): writeStringAscii(s, to: &out)
        case .array(let a):
            out += "["
            for (i, e) in a.enumerated() {
                if i > 0 { out += ", " }
                writeAscii(e, to: &out)
            }
            out += "]"
        case .object(let pairs):
            let ps = pairs.sorted { $0.key < $1.key }
            out += "{"
            for (i, p) in ps.enumerated() {
                if i > 0 { out += ", " }
                writeStringAscii(p.key, to: &out)
                out += ": "
                writeAscii(p.value, to: &out)
            }
            out += "}"
        }
    }

    private static func writeStringAscii(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value >= 0x7F {
                    if scalar.value <= 0xFFFF {
                        out += String(format: "\\u%04x", scalar.value)
                    } else {
                        let v = scalar.value - 0x10000
                        out += String(format: "\\u%04x\\u%04x",
                                      0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    private static func write(_ v: JSONValue, to out: inout String, sortKeys: Bool, sep: (String, String)) {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += pyRepr(d)
        case .string(let s): writeString(s, to: &out)
        case .array(let a):
            out += "["
            for (i, e) in a.enumerated() {
                if i > 0 { out += sep.0 }
                write(e, to: &out, sortKeys: sortKeys, sep: sep)
            }
            out += "]"
        case .object(let pairs):
            var ps = pairs
            if sortKeys { ps.sort { $0.key < $1.key } }
            out += "{"
            for (i, p) in ps.enumerated() {
                if i > 0 { out += sep.0 }
                writeString(p.key, to: &out)
                out += sep.1
                write(p.value, to: &out, sortKeys: sortKeys, sep: sep)
            }
            out += "}"
        }
    }

    /// repr(float) shortest-roundtrip form Python uses (repr(1.0) == "1.0").
    public static func pyRepr(_ d: Double) -> String {
        if d.isNaN { return "nan" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        if d == d.rounded(), d.magnitude < 1e16 {
            let i = Int64(d)
            if Double(i) == d { return String(format: "%.1f", d) }
        }
        // Shortest roundtrip; Swift's \\(d) prints "1e-05"-style exponents as
        // "1e-05"→"0.00001"? Python repr uses repr(1e-05)="1e-05". Match C99
        // %g-style with exponent threshold 1e-4 like CPython float_repr.
        // String(format:) because Darwin swift overlays mark snprintf variadic-unavailable.
        for p in 1...17 {
            let s = String(format: "%.\(p)g", d)
            if Double(s) == d { return normalizePyRepr(s) }
        }
        return normalizePyRepr(String(format: "%.17g", d))
    }

    private static func normalizePyRepr(_ s: String) -> String {
        // Python repr always keeps a decimal point for finite non-exponent
        // floats ("3.0", not "3"); exponent form "1e-05" matches already.
        if !s.contains(".") && !s.contains("e") && !s.contains("inf") && !s.contains("nan") {
            return s + ".0"
        }
        return s
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)  // ensure_ascii=False
                }
            }
        }
        out += "\""
    }

    // MARK: parsing

    /// Parse one JSON document. Accepts NaN/Infinity (Python json.loads does)
    /// — the question-API validators then reject them as non-numbers where
    /// the Python side would too.
    public static func parse(_ text: String) -> JSONValue? {
        var p = JSONParser(Array(text.utf16))
        p.skipWS()
        guard let v = p.parseValue() else { return nil }
        p.skipWS()
        return p.peekIsEOF() ? v : nil
    }

    public static func parse(_ data: Data) -> JSONValue? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        return parse(s)
    }
}

/// UTF-16-code-unit JSON scanner (surrogate pairs stay glued as Python does
/// for lone surrogates; string lengths then match Python len()).
extension UInt16 {
    /// Single-ASCII-character initializer (the SDK's NumericConversion
    /// overlay does not ship `UInt16(ascii:)` on this toolchain).
    init(ascii: String) {
        var it = unicodeScalars(of: ascii)
        guard let s = it.next(), it.next() == nil, s.isASCII else {
            preconditionFailure("ascii: not a single ASCII scalar")
        }
        self = UInt16(s.value)
    }
}

private func unicodeScalars(of s: String) -> String.UnicodeScalarView.Iterator {
    s.unicodeScalars.makeIterator()
}

struct JSONParser {
    let text: [UInt16]
    var pos = 0

    init(_ text: [UInt16]) { self.text = text }

    mutating func skipWS() {
        while pos < text.count {
            switch text[pos] {
            case 0x20, 0x09, 0x0A, 0x0D: pos += 1
            default: return
            }
        }
    }

    func peekIsEOF() -> Bool { pos >= text.count }

    mutating func parseValue() -> JSONValue? {
        skipWS()
        guard pos < text.count else { return nil }
        switch text[pos] {
        case 0x7B: return parseObject()   // {
        case 0x5B: return parseArray()    // [
        case 0x22: return parseString().map { JSONValue.string($0) }  // "
        case 0x74: return match("true").map { _ in .bool(true) }      // t
        case 0x66: return match("false").map { _ in .bool(false) }    // f
        case 0x6E: // n
            if match("null") != nil { return .null }
            if match("NaN") != nil { return .double(.nan) }
            return nil
        case 0x49: return match("Infinity").map { _ in .double(.infinity) }  // I
        case UInt16(ascii: "-"):
            if match("-Infinity") != nil { return .double(-.infinity) }
            return parseNumber()
        default: return parseNumber()
        }
    }

    mutating func match(_ lit: String) -> Bool? {
        let u = Array(lit.utf16)
        guard pos + u.count <= text.count, Array(text[pos..<(pos + u.count)]) == u else { return nil }
        pos += u.count
        return true
    }

    mutating func parseObject() -> JSONValue? {
        pos += 1 // {
        var pairs: [(key: String, value: JSONValue)] = []
        skipWS()
        if pos < text.count, text[pos] == UInt16(ascii: "}") { pos += 1; return .object(pairs) }
        while true {
            skipWS()
            guard pos < text.count, text[pos] == UInt16(ascii: "\""), let k = parseString() else { return nil }
            skipWS()
            guard pos < text.count, text[pos] == UInt16(ascii: ":") else { return nil }
            pos += 1
            guard let v = parseValue() else { return nil }
            pairs.append((key: k, value: v))
            skipWS()
            guard pos < text.count else { return nil }
            if text[pos] == UInt16(ascii: ",") { pos += 1; continue }
            if text[pos] == UInt16(ascii: "}") { pos += 1; return .object(pairs) }
            return nil
        }
    }

    mutating func parseArray() -> JSONValue? {
        pos += 1 // [
        var arr: [JSONValue] = []
        skipWS()
        if pos < text.count, text[pos] == UInt16(ascii: "]") { pos += 1; return .array(arr) }
        while true {
            guard let v = parseValue() else { return nil }
            arr.append(v)
            skipWS()
            guard pos < text.count else { return nil }
            if text[pos] == UInt16(ascii: ",") { pos += 1; continue }
            if text[pos] == UInt16(ascii: "]") { pos += 1; return .array(arr) }
            return nil
        }
    }

    mutating func parseString() -> String? {
        guard text[pos] == UInt16(ascii: "\"") else { return nil }
        pos += 1
        var units: [UInt16] = []
        while pos < text.count {
            let c = text[pos]
            if c == UInt16(ascii: "\"") {
                pos += 1
                return String(utf16CodeUnits: units, count: units.count)
            }
            if c == UInt16(ascii: "\\") {
                pos += 1
                guard pos < text.count else { return nil }
                switch text[pos] {
                case UInt16(ascii: "\""): units.append(0x22)
                case UInt16(ascii: "\\"): units.append(0x5C)
                case UInt16(ascii: "/"): units.append(0x2F)
                case UInt16(ascii: "b"): units.append(0x08)
                case UInt16(ascii: "f"): units.append(0x0C)
                case UInt16(ascii: "n"): units.append(0x0A)
                case UInt16(ascii: "r"): units.append(0x0D)
                case UInt16(ascii: "t"): units.append(0x09)
                case UInt16(ascii: "u"):
                    pos += 1
                    guard pos + 4 <= text.count,
                          let cp = UInt16(hex4: text[pos..<(pos + 4)]) else { return nil }
                    units.append(cp)
                    pos += 3 // +1 below lands past the 4 hex digits
                default: return nil
                }
                pos += 1
                continue
            }
            units.append(c)
            pos += 1
        }
        return nil
    }

    mutating func parseNumber() -> JSONValue? {
        let start = pos
        if pos < text.count, text[pos] == UInt16(ascii: "-") { pos += 1 }
        var isDouble = false
        while pos < text.count {
            let c = text[pos]
            if c >= UInt16(ascii: "0") && c <= UInt16(ascii: "9") { pos += 1; continue }
            if c == UInt16(ascii: ".") || c == UInt16(ascii: "e") || c == UInt16(ascii: "E")
                || c == UInt16(ascii: "+") || c == UInt16(ascii: "-") { isDouble = true; pos += 1; continue }
            break
        }
        guard pos > start else { return nil }
        let s = String(utf16CodeUnits: Array(text[start..<pos]), count: pos - start)
        if !isDouble, let i = Int64(s) { return .int(i) }
        guard let d = Double(s) else { return nil }
        return .double(d)
    }
}

private extension UInt16 {
    init?(hex4: ArraySlice<UInt16>) {
        var v: UInt16 = 0
        for u in hex4 {
            let d: UInt16
            switch u {
            case let x where (UInt16(ascii: "0")...UInt16(ascii: "9")).contains(x): d = x - UInt16(ascii: "0")
            case let x where (UInt16(ascii: "a")...UInt16(ascii: "f")).contains(x): d = x - UInt16(ascii: "a") + 10
            case let x where (UInt16(ascii: "A")...UInt16(ascii: "F")).contains(x): d = x - UInt16(ascii: "A") + 10
            default: return nil
            }
            v = v &* 16 &+ d
        }
        self = v
    }
}
