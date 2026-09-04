import Foundation

// MARK: - AST

struct OFMFrontmatter: Equatable, Sendable {
    var raw: String = ""
    var aliases: [String] = []
    var tags: [String] = []
    var cssClasses: [String] = []
    var publish: Bool? = nil
    var extra: [String: String] = [:]
}

struct WikiTarget: Equatable, Sendable {
    var raw: String
    var dest: String
    var headings: [String] = []
    var blockId: String? = nil
    var alias: String? = nil
    var width: Int? = nil
    var height: Int? = nil
    var embed: Bool = false
    var pdfPage: Int? = nil
    var pdfHeight: Int? = nil

    var display: String {
        if let alias, !alias.isEmpty { return alias }
        if dest.isEmpty {
            if let blockId { return "#^\(blockId)" }
            if !headings.isEmpty { return headings.map { "#\($0)" }.joined() }
        }
        return dest
    }

    var isMedia: Bool {
        let ext = (dest as NSString).pathExtension.lowercased()
        return Self.imageExt.contains(ext) || Self.audioExt.contains(ext)
            || Self.videoExt.contains(ext) || ext == "pdf"
    }

    var isImage: Bool { Self.imageExt.contains((dest as NSString).pathExtension.lowercased()) }
    var isAudio: Bool { Self.audioExt.contains((dest as NSString).pathExtension.lowercased()) }
    var isVideo: Bool { Self.videoExt.contains((dest as NSString).pathExtension.lowercased()) }
    var isPDF: Bool { (dest as NSString).pathExtension.lowercased() == "pdf" }

    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic"]
    static let audioExt: Set<String> = ["mp3", "m4a", "wav", "ogg", "aac", "flac"]
    static let videoExt: Set<String> = ["mp4", "webm", "ogv", "mov", "m4v"]

    static func parse(_ raw: String, embed: Bool) -> WikiTarget {
        var t = WikiTarget(raw: raw, dest: "", embed: embed)
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pipe = body.firstIndex(of: "|") {
            let left = String(body[..<pipe])
            let right = String(body[body.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
            body = left
            let destGuess = left.split(separator: "#", maxSplits: 1).first.map(String.init) ?? left
            let ext = (destGuess as NSString).pathExtension.lowercased()
            if embed, WikiTarget.imageExt.contains(ext) || ext == "svg" {
                if right.contains("x") {
                    let parts = right.lowercased().split(separator: "x")
                    t.width = parts.first.flatMap { Int($0) }
                    t.height = parts.dropFirst().first.flatMap { Int($0) }
                } else {
                    t.width = Int(right)
                }
            } else {
                t.alias = right
            }
        }
        let hashParts = body.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        t.dest = hashParts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        for part in hashParts.dropFirst() {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("^") {
                t.blockId = String(p.dropFirst())
            } else if p.contains("=") {
                for pair in p.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { continue }
                    if kv[0] == "page" { t.pdfPage = Int(kv[1]) }
                    if kv[0] == "height" { t.pdfHeight = Int(kv[1]) }
                }
            } else if !p.isEmpty {
                t.headings.append(p)
            }
        }
        return t
    }
}

indirect enum OFMInline: Equatable, Sendable {
    case text(String)
    case code(String)
    case emphasis([OFMInline])
    case strong([OFMInline])
    case strike([OFMInline])
    case highlight([OFMInline])
    case link(text: [OFMInline], url: String)
    case image(alt: String, url: String, width: Int?, height: Int?)
    case wikilink(WikiTarget)
    case embed(WikiTarget)
    case tag(String)
    case footnoteRef(String)
    case inlineFootnote([OFMInline])
    case math(String)
    case html(String)
    case lineBreak
}

struct OFMListItem: Equatable, Sendable {
    var task: Character?
    var blocks: [OFMBlock]
    var blockId: String?
}

indirect enum OFMBlock: Equatable, Sendable {
    case heading(level: Int, text: [OFMInline], blockId: String?)
    case paragraph([OFMInline], String?)
    case list(ordered: Bool, items: [OFMListItem])
    case blockquote([OFMBlock])
    case callout(type: String, title: String, fold: String?, children: [OFMBlock])
    case code(language: String, text: String)
    case mermaid(String)
    case query(String)
    case table(align: [String], header: [[OFMInline]], rows: [[[OFMInline]]])
    case thematicBreak
    case math(String)
    case html(String)
}

struct OFMDocument: Equatable, Sendable {
    var frontmatter: OFMFrontmatter
    var blocks: [OFMBlock]
    var footnotes: [String: [OFMInline]]
}

enum OFMCallout {
    static let aliases: [String: String] = [
        "summary": "abstract", "tldr": "abstract",
        "hint": "tip", "important": "tip",
        "check": "success", "done": "success",
        "help": "question", "faq": "question",
        "caution": "warning", "attention": "warning",
        "fail": "failure", "missing": "failure",
        "error": "danger",
        "cite": "quote"
    ]

