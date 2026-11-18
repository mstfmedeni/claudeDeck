import SwiftUI
import UIKit

// Copying and selecting the conversation's text, and its links.
//
// Links open in Safari (the system's handler for http/https), as the terminal's do: the pages
// Claude points at (pull requests, docs, dashboards) usually want the user's own logins, and
// Safari keeps them; an in-app browser would sign in again and lose the page on dismissal.

extension EnvironmentValues {
    /// Opens the "Select Text" sheet with the given text (set by the conversation).
    @Entry var selectText = SelectTextAction(id: nil) { _ in }
}

/// Equal by its id, so setting it again on each of the conversation's updates doesn't make every
/// row that reads it draw again (a closure alone compares as changed).
struct SelectTextAction: Equatable {
    let id: UUID?
    let action: (String) -> Void
    func callAsFunction(_ text: String) { action(text) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Text to select in a sheet.
struct SelectableText: Identifiable {
    let id = UUID()
    let text: String
}

enum TextLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Bare URLs ("https://…", "www.…") in the text made links; markdown links stay as they are.
    static func linkify(_ attributed: AttributedString) -> AttributedString {
        let plain = String(attributed.characters)
        // Cheap test first: most messages have no URL at all.
        guard plain.contains("://") || plain.contains("www."), let detector else { return attributed }
        var result = attributed
        let ns = plain as NSString
        for match in detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, url.scheme == "http" || url.scheme == "https",
                  let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            let span = lower..<upper
            // A markdown link (or `code`) already there wins.
            if result[span].runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) { continue }
            result[span].link = url
        }
        return result
    }

    /// The text as read: markdown's marks dropped (for "Copy" on Claude's answers).
    static func plain(markdown: String) -> String {
        String(ChatEntryView.markdown(markdown).characters)
    }
}

/// Prose and fenced code blocks of a markdown text block (MarkdownBlocks keeps fences in its
/// text blocks; here they get a box with a copy button).
enum MarkdownSegments {
    enum Segment: Equatable {
        case prose(String)
        case code(String)
    }

    static func split(_ text: String) -> [Segment] {
        guard text.contains("```") else { return [.prose(text)] }
        var segments: [Segment] = []
        var prose: [String] = []
        var code: [String]?
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
            prose = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let open = code {
                    segments.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushProse()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else {
                prose.append(line)
            }
        }
        // An unclosed fence (Claude still writing): what came so far, as code.
        if let open = code { segments.append(.code(open.joined(separator: "\n"))) }
        flushProse()
        return segments
    }
}

/// A fenced code block: monospaced, scrolling sideways, with a copy button.
struct CodeBlockView: View {
    let code: String
    @State private var copied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code.isEmpty ? " " : code)
                .listFont(.callout, design: .monospaced)
                .textSelection(.enabled)
                .fixedSize()
                .padding(10)
                .padding(.trailing, 30)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            Button {
                UIPasteboard.general.string = code
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .listFont(.caption)
                    .frame(width: 28, height: 28)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel(Text("Copy Code"))
        }
        .contextMenu {
            Button { UIPasteboard.general.string = code } label: { Label("Copy Code", systemImage: "doc.on.doc") }
        }
    }
}

/// "Copy", "Copy as Markdown" (Claude's answers) and "Select Text…" on a message.
struct MessageCopyMenu: ViewModifier {
    let text: String
    /// Claude's answers: "Copy" drops the markdown, "Copy as Markdown" keeps it.
    var markdown = false
    @Environment(\.selectText) private var selectText

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { UIPasteboard.general.string = markdown ? TextLinks.plain(markdown: text) : text } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if markdown {
                Button { UIPasteboard.general.string = text } label: { Label("Copy as Markdown", systemImage: "doc.plaintext") }
            }
            Button { selectText(markdown ? TextLinks.plain(markdown: text) : text) } label: {
                Label("Select Text…", systemImage: "selection.pin.in.out")
            }
        }
    }
}

extension View {
    func messageCopyMenu(_ text: String, markdown: Bool = false) -> some View {
        modifier(MessageCopyMenu(text: text, markdown: markdown))
    }
}

/// The whole message in a text view: drag its handles to select any part, then Copy.
struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle(Text("Select Text"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { UIPasteboard.general.string = text } label: { Text("Copy All") }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = [.link]
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        view.alwaysBounceVertical = true
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
