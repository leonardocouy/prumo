import AppKit
import Observation
import PrumoCore

enum LibrarySection: String, CaseIterable, Identifiable {
    case sessions, answers, skills
    var id: Self { self }
    var title: String {
        switch self { case .sessions: "Sessions"; case .answers: "Ask your history"; case .skills: "Skills" }
    }
    var symbol: String {
        switch self { case .sessions: "text.bubble"; case .answers: "sparkle.magnifyingglass"; case .skills: "square.stack.3d.up" }
    }
}

@Observable @MainActor
final class AppModel {
    var settings = AppSettings.load()
    var section: LibrarySection = .sessions
    var query = ""
    var agentFilter = ""
    var projectFilter = ""
    var hits: [SearchHit] = []
    var sessionOrder: SearchOrder = .newest
    var skills: [SkillRow] = []
    var skillUsage: [String: SkillUsage] = [:]
    var skillUsageFilter = "all"
    var skillSort = "name"
    var selectedSkills: Set<String> = []
    var bulkReview: SkillBulkReview?
    var isManagingSkills = false
    var skillActionSummary: String?
    @ObservationIgnored private var skillRequestID: UUID?

    var visibleSkills: [SkillRow] {
        let filtered = skills.filter { skill in
            let matches = query.isEmpty || "\(skill.name) \(skill.description)".localizedStandardContains(query)
            let count = skillUsage[skill.id]?.uses ?? 0
            return matches && (skillUsageFilter == "all" || (skillUsageFilter == "unused" ? count == 0 : count > 0))
        }
        return filtered.sorted { a, b in
            let left = skillUsage[a.id], right = skillUsage[b.id]
            if skillSort == "most", left?.uses ?? 0 != right?.uses ?? 0 { return (left?.uses ?? 0) > (right?.uses ?? 0) }
            if skillSort == "recent", left?.lastUsedMs ?? 0 != right?.lastUsedMs ?? 0 { return (left?.lastUsedMs ?? 0) > (right?.lastUsedMs ?? 0) }
            if ["newest", "oldest"].contains(skillSort), a.addedMs != b.addedMs {
                guard let left = a.addedMs else { return false }
                guard let right = b.addedMs else { return true }
                return skillSort == "newest" ? left > right : left < right
            }
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }
    var projects: [String] = []
    var stats = LibraryStats(sessions: 0, messages: 0, projects: 0)
    var selectedSession: String?
    var transcript: SessionDetail?
    var selectedSkill: String?
    var skillDetail: SkillDetail?
    var scrollMessage: UInt32?
    var isScanning = false
    var isLoadingTranscript = false
    var scanSummary = "Your library stays on this Mac."
    var scanWarnings: [String] = []
    var error: String?
    var showCreateSkill = false
    var revision = 0
    var question = ""
    var evidence: [SearchHit] = []
    var excludedEvidence: Set<String> = []
    var evidenceQuestion = ""
    var answer: CitedAnswer?
    var isFindingEvidence = false
    var isAnswering = false
    var answerError: String?
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?
    @ObservationIgnored private var activeAnswerID: UUID?
    @ObservationIgnored private var evidenceRequestID: UUID?
    @ObservationIgnored let index: SessionIndex?

    init() {
        do {
            let override = ProcessInfo.processInfo.environment["PRUMO_DATA_DIR"]
            let data = override.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Prumo")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if override == nil { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path) }
            index = try SessionIndex(databasePath: data.appendingPathComponent("Library.sqlite").path)
        } catch {
            index = nil
            self.error = error.prumoDescription
        }
    }

    var filterIdentity: String { "\(section)|\(query)|\(agentFilter)|\(projectFilter)|\(sessionOrder)|\(revision)" }
    var sidebarSelection: LibrarySection? {
        get { section }
        set {
            guard let newValue, newValue != section else { return }
            section = newValue
            query = ""
        }
    }
    var sessionSelection: String? {
        get { selectedSession }
        set {
            guard let newValue, newValue != selectedSession else { return }
            openSession(newValue, message: query.isEmpty ? nil : hits.first(where: { $0.id == newValue })?.messageIndex)
        }
    }
    var skillSelection: String? {
        get { selectedSkill }
        set { if let newValue, newValue != selectedSkill { openSkill(newValue) } }
    }
    var includedEvidence: [SearchHit] { evidence.filter { !excludedEvidence.contains($0.id) } }

    func refresh(background: Bool = false) async {
        guard let index, !isScanning else { return }
        isScanning = true
        let sources = settings.sources
        if !background { scanSummary = "Reading your session folders…" }
        let progress = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                if let count = try? await Task.detached(priority: .utility, operation: { try index.stats() }).value {
                    if self.stats != count {
                        self.stats = count
                        self.revision += 1
                    }
                }
            }
        }
        defer { progress.cancel(); isScanning = false }
        do {
            let report = try await Task.detached(priority: .utility) { try index.scan(sources: sources) }.value
            stats = try await Task.detached(priority: .utility) { try index.stats() }.value
            projects = try await Task.detached(priority: .utility) { try index.projects() }.value
            scanWarnings = report.warnings
            scanSummary = report.cancelled ? "Refresh stopped. Indexed sessions are ready." : "\(stats.sessions.formatted()) sessions · \(stats.projects.formatted()) projects"
            if report.skipped > 0 { scanSummary += " · \(report.skipped) skipped" }
            revision += 1
            await loadSkills()
            if let selectedSession { openSession(selectedSession, message: scrollMessage) }
        } catch { self.error = error.prumoDescription }
    }

    func loadResults() async {
        let identity = filterIdentity
        do {
            if section == .skills {
                return
            } else if let index {
                let query = query, agent = agentFilter, project = projectFilter, order = sessionOrder
                let result = try await Task.detached(priority: .utility) { try index.search(query: query, agent: agent, project: project, limit: 300, order: order) }.value
                if identity == filterIdentity { hits = result }
            }
        } catch { if identity == filterIdentity { self.error = error.prumoDescription } }
    }

    func loadSkills() async {
        do {
            let request = UUID()
            skillRequestID = request
            let store = settings.makeSkillStore(), index = index
            let result = try await Task.detached(priority: .utility) {
                let inventory = try store.list(query: "")
                let usage = try index?.skillUsage(skills: inventory) ?? []
                return (inventory, usage)
            }.value
            guard skillRequestID == request else { return }
            skills = result.0
            skillUsage = Dictionary(uniqueKeysWithValues: result.1.map { ($0.skillId, $0) })
            selectedSkills.formIntersection(Set(skills.map(\.id)))
            if let selectedSkill, !skills.contains(where: { $0.id == selectedSkill }) {
                self.selectedSkill = nil; skillDetail = nil
            }
        } catch { self.error = error.prumoDescription }
    }

    func reviewSkillAction(_ action: SkillBulkAction, ids: Set<String>? = nil) {
        guard !isManagingSkills else { return }
        let selected = skills.filter { (ids ?? selectedSkills).contains($0.id) }
        let applicable = selected.filter { action.applies(to: $0) }
        guard !applicable.isEmpty else { return }
        let store = settings.makeSkillStore()
        isManagingSkills = true
        Task {
            defer { isManagingSkills = false }
            do {
                let targets = action == .trash ? try await Task.detached { try store.prepareTrash(ids: applicable.map(\.id)) }.value : []
                bulkReview = SkillBulkReview(action: action, skills: applicable, skipped: selected.count - applicable.count, trashTargets: targets)
            } catch { self.error = error.prumoDescription }
        }
    }

    func performSkillAction(_ review: SkillBulkReview) {
        guard !isManagingSkills else { return }
        isManagingSkills = true
        bulkReview = nil
        let store = settings.makeSkillStore()
        Task {
            defer { isManagingSkills = false }
            let result = await Task.detached(priority: .userInitiated) { SkillActions.perform(review: review, store: store) }.value
            selectedSkills.subtract(result.completed)
            skillActionSummary = "\(result.completed.count) of \(review.skills.count) skills updated."
            if review.skipped > 0 { skillActionSummary! += " \(review.skipped) ineligible skills skipped." }
            await loadSkills()
            if let selectedSkill { openSkill(selectedSkill) }
            if !result.failures.isEmpty { error = result.failures.joined(separator: "\n\n") }
        }
    }

    func openSession(_ key: String, message: UInt32? = nil) {
        guard let index else { return }
        transcriptTask?.cancel()
        selectedSession = key
        scrollMessage = message
        isLoadingTranscript = true
        transcriptTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try index.transcript(key: key) }.value
                guard !Task.isCancelled, selectedSession == key else { return }
                transcript = result
                isLoadingTranscript = false
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingTranscript = false
                self.error = error.prumoDescription
            }
        }
    }

    func openCitation(_ hit: SearchHit) {
        guard let index else { return }
        Task {
            do {
                let position = try await Task.detached { try index.resolveCitation(key: hit.session.key, messageIndex: hit.messageIndex, messageDigest: hit.messageDigest) }.value
                section = .sessions
                openSession(hit.session.key, message: position)
            } catch { self.error = error.prumoDescription }
        }
    }

    func openSkill(_ id: String) {
        selectedSkill = id
        Task {
            do {
                let store = settings.makeSkillStore()
                let result = try await Task.detached { try store.detail(id: id) }.value
                if selectedSkill == id { skillDetail = result }
            } catch { self.error = error.prumoDescription }
        }
    }

    func applySettings(_ value: AppSettings) throws {
        try value.validate()
        try value.save()
        cancelAnswer()
        settings = value
        transcript = nil; selectedSession = nil
        skillDetail = nil; selectedSkill = nil; selectedSkills = []; skillUsage = [:]
        evidence = []; answer = nil
        evidenceRequestID = nil
        Task { await refresh() }
    }

    func askFromSearch() {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { question = query }
        section = .answers
        Task { await findEvidence() }
    }

    func findEvidence() async {
        guard let index, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelAnswer()
        answer = nil; answerError = nil; excludedEvidence = []
        isFindingEvidence = true
        let question = question, agent = agentFilter, project = projectFilter
        let requestID = UUID()
        evidenceRequestID = requestID
        evidenceQuestion = question
        do {
            let result = try await Task.detached(priority: .userInitiated) { try index.evidence(question: question, agent: agent, project: project) }.value
            if evidenceRequestID == requestID { evidence = result }
        } catch { if evidenceRequestID == requestID { answerError = error.prumoDescription } }
        if evidenceRequestID == requestID { isFindingEvidence = false }
    }

    func generateAnswer() {
        guard !isAnswering, !includedEvidence.isEmpty else { return }
        let id = UUID()
        activeAnswerID = id
        isAnswering = true; answerError = nil; answer = nil
        let sources = includedEvidence, question = evidenceQuestion, settings = settings
        answerTask = Task {
            do {
                let result = try await AnswerService.answer(question: question, sources: sources, settings: settings)
                guard !Task.isCancelled, activeAnswerID == id else { return }
                answer = result
            } catch {
                if !Task.isCancelled, activeAnswerID == id { answerError = error.prumoDescription }
            }
            if activeAnswerID == id { isAnswering = false; activeAnswerID = nil }
        }
    }

    func cancelAnswer() {
        answerTask?.cancel()
        answerTask = nil
        activeAnswerID = nil
        isAnswering = false
    }

    func continueSession(_ session: SessionRow) {
        Task {
            do { try await Continuation.open(session: session, settings: settings) }
            catch { self.error = error.prumoDescription }
        }
    }

    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}
