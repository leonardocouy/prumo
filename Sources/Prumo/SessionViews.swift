import SwiftUI
import AppKit
import PrumoCore

struct SessionListView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: PrumoTheme.gap) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sessions").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(model.hits.count == 300 ? "300+" : model.hits.count.formatted()).font(PrumoTheme.meta)
                        .monospacedDigit().foregroundStyle(PrumoTheme.secondary)
                }
                LibrarySearchField(text: $model.query, placeholder: "Search conversations…")
                HStack {
                    SessionFilters(model: model).fixedSize()
                    Spacer(minLength: 0)
                    Picker("Order", selection: $model.sessionOrder) {
                        Text("Newest activity").tag(SearchOrder.newest)
                        Text("Oldest activity").tag(SearchOrder.oldest)
                        Text("Relevance").tag(SearchOrder.relevance)
                    }.labelsHidden().frame(maxWidth: 165).help(
                        "Order matching sessions by last activity or matching passage relevance.")
                }.font(PrumoTheme.meta)
                if !model.query.isEmpty {
                    Button {
                        model.askFromSearch()
                    } label: {
                        HStack {
                            Image(systemName: "sparkle.magnifyingglass");
                            Text("Ask about “\(model.query)”").lineLimit(1); Spacer();
                            Image(systemName: "arrow.up.right")
                        }
                        .font(PrumoTheme.meta).foregroundStyle(PrumoTheme.accent)
                    }.buttonStyle(.plain)
                }
            }.padding(PrumoTheme.inset)
            Divider()
            if model.hits.isEmpty {
                EmptyPanel(
                    symbol: "text.magnifyingglass",
                    title: model.isScanning ? "Indexing sessions…" : "No sessions found",
                    message: model.query.isEmpty
                        ? "Check your agent folders in Settings, or let the first scan finish."
                        : "Try a name, a decision, or a phrase from the conversation.")
            } else {
                List(selection: $model.sessionSelection) {
                    ForEach(model.hits, id: \.id) { hit in
                        SessionRowView(
                            hit: hit, selected: model.selectedSession == hit.session.key,
                            showExcerpt: !model.query.isEmpty
                        )
                        .tag(hit.session.key)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8))
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)

            }
        }.background(PrumoTheme.canvas)
    }
}

struct SessionRowView: View {
    let hit: SearchHit
    let selected: Bool
    let showExcerpt: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hit.session.title).font(PrumoTheme.row).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).help(hit.session.title)
            if showExcerpt {
                Text(hit.excerpt).font(PrumoTheme.meta).foregroundStyle(PrumoTheme.rowDetailStyle(selected: selected))
                    .lineLimit(3).lineSpacing(3)
            }
            HStack(spacing: 7) {
                AgentBadge(agent: hit.session.agent, compact: true)
                Text(hit.session.projectName).lineLimit(1).help(hit.session.project)
                Spacer(minLength: 0)
                Text(hit.session.updated, format: .dateTime.month(.abbreviated).day())
                    .help(hit.session.updated.formatted(date: .complete, time: .shortened))
            }.font(PrumoTheme.meta).foregroundStyle(PrumoTheme.rowDetailStyle(selected: selected))
        }.padding(.vertical, 6)
            .contentShape(.rect).accessibilityElement(children: .combine)
    }

}

struct TranscriptView: View {
    @Bindable var model: AppModel
    let detail: SessionDetail
    @State private var findText = ""

