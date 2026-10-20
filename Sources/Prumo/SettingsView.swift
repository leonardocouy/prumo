import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppSettings
    @State private var tab = 0
    @State private var error: String?
    @State private var choosingPath = false
    @State private var pathTarget: SettingsPathTarget = .codex

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $tab) {
                Text("Folders").tag(0)
                Text("Agents & answers").tag(1)
            }.pickerStyle(.segmented).labelsHidden().padding(PrumoTheme.contentInset)
            Form {
                if tab == 0 {
                    Section {
                        PathSetting(
                            title: "Codex data folder", detail: "Contains sessions and archived_sessions.",
                            path: $draft.codexHome
                        ) { choose(.codex) }
                        PathSetting(
                            title: "Claude Code data folder",
                            detail: "Contains projects. Custom profiles such as ~/.claude-work work here.",
                            path: $draft.claudeHome
                        ) { choose(.claude) }
                    } header: {
                        Text("Session folders")
                    } footer: {
                        Text("Prumo reads these sessions without changing the original files.").foregroundStyle(
                            PrumoTheme.secondary)
                    }
                    Section("Skill folders") {
                        PathSetting(
                            title: "Shared skills folder",
                            detail: "Shared Codex skills and the default location for new skills.",
                            path: $draft.sharedSkills
                        ) { choose(.shared) }
                        ForEach(draft.extraSkillRoots, id: \.self) { path in
                            HStack(alignment: .top, spacing: PrumoTheme.gap) {
                                Text(path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                Spacer(minLength: 0)
                                Button("Remove skill folder", systemImage: "minus.circle") {
                                    draft.extraSkillRoots.removeAll { $0 == path }
                                }
                                .labelStyle(.iconOnly).help("Remove \(path) from the library")
                            }
                        }
                        Button("Add skill folders…", systemImage: "folder.badge.plus") { choose(.extra) }
                        Text("Each agent’s skills directory is included automatically.").foregroundStyle(
                            PrumoTheme.secondary)
                    }
                } else {
                    Section {
                        PathSetting(
                            title: "Codex executable", detail: "Used for session continuation and cited answers.",
                            path: $draft.codexExecutable, directory: false
                        ) { choose(.codexExecutable) }
                        PathSetting(
                            title: "Claude Code executable", detail: "Used for session continuation.",
                            path: $draft.claudeExecutable, directory: false
                        ) { choose(.claudeExecutable) }
                    } header: {
                        Text("Command-line agents")
                    } footer: {
                        Text("Continuation opens Terminal with the original agent and data folder.").foregroundStyle(
                            PrumoTheme.secondary)
                    }
                    Section("Cited answers") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Codex model").font(PrumoTheme.row)
                            TextField("Use the Codex CLI default", text: $draft.answerModel).labelsHidden()
                                .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                                .accessibilityLabel("Codex model")
                            Text("Optional. Leave empty to use the CLI default model.").foregroundStyle(
                                PrumoTheme.secondary)
                        }
                        Text(
                            "Local search needs no model. Answer with Codex sends only your question and selected excerpts through your existing CLI setup."
                        )
                        .foregroundStyle(PrumoTheme.secondary)
                    }
                }
            }.formStyle(.grouped).font(PrumoTheme.meta).scrollContentBackground(.hidden)
            VStack(alignment: .leading, spacing: PrumoTheme.gap) {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").font(PrumoTheme.meta)
                        .foregroundStyle(PrumoTheme.accent).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: PrumoTheme.gap) {
                    Button("Stop refresh") { model.index?.cancelScan() }.disabled(!model.isScanning)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save settings", action: save).prumoPrimaryAction().keyboardShortcut(.defaultAction)
                }
            }.padding(PrumoTheme.contentInset).background(PrumoTheme.panel)
        }
        .frame(width: 740, height: 660).background(PrumoTheme.canvas)
        .onAppear {
            draft = model.settings; error = nil
        }
        .fileImporter(
            isPresented: $choosingPath, allowedContentTypes: pathTarget.isDirectory ? [.folder] : [.item],
            allowsMultipleSelection: pathTarget == .extra
        ) { result in
            do {
                let urls = try result.get()
                guard let first = urls.first else { return }
                switch pathTarget {
                case .codex: draft.codexHome = first.path
                case .claude: draft.claudeHome = first.path
                case .shared: draft.sharedSkills = first.path
                case .codexExecutable: draft.codexExecutable = first.path
                case .claudeExecutable: draft.claudeExecutable = first.path
                case .extra:
                    for url in urls where !draft.extraSkillRoots.contains(url.path) {
                        draft.extraSkillRoots.append(url.path)
                    }
                }
                error = nil
            } catch { self.error = "Could not select the path. Choose it again or enter it directly." }
        }
    }

    private func choose(_ target: SettingsPathTarget) {
        pathTarget = target
        choosingPath = true
    }

    private func save() {
        guard !model.isScanning else { error = "A refresh is running. Stop it below, then save again."; return }
        do {
            try model.applySettings(draft)
            dismiss()
        } catch { self.error = error.prumoDescription }
    }
}

private enum SettingsPathTarget {
    case codex, claude, shared, codexExecutable, claudeExecutable, extra
    var isDirectory: Bool { self != .codexExecutable && self != .claudeExecutable }
}

struct PathSetting: View {
    let title: String
    let detail: String
    @Binding var path: String
    var directory = true
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(PrumoTheme.row)
            HStack(spacing: PrumoTheme.gap) {
                TextField(directory ? "~/path/to/folder" : "/path/to/executable", text: $path)
                    .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                    .font(.system(size: 12, design: .monospaced)).accessibilityLabel(title)
                Button("Choose…", action: choose).help("Choose \(title.lowercased())")
            }
            Text(detail).font(PrumoTheme.meta).foregroundStyle(PrumoTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4)
    }
}