    static func canonical(_ raw: String) -> String {
        let key = raw.lowercased()
        return aliases[key] ?? key
    }

    static func defaultTitle(_ type: String) -> String {
        let c = canonical(type)
        return c.prefix(1).uppercased() + c.dropFirst()
    }
}

// MARK: - Parser

enum OFMParser {
    static func parse(_ markdown: String) -> OFMDocument {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var fm = OFMFrontmatter()
        var start = 0
        if lines.first == "---" {
            if let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
                let raw = lines[1..<end].joined(separator: "\n")
                fm = parseYAML(raw)
                fm.raw = raw
                start = end + 1
            }
        }
        var i = start
        var footnotes: [String: [OFMInline]] = [:]
        let blocks = parseBlocks(lines, i: &i, footnotes: &footnotes)
        return OFMDocument(frontmatter: fm, blocks: blocks, footnotes: footnotes)
    }

    static func extractFrontmatter(_ markdown: String) -> OFMFrontmatter {
        guard markdown.hasPrefix("---") else { return OFMFrontmatter() }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else {
            return OFMFrontmatter()
        }
        let raw = lines[1..<end].joined(separator: "\n")
        var fm = parseYAML(raw)
        fm.raw = raw
        return fm
    }

    /// Longest run of characters a single link is allowed to span. Forward
    /// searches used to run to the end of the note, so a document with stray
    /// brackets cost O(n^2).
    private static let linkScanWindow = 512

