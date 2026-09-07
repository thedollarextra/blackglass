import Foundation

struct OFMRenderMode: Equatable {
    var web: Bool
    var themeClass: String
}

enum OFMHTML {
    static func render(
        markdown: String,
        current: URL,
        vault: URL,
        wiki: WikiIndex,
        search: SearchIndex,
        mode: OFMRenderMode,
        depth: Int = 0,
        seen: Set<String> = []
    ) -> String {
        let doc = OFMParser.parse(markdown)
        var ctx = Context(
            current: current,
            vault: vault,
            wiki: wiki,
            search: search,
            web: mode.web,
            depth: depth,
            seen: seen.union([current.standardizedFileURL.path])
        )
        var body = renderBlocks(doc.blocks, ctx: &ctx)
        if !doc.footnotes.isEmpty {
            body += "<section class=\"footnotes\"><hr/><ol>"
            for (key, ins) in doc.footnotes.sorted(by: { $0.key < $1.key }) {
                body += "<li id=\"fn-\(escapeAttr(key))\">\(renderInlines(ins, ctx: &ctx)) <a href=\"#fnref-\(escapeAttr(key))\">↩︎</a></li>"
            }
            body += "</ol></section>"
        }
        let classes = (["ofm-note"] + doc.frontmatter.cssClasses).joined(separator: " ")
        if mode.web {
            return "<div class=\"\(escapeAttr(classes))\">\(body)</div>"
        }
        let css = stylesheet()
        return """
        <!doctype html>
        <html class="\(escapeAttr(mode.themeClass))" lang="en">
        <head>
          <meta charset="utf-8"/>
          <meta name="viewport" content="width=device-width, initial-scale=1"/>
          <style>\(css)</style>
          <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        </head>
        <body>
          <div class="\(escapeAttr(classes))">\(body)</div>
          <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
          <script defer src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
          <script>
            document.addEventListener('DOMContentLoaded', () => {
              try { mermaid.initialize({ startOnLoad: true, theme: document.documentElement.classList.contains('theme-light') ? 'neutral' : 'dark' }); } catch (e) {}
              try {
                document.querySelectorAll('.math-inline').forEach(el => {
                  katex.render(el.getAttribute('data-latex') || el.textContent, el, { throwOnError: false, displayMode: false });
                });
                document.querySelectorAll('.math-block').forEach(el => {
                  katex.render(el.getAttribute('data-latex') || el.textContent, el, { throwOnError: false, displayMode: true });
                });
              } catch (e) {}
            });
          </script>
        </body>
        </html>
        """
    }

    private struct Context {
        var current: URL
        var vault: URL
        var wiki: WikiIndex
        var search: SearchIndex
        var web: Bool
        var depth: Int
        var seen: Set<String>
        /// Notes link to the same handful of targets over and over, and each
        /// miss in `WikiIndex.resolveNote` costs up to eight `stat` calls.
        /// Reset for an embed, whose resolution is relative to its own folder.
        var noteCache: [String: URL?] = [:]
    }

    private static func resolvedNote(_ target: String, ctx: inout Context) -> URL? {
        if let hit = ctx.noteCache[target] { return hit }
        let url = ctx.wiki.resolveNote(target: target, from: ctx.current, vault: ctx.vault)
        ctx.noteCache.updateValue(url, forKey: target)
        return url
    }

    private static func renderBlocks(_ blocks: [OFMBlock], ctx: inout Context) -> String {
        var out = ""
        for b in blocks { out += renderBlock(b, ctx: &ctx) }
        return out
    }

