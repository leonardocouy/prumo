import SwiftUI
import AppKit
import PrumoCore

extension SkillRow: Identifiable {}

struct SkillListView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Skills").font(PrumoTheme.title)
                        Text("Your instructions, across both agents.").font(PrumoTheme.meta).foregroundStyle(PrumoTheme.secondary)
                    }
                    Spacer()
                    Button("New skill", systemImage: "plus") { model.showCreateSkill = true }.prumoPrimaryAction()
                }
                LibrarySearchField(text: $model.query, placeholder: "Search skills…")
                HStack(spacing: 12) {
                    Picker("Usage", selection: $model.skillUsageFilter) {
                        Text("All usage").tag("all")
                        Text("Recorded use").tag("used")
                        Text("No recorded use").tag("unused")
                    }.labelsHidden().frame(maxWidth: 170)
                    Spacer(minLength: 0)
                    Picker("Sort skills", selection: $model.skillSort) {
                        Text("Name").tag("name")
                        Text("Most used").tag("most")
                        Text("Last used").tag("recent")
                        Text("Newest added").tag("newest")
                        Text("Oldest added").tag("oldest")
                    }.labelsHidden().frame(maxWidth: 160)
                }.font(PrumoTheme.meta)
                HStack {
                    Button("Select visible") { model.selectedSkills.formUnion(model.visibleSkills.map(\.id)) }
                        .disabled(model.visibleSkills.isEmpty)
                    Spacer()
                    if !model.selectedSkills.isEmpty {
                        Button("Clear selection") { model.selectedSkills = [] }
                    }
                }.font(PrumoTheme.meta).buttonStyle(.borderless)
                if !model.selectedSkills.isEmpty { SkillBulkToolbar(model: model) }
            }.padding(PrumoTheme.contentInset)
            Divider()
            if model.visibleSkills.isEmpty {
                EmptyPanel(symbol: "square.stack.3d.up", title: model.skills.isEmpty ? "No skills found" : "No matching skills", message: model.skills.isEmpty ? "Add a skill folder in Settings or create your first skill." : "Change the search or usage filter.")
            } else {
                Table(model.visibleSkills, selection: $model.skillSelection) {
                    TableColumn("Select") { skill in
                        Toggle("Select \(skill.name) for bulk actions", isOn: Binding(get: { model.selectedSkills.contains(skill.id) }, set: { selected in
                            if selected { model.selectedSkills.insert(skill.id) } else { model.selectedSkills.remove(skill.id) }
                        })).labelsHidden().toggleStyle(.checkbox)
                    }.width(38)
                    TableColumn("Skill") { skill in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(skill.name).font(PrumoTheme.row).lineLimit(1)
                                if skill.readOnly { Image(systemName: "lock").font(PrumoTheme.meta).accessibilityLabel("Managed skill") }
                            }
                            Text(skill.description).font(PrumoTheme.meta).foregroundStyle(PrumoTheme.rowDetailStyle(selected: model.selectedSkill == skill.id)).lineLimit(1)
                        }.padding(.vertical, 8).help(skill.name + "\n" + skill.description)
                    }.width(min: 140, ideal: 280)
                    TableColumn("Agents") { skill in
                        HStack(spacing: 4) {
                            if skill.codexState != "absent" { AgentBadge(agent: "codex", compact: true) }
                            if skill.claudeState != "absent" { AgentBadge(agent: "claude", compact: true) }
                        }
                    }.width(64)
                    TableColumn("Uses") { skill in
                        Text(model.skillUsage[skill.id].map { $0.uses.formatted() } ?? "—")
                            .monospacedDigit().help("Recorded skill calls and reads. Zero means no recorded use.")
                    }.width(44)
                    TableColumn("Added ≈") { skill in
                        Text(skill.addedDate.map { $0.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits)) } ?? "Unknown")
                            .font(PrumoTheme.meta).foregroundStyle(PrumoTheme.rowDetailStyle(selected: model.selectedSkill == skill.id)).help(skill.addedDateExplanation)
                    }.width(88)
                }.tableStyle(.inset(alternatesRowBackgrounds: false)).scrollContentBackground(.hidden)
            }
            Divider()
            HStack(alignment: .top) {
                Text("\(model.visibleSkills.count) of \(model.skills.count) skills").monospacedDigit()
                Spacer()
                Text(model.skillActionSummary ?? (model.isScanning ? "Refreshing usage…" : "Usage from indexed main sessions"))
                    .foregroundStyle(PrumoTheme.secondary)
            }.font(PrumoTheme.meta).padding(PrumoTheme.inset)
        }.background(PrumoTheme.canvas).disabled(model.isManagingSkills)
    }
}

