import SwiftUI

struct SummaryView: View {
    @ObservedObject var store: GlucoseStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let s = store.summary {
                        Text("\(s.periodStart.formatted(.dateTime.day().month())) – \(s.periodEnd.formatted(.dateTime.day().month().year()))")
                            .font(.caption).foregroundStyle(.secondary)
                        MarkdownText(s.text)
                    } else {
                        Text("No summary yet").font(.headline)
                        Text("A summary of the past 7 days is written every Sunday evening.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
            }
            Divider()
            HStack {
                if !store.aiAvailable {
                    Text("Needs an Anthropic API key in the Keychain").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.generatingSummary { ProgressView().controlSize(.small) }
                Button("Write a new summary now") { Task { await store.generateSummary() } }
                    .disabled(store.generatingSummary || !store.aiAvailable)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 440)
        .task { await store.refreshSummary() }
    }
}

/// Minimal block Markdown: headings, bullets, paragraphs; inline styles via AttributedString.
struct MarkdownText: View {
    let lines: [String]
    init(_ text: String) { lines = text.components(separatedBy: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") {
                    inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)).font(.headline).padding(.top, 4)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        inline(String(line.dropFirst(2)))
                    }
                } else if !line.isEmpty {
                    inline(line)
                }
            }
        }
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s)) ?? AttributedString(s))
    }
}
