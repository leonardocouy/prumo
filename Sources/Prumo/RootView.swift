import SwiftUI
import PrumoCore

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch model.section {
                case .sessions:
                    HStack(spacing: 0) {
                        SessionListView(model: model).frame(width: 320)
                        Divider()
                        sessionDetail.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .skills:
                    HStack(spacing: 0) {
                        SkillListView(model: model).frame(minWidth: 0, maxWidth: .infinity)
                        if let detail = model.skillDetail, detail.skill.id == model.selectedSkill {
                            Divider()
                            VStack(spacing: 0) {
                                HStack {
                                    Text("Skill details").font(PrumoTheme.row)
                                    Spacer()
                                    Button("Close skill details", systemImage: "xmark") { model.selectedSkill = nil; model.skillDetail = nil }
                                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                                }.padding(PrumoTheme.inset)
                                Divider()
                                SkillDetailView(model: model, detail: detail).id(detail.skill.id).disabled(model.isManagingSkills)
                            }.frame(width: 320)
                        }
                    }
                case .answers:
                    HStack(spacing: 0) {
                        AnswerView(model: model).frame(minWidth: 0, maxWidth: .infinity)
                        Divider()
                        EvidenceListView(model: model).frame(width: 280)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(min: 720, ideal: 1120)
            .background(PrumoTheme.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Prumo")
        .toolbar {
            ToolbarItem(id: "refresh", placement: .primaryAction) {
                Button(model.isScanning ? "Stop refresh" : "Refresh library", systemImage: model.isScanning ? "stop.circle" : "arrow.clockwise") {
                    if model.isScanning { model.index?.cancelScan() }
                    else { Task { await model.refresh() } }
                }.labelStyle(.iconOnly)
            }
            ToolbarItem(id: "settings", placement: .primaryAction) {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .labelStyle(.iconOnly).disabled(model.isManagingSkills)
            }
        }
        .sheet(item: $model.bulkReview) { review in SkillBulkReviewView(model: model, review: review) }
        .sheet(isPresented: $model.showCreateSkill) { CreateSkillView(model: model) }
        .alert("Prumo", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .task {
            await model.loadSkills()
            await model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(25)) } catch { break }
                await model.refresh(background: true)
            }
        }
        .task(id: model.filterIdentity) {
            if !model.query.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            await model.loadResults()
        }
    }

    @ViewBuilder private var sessionDetail: some View {
        if let transcript = model.transcript, transcript.session.key == model.selectedSession {
            TranscriptView(model: model, detail: transcript)
        } else if model.isLoadingTranscript {
            ProgressView("Opening session…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WelcomeView(model: model)
        }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PrumoMark(size: 28)
                Text("Prumo").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
            }.padding(.horizontal, PrumoTheme.inset).padding(.vertical, 20)
            List(selection: $model.sidebarSelection) {
                ForEach(LibrarySection.allCases) { section in
                    HStack(spacing: 10) {
                        Label(section.title, systemImage: section.symbol)
                        Spacer(minLength: 0)
                        if section == .sessions { Text(model.stats.sessions.formatted()).monospacedDigit().foregroundStyle(PrumoTheme.rowDetailStyle(selected: model.section == section)) }
                        if section == .skills { Text(model.skills.count.formatted()).monospacedDigit().foregroundStyle(PrumoTheme.rowDetailStyle(selected: model.section == section)) }
                    }.font(.system(size: 13)).padding(.vertical, 5).tag(section)
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 10) {
                if !model.scanWarnings.isEmpty {
                    Menu {
                        ForEach(Array(model.scanWarnings.enumerated()), id: \.offset) { _, warning in Text(warning) }
                        Divider()
                        Button("Open source settings…") { openSettings() }
                    } label: { Label("Source notices", systemImage: "exclamationmark.circle") }
                }
                Label(model.isScanning ? "Refreshing library…" : "Local library", systemImage: model.isScanning ? "arrow.triangle.2.circlepath" : "internaldrive")
                    .font(.system(size: 12, weight: .medium))
                Text(model.scanSummary).font(PrumoTheme.meta).foregroundStyle(PrumoTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.font(PrumoTheme.meta).padding(PrumoTheme.inset).frame(maxWidth: .infinity, alignment: .leading)
        }.background(PrumoTheme.panel)
    }
}

struct SessionFilters: View {
    @Bindable var model: AppModel
    var body: some View {
        Menu {
            Picker("Agent", selection: $model.agentFilter) {
                Text("All agents").tag("")
                Text("Codex").tag("codex")
                Text("Claude Code").tag("claude")
            }
            Menu("Project") {
                Button("All projects") { model.projectFilter = "" }
                ForEach(model.projects, id: \.self) { project in
                    Button(project) { model.projectFilter = project }
                }
            }
            Divider()
            Button("Clear filters") { model.agentFilter = ""; model.projectFilter = "" }
        } label: {
            Label(model.agentFilter.isEmpty && model.projectFilter.isEmpty ? "Filters" : "Filters applied", systemImage: "line.3.horizontal.decrease")
        }.help([model.agentFilter, model.projectFilter].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

struct LibrarySearchField: View {
    @Binding var text: String
    let placeholder: String
    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
                .font(.system(size: 13)).accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Clear search")
            }
        }.controlSize(.large)
    }
}

struct WelcomeView: View {
    @Bindable var model: AppModel
    var body: some View {
        EmptyPanel(symbol: "text.bubble", title: "Select a conversation", message: "Read a session, find a passage, or continue where you left off.")
    }
}

struct StatValue: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
            Text(label).font(PrumoTheme.meta).foregroundStyle(PrumoTheme.secondary)
        }
    }
}