struct SkillBulkToolbar: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack {
            Text("\(model.selectedSkills.count) selected").font(.system(size: 12, weight: .medium))
            Spacer()
            Menu("Actions") {
                ForEach(SkillBulkAction.allCases) { action in
                    Button(action.title + (action == .trash ? "…" : ""), role: action == .trash ? .destructive : nil) { model.reviewSkillAction(action) }
                        .disabled(!model.skills.contains { model.selectedSkills.contains($0.id) && action.applies(to: $0) })
                }
            }.fixedSize()
        }.padding(9).background(PrumoTheme.accent.opacity(0.08), in: .rect(cornerRadius: 7))
    }
}

struct SkillBulkReviewView: View {
    @Bindable var model: AppModel
    let review: SkillBulkReview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(review.action.title): \(review.skills.count) skills").font(.title2)
            Text(review.action == .trash ? "Move these whole skill folders and their supporting files to macOS Trash. Matching agent links will be removed. Restore folders from Trash, then relink them if needed." : "Apply this action to the skills below. Original folders and shared access stay protected.")
                .font(.callout).foregroundStyle(PrumoTheme.secondary).fixedSize(horizontal: false, vertical: true)
            if review.skipped > 0 { Text("\(review.skipped) selected skills are ineligible and will be skipped.").font(.caption).foregroundStyle(PrumoTheme.accent) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(review.skills, id: \.id) { skill in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill.name).font(.system(size: 12, weight: .medium))
                            Text(skill.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(PrumoTheme.secondary).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(12)
            }.background(PrumoTheme.canvas, in: .rect(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(review.action.title, role: review.action == .trash ? .destructive : nil) { model.performSkillAction(review) }
                    .prumoPrimaryAction()
            }
        }.padding(24).frame(width: 620, height: 500).background(PrumoTheme.panel)
    }
}

struct SkillUsageView: View {
    let usage: SkillUsage?
    let open: (SessionRow) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Recorded usage")
            if let usage {
                HStack(spacing: 24) {
                    StatValue(value: usage.uses.formatted(), label: "Uses")
                    StatValue(value: usage.codexUses.formatted(), label: "Codex")
                    StatValue(value: usage.claudeUses.formatted(), label: "Claude Code")
                }
                if usage.lastUsedMs > 0 {
                    Text("Last recorded use: \(Date(timeIntervalSince1970: Double(usage.lastUsedMs) / 1000).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(PrumoTheme.secondary)
                }
                Text("Successful skill calls and SKILL.md reads in indexed main sessions. Reads can include inspection. Missing history, subagent-only activity, and unsupported records are excluded.")
                    .font(.caption).foregroundStyle(PrumoTheme.secondary)
                if !usage.sessions.isEmpty {
                    DisclosureGroup("\(usage.sessions.count) source \(usage.sessions.count == 1 ? "session" : "sessions")") {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(usage.sessions, id: \.key) { session in
                                Button { open(session) } label: {
                                    HStack { AgentBadge(agent: session.agent); Text(session.title).lineLimit(1); Spacer(); Image(systemName: "arrow.up.right") }
                                        .font(PrumoTheme.meta).padding(7).contentShape(.rect)
                                }.buttonStyle(.plain)
                            }
                        }.padding(.top, 8)
                    }.font(.caption)
                }
            } else { Text("Usage is unavailable until the session index is ready.").font(.caption).foregroundStyle(PrumoTheme.secondary) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(PrumoTheme.card, in: .rect(cornerRadius: 9))
    }
}

struct SkillDetailView: View {
    @Bindable var model: AppModel
    let detail: SkillDetail
    @State private var editing = false
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    SectionLabel(text: detail.skill.readOnly ? "Managed skill" : "Your skill")
                    Spacer()
                    Menu {
                        Button("Reveal in Finder") { model.reveal(detail.skill.path) }
                        if !detail.skill.readOnly {
                            Divider()
                            Button("Move to Trash…", role: .destructive) { model.reviewSkillAction(.trash, ids: [detail.skill.id]) }
                        }
                    } label: { Label("Skill actions", systemImage: "ellipsis") }
                        .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize().help("Skill actions")
                    Button("Edit", systemImage: "pencil") { editing = true }.disabled(detail.skill.readOnly)
                }
                Text(detail.skill.name).font(PrumoTheme.title).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if !detail.skill.description.isEmpty { Text(detail.skill.description).font(.system(size: 14)).foregroundStyle(PrumoTheme.secondary).lineSpacing(4) }
                VStack(alignment: .leading, spacing: 8) {
                    AgentLinkView(agent: "codex", state: detail.skill.codexState, busy: isWorking) { toggle("codex", state: detail.skill.codexState) }
                    AgentLinkView(agent: "claude", state: detail.skill.claudeState, busy: isWorking) { toggle("claude", state: detail.skill.claudeState) }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(PrumoTheme.accent)
                    Text(detail.skill.path).textSelection(.enabled).foregroundStyle(PrumoTheme.secondary)
                }.font(PrumoTheme.meta).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(PrumoTheme.card, in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 5) {
                    Label(detail.skill.addedDateLabel, systemImage: "calendar").font(.system(size: 12, weight: .medium))
                    Text(detail.skill.addedDateExplanation).font(.caption).foregroundStyle(PrumoTheme.secondary)
                }
                SkillUsageView(usage: model.skillUsage[detail.skill.id]) { session in
                    model.section = .sessions
                    model.openSession(session.key)
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(text: "Instructions")
                    Text(.init(markdownBody)).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !detail.files.isEmpty {
                    Divider()
                    DisclosureGroup("\(detail.files.count) supporting files") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(detail.files, id: \.self) { file in
                                Button { model.reveal(detail.skill.path + "/" + file) } label: { Label(file, systemImage: "doc.text").font(.system(size: 12, design: .monospaced)).foregroundStyle(PrumoTheme.secondary) }.buttonStyle(.plain)
                            }
                        }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 12))
                }
            }.padding(PrumoTheme.contentInset).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $editing) { SkillEditorView(model: model, detail: detail) }
    }

    private var markdownBody: String {
        let lines = detail.text.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            return lines.dropFirst(end + 1).joined(separator: "\n")
        }
        return detail.text
    }

    private func toggle(_ agent: String, state: String) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let store = model.settings.makeSkillStore(), id = detail.skill.id
                model.skillDetail = try await Task.detached { try store.setLink(id: id, agent: agent, enabled: state == "absent") }.value
                await model.loadSkills()
            } catch { model.error = error.prumoDescription }
        }
    }


}

