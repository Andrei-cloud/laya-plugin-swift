import Foundation

/// Deployed thresholds — the ONE place any rail/threshold is written (DRY;
/// "thresholds must not drift"). Swift port of server/laya_constants.py;
/// every number cites the same spec-v2 section as the Python original.
public enum K {
    // ---- routing rails (spec §3 "Routing policy") --------------------------
    static let minConfidence = 0.6
    static let hardNeedsProb = 0.6
    static let simpleNeedsProb = 0.7
    static let simpleNeedsConf = 0.85
    static let hardRiskStakesFloor = 0.4
    static let hardTierStakes = 0.85
    static let hardTierPHard = 0.35
    static let specialtyMinKindConf = 0.5
    static let stickyContextTokens = 32_000

    /// hard-risk vocabulary (spec §3 _HARD_RISK): words that force caution
    static let hardRiskWords: [String] = [
        "production", "prod", "delete", "drop table", "truncate", "format",
        "force push", "rm -rf", "sudo", "chmod -R", "chmod 777", "kill -9",
        "terraform destroy", "migration", "release", "deploy", "pay", "wire",
        "invoice", "contract", "credentials", "secret", "customer", "pii",
        "irreversible", "overwrite", "wipe",
    ]

    // route rubric / vocabularies (spec §2 route row)
    static let difficultyLevels = ["Trivial", "Moderate", "Hard", "Expert"]
    static let kinds = ["coding", "writing", "research", "general"]

    // ---- rerank / context filter (spec §2 rerank row) ----------------------
    static let rerankBatch = 60
    static let rerankMaxTotal = 480
    static let rerankCharsPerPassage = 900
    static let relThreshold = 0.5
    static let injThreshold = 0.5

    // ---- compaction (spec §2 compact-select row) ---------------------------
    static let compactBatchTurns = 40
    static let compactBatchChars = 40_000
    static let compactDropMinConf = 0.7
    static let compactKeepLast = 6

    // ---- skill pick (spec §2 pick-skill row + §5 stage-2 eval) -------------
    static let skillBatch = 120
    static let skillBatchCap = 960
    static let shortlistFloor = 0.02
    static let stage2Min = 0.5
    static let ackGateWords = 6

    // ---- next_action / choose (spec §2 choose row + §5 floor eval) ---------
    static let chooseIdPattern = "^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"
    static let chooseMinCandidates = 2
    static let chooseMaxCandidates = 32
    static let chooseFailsafeIds: [String] = ["reobserve", "abstain"]
    static let chooseFloorDefault = 0.65
    static let chooseFloorClamp: (lo: Double, hi: Double) = (0.60, 0.95)
    static let chooseGoalMaxChars = 2000
    static let chooseRegionsMaxChars = 100
    static let chooseHistoryMax = 16

    // ---- supervise (spec §3 supervise thresholds) ---------------------------
    static let superviseDone = 0.8
    static let superviseNeedsInput = 0.7
    static let superviseBlocked = 0.7
    static let superviseBlockedConf = 0.6
    static let superviseAlertAfter = 2
    static let superviseNoOutputS = 180
    static let superviseActions = ["keep_waiting", "answer_question", "nudge",
                                   "escalate", "collect"]

    // ---- triage / mail (spec §2 triage + mail rows) -------------------------
    static let urgencyLevels = ["none", "later", "today", "right-now", "deadline"]
    static let triageKinds = ["customer-problem", "question", "info", "promotion",
                              "sales", "noise"]
    static let mailLanes = ["needs_reply", "updates", "promotional", "sales", "spam"]

    // ---- privacy before send (spec §4) ---------------------------------------
    static let askChars = 2500
    /// §2 supervise row facts (SUPERVISE_FACT_KEYS — the CLI pre-filters
    /// stdin to these keys, in this insertion order, before the primitive).
    public static let superviseFactKeys = ["no_output_s", "nudge_streak",
                                    "question_pending", "last_output", "notes"]
    static let askCharsHeadroom = 50

    /// Redact patterns (spec §4). Python `re` semantics preserved via NSC
    /// ranges; alternation order = longest-first so `api_key` beats bare
    /// `token` (documented Swift-side deviation, strictly more protective).
    static let redactPatterns: [(name: String, regex: NSRegularExpression)] = {
        func re(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: [])
        }
        return [
            ("email", re("[\\w.+-]+@[\\w-]+\\.[\\w.]+")),
            ("phone", re("(?<!\\d)(?:\\+?\\d[\\d ()-]{7,18}\\d)(?!\\d)")),
            ("bearer", re("(?i)bearer\\s+[A-Za-z0-9._\\-]{8,}")),
            ("keyval", re("(?i)\\b(?:api[_-]?key|token|secret|password)\\b\\s*[:=]\\s*\\S+")),
            ("hex", re("\\b[0-9a-fA-F]{24,}\\b")),
        ]
    }()

    // ---- ladder (spec §2 ladder row) -----------------------------------------
    static let ladderProbeCacheS = 900

    // ---- decision log kinds (spec §4; the dual-written log's vocabulary) ----
    static let logKinds: Set<String> = ["route", "route_effective", "skill",
                                        "merged", "skill_unreachable"]
}

/// The verdict rail (ONE definition — DRY; mirrors engine.py's
/// GUARD_ACT_CONFIDENCE + guardrail_verdict). Safety semantics: the harness
/// may ACT only on "allow" at confidence >= guardActConfidence.
public let guardActConfidence = 0.7

func guardrailVerdict(choice: String, confidence: Double, floor: Double? = nil) -> String {
    let fl = floor ?? guardActConfidence
    if choice == "block" { return "deny" }
    if choice == "ask_user" || confidence < fl { return "confirm" }
    return "allow"
}
