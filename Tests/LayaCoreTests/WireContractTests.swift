import XCTest
@testable import LayaCore

/// Wire-contract parity against golden/wire_golden.json — real request/
/// response pairs captured from the live Python daemon. The Swift API layer
/// must (a) accept every golden payload, (b) reproduce usage.chars_in /
/// chars_out / model echo exactly, (c) pass its own answer validators on the
/// golden answers (they encode the invariants), and (d) refuse with the same
/// error vocabulary as the Python.
@MainActor
final class WireContractTests: XCTestCase {

    func testVersionSingleSource() throws {
        // The shipped version. Release tags (v0.1.0) and the GitHub
        // release must carry exactly this value; a bump that forgets
        // the tag is caught here.
        XCTAssertEqual(LayaVersion.string, "0.1.0")
    }
    func loadJSON(_ rel: String) -> JSONValue {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path
        let data = try! Data(contentsOf: URL(fileURLWithPath: root + "/" + rel))
        guard let v = JSONValue.parse(data) else {
            XCTFail("unparseable golden \(rel)"); return .null
        }
        return v
    }

    func cases() -> [JSONValue] { loadJSON("golden/wire_golden.json")["cases"]!.arrayValue! }

    func testEnvelopeValidationAndUsageEcho() throws {
        for c in cases() {
            let payload = c["payload"]!
            let want = c["response"]!
            let req = try LayaAPI.validateRequest(payload)

            // model echo verbatim-or-default
            XCTAssertEqual(req.model, want["model"]?.stringValue)

            // chars_in == JSON-encoded state length
            XCTAssertEqual(req.stateChars, want["usage"]?["chars_in"]?.intValue)

            // chars_out == len(json.dumps(answers)) — the golden answers
            // re-serialized with our Python-compatible serializer must match
            // the Python char count (proves serialize() parity).
            let answers = want["answers"]!
            let charsOut = JSONValue.serialize(answers).unicodeScalars.count
            XCTAssertEqual(charsOut, want["usage"]?["chars_out"]?.intValue,
                           "chars_out diverge for \(c["name"]!.stringValue!)")
        }
    }

    func testGoldenAnswersPassOwnValidators() throws {
        for c in cases() {
            let payload = c["payload"]!
            let want = c["response"]!
            let req = try LayaAPI.validateRequest(payload)
            try LayaAPI.validateAnswers(questions: req.questions, answers: want["answers"]!)
            try LayaAPI.checkResponseSize(want)
        }
    }

    func testHealthAndModelsDocuments() throws {
        let w = loadJSON("golden/wire_golden.json")
        let health = w["health"]!
        XCTAssertEqual(health["ok"], .bool(true))
        XCTAssertNotNil(health["chains"]?.arrayValue)
        let models = w["models"]!
        XCTAssertEqual(models["object"], .string("list"))
        let first = models["data"]!.arrayValue![0]
        XCTAssertEqual(first["id"]?.stringValue, "laya-r15")
        XCTAssertEqual(first["owned_by"]?.stringValue, "laya")
    }

    func testRefusalsMatchPythonVocabulary() throws {
        // state missing
        XCTAssertThrowsError(try LayaAPI.validateRequest(
            JSONValue.obj("questions",
                          JSONValue.obj("q", JSONValue.obj("type", .string("noul"),
                                                            "instructions", .string("x")))))) { e in
            XCTAssertEqual((e as! LayaAPI.ApiError).code, "state_required")
        }
        // questions empty
        XCTAssertThrowsError(try LayaAPI.validateRequest(
            JSONValue.obj("state", .string("s"), "questions", .object([])))) { e in
            XCTAssertEqual((e as! LayaAPI.ApiError).code, "questions_required")
        }
        // noul carrying criteria
        XCTAssertThrowsError(try LayaAPI.validateRequest(
            JSONValue.obj("state", .string("s"), "questions",
                          JSONValue.obj("q", JSONValue.obj("type", .string("noul"),
                                                            "instructions", .string("x"),
                                                            "criteria", JSONValue.obj("a", .string("b"))))))) { e in
            XCTAssertEqual((e as! LayaAPI.ApiError).code, "noul_criteria_forbidden")
        }
        // CLI alias on the wire
        XCTAssertThrowsError(try LayaAPI.validateRequest(
            JSONValue.obj("state", .string("s"), "questions",
                          JSONValue.obj("q", JSONValue.obj("kind", .string("noul"),
                                                            "instructions", .string("x")))))) { e in
            XCTAssertEqual((e as! LayaAPI.ApiError).code, "cli_alias_on_http")
        }
        // state over the 60k cap
        XCTAssertThrowsError(try LayaAPI.validateRequest(
            JSONValue.obj("state", .string(String(repeating: "x", count: 60_001)), "questions",
                          JSONValue.obj("q", JSONValue.obj("type", .string("noul"),
                                                            "instructions", .string("x")))))) { e in
            XCTAssertEqual((e as! LayaAPI.ApiError).code, "state_too_large")
        }
    }

    func testOpsMapperInvariantsOnGoldenAnswers() throws {
        // Rebuild each golden answer through LayaOps from an EngineOut whose
        // probs are the golden probabilities; the mapper's invariants must
        // reproduce the golden pick/confidence exactly, and our own
        // validators must accept the mapper's output.
        for c in cases() {
            let payload = c["payload"]!
            let want = c["response"]!
            let req = try LayaAPI.validateRequest(payload)
            for qp in req.questions {
                let qname = qp.name
                let q = qp.q
                let wantAns = want["answers"]![qname]!
                let qtype = q["type"]!.stringValue!
                let probs: [(key: String, value: Double)]
                if let pp = wantAns["probabilities"]?.objectPairs {
                    probs = pp.map { ($0.key, $0.value.numberValue!) }
                } else {
                    let p = wantAns["noul"]!.numberValue!
                    probs = [("no", 1 - p), ("yes", p)]
                }
                let out = LayaOps.EngineOut(task: "base", chain: "base", probs: probs,
                                            confidence: 0, actP: 0)
                let mapped = try LayaOps.answerer(qtype)(qname, q, out)
                switch qtype {
                case "choice":
                    XCTAssertEqual(mapped["choice"]?.stringValue, wantAns["choice"]?.stringValue)
                    XCTAssertEqual(mapped["confidence"]?.numberValue ?? -1,
                                   wantAns["confidence"]?.numberValue ?? -2, accuracy: 1e-9)
                case "noul":
                    XCTAssertEqual(mapped["noul"]?.numberValue ?? -1,
                                   wantAns["noul"]?.numberValue ?? -2, accuracy: 1e-9)
                default: break
                }
                try LayaAPI.validateAnswer(name: qname, question: q, answer: mapped)
            }
        }
    }
}