    /// A transcluded note or PDF renders as a block element, but the parser
    /// sees an embed as inline, so it lands inside the paragraph it was
    /// written in. No parser accepts a <div> inside a <p>: the browser closes
    /// the paragraph before it and strands the </p> as an empty one after,
    /// leaving the embed outside the element meant to be styling it.
    ///
    /// So a paragraph is split around any block-level embed — the text either
    /// side of it becomes its own paragraph. An embedded *image* is genuinely
    /// inline and stays where it was written.
    private static func renderParagraph(
        _ inlines: [OFMInline], bid: String, ctx: inout Context
    ) -> String {
        // Almost every paragraph has no embed at all, and transcluding one is
        // expensive enough not to want it rendered twice to find out.
        let hasEmbed = inlines.contains { if case .embed = $0 { return true } else { return false } }
        if !hasEmbed {
            return "<p\(bid)>\(renderInlines(inlines, ctx: &ctx))</p>\n"
        }

        var out = ""
        var run: [OFMInline] = []
        func flushRun(_ ctx: inout Context) {
            guard !run.isEmpty else { return }
            let html = renderInlines(run, ctx: &ctx)
            run.removeAll()
            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            out += "<p>\(html)</p>\n"
        }
        for node in inlines {
            guard case .embed = node else {
                run.append(node)
                continue
            }
            let html = renderInlines([node], ctx: &ctx)
            guard html.hasPrefix("<div") || html.hasPrefix("<iframe") else {
                run.append(node)
                continue
            }
            flushRun(&ctx)
            out += html + "\n"
        }
        flushRun(&ctx)
        if out.isEmpty { return "<p\(bid)></p>\n" }
        // The block id belonged to one paragraph that is now several elements,
        // so it moves to a wrapper around them. Only a paragraph carrying both
        // a ^block-id and an embed takes this path.
        return bid.isEmpty ? out : "<div\(bid)>\n\(out)</div>\n"
    }

    private static func renderBlock(_ block: OFMBlock, ctx: inout Context) -> String {
        switch block {
        case .heading(let level, let text, let id):
            let slug = slugify(OFMParser.plain(text))
            let bid = id.map { " id=\"^\($0)\"" } ?? ""
            return "<h\(level) id=\"\(escapeAttr(slug))\"\(bid)>\(renderInlines(text, ctx: &ctx))</h\(level)>\n"
        case .paragraph(let text, let id):
            return renderParagraph(text, bid: id.map { " id=\"^\($0)\"" } ?? "", ctx: &ctx)
        case .list(let ordered, let items):
            let tag = ordered ? "ol" : "ul"
            var inner = ""
            for item in items {
                if let task = item.task {
                    let checked = task == "x" || task == "X"
                    let box = "<input type=\"checkbox\" disabled \(checked ? "checked" : "")/> "
                    let body = renderBlocks(item.blocks, ctx: &ctx)
                    inner += "<li class=\"task\" data-task=\"\(task)\">\(box)\(body)</li>"
                    continue
                }
                let bid = item.blockId.map { " id=\"^\($0)\"" } ?? ""
                inner += "<li\(bid)>\(renderBlocks(item.blocks, ctx: &ctx))</li>"
            }
            return "<\(tag)>\(inner)</\(tag)>\n"
        case .blockquote(let children):
            return "<blockquote>\(renderBlocks(children, ctx: &ctx))</blockquote>\n"
        case .callout(let type, let title, let fold, let children):
            let inner = renderBlocks(children, ctx: &ctx)
            let icon = calloutIcon(type)
            let head = "<div class=\"callout-title\"><span class=\"callout-icon\">\(icon)</span><span>\(escape(title))</span></div>"
            if fold == "+" {
                return "<details class=\"callout callout-\(escapeAttr(type))\" open><summary>\(head)</summary><div class=\"callout-body\">\(inner)</div></details>\n"
            }
            if fold == "-" {
                return "<details class=\"callout callout-\(escapeAttr(type))\"><summary>\(head)</summary><div class=\"callout-body\">\(inner)</div></details>\n"
            }
            return "<div class=\"callout callout-\(escapeAttr(type))\">\(head)<div class=\"callout-body\">\(inner)</div></div>\n"
        case .code(let language, let text):
            let cls = language.isEmpty ? "" : " class=\"language-\(escapeAttr(language))\""
            return "<pre><code\(cls)>\(escape(text))</code></pre>\n"
        case .mermaid(let text):
            return "<pre class=\"mermaid\">\(escape(text))</pre>\n"
        case .query(let text):
            return renderQuery(text, ctx: &ctx)
        case .table(let align, let header, let rows):
            func cell(_ ins: [OFMInline], _ tag: String, _ i: Int) -> String {
                let a = i < align.count && !align[i].isEmpty ? " style=\"text-align:\(align[i])\"" : ""
                return "<\(tag)\(a)>\(renderInlines(ins, ctx: &ctx))</\(tag)>"
            }
            var html = "<table><thead><tr>"
            for (i, h) in header.enumerated() { html += cell(h, "th", i) }
            html += "</tr></thead><tbody>"
            for row in rows {
                html += "<tr>"
                for (i, c) in row.enumerated() { html += cell(c, "td", i) }
                html += "</tr>"
            }
            html += "</tbody></table>\n"
            return html
        case .thematicBreak:
            return "<hr/>\n"
        case .math(let tex):
            return "<div class=\"math-block\" data-latex=\"\(escapeAttr(tex))\">\(escape(tex))</div>\n"
        case .html(let raw):
            return raw + "\n"
        }
    }