struct AgentLinkView: View {
    let agent: String
    let state: String
    let busy: Bool
    let action: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            AgentBadge(agent: agent).fixedSize()
            Spacer(minLength: 0)
            if state == "shared" || state == "source" {
                Label(state == "shared" ? "Shared folder" : "Original folder", systemImage: "checkmark").font(PrumoTheme.meta).foregroundStyle(PrumoTheme.secondary).fixedSize()
            } else {
                Button(state == "linked" ? "Unlink" : "Link") { action() }.font(PrumoTheme.meta).disabled(busy)
            }
        }.padding(10).frame(maxWidth: .infinity).background(PrumoTheme.card, in: .rect(cornerRadius: 8))
    }
}

struct SkillEditorView: View {
    @Bindable var model: AppModel
    let detail: SkillDetail
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var error: String?

    init(model: AppModel, detail: SkillDetail) {
        self.model = model; self.detail = detail
        _text = State(initialValue: detail.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("Edit \(detail.skill.name)").font(.title2); Text("SKILL.md").font(.caption).foregroundStyle(PrumoTheme.secondary) }; Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Save changes") { save() }.keyboardShortcut("s").prumoPrimaryAction().disabled(saving || text == detail.text) }
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(10).background(PrumoTheme.canvas, in: .rect(cornerRadius: 8)).accessibilityLabel("Skill document")
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(24).frame(width: 800, height: 650).background(PrumoTheme.panel)
    }

    private func save() {
        saving = true
        let text = text, id = detail.skill.id, revision = detail.revision, store = model.settings.makeSkillStore()
        Task {
            defer { saving = false }
            do {
                model.skillDetail = try await Task.detached { try store.save(id: id, text: text, expectedRevision: revision) }.value
                await model.loadSkills()
                dismiss()
            } catch { self.error = error.prumoDescription }
        }
    }
}

struct CreateSkillView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var destination = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("A new skill").font(PrumoTheme.heading); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Create skill") { create() }.prumoPrimaryAction().disabled(saving || name.isEmpty || instructions.isEmpty) }
            TextField("Folder name, such as review-changes", text: $name).textFieldStyle(.roundedBorder)
            TextField("When should an agent use this skill?", text: $description).textFieldStyle(.roundedBorder)
            Picker("Save in", selection: $destination) { ForEach(model.settings.skillRoots, id: \.self) { root in Text(root).tag(root) } }
            TextEditor(text: $instructions).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(10).background(PrumoTheme.canvas, in: .rect(cornerRadius: 8)).accessibilityLabel("Skill instructions")
            Text("Write the instructions in Markdown. Prumo adds the name and description as frontmatter.").font(.caption).foregroundStyle(PrumoTheme.secondary)
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
        }.padding(25).frame(width: 740, height: 580).background(PrumoTheme.panel)
            .onAppear { destination = model.settings.expanded(model.settings.sharedSkills) }
    }

    private func create() {
        saving = true
        let store = model.settings.makeSkillStore(), name = name, root = destination
        let encode: (String) -> String = { String(data: (try? JSONEncoder().encode($0)) ?? Data(), encoding: .utf8) ?? "\"\"" }
        let text = "---\nname: \(encode(name))\ndescription: \(encode(description))\n---\n\n\(instructions)\n"
        Task {
            defer { saving = false }
            do {
                let detail = try await Task.detached { try store.create(name: name, text: text, root: root) }.value
                model.section = .skills; model.query = ""
                await model.loadSkills()
                model.selectedSkill = detail.skill.id; model.skillDetail = detail
                dismiss()
            } catch { self.error = error.prumoDescription }
        }
    }
}
