import SwiftUI

/// Renderizador sencillo de Markdown por bloques (títulos, listas, tablas, citas y código).
/// SwiftUI solo interpreta Markdown en línea, así que la estructura se arma aquí.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        let blocks = MarkdownParser.parse(markdown)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { item in
                MarkdownBlockView(block: item.block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(level: Int, text: String)
    case numbered(number: String, level: Int, text: String)
    case table(header: [String], rows: [[String]])
    case quote(String)
    case code(String)
    case rule
}

struct MarkdownBlockItem: Identifiable {
    let id: Int
    let block: MarkdownBlock
}

enum MarkdownParser {
    static func parse(_ markdown: String) -> [MarkdownBlockItem] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var tableLines: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        func flushTable() {
            if !tableLines.isEmpty {
                if let table = makeTable(tableLines) {
                    blocks.append(table)
                }
                tableLines.removeAll()
            }
        }

        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inCode {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCode = false
                } else {
                    codeLines.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushTable()
                inCode = true
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                tableLines.append(trimmed)
                continue
            }
            flushTable()

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            let level = indentLevel(line)
            if let text = bulletText(trimmed) {
                flushParagraph()
                blocks.append(.bullet(level: level, text: text))
                continue
            }
            if let item = numberedItem(trimmed) {
                flushParagraph()
                blocks.append(.numbered(number: item.number, level: level, text: item.text))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            paragraph.append(trimmed)
        }
        if inCode {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        flushTable()

        return blocks.enumerated().map { MarkdownBlockItem(id: $0.offset, block: $0.element) }
    }

    /// Markdown en línea (negritas, cursivas, código, enlaces).
    static func inline(_ text: String) -> AttributedString {
        let cleaned = text
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(cleaned)
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") {
            text.removeLast()
        }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func indentLevel(_ line: String) -> Int {
        var spaces = 0
        for character in line {
            if character == " " {
                spaces += 1
            } else if character == "\t" {
                spaces += 4
            } else {
                break
            }
        }
        return min(spaces / 2, 4)
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            var text = String(line.dropFirst(marker.count))
            // Casillas de tareas: "- [ ] texto" / "- [x] texto".
            if text.hasPrefix("[ ] ") {
                text = "☐ " + text.dropFirst(4)
            } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                text = "☑ " + text.dropFirst(4)
            }
            return text
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> (number: String, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return nil }
        let afterMarker = rest.dropFirst()
        guard afterMarker.first == " " else { return nil }
        return (number: String(digits), text: afterMarker.trimmingCharacters(in: .whitespaces))
    }

    private static func cells(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            let core = cell.replacingOccurrences(of: ":", with: "")
            return core.count >= 1 && core.allSatisfy { $0 == "-" }
        }
    }

    private static func makeTable(_ lines: [String]) -> MarkdownBlock? {
        let rows = lines.map { cells($0) }.filter { !isSeparatorRow($0) }
        guard let header = rows.first else { return nil }
        let body = Array(rows.dropFirst())
        guard !body.isEmpty else {
            return .paragraph(header.joined(separator: " · "))
        }
        return .table(header: header, rows: body)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(MarkdownParser.inline(text))
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 10 : 4)
        case let .paragraph(text):
            Text(MarkdownParser.inline(text))
        case let .bullet(level, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(level == 0 ? "•" : "◦")
                    .foregroundStyle(.secondary)
                Text(MarkdownParser.inline(text))
            }
            .padding(.leading, CGFloat(level) * 18)
        case let .numbered(number, level, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(MarkdownParser.inline(text))
            }
            .padding(.leading, CGFloat(level) * 18)
        case let .table(header, rows):
            MarkdownTableView(header: header, rows: rows)
        case let .quote(text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                Text(MarkdownParser.inline(text))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .code(text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        case .rule:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline
        default: return .subheadline.bold()
        }
    }
}

/// Tablas mostradas como tarjetas: más legibles en la pantalla de un iPhone.
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(MarkdownParser.inline(cell(row, 0)))
                        .font(.body.weight(.medium))
                    ForEach(Array(stride(from: 1, to: max(header.count, row.count), by: 1)), id: \.self) { column in
                        let value = cell(row, column)
                        if !value.isEmpty {
                            Text(MarkdownParser.inline("**\(title(column)):** \(value)"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
            }
        }
    }

    private func cell(_ row: [String], _ column: Int) -> String {
        column < row.count ? row[column] : ""
    }

    private func title(_ column: Int) -> String {
        if column < header.count, !header[column].isEmpty {
            return header[column].replacingOccurrences(of: "*", with: "")
        }
        return "Columna \(column + 1)"
    }
}
