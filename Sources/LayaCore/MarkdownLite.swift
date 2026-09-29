import Foundation

// Minimal, dependency-free Markdown → HTML renderer for GitHub release
// notes. Covers the subset release bodies actually use: ATX headings,
// fenced code blocks, inline code, bold/italic, links, autolinks,
// unordered/ordered lists, blockquotes, hr, paragraphs. Everything is
// HTML-escaped first — release notes are remote content and must not be
// able to inject markup.

public enum MarkdownLite {
    public static func html(_ markdown: String) -> String {
        // Normalize line endings, split into lines.
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var out: [String] = []
        var i = 0
        var listKind = ""      // "ul" | "ol" | ""
        func closeList() {
            if !listKind.isEmpty { out.append("</\(listKind)>"); listKind = "" }
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // fenced code block
            if line.hasPrefix("```") {
                closeList()
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(escape(lines[i])); i += 1
                }
                i += 1 // skip closing fence (or EOF)
                out.append("<pre><code>" + code.joined(separator: "\n") + "</code></pre>")
                continue
            }

            // heading
            if let h = headingLevel(line) {
                closeList()
                let text = inline(String(line.dropFirst(h + line.dropFirst(h).prefix(while: { $0 == " " }).count)))
                out.append("<h\(h)>\(text)</h\(h)>")
                i += 1
                continue
            }

            // horizontal rule
            if line == "---" || line == "***" || line == "___" {
                closeList(); out.append("<hr>"); i += 1; continue
            }

            // blockquote (collapse consecutive)
            if line.hasPrefix("> ") || line == ">" {
                closeList()
                var quote: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    if q.hasPrefix("> ") { quote.append(inline(String(q.dropFirst(2)))) }
                    else if q == ">" { quote.append("") }
                    else { break }
                    i += 1
                }
                out.append("<blockquote>" + quote.map { "<p>\($0)</p>" }.joined() + "</blockquote>")
                continue
            }

            // unordered list item
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if listKind != "ul" { closeList(); out.append("<ul>"); listKind = "ul" }
                out.append("<li>" + inline(String(line.dropFirst(2))) + "</li>")
                i += 1
                continue
            }

            // ordered list item ("1. ", "2. " …)
            if let n = orderedNumber(line) {
                if listKind != "ol" { closeList(); out.append("<ol>"); listKind = "ol" }
                out.append("<li value=\"\(n.value)\">" + inline(String(line.dropFirst(n.digits + 2))) + "</li>")
                i += 1
                continue
            }

            // blank line
            if line.isEmpty { closeList(); i += 1; continue }

            // paragraph (merge soft-wrapped lines until blank/block start)
            var para = [inline(line)]
            i += 1
            while i < lines.count {
                let nxt = lines[i].trimmingCharacters(in: .whitespaces)
                if nxt.isEmpty || nxt.hasPrefix("```") || nxt.hasPrefix("- ") || nxt.hasPrefix("* ")
                    || headingLevel(nxt) != nil || nxt.hasPrefix("> ") || orderedNumber(nxt) != nil { break }
                para.append(inline(nxt)); i += 1
            }
            closeList()
            out.append("<p>" + para.joined(separator: "<br>") + "</p>")
        }
        closeList()
        return out.joined(separator: "\n")
    }

    // MARK: helpers

    private static func headingLevel(_ line: String) -> Int? {
        var n = 0
        for ch in line {
            if ch == "#" { n += 1 } else { break }
        }
        guard (1...4).contains(n), line.dropFirst(n).first == " " else { return nil }
        return n
    }

    private struct Num { let value: Int; let digits: Int }
    private static func orderedNumber(_ line: String) -> Num? {
        let digits = String(line.prefix(while: \.isNumber))
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return Num(value: Int(digits) ?? 1, digits: digits.count)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Inline pass: escape everything first, then re-introduce only the
    /// constructs we render. Code spans and markdown-link hrefs are
    /// MASKED into private placeholders before the emphasis/autolink
    /// passes run, then restored — so autolink can never eat a URL
    /// inside an href="…" and emphasis can never fire inside a code
    /// span.
    static func inline(_ s: String) -> String {
        var t = escape(s)
        var stash: [String] = []
        func mask(_ html: String) -> String {
            stash.append(html)
            return "\u{0}M\(stash.count - 1)\u{0}"
        }

        // 1. code spans `x` → masked
        t = replace(t, pattern: "`([^`]+)`") { mask("<code>\($0[1])</code>") }
        // 2. markdown links [text](url) → masked anchor (link text
        //    renders plain; masking shields the href from autolink)
        t = replace(t, pattern: "\\[([^\\]]+)\\]\\((https?://[^)\\s]+)\\)") {
            mask("<a href=\"\($0[2])\">\($0[1])</a>")
        }
        // 3. autolinks for bare https URLs. \x00 is ICU's hex escape —
        //    it keeps the class from swallowing a NUL-mask placeholder.
        t = replace(t, pattern: "(?<![\"'>])\\b(https?://[^<\\s\\x00]+)") {
            var url = $0[1]
            if url.hasSuffix(".") { url = String(url.dropLast()); return "<a href=\"\(url)\">\(url)</a>." }
            return "<a href=\"\(url)\">\(url)</a>"
        }
        // 4. bold then italic (masked spans are invisible to these)
        t = replace(t, pattern: "\\*\\*([^*]+)\\*\\*") { "<strong>\($0[1])</strong>" }
        t = replace(t, pattern: "(?<![A-Za-z0-9*])\\*([^*\\n]+)\\*(?![A-Za-z0-9*])") { "<em>\($0[1])</em>" }
        t = replace(t, pattern: "(^|[ \\n])__([^_]+)__(?=$|[ \\n])") { "\($0[1])<strong>\($0[2])</strong>" }

        // 5. restore masked spans
        for (i, html) in stash.enumerated() {
            t = t.replacingOccurrences(of: "\u{0}M\(i)\u{0}", with: html)
        }
        return t
    }

    /// NSRegularExpression replace with capture access. A pattern that
    /// fails to compile is a programming error — surface it loudly on
    /// stderr instead of silently passing text through.
    private static func replace(_ s: String, pattern: String, _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            FileHandle.standardError.write(Data("MarkdownLite: bad regex \(pattern)\n".utf8))
            return s
        }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for g in 0..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