    /// Fast scan for `[[wikilinks]]`, embeds, and markdown links to notes.
    static func extractLinksFast(_ markdown: String) -> [WikiTarget] {
        var s = markdown
        if s.hasPrefix("---"),
           let end = s.range(of: "\n---", range: s.index(after: s.startIndex)..<s.endIndex) {
            s = String(s[end.upperBound...])
        }
        var links: [WikiTarget] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            guard s[idx] == "[" else { idx = s.index(after: idx); continue }
            let after = s.index(after: idx)
            let window = s.index(idx, offsetBy: linkScanWindow, limitedBy: s.endIndex) ?? s.endIndex

            if after < s.endIndex, s[after] == "[" {
                let innerStart = s.index(after: after)
                if innerStart <= window, let close = s.range(of: "]]", range: innerStart..<window) {
                    let inner = String(s[innerStart..<close.lowerBound])
                    let embed = idx > s.startIndex && s[s.index(before: idx)] == "!"
                    links.append(WikiTarget.parse(inner, embed: embed))
                    idx = close.upperBound
                    continue
                }
            }

            // `[text](dest)`: find the first `]` inside the window that a `(`
            // follows, so nested brackets in the label still resolve.
            var probe = after
            var bracket: Range<String.Index>?
            while probe < window, let hit = s.range(of: "]", range: probe..<window) {
                if hit.upperBound < s.endIndex, s[hit.upperBound] == "(" { bracket = hit; break }
                probe = hit.upperBound
            }
            if let bracket {
                let urlStart = s.index(after: bracket.upperBound)
                let urlWindow = s.index(urlStart, offsetBy: linkScanWindow, limitedBy: s.endIndex) ?? s.endIndex
                if urlStart <= urlWindow, let end = s.range(of: ")", range: urlStart..<urlWindow) {
                    var url = String(s[urlStart..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if let space = url.firstIndex(of: " ") { url = String(url[..<space]) }
                    let dest = url.split(separator: "#").first.map(String.init) ?? url
                    let lower = dest.lowercased()
                    if !lower.hasPrefix("http://"), !lower.hasPrefix("https://"),
                       !lower.hasPrefix("mailto:"), !dest.hasPrefix("#"), !dest.isEmpty {
                        links.append(WikiTarget.parse(dest, embed: false))
                    }
                    idx = end.upperBound
                    continue
                }
            }
            idx = after
        }
        return links
    }

    static func extractWikiLinks(_ markdown: String) -> [WikiTarget] {
        let doc = parse(markdown)
        var out: [WikiTarget] = []
        func walkBlocks(_ blocks: [OFMBlock]) {
            for b in blocks {
                switch b {
                case .heading(_, let t, _), .paragraph(let t, _):
                    walkInlines(t)
                case .list(_, let items):
                    for it in items { walkBlocks(it.blocks) }
                case .blockquote(let ch), .callout(_, _, _, let ch):
                    walkBlocks(ch)
                case .table(_, let header, let rows):
                    header.forEach(walkInlines)
                    rows.forEach { $0.forEach(walkInlines) }
                default: break
                }
            }
        }
        func walkInlines(_ ins: [OFMInline]) {
            for n in ins {
                switch n {
                case .wikilink(let t), .embed(let t): out.append(t)
                case .emphasis(let c), .strong(let c), .strike(let c), .highlight(let c),
                     .link(text: let c, _), .inlineFootnote(let c):
                    walkInlines(c)
                default: break
                }
            }
        }
        walkBlocks(doc.blocks)
        return out
    }

    /// Compiled once: building an NSRegularExpression per paragraph showed up
    /// as ICU pattern compilation in CPU samples.
    private static let blockIDRx = try? NSRegularExpression(pattern: #"\s\^([A-Za-z0-9-]+)\s*$"#)
    private static let blockIDLineRx = try? NSRegularExpression(pattern: #"\s\^([A-Za-z0-9-]+)\s*$"#, options: .anchorsMatchLines)
    private static let calloutRx = try? NSRegularExpression(pattern: #"^\[!([A-Za-z0-9_-]+)\]([+-])?\s*(.*)$"#)

    static func extractBlockIDs(_ markdown: String) -> [String] {
        var ids: [String] = []
        let rx = blockIDLineRx
        let ns = markdown as NSString
        rx?.enumerateMatches(in: markdown, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            ids.append(ns.substring(with: match.range(at: 1)))
        }
        return ids
    }

    static func extractHeadings(_ markdown: String) -> [String] {
        parse(markdown).blocks.compactMap {
            if case .heading(_, let t, _) = $0 { return plain(t) }
            return nil
        }
    }

    static func plain(_ ins: [OFMInline]) -> String {
        ins.map { n -> String in
            switch n {
            case .text(let s), .code(let s), .math(let s), .tag(let s), .html(let s): return s
            case .emphasis(let c), .strong(let c), .strike(let c), .highlight(let c),
                 .link(text: let c, _), .inlineFootnote(let c):
                return plain(c)
            case .wikilink(let t), .embed(let t): return t.display
            case .image(let alt, _, _, _): return alt
            case .lineBreak: return " "
            case .footnoteRef: return ""
            }
        }.joined()
    }

    // MARK: YAML (properties subset)

    static func parseYAML(_ raw: String) -> OFMFrontmatter {
        var fm = OFMFrontmatter()
        var currentKey: String?
        var list: [String] = []
        func flushList() {
            guard let key = currentKey else { return }
            assign(key, .list(list), &fm)
            list = []
            currentKey = nil
        }
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("  - ") || line.hasPrefix("    - ") || line.hasPrefix("- ") && currentKey != nil {
                let item = line.trimmingCharacters(in: .whitespaces)
                    .drop(while: { $0 == "-" || $0 == " " })
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                list.append(String(item))
                continue
            }
            if currentKey != nil { flushList() }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            var val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if val.isEmpty {
                currentKey = key
                list = []
                continue
            }
            if val.hasPrefix("[") && val.hasSuffix("]") {
                let inner = val.dropFirst().dropLast()
                let items = inner.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }.filter { !$0.isEmpty }
                assign(key, .list(items), &fm)
            } else {
                val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                assign(key, .scalar(val), &fm)
            }
        }
        if currentKey != nil { flushList() }
        return fm
    }

    private enum YAMLVal { case scalar(String), list([String]) }

    private static func assign(_ key: String, _ val: YAMLVal, _ fm: inout OFMFrontmatter) {
        func strings() -> [String] {
            switch val {
            case .scalar(let s): return s.isEmpty ? [] : [s]
            case .list(let a): return a
            }
        }
        switch key {
        case "aliases", "alias": fm.aliases.append(contentsOf: strings())
        case "tags", "tag":
            fm.tags.append(contentsOf: strings().map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 })
        case "cssclasses", "cssclass": fm.cssClasses.append(contentsOf: strings())
        case "publish":
            if case .scalar(let s) = val { fm.publish = ["true", "yes", "1"].contains(s.lowercased()) }
        default:
            if case .scalar(let s) = val { fm.extra[key] = s }
            else { fm.extra[key] = strings().joined(separator: ", ") }
        }
    }

    // MARK: Blocks

    private static func parseBlocks(_ lines: [String], i: inout Int, footnotes: inout [String: [OFMInline]]) -> [OFMBlock] {
        var blocks: [OFMBlock] = []
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            if let fn = footnoteDef(trimmed) {
                i += 1
                var text = fn.1
                while i < lines.count, lines[i].hasPrefix("    ") || lines[i].hasPrefix("\t") {
                    text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                }
                footnotes[fn.0] = parseInlines(text)
                continue
            }

            if isFence(trimmed) {
                blocks.append(parseFence(lines, i: &i))
                continue
            }
            if trimmed.hasPrefix("$$") {
                blocks.append(parseMathBlock(lines, i: &i))
                continue
            }
            if isThematicBreak(trimmed), i + 1 >= lines.count || !isSetextUnderline(lines[i]) {
                // could still be setext if previous was paragraph — handled below
            }
            if let heading = atxHeading(trimmed) {
                i += 1
                let stripped = stripBlockID(heading.1)
                blocks.append(.heading(level: heading.0, text: parseInlines(stripped.text), blockId: stripped.id))
                continue
            }
            if isTableStart(lines, i) {
                blocks.append(parseTable(lines, i: &i))
                continue
            }
            if isListLine(line) {
                blocks.append(parseList(lines, i: &i, footnotes: &footnotes))
                continue
            }
            if trimmed.hasPrefix(">") {
                blocks.append(parseQuoteOrCallout(lines, i: &i, footnotes: &footnotes))
                continue
            }
            if isThematicBreak(trimmed) {
                i += 1
                blocks.append(.thematicBreak)
                continue
            }
            if trimmed.hasPrefix("<") && htmlBlockStart(trimmed) {
                blocks.append(parseHTMLBlock(lines, i: &i))
                continue
            }

            var para: [String] = []
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if isFence(t) || t.hasPrefix(">") || isListLine(l) || atxHeading(t) != nil { break }
                if isThematicBreak(t) && para.isEmpty { break }
                if i + 1 < lines.count, !para.isEmpty, isSetextUnderline(lines[i + 1]), para.count == 1 {
                    let level = lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix("=") ? 1 : 2
                    let stripped = stripBlockID(l)
                    i += 2
                    blocks.append(.heading(level: level, text: parseInlines(stripped.text), blockId: stripped.id))
                    para.removeAll()
                    break
                }
                para.append(l)
                i += 1
            }
            if !para.isEmpty {
                let joined = para.joined(separator: "\n")
                let stripped = stripBlockID(joined)
                blocks.append(.paragraph(parseInlines(stripped.text), stripped.id))
            }
        }
        return blocks
    }

    private static func isFence(_ t: String) -> Bool {
        t.hasPrefix("```") || t.hasPrefix("~~~")
    }

    private static func isThematicBreak(_ t: String) -> Bool {
        var marker: Character?
        var count = 0
        for c in t {
            if c == " " || c == "\t" { continue }
            guard c == "-" || c == "*" || c == "_" else { return false }
            if let marker, marker != c { return false }
            marker = c
            count += 1
        }
        return count >= 3
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && (t.allSatisfy { $0 == "=" } || t.allSatisfy { $0 == "-" })
    }

    private static func atxHeading(_ t: String) -> (Int, String)? {
        guard t.hasPrefix("#") else { return nil }
        var n = 0
        for ch in t {
            if ch == "#" { n += 1 } else { break }
        }
        guard n >= 1, n <= 6 else { return nil }
        let rest = t.dropFirst(n)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (n, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isListLine(_ line: String) -> Bool {
        let t = line.drop(while: { $0 == " " || $0 == "\t" })
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return true }
        var i = t.startIndex
        var saw = false
        while i < t.endIndex, t[i].isNumber { saw = true; i = t.index(after: i) }
        return saw && i < t.endIndex && t[i] == "." && t.index(after: i) < t.endIndex && t[t.index(after: i)] == " "
    }

    private static func listMarker(_ line: String) -> (indent: Int, ordered: Bool, rest: String, task: Character?)? {
        var indent = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            indent += line[idx] == "\t" ? 4 : 1
            idx = line.index(after: idx)
        }
        let restLine = String(line[idx...])
        var ordered = false
        var after = restLine
        if restLine.hasPrefix("- ") || restLine.hasPrefix("* ") || restLine.hasPrefix("+ ") {
            after = String(restLine.dropFirst(2))
        } else {
            var j = restLine.startIndex
            var saw = false
            while j < restLine.endIndex, restLine[j].isNumber { saw = true; j = restLine.index(after: j) }
            guard saw, j < restLine.endIndex, restLine[j] == "." else { return nil }
            let afterDot = restLine.index(after: j)
            guard afterDot < restLine.endIndex, restLine[afterDot] == " " else { return nil }
            ordered = true
            after = String(restLine[restLine.index(after: afterDot)...])
        }
        var task: Character?
        if after.hasPrefix("[") , after.count >= 3 {
            let chars = Array(after)
            if chars.count >= 4, chars[2] == "]", chars[3] == " " {
                task = chars[1]
                after = String(chars.dropFirst(4))
            }
        }
        return (indent, ordered, after, task)
    }

    private static func parseList(_ lines: [String], i: inout Int, footnotes: inout [String: [OFMInline]]) -> OFMBlock {
        guard let first = listMarker(lines[i]) else {
            i += 1
            return .paragraph(parseInlines(lines[i - 1]), nil)
        }
        let ordered = first.ordered
        let baseIndent = first.indent
        var items: [OFMListItem] = []
        while i < lines.count, let mark = listMarker(lines[i]), mark.ordered == ordered, mark.indent == baseIndent {
            i += 1
            var chunk = [mark.rest]
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty {
                    if i + 1 < lines.count, listMarker(lines[i + 1]) != nil { break }
                    if i + 1 < lines.count, lines[i + 1].hasPrefix(String(repeating: " ", count: baseIndent + 2)) {
                        i += 1
                        continue
                    }
                    break
                }
                if let m = listMarker(l) {
                    if m.indent == baseIndent { break }
                    if m.indent > baseIndent { break }
                }
                let indentStr = String(repeating: " ", count: baseIndent + 2)
                if l.hasPrefix(indentStr) {
                    chunk.append(String(l.dropFirst(min(l.count, baseIndent + 2))))
                    i += 1
                    continue
                }
                break
            }
            var subI = 0
            let subLines = chunk
            var nested = parseBlocks(subLines, i: &subI, footnotes: &footnotes)
            if nested.isEmpty {
                let stripped = stripBlockID(mark.rest)
                nested = [.paragraph(parseInlines(stripped.text), stripped.id)]
                items.append(OFMListItem(task: mark.task, blocks: nested, blockId: stripped.id))
            } else {
                var bid: String?
                if case .paragraph(let ins, let id) = nested.first {
                    bid = id
                    nested[0] = .paragraph(ins, id)
                }
                items.append(OFMListItem(task: mark.task, blocks: nested, blockId: bid))
            }
        }
        return .list(ordered: ordered, items: items)
    }

    private static func parseQuoteOrCallout(_ lines: [String], i: inout Int, footnotes: inout [String: [OFMInline]]) -> OFMBlock {
        var inner: [String] = []
        while i < lines.count {
            let t = lines[i]
            if t.hasPrefix(">") {
                var s = String(t.dropFirst())
                if s.hasPrefix(" ") { s = String(s.dropFirst()) }
                inner.append(s)
                i += 1
            } else if t.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            } else {
                break
            }
        }
        if let first = inner.first,
           let m = calloutRx?.firstMatch(in: first, range: NSRange(location: 0, length: (first as NSString).length)),
           m.numberOfRanges >= 4 {
            let ns = first as NSString
            let type = ns.substring(with: m.range(at: 1))
            var fold: String?
            if m.range(at: 2).location != NSNotFound, m.range(at: 2).length > 0 {
                fold = ns.substring(with: m.range(at: 2))
            }
            var title = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            if title.isEmpty { title = OFMCallout.defaultTitle(type) }
            var rest = Array(inner.dropFirst())
            var j = 0
            let children = parseBlocks(rest, i: &j, footnotes: &footnotes)
            return .callout(type: OFMCallout.canonical(type), title: title, fold: fold, children: children)
        }
        var j = 0
        let children = parseBlocks(inner, i: &j, footnotes: &footnotes)
        return .blockquote(children)
    }

    private static func parseFence(_ lines: [String], i: inout Int) -> OFMBlock {
        let open = lines[i].trimmingCharacters(in: .whitespaces)
        let mark = open.hasPrefix("```") ? "```" : "~~~"
        var n = 0
        for ch in open {
            if ch == mark.first! { n += 1 } else { break }
        }
        let info = String(open.dropFirst(n)).trimmingCharacters(in: .whitespaces)
        let lang = info.split(separator: " ").first.map(String.init) ?? ""
        i += 1
        var body: [String] = []
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(mark), t.filter({ $0 == mark.first }).count >= n {
                i += 1
                break
            }
            body.append(lines[i])
            i += 1
        }
        let text = body.joined(separator: "\n")
        let key = lang.lowercased()
        if key == "mermaid" { return .mermaid(text) }
        if key == "query" { return .query(text) }
        if key == "math" || key == "latex" { return .math(text) }
        return .code(language: lang, text: text)
    }

    private static func parseMathBlock(_ lines: [String], i: inout Int) -> OFMBlock {
        var line = lines[i].trimmingCharacters(in: .whitespaces)
        i += 1
        if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count > 4 {
            let inner = String(line.dropFirst(2).dropLast(2))
            return .math(inner)
        }
        var body: [String] = []
        if line != "$$" { body.append(String(line.dropFirst(2))) }
        while i < lines.count {
            let t = lines[i]
            i += 1
            if t.trimmingCharacters(in: .whitespaces).hasSuffix("$$") {
                let cut = t.trimmingCharacters(in: .whitespaces)
                if cut != "$$" { body.append(String(cut.dropLast(2))) }
                break
            }
            body.append(t)
        }
        return .math(body.joined(separator: "\n"))
    }

    private static func isTableStart(_ lines: [String], _ i: Int) -> Bool {
        guard i + 1 < lines.count, lines[i].contains("|") else { return false }
        let sep = lines[i + 1].trimmingCharacters(in: .whitespaces)
        let compact = sep.replacingOccurrences(of: " ", with: "")
        return compact.contains("|") && compact.contains("-") && compact.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" }
    }

    private static func parseTable(_ lines: [String], i: inout Int) -> OFMBlock {
        func cells(_ line: String) -> [String] {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s = String(s.dropFirst()) }
            if s.hasSuffix("|") { s = String(s.dropLast()) }
            return s.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let header = cells(lines[i]).map { parseInlines($0) }
        i += 1
        let seps = cells(lines[i])
        i += 1
        let align: [String] = seps.map { s in
            let left = s.hasPrefix(":")
            let right = s.hasSuffix(":")
            if left && right { return "center" }
            if right { return "right" }
            if left { return "left" }
            return ""
        }
        var rows: [[[OFMInline]]] = []
        while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            rows.append(cells(lines[i]).map { parseInlines($0) })
            i += 1
        }
        return .table(align: align, header: header, rows: rows)
    }

    private static func htmlBlockStart(_ t: String) -> Bool {
        let tags = ["div", "table", "pre", "ul", "ol", "p", "blockquote", "details", "summary", "section", "article", "iframe"]
        let lower = t.lowercased()
        return tags.contains { lower.hasPrefix("<" + $0) }
    }

    private static func parseHTMLBlock(_ lines: [String], i: inout Int) -> OFMBlock {
        var body: [String] = []
        let start = lines[i].trimmingCharacters(in: .whitespaces).lowercased()
        var tag = ""
        if start.hasPrefix("<") {
            tag = String(start.dropFirst().prefix { $0.isLetter })
        }
        repeat {
            body.append(lines[i])
            i += 1
            if let last = body.last?.lowercased(), !tag.isEmpty, last.contains("</\(tag)") { break }
            if i >= lines.count { break }
            if lines[i].trimmingCharacters(in: .whitespaces).isEmpty, tag.isEmpty { break }
        } while i < lines.count
        return .html(body.joined(separator: "\n"))
    }

    private static func footnoteDef(_ t: String) -> (String, String)? {
        guard t.hasPrefix("[^"), let close = t.firstIndex(of: "]"),
              close < t.endIndex, t[t.index(after: close)] == ":" else { return nil }
        let id = String(t[t.index(t.startIndex, offsetBy: 2)..<close])
        let text = String(t[t.index(after: t.index(after: close))...]).trimmingCharacters(in: .whitespaces)
        return (id, text)
    }

    private static func stripBlockID(_ text: String) -> (text: String, id: String?) {
        guard let rx = blockIDRx else { return (text, nil) }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = rx.firstMatch(in: text, range: range), m.numberOfRanges > 1 else {
            return (text, nil)
        }
        let id = ns.substring(with: m.range(at: 1))
        let cut = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        return (cut, id)
    }

    // MARK: Inlines

    static func parseInlines(_ text: String) -> [OFMInline] {
        let chars = Array(text)
        var i = 0
        var out: [OFMInline] = []
        var buf = ""
        func flush() {
            if !buf.isEmpty { out.append(.text(buf)); buf.removeAll(keepingCapacity: true) }
        }
        let n = chars.count
        let punct = CharacterSet(charactersIn: "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

        while i < n {
            let c = chars[i]
            if c == "\\" , i + 1 < n {
                let next = chars[i + 1]
                if String(next).unicodeScalars.allSatisfy({ punct.contains($0) }) {
                    buf.append(next)
                    i += 2
                    continue
                }
            }
            if c == "%" , i + 1 < n, chars[i + 1] == "%" {
                flush()
                i += 2
                while i + 1 < n, !(chars[i] == "%" && chars[i + 1] == "%") { i += 1 }
                if i + 1 < n { i += 2 } else { i = n }
                continue
            }
            if c == "`" {
                flush()
                if let code = takeDelimited(chars, i: &i, delim: "`") {
                    out.append(.code(code))
                    continue
                }
            }
            if c == "$", i + 1 < n, chars[i + 1] != " ", chars[i + 1] != "$" {
                flush()
                if let math = takeMath(chars, i: &i) {
                    out.append(.math(math))
                    continue
                }
            }
            if c == "!", i + 2 < n, chars[i + 1] == "[", chars[i + 2] == "[" {
                flush()
                i += 3
                if let inner = takeUntil(chars, i: &i, close: "]]") {
                    out.append(.embed(WikiTarget.parse(inner, embed: true)))
                    continue
                }
            }
            if c == "[", i + 1 < n, chars[i + 1] == "[" {
                flush()
                i += 2
                if let inner = takeUntil(chars, i: &i, close: "]]") {
                    out.append(.wikilink(WikiTarget.parse(inner, embed: false)))
                    continue
                }
            }
            if c == "=", i + 1 < n, chars[i + 1] == "=" {
                flush()
                i += 2
                if let inner = takeUntil(chars, i: &i, close: "==") {
                    out.append(.highlight(parseInlines(inner)))
                    continue
                }
            }
            if c == "~", i + 1 < n, chars[i + 1] == "~" {
                flush()
                i += 2
                if let inner = takeUntil(chars, i: &i, close: "~~") {
                    out.append(.strike(parseInlines(inner)))
                    continue
                }
            }
            if c == "*", i + 1 < n, chars[i + 1] == "*" {
                flush()
                i += 2
                if let inner = takeUntil(chars, i: &i, close: "**") {
                    out.append(.strong(parseInlines(inner)))
                    continue
                }
            }
            if c == "_", i + 1 < n, chars[i + 1] == "_" {
                flush()
                i += 2
                if let inner = takeUntil(chars, i: &i, close: "__") {
                    out.append(.strong(parseInlines(inner)))
                    continue
                }
            }
            if c == "*" {
                flush()
                i += 1
                if let inner = takeUntil(chars, i: &i, close: "*") {
                    out.append(.emphasis(parseInlines(inner)))
                    continue
                }
            }
            if c == "_" {
                let atEdge = i == 0 || chars[i - 1].isWhitespace || !chars[i - 1].isLetter
                if atEdge {
                    flush()
                    i += 1
                    if let inner = takeUntil(chars, i: &i, close: "_") {
                        out.append(.emphasis(parseInlines(inner)))
                        continue
                    }
                }
            }
            if c == "!", i + 1 < n, chars[i + 1] == "[" {
                flush()
                if let img = takeMarkdownImage(chars, i: &i) {
                    out.append(img)
                    continue
                }
            }
            if c == "[", i + 1 < n, chars[i + 1] == "^" {
                flush()
                i += 2
                if let id = takeUntil(chars, i: &i, close: "]") {
                    out.append(.footnoteRef(id))
                    continue
                }
            }
            if c == "^", i + 1 < n, chars[i + 1] == "[" {
                flush()
                i += 2
                if let inner = takeUntil(chars, i: &i, close: "]") {
                    out.append(.inlineFootnote(parseInlines(inner)))
                    continue
                }
            }
            if c == "[" {
                flush()
                if let link = takeMarkdownLink(chars, i: &i) {
                    out.append(link)
                    continue
                }
            }
            if c == "#", i + 1 < n, isTagStart(chars[i + 1]) {
                flush()
                i += 1
                var tag = ""
                while i < n, isTagChar(chars[i]) { tag.append(chars[i]); i += 1 }
                if tag.isEmpty || tag.allSatisfy(\.isNumber) {
                    buf.append("#")
                    buf.append(tag)
                } else {
                    out.append(.tag(tag))
                }
                continue
            }
            if c == "<" {
                flush()
                if let html = takeHTML(chars, i: &i) {
                    out.append(.html(html))
                    continue
                }
            }
            if c == "\n" {
                flush()
                out.append(.lineBreak)
                i += 1
                continue
            }
            buf.append(c)
            i += 1
        }
        flush()
        return out
    }

    private static func isTagStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
    private static func isTagChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-" || c == "/"
    }

    private static func takeUntil(_ chars: [Character], i: inout Int, close: String) -> String? {
        let start = i
        let closeChars = Array(close)
        while i < chars.count {
            if matches(chars, at: i, closeChars) {
                let inner = String(chars[start..<i])
                i += closeChars.count
                return inner
            }
            i += 1
        }
        i = start
        return nil
    }

    private static func takeDelimited(_ chars: [Character], i: inout Int, delim: Character) -> String? {
        var n = 0
        while i + n < chars.count, chars[i + n] == delim { n += 1 }
        i += n
        let start = i
        while i + n <= chars.count {
            if matches(chars, at: i, Array(repeating: delim, count: n)) {
                let inner = String(chars[start..<i])
                i += n
                return inner
            }
            i += 1
        }
        i = start - n
        return nil
    }

    private static func takeMath(_ chars: [Character], i: inout Int) -> String? {
        let startI = i
        i += 1
        let start = i
        while i < chars.count {
            if chars[i] == "$", i > start, chars[i - 1] != " ", chars[i - 1] != "\\" {
                let inner = String(chars[start..<i])
                if inner.contains("\n\n") { break }
                i += 1
                return inner
            }
            i += 1
        }
        i = startI
        return nil
    }

    private static func takeMarkdownLink(_ chars: [Character], i: inout Int) -> OFMInline? {
        let save = i
        i += 1
        guard let text = takeUntil(chars, i: &i, close: "]") else { i = save; return nil }
        guard i < chars.count, chars[i] == "(" else { i = save; return nil }
        i += 1
        guard let url = takeUntil(chars, i: &i, close: ")") else { i = save; return nil }
        return .link(text: parseInlines(text), url: url.trimmingCharacters(in: .whitespaces))
    }

    private static func takeMarkdownImage(_ chars: [Character], i: inout Int) -> OFMInline? {
        let save = i
        i += 2
        guard let altRaw = takeUntil(chars, i: &i, close: "]") else { i = save; return nil }
        guard i < chars.count, chars[i] == "(" else { i = save; return nil }
        i += 1
        guard let url = takeUntil(chars, i: &i, close: ")") else { i = save; return nil }
        var alt = altRaw
        var width: Int?
        var height: Int?
        if let pipe = altRaw.lastIndex(of: "|") {
            let size = String(altRaw[altRaw.index(after: pipe)...])
            alt = String(altRaw[..<pipe])
            if size.contains("x") {
                let p = size.lowercased().split(separator: "x")
                width = p.first.flatMap { Int($0) }
                height = p.dropFirst().first.flatMap { Int($0) }
            } else {
                width = Int(size)
            }
        }
        return .image(alt: alt, url: url.trimmingCharacters(in: .whitespaces), width: width, height: height)
    }

    private static func takeHTML(_ chars: [Character], i: inout Int) -> String? {
        let save = i
        var j = i + 1
        if j < chars.count, chars[j] == "/" { j += 1 }
        guard j < chars.count, chars[j].isLetter else { return nil }
        while j < chars.count, chars[j] != ">" { j += 1 }
        guard j < chars.count else { i = save; return nil }
        let html = String(chars[i...j])
        i = j + 1
        return html
    }

    private static func matches(_ chars: [Character], at i: Int, _ needle: [Character]) -> Bool {
        guard i + needle.count <= chars.count else { return false }
        for k in 0..<needle.count where chars[i + k] != needle[k] { return false }
        return true
    }
}