    private static func renderInlines(_ ins: [OFMInline], ctx: inout Context) -> String {
        if ins.count == 1 { return renderInline(ins[0], ctx: &ctx) }
        var out = ""
        for n in ins { out += renderInline(n, ctx: &ctx) }
        return out
    }

    private static func renderInline(_ n: OFMInline, ctx: inout Context) -> String {
        switch n {
        case .text(let s): return escape(s)
        case .code(let s): return "<code>\(escape(s))</code>"
        case .emphasis(let c): return "<em>\(renderInlines(c, ctx: &ctx))</em>"
        case .strong(let c): return "<strong>\(renderInlines(c, ctx: &ctx))</strong>"
        case .strike(let c): return "<del>\(renderInlines(c, ctx: &ctx))</del>"
        case .highlight(let c): return "<mark>\(renderInlines(c, ctx: &ctx))</mark>"
        case .link(let text, let url):
            return "<a href=\"\(escapeAttr(url))\">\(renderInlines(text, ctx: &ctx))</a>"
        case .image(let alt, let url, let w, let h):
            var dim = ""
            if let w { dim += " width=\"\(w)\"" }
            if let h { dim += " height=\"\(h)\"" }
            return "<img src=\"\(escapeAttr(mediaSrc(url, ctx: ctx)))\" alt=\"\(escapeAttr(alt))\"\(dim)/>"
        case .wikilink(let t):
            return renderWiki(t, ctx: &ctx)
        case .embed(let t):
            return renderEmbed(t, ctx: &ctx)
        case .tag(let t):
            return "<span class=\"tag\">#\(escape(t))</span>"
        case .footnoteRef(let id):
            return "<sup class=\"fn\" id=\"fnref-\(escapeAttr(id))\"><a href=\"#fn-\(escapeAttr(id))\">[\(escape(id))]</a></sup>"
        case .inlineFootnote(let c):
            return "<span class=\"inline-fn\">(\(renderInlines(c, ctx: &ctx)))</span>"
        case .math(let tex):
            return "<span class=\"math-inline\" data-latex=\"\(escapeAttr(tex))\">\(escape(tex))</span>"
        case .html(let raw): return raw
        case .lineBreak: return "<br/>"
        }
    }