    private var messages: [SessionMessage] {
        findText.isEmpty ? detail.messages : detail.messages.filter { $0.text.localizedStandardContains(findText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 9) {
                    AgentBadge(agent: detail.session.agent)
                    Text(detail.session.updated, format: .dateTime.month(.abbreviated).day()).font(PrumoTheme.meta)
                        .foregroundStyle(PrumoTheme.secondary)
                    Spacer(minLength: 0)
                    Menu {
                        Button("Continue in \(detail.session.agentName)") { model.continueSession(detail.session) }
                        Button("Copy resume command") { copyResume() }
                        Divider()
                        Button("Reveal session file") { model.reveal(detail.session.sourcePath) }
                        Button("Copy session ID") { copy(detail.session.externalId) }
                    } label: {
                        Label("Session actions", systemImage: "ellipsis")
                    }
                    .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize().help("Session actions")
                    Button {
                        model.continueSession(detail.session)
                    } label: {
                        Label("Continue", systemImage: "arrow.up.right")
                    }
                    .prumoPrimaryAction().help("Continue in \(detail.session.agentName) using Terminal")
                }
                Text(detail.session.title).font(PrumoTheme.title).textSelection(.enabled).frame(
                    maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    Image(systemName: "folder").font(PrumoTheme.meta)
                    Text(detail.session.project.isEmpty ? "No project folder" : detail.session.project).lineLimit(1)
                        .truncationMode(.middle).help(detail.session.project)
                    Spacer()
                    Text("\(detail.session.messageCount) messages").font(.system(size: 12, design: .monospaced))
                }.font(PrumoTheme.meta).foregroundStyle(PrumoTheme.muted)
                HStack {
                    Image(systemName: "magnifyingglass").font(PrumoTheme.meta).foregroundStyle(PrumoTheme.muted)
                    TextField("Find in this session", text: $findText).textFieldStyle(.plain).font(PrumoTheme.meta)
                        .accessibilityLabel("Find in this session")
                    if !findText.isEmpty {
                        Text("\(messages.count) matches").font(.caption2).foregroundStyle(PrumoTheme.secondary)
                    }
                }.padding(8).background(PrumoTheme.card, in: .rect(cornerRadius: 6))
            }.padding(PrumoTheme.contentInset)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(messages, id: \.id) { message in
                            MessageView(
                                message: message, highlighted: model.scrollMessage == message.index,
                                agent: detail.session.agentName
                            )
                            .id(message.index)
                        }
                    }.padding(PrumoTheme.contentInset).frame(maxWidth: 800, alignment: .leading).frame(
                        maxWidth: .infinity)
                }
                .onChange(of: detail.session.key, initial: true) { scroll(proxy) }
                .onChange(of: model.scrollMessage) { scroll(proxy) }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        if let message = model.scrollMessage { proxy.scrollTo(message, anchor: .top) }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
    private func copyResume() {
        do { copy(try Continuation.command(session: detail.session, settings: model.settings)) } catch {
            model.error = error.prumoDescription
        }
    }
}

struct MessageView: View {
    let message: SessionMessage
    let highlighted: Bool
    let agent: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: message.role == "user" ? "person.crop.circle" : "sparkle").foregroundStyle(
                    message.role == "user" ? .secondary : PrumoTheme.accent)
                Text(message.role == "user" ? "You" : agent).font(.system(size: 12, weight: .semibold)).foregroundStyle(
                    PrumoTheme.secondary)
                Spacer()
                Text("\(message.index + 1)").font(.system(size: 12, design: .monospaced)).foregroundStyle(
                    PrumoTheme.muted)
                Button("Copy message", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
                }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(PrumoTheme.muted).font(PrumoTheme.meta)
            }
            Text(displayedText).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled).frame(
                maxWidth: .infinity, alignment: .leading)
            if message.text.count > 7000 {
                Button(expanded ? "Show less" : "Read full message") { expanded.toggle() }.font(.caption).buttonStyle(
                    .plain
                ).foregroundStyle(PrumoTheme.accent)
            }
        }
        .padding(message.role == "user" ? 18 : 12)
        .background(message.role == "user" ? PrumoTheme.card : .clear, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(highlighted ? PrumoTheme.accent.opacity(0.5) : .clear)
        }
    }

    private var displayedText: String {
        expanded ? message.text : String(message.text.prefix(7000)) + (message.text.count > 7000 ? "\n…" : "")
    }
}
