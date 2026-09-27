import XCTest
@testable import LayaCore

/// Regression gates for Decisions.redact + the mail decode-before-
/// screening primitives (UseCases). The redact NSRangeException crash —
/// searching pattern N+1 with pattern N's pre-shrink NSString length —
/// killed the triage row with SIGABRT on any email-bearing message and
/// had ZERO unit coverage (the rows gate only saw it as rc=-6).
final class DecisionsRedactTests: XCTestCase {

    func testRedactMultiplePatternsNoRangeCrash() {
        // Every combination of patterns hitting in sequence: email then
        // keyval then hex then phone then bearer — the shrink between
        // hits is what used to crash the next search.
        let text = """
        from alice@corp.example contact me at +1 555 123 4567
        api_key = sk-live-9938abcdef0123456789deadbeef
        bearer abcdefghijklmnop0123456789
        token: zzz999888777666555444333
        """
        let out = Decisions.redact(text)
        XCTAssertFalse(out.contains("alice@corp.example"))
        XCTAssertFalse(out.contains("sk-live-9938"))
        XCTAssertFalse(out.contains("abcdefghijklmnop0123456789"))
        XCTAssertTrue(out.contains("[redacted]"))
        // idempotent: redacting redacted text is stable
        XCTAssertEqual(Decisions.redact(out), out)
    }

    func testRedactEmptyAndNoMatch() {
        XCTAssertEqual(Decisions.redact(""), "")
        XCTAssertEqual(Decisions.redact("plain text no secrets"), "plain text no secrets")
    }

    @available(macOS 27.0, *)
    func testPercentDecodeUnquoteTwin() {
        // urllib.parse.unquote semantics: valid %XX -> bytes, invalid
        // sequences stay LITERAL.
        XCTAssertEqual(UseCases.percentDecode("%48%45%4C%4C%4F"), "HELLO")
        XCTAssertEqual(UseCases.percentDecode("a%20b"), "a b")
        XCTAssertEqual(UseCases.percentDecode("100%zz done"), "100%zz done")
        XCTAssertEqual(UseCases.percentDecode("tail%"), "tail%")
        // percent-encoded UTF-8 re-decodes to the string
        XCTAssertEqual(UseCases.percentDecode("%C3%A9"), "é")
    }

    @available(macOS 27.0, *)
    func testDecodeForScreeningStructure() {
        // Python _decode_for_screening: URL queries stripped, each
        // decodable base64 block and each percent span becomes its own
        // appended line.
        let text = "see https://example.com/x?secret=1 and "
            + "aHR0cHM6Ly9leGFtcGxlLmNvbS9zdWJzY3JpcHRpb24?"
            + "cHJvbW89NTAlIG9mZiB0aGlzIHdlZWsgb25seSBjbGFpbQ== plus %48%45%4C%4C%4F%20%57%4F%52%4C%44"
        let out = UseCases.decodeForScreening(text)
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, "stripped + b64 + percent = 3 lines, got \(lines)")
        XCTAssertTrue(lines[0].contains("https://example.com/x? "))
        XCTAssertFalse(lines[0].contains("secret=1"))
        // Python truth (captured live): the decoded b64 is itself a URL
        // with a query, so the strip loop cuts it at '?' -> exactly
        // "https://example.com/subscription" (the "promo=50%" text never
        // reaches the screening line).
        XCTAssertEqual(lines[1], "https://example.com/subscription")
        XCTAssertTrue(lines[2].contains("HELLO WORLD"))
    }

    @available(macOS 27.0, *)
    func testBase64IgnoreSemantics() {
        // Invalid-utf8 base64: Python decode(...,"ignore") drops the bad
        // bytes (may leave whitespace-only -> not appended); our String
        // U+FFFD replacement is stripped to match.
        // "AA==" decodes to 0x00 (kept, non-space); "/w==" decodes to
        // 0xFF (invalid utf8 -> dropped -> empty -> NOT appended).
        let onlyInvalid = "/w==/w==/w==/w==/w==/w==/w==/w=="   // ≥40 chars b64 run
        let out = UseCases.decodeForScreening(onlyInvalid)
        XCTAssertEqual(out.components(separatedBy: "\n").count, 1,
                       "invalid-utf8 block must not append a line")
    }
}