    private static func renderWiki(_ t: WikiTarget, ctx: inout Context) -> String {
        if t.dest.isEmpty, t.headings.isEmpty, t.blockId == nil {
            return "<span class=\"wikilink unresolved\">\(escape(t.display))</span>"
        }
        // The old `??` fallback re-ran the identical lookup whenever a link with
        // a non-empty destination failed to resolve, doubling the `stat` storm
        // for exactly the links that are already the expensive ones.
        let target = t.dest.isEmpty ? ctx.current.deletingPathExtension().lastPathComponent : t.dest
        var resolved = resolvedNote(target, ctx: &ctx)
        if resolved == nil, t.dest.isEmpty { resolved = ctx.current }
        if let url = resolved {
            let rel = ctx.wiki.relative(url, vault: ctx.vault)
            var href = wikiHref(rel, web: ctx.web)
            if let bid = t.blockId { href += "#^\(bid)" }
            else if !t.headings.isEmpty { href += "#\(slugify(t.headings.last ?? ""))" }
            return "<a class=\"wikilink\" href=\"\(escapeAttr(href))\" data-path=\"\(escapeAttr(rel))\">\(escape(t.display))</a>"
        }
        return "<a class=\"wikilink unresolved\" href=\"#\" data-target=\"\(escapeAttr(t.dest))\">\(escape(t.display))</a>"
    }

    private static func renderEmbed(_ t: WikiTarget, ctx: inout Context) -> String {
        if t.isImage {
            let file = ctx.wiki.resolveFile(named: t.dest, from: ctx.current, vault: ctx.vault)
            let src = file.map { mediaFile($0, ctx: ctx) } ?? t.dest
            var dim = ""
            if let w = t.width { dim += " width=\"\(w)\"" }
            if let h = t.height { dim += " height=\"\(h)\"" }
            return "<img class=\"embed-img\" src=\"\(escapeAttr(src))\" alt=\"\(escapeAttr(t.dest))\"\(dim)/>"
        }
        if t.isAudio {
            let file = ctx.wiki.resolveFile(named: t.dest, from: ctx.current, vault: ctx.vault)
            let src = file.map { mediaFile($0, ctx: ctx) } ?? t.dest
            return "<audio controls src=\"\(escapeAttr(src))\"></audio>"
        }
        if t.isVideo {
            let file = ctx.wiki.resolveFile(named: t.dest, from: ctx.current, vault: ctx.vault)
            let src = file.map { mediaFile($0, ctx: ctx) } ?? t.dest
            return "<video controls src=\"\(escapeAttr(src))\"></video>"
        }
        if t.isPDF {
            let file = ctx.wiki.resolveFile(named: t.dest, from: ctx.current, vault: ctx.vault)
            var src = file.map { mediaFile($0, ctx: ctx) } ?? t.dest
            if let page = t.pdfPage { src += src.contains("#") ? "&page=\(page)" : "#page=\(page)" }
            let height = t.pdfHeight ?? 480
            return "<iframe class=\"embed-pdf\" src=\"\(escapeAttr(src))\" style=\"height:\(height)px\"></iframe>"
        }
        guard ctx.depth < 4 else { return "<div class=\"embed\">Too many nested embeds.</div>" }
        let destURL: URL? = t.dest.isEmpty
            ? ctx.current
            : resolvedNote(t.dest, ctx: &ctx)
        guard let destURL else {
            return "<div class=\"embed unresolved\">Missing: \(escape(t.display))</div>"
        }
        let key = destURL.standardizedFileURL.path
        if ctx.seen.contains(key), !t.dest.isEmpty {
            return "<div class=\"embed\">Cycle: \(escape(t.display))</div>"
        }
        let content = (try? String(contentsOf: destURL, encoding: .utf8)) ?? ""
        let doc = OFMParser.parse(content)
        var slice = doc.blocks
        if let bid = t.blockId {
            slice = blocksWithID(bid, in: doc.blocks)
        } else if let heading = t.headings.last {
            slice = blocksUnderHeading(heading, in: doc.blocks)
        }
        var child = ctx
        child.current = destURL
        child.depth += 1
        child.seen.insert(key)
        child.noteCache.removeAll()
        let inner = renderBlocks(slice, ctx: &child)
        let title = FileItem(url: destURL, isDirectory: false).displayTitle
        return "<div class=\"embed\"><div class=\"embed-title\">\(escape(title))</div>\(inner)</div>"
    }

