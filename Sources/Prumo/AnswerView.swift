import SwiftUI
import PrumoCore

struct EvidenceListView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sources").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(model.evidence.count.formatted()).font(PrumoTheme.meta).monospacedDigit().foregroundStyle(
                        PrumoTheme.secondary)
                }
                Text("Review the passages behind an answer.").font(PrumoTheme.meta).foregroundStyle(
                    PrumoTheme.secondary)
            }.padding(PrumoTheme.inset)
            Divider()
            if model.evidence.isEmpty {
                EmptyPanel(
                    symbol: "quote.opening", title: "No sources selected",
                    message: "Ask a question to find matching passages from your local sessions.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.evidence.enumerated()), id: \.element.id) { index, hit in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top) {
                                    Text(String(format: "%02d", index + 1)).font(
                                        .system(size: 12, weight: .medium, design: .monospaced)
                                    ).foregroundStyle(PrumoTheme.accent)
                                    Text(hit.session.title).font(PrumoTheme.row).lineLimit(2).help(hit.session.title)
                                    Spacer(minLength: 0)
                                    Toggle(
                                        "Include source \(index + 1)",
                                        isOn: Binding(
                                            get: { !model.excludedEvidence.contains(hit.id) },
                                            set: { included in
                                                if included {
                                                    model.excludedEvidence.remove(hit.id)
                                                } else {
                                                    model.excludedEvidence.insert(hit.id)
                                                }
                                                model.answer = nil
                                            })
                                    ).labelsHidden().toggleStyle(.checkbox).disabled(model.isAnswering)
                                }
                                HStack {
                                    AgentBadge(agent: hit.session.agent);
                                    Text(hit.session.projectName).font(PrumoTheme.meta).foregroundStyle(
                                        PrumoTheme.secondary
                                    ).lineLimit(1).help(hit.session.projectName)
                                }
                                Text(hit.excerpt).font(PrumoTheme.meta).foregroundStyle(PrumoTheme.secondary).lineLimit(
                                    8
                                ).textSelection(.enabled)
                                Button("Open passage", systemImage: "arrow.up.right") { model.openCitation(hit) }.font(
                                    PrumoTheme.meta
                                ).buttonStyle(.plain).foregroundStyle(PrumoTheme.accent)
                            }.padding(.vertical, 12)
                            Divider()
                        }
                    }.padding(13)
                }
            }
        }.background(PrumoTheme.canvas)
    }
}

struct AnswerView: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(text: "Cited answers")
                    Text("Ask your history").font(PrumoTheme.title)
                    Text("Ask about a decision, a fix, or a previous investigation.").font(.system(size: 13))
                        .foregroundStyle(PrumoTheme.secondary)
                }
                SessionFilters(model: model).font(PrumoTheme.meta)
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Where did we configure the database timeout?", text: $model.question, axis: .vertical)
                        .font(.system(size: 15)).textFieldStyle(.plain).lineLimit(2...5).accessibilityLabel(
                            "Question about your history")
                    HStack {
                        Label("Search stays on this Mac", systemImage: "internaldrive").font(PrumoTheme.meta)
                            .foregroundStyle(PrumoTheme.muted)
                        Spacer()
                        Button(
                            model.isFindingEvidence ? "Finding passages…" : "Find passages",
                            systemImage: "magnifyingglass"
                        ) { Task { await model.findEvidence() } }.prumoPrimaryAction().disabled(
                            model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.isFindingEvidence || model.isAnswering)
                    }
                }.padding(19).background(PrumoTheme.card, in: .rect(cornerRadius: 12)).overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(PrumoTheme.line)
                }
                if !model.evidenceQuestion.isEmpty && !model.isFindingEvidence {
                    if model.evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No matching passages yet.").font(.system(size: 18, weight: .semibold))
                            Text(
                                "Try the names or terms used in the original conversation. You can also change the agent or project filter."
                            ).font(.system(size: 12)).foregroundStyle(PrumoTheme.secondary)
                        }
                    } else {
                        answerActions
                        if let answer = model.answer {
                            CitedAnswerView(answer: answer, open: model.openCitation)
                        } else {
                            VStack(alignment: .leading, spacing: 13) {
                                SectionLabel(text: "From your sessions")
                                Text(
                                    "\(model.evidence.count) \(model.evidence.count == 1 ? "conversation contains" : "conversations contain") matching passages."
                                ).font(PrumoTheme.heading)
                                Text(
                                    "Read them in the source panel, or ask Codex to put together a cited answer from the excerpts you select."
                                ).font(.system(size: 13)).foregroundStyle(PrumoTheme.secondary).lineSpacing(4)
                            }.padding(.vertical, 10)
                        }
                    }
                }
                if let error = model.answerError {
                    Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 30)
            }.padding(PrumoTheme.contentInset).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private var answerActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if model.isAnswering {
                    ProgressView().controlSize(.small)
                    Text("Reading the selected sources…").font(.system(size: 12)).foregroundStyle(PrumoTheme.secondary)
                    Spacer()
                    Button("Stop") { model.cancelAnswer() }
                } else {
                    Button {
                        model.generateAnswer()
                    } label: {
                        Label("Answer with Codex", systemImage: "sparkles")
                    }.prumoPrimaryAction()
                        .disabled(model.includedEvidence.isEmpty || model.question != model.evidenceQuestion)
                    Text(
                        "\(model.includedEvidence.count) selected \(model.includedEvidence.count == 1 ? "source" : "sources")"
                    ).font(PrumoTheme.meta).foregroundStyle(PrumoTheme.secondary)
                }
            }
            Text(
                "Sends your question and selected excerpts through your existing Codex CLI. Its provider processes the answer."
            )
            .font(PrumoTheme.meta).foregroundStyle(PrumoTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CitedAnswerView: View {
    let answer: CitedAnswer
    let open: (SearchHit) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Divider()
            HStack {
                SectionLabel(text: "The answer"); Spacer();
                Label("Citations linked", systemImage: "link").font(PrumoTheme.meta).foregroundStyle(
                    PrumoTheme.secondary)
            }
            if answer.noEvidence {
                Text("The selected passages do not support an answer to this question.").font(.system(size: 16))
                    .foregroundStyle(PrumoTheme.secondary)
            } else {
                ForEach(Array(answer.statements.enumerated()), id: \.offset) { _, statement in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(statement.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                        HStack(spacing: 7) {
                            ForEach(Array(Set(statement.citations)).sorted(), id: \.self) { citation in
                                Button {
                                    open(answer.sources[citation - 1])
                                } label: {
                                    Label("\(citation)", systemImage: "arrow.up.right").font(
                                        .system(size: 12, weight: .medium)
                                    ).padding(.horizontal, 8).padding(.vertical, 5).background(
                                        PrumoTheme.accent.opacity(0.10), in: .capsule)
                                }.buttonStyle(.plain).foregroundStyle(PrumoTheme.accent).help(
                                    answer.sources[citation - 1].session.title)
                            }
                        }
                    }
                }
                Text("An account of past sessions. Check the current project before acting on it.").font(
                    PrumoTheme.meta
                ).foregroundStyle(PrumoTheme.muted)
            }
        }
    }
}
