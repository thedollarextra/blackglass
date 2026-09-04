import SwiftUI

public struct MarkdownContentView: View {
    let markdown: String

    public var body: some View {
        MarkdownRenderer(markdown: markdown)
    }
}

public struct MarkdownRenderer: View {
    let markdown: String

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("This note is empty.")
                    .foregroundStyle(.tertiary)
                    .italic()
            } else if let attributed = try? AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            ) {
                Text(attributed)
                    .font(.system(.body, design: .serif))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: 760, alignment: .leading)
            } else {
                fallbackBlocks
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var fallbackBlocks: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .heading(let level, let text):
                Text(text)
                    .font(headingFont(level))
                    .fontWeight(.semibold)
                    .padding(.top, level == 1 ? 4 : 8)
            case .quote(let text):
                Text(text)
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.45))
                            .frame(width: 3)
                    }
            case .code(let text):
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            case .bullet(let text):
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                    Text(text)
                }
            case .paragraph(let text):
                Text(text)
                    .lineSpacing(5)
            }
        }
        .font(.system(.body, design: .serif))
        .textSelection(.enabled)
        .frame(maxWidth: 760, alignment: .leading)
    }

    private enum Block {
        case heading(Int, String)
        case quote(String)
        case code(String)
        case bullet(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    result.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                code.append(line)
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }

            if let heading = parseHeading(line) {
                flushParagraph()
                result.append(.heading(heading.0, heading.1))
            } else if line.hasPrefix("> ") {
                flushParagraph()
                result.append(.quote(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                result.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        if inCode { result.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return result
    }

    private func parseHeading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return (level, rest)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .largeTitle
        case 2: return .title
        case 3: return .title2
        default: return .title3
        }
    }
}