    private static func blocksWithID(_ id: String, in blocks: [OFMBlock]) -> [OFMBlock] {
        func match(_ block: OFMBlock) -> OFMBlock? {
            switch block {
            case .paragraph(_, let bid), .heading(_, _, let bid):
                return bid == id ? block : nil
            case .list(let ordered, let items):
                let hits = items.filter { $0.blockId == id }
                if !hits.isEmpty { return .list(ordered: ordered, items: hits) }
                return nil
            case .blockquote(let ch):
                let inner = blocksWithID(id, in: ch)
                return inner.isEmpty ? nil : .blockquote(inner)
            case .callout(let t, let title, let f, let ch):
                let inner = blocksWithID(id, in: ch)
                return inner.isEmpty ? nil : .callout(type: t, title: title, fold: f, children: inner)
            default:
                return nil
            }
        }
        var found: [OFMBlock] = []
        for b in blocks {
            if let m = match(b) { found.append(m) }
        }
        return found
    }

    private static func blocksUnderHeading(_ heading: String, in blocks: [OFMBlock]) -> [OFMBlock] {
        var start: Int?
        var level = 1
        for (i, b) in blocks.enumerated() {
            if case .heading(let lv, let text, _) = b, OFMParser.plain(text).caseInsensitiveCompare(heading) == .orderedSame {
                start = i + 1
                level = lv
                break
            }
        }
        guard let start else { return [] }
        var end = blocks.count
        for j in start..<blocks.count {
            if case .heading(let lv, _, _) = blocks[j], lv <= level {
                end = j
                break
            }
        }
        return Array(blocks[start..<end])
    }

