import SwiftUI

struct SummaryView: View {
    @ObservedObject var store: GlucoseStore

    var body: some View {
        Group {
            if let s = store.summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("\(s.periodStart.formatted(.dateTime.day().month(.wide))) – \(s.periodEnd.formatted(.dateTime.day().month(.wide).year()))")
                            .font(.subheadline).foregroundStyle(.secondary)
                        MarkdownText(s.text)
                        Text("Written by Claude \(s.created.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.tertiary)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView {
                    Label("No Summary Yet", systemImage: "text.document")
                } description: {
                    Text("A summary of the past 7 days is written every Sunday evening.")
                } actions: {
                    Button("Write One Now") { Task { await store.generateSummary() } }
                        .disabled(store.generatingSummary || !store.aiAvailable)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 480)
        .navigationTitle("Weekly Summary")
        .toolbar {
            ToolbarItem {
                if store.generatingSummary {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await store.generateSummary() } } label: {
                        Label("Write New Summary", systemImage: "sparkles")
                    }
                    .disabled(!store.aiAvailable)
                    .help(store.aiAvailable ? "Write a new summary of the past 7 days" : "Claude is unavailable: run `claude` once on the server Mac to log in")
                }
            }
        }
        .task { await store.refreshSummary() }
        .activatesWindow("summary")
    }
}

/// Minimal block Markdown: headings, bullets, paragraphs; inline styles via AttributedString.
struct MarkdownText: View {
    let lines: [String]
    init(_ text: String) { lines = text.components(separatedBy: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") {
                    inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)).font(.title3.weight(.semibold)).padding(.top, 8)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(String(line.dropFirst(2)))
                    }
                } else if !line.isEmpty {
                    inline(line)
                }
            }
        }
        .font(.body)
        .lineSpacing(3)
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s)) ?? AttributedString(s))
    }
}
