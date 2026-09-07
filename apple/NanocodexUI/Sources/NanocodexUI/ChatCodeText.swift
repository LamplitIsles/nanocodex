import HighlightSwift
import SwiftUI

struct ChatCodeText: View {
    let source: String
    let language: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlighted: (request: Request, text: AttributedString)?

    private struct Request: Hashable {
        let source: String
        let language: String
        let dark: Bool
    }

    var body: some View {
        let request = Request(source: source, language: language, dark: colorScheme == .dark)
        Text(highlighted?.request == request ? highlighted!.text : AttributedString(source))
            .task(id: request) {
                let text = await ChatCodeHighlighter.highlight(source, language: language, dark: request.dark)
                guard !Task.isCancelled else { return }
                highlighted = (request, text)
            }
    }
}

enum ChatCodeHighlighter {
    private static let engine = Highlight()

    static func highlight(_ source: String, language: String, dark: Bool) async -> AttributedString {
        let plain = AttributedString(source)
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return plain }
        let alias = language.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        let mode: HighlightMode = alias.isEmpty ? .automatic : .languageAliasIgnoreIllegal(alias)
        guard let result = try? await engine.request(source, mode: mode, colors: dark ? .dark(.github) : .light(.github)) else { return plain }

        // The highlighter's HTML bridge trims fence whitespace. Keep the exact
        // original code, including indentation and streamed trailing newlines.
        let rendered = String(result.attributedText.characters)
        guard rendered.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed,
              let originalRange = source.range(of: trimmed),
              let renderedRange = result.attributedText.range(of: trimmed) else { return plain }
        var text = AttributedString(String(source[..<originalRange.lowerBound]))
        text.append(AttributedString(result.attributedText[renderedRange]))
        text.append(AttributedString(String(source[originalRange.upperBound...])))
        return text
    }
}