    private static func renderQuery(_ text: String, ctx: inout Context) -> String {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [(String, String)] = []
        let parts = q.replacingOccurrences(of: " AND ", with: "\u{1e}").replacingOccurrences(of: " and ", with: "\u{1e}").split(separator: "\u{1e}").map(String.init)
        var tagFilter: String?
        var fileFilter: String?
        var rest: [String] = []
        for p in parts {
            let t = p.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("tag:") {
                tagFilter = String(t.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "#\"' "))
            } else if t.lowercased().hasPrefix("file:") {
                fileFilter = t.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            } else if !t.isEmpty {
                rest.append(t)
            }
        }
        if let tagFilter {
            results = ctx.wiki.notesWithTag(tagFilter).map { ($0.title, $0.relativePath) }
        } else if rest.isEmpty, fileFilter == nil {
            results = []
        }
        if let fileFilter {
            let needle = fileFilter.lowercased()
            if results.isEmpty {
                results = ctx.search.search(query: fileFilter).map {
                    ($0.title, ctx.wiki.relative($0.fileItem.url, vault: ctx.vault))
                }
            }
            results = results.filter { $0.0.lowercased().contains(needle) || $0.1.lowercased().contains(needle) }
        }
        if !rest.isEmpty {
            let hits = ctx.search.search(query: rest.joined(separator: " "))
            let mapped = hits.map { ($0.title, ctx.wiki.relative($0.fileItem.url, vault: ctx.vault)) }
            if results.isEmpty { results = mapped }
            else {
                let set = Set(mapped.map(\.1))
                results = results.filter { set.contains($0.1) }
            }
        }
        if results.isEmpty {
            return "<div class=\"query\"><div class=\"query-q\"><code>\(escape(q))</code></div><p class=\"muted\">No matches</p></div>"
        }
        let items = results.prefix(40).map { title, path in
            "<li><a class=\"wikilink\" href=\"\(escapeAttr(wikiHref(path, web: ctx.web)))\" data-path=\"\(escapeAttr(path))\">\(escape(title))</a></li>"
        }.joined()
        return "<div class=\"query\"><div class=\"query-q\"><code>\(escape(q))</code></div><ul>\(items)</ul></div>"
    }

    private static func wikiHref(_ rel: String, web: Bool) -> String {
        if web { return "#note=\(rel)" }
        return "blackglass://note?path=\(rel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rel)"
    }

    private static func mediaSrc(_ url: String, ctx: Context) -> String {
        if url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("data:") { return url }
        if let file = ctx.wiki.resolveFile(named: url, from: ctx.current, vault: ctx.vault) {
            return mediaFile(file, ctx: ctx)
        }
        return url
    }

    private static func mediaFile(_ url: URL, ctx: Context) -> String {
        let rel = ctx.wiki.relative(url, vault: ctx.vault)
        if ctx.web { return "/api/file?path=\(rel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rel)" }
        return url.absoluteString
    }

    /// The old chain built a whole replacement string, then a filtered scalar
    /// array, then a `String` per surviving scalar, then joined them — four
    /// passes and one allocation per character of every heading and every
    /// heading-bearing wikilink.
    private static func slugify(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var out = String.UnicodeScalarView()
        for c in s.lowercased() {
            // Walking graphemes, not scalars: `replacingOccurrences` matched
            // whole characters, so a space carrying a combining mark was never
            // a space to it and fell through to the scalar filter instead.
            if c == " " {
                out.append("-")
                continue
            }
            for u in c.unicodeScalars where allowed.contains(u) || u == "-" {
                out.append(u)
            }
        }
        return String(out)
    }

    /// Chained `replacingOccurrences` walked the string three times (four for
    /// an attribute) and allocated a fresh `String` per pass, for every text
    /// node in the note. Escaping is pure ASCII, so one UTF-8 pass does it —
    /// and the overwhelmingly common case, nothing to escape, allocates nothing.
    private static func escape(_ s: String) -> String {
        guard s.utf8.contains(where: { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E }) else { return s }
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count + 16)
        for b in s.utf8 {
            switch b {
            case 0x26: out.append(contentsOf: "&amp;".utf8)
            case 0x3C: out.append(contentsOf: "&lt;".utf8)
            case 0x3E: out.append(contentsOf: "&gt;".utf8)
            default: out.append(b)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func escapeAttr(_ s: String) -> String {
        guard s.utf8.contains(where: { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0x22 }) else { return s }
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count + 16)
        for b in s.utf8 {
            switch b {
            case 0x26: out.append(contentsOf: "&amp;".utf8)
            case 0x3C: out.append(contentsOf: "&lt;".utf8)
            case 0x3E: out.append(contentsOf: "&gt;".utf8)
            case 0x22: out.append(contentsOf: "&quot;".utf8)
            default: out.append(b)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func calloutIcon(_ type: String) -> String {
        switch type {
        case "abstract", "tip": return "💡"
        case "todo", "info", "note": return "ℹ️"
        case "success": return "✅"
        case "question": return "❓"
        case "warning": return "⚠️"
        case "failure", "danger", "bug": return "🚫"
        case "example": return "📎"
        case "quote": return "❝"
        default: return "✎"
        }
    }

    /// Read once and reused: every cooked-mode render (and every `/api/render`
    /// hit) was otherwise doing a bundle resource lookup plus a file read just
    /// to fetch a stylesheet that never changes at runtime.
    private static let cachedStylesheet: String = {
        // Deliberately never touches `Bundle.module` — see the comment on
        // `NoteServer.webRoot()` for why: its generated accessor `fatalError`s
        // the whole app, not just this lookup, when it can't find its bundle.
        if let url = Bundle.main.url(forResource: "ofm", withExtension: "css", subdirectory: "Web"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return fallbackCSS
    }()

    static func stylesheet() -> String { cachedStylesheet }

    private static let fallbackCSS = """
    .ofm-note { font: 16px/1.55 ui-serif, Palatino, serif; max-width: 760px; }
    """
}
