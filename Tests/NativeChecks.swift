import Foundation
import PrumoCore

private func fixtureSession(
    project: String = "/tmp", root: String = "/custom/profile", agent: String = "codex", id: String = "session-one"
) -> SessionRow {
    SessionRow(
        key: "\(agent):\(id)", agent: agent, externalId: id, title: "Database settings", project: project, updatedMs: 0,
        messageCount: 2, sourcePath: "/tmp/session.jsonl", sourceRoot: root)
}

private func sources() -> [SearchHit] {
    [
        SearchHit(
            session: fixtureSession(), messageIndex: 1, excerpt: "assistant: The timeout was set to 40 seconds.",
            role: "assistant", messageDigest: "recorded-digest")
    ]
}

func invalidCitationNumbersAreRejected() throws {
    for citations in [[0], [2], [-1], []] {
        let data = try JSONSerialization.data(withJSONObject: [
            "noEvidence": false, "statements": [["text": "The timeout was 40 seconds.", "citations": citations]],
        ])
        try expectThrows { try AnswerService.validate(data: data, sources: sources()) }
    }
}

func noEvidenceCannotCarryAnUnsupportedClaim() throws {
    let data = Data(#"{"noEvidence":true,"statements":[{"text":"Unsupported","citations":[1]}]}"#.utf8)
    try expectThrows { try AnswerService.validate(data: data, sources: sources()) }
}

func supportedAnswerRetainsItsOriginalSources() throws {
    let data = Data(
        #"{"noEvidence":false,"statements":[{"text":"The timeout was set to 40 seconds.","citations":[1]}]}"#.utf8)
    let answer = try AnswerService.validate(data: data, sources: sources())
    try expect(answer.sources[answer.statements[0].citations[0] - 1].messageIndex == 1)
    try expect(answer.sources[0].session.key == "codex:session-one")
}

func emptyOrMalformedAnswersAreRejected() throws {
    for json in [
        #"{"noEvidence":false,"statements":[]}"#, #"{"noEvidence":false,"statements":[{"text":"  ","citations":[1]}]}"#,
        "not JSON",
    ] {
        try expectThrows { try AnswerService.validate(data: Data(json.utf8), sources: sources()) }
    }
}

func continuationPreservesCustomProfilesAndQuotesShellInput() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prumo-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let project = directory.appendingPathComponent("project with ' quotes")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("mock agent")
    try Data("#!/bin/zsh\nprintf '%s\\n' \"${CODEX_HOME:-}\" \"${CLAUDE_CONFIG_DIR:-}\" \"$PWD\" \"$@\"\n".utf8).write(
        to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let root = "/custom/profile's folder"
    let id = "abc'$(touch INJECTED)"
    for agent in ["codex", "claude"] {
        let work = directory.appendingPathComponent(agent)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var settings = AppSettings.defaults
        settings.codexExecutable = executable.path; settings.claudeExecutable = executable.path
        let script = try Continuation.command(
            session: fixtureSession(project: project.path, root: root, agent: agent, id: id), settings: settings)
        let result = try ProcessRunner().run(
            executable: "/bin/zsh", arguments: ["-f", "-c", script], input: "", directory: work, environment: [:],
            timeout: 5)
        try expect(result.status == 0)
        try expect(result.output.contains(root + "\n"))
        try expect(result.output.contains(project.path + "\n"))
        try expect(result.output.hasSuffix(id + "\n"))
        try expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("INJECTED").path))
    }
}

func continuationRejectsMissingProjectOrExecutable() throws {
    var settings = AppSettings.defaults
    settings.codexExecutable = "/bin/echo"
    try expectThrows {
        try Continuation.command(session: fixtureSession(project: "/path/that/does/not/exist"), settings: settings)
    }
    settings.codexExecutable = "/missing/executable"
    try expectThrows { try Continuation.command(session: fixtureSession(), settings: settings) }
}

func processDeadlineStopsAnUnresponsiveCommand() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prumo-deadline-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        _ = try ProcessRunner().run(
            executable: "/bin/sleep", arguments: ["10"], input: "", directory: directory, environment: [:], timeout: 0.1
        )
        throw CheckFailure(message: "The command should have timed out.")
    } catch { try expect(error.localizedDescription.contains("timed out")) }
}

func cancellationBeforeLaunchPreventsTheCommand() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prumo-cancel-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = ProcessRunner()
    runner.cancel()
    try expectCancellation {
        try runner.run(
            executable: "/bin/touch", arguments: [directory.appendingPathComponent("should-not-exist").path], input: "",
            directory: directory, environment: [:], timeout: 5)
    }
    try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("should-not-exist").path))
}

struct CheckFailure: Error { let message: String }

func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition() { throw CheckFailure(message: "Check failed at \(file):\(line)") }
}

func expectThrows<T>(_ body: () throws -> T) throws {
    do { _ = try body() } catch { return }
    throw CheckFailure(message: "Expected an error, but the operation succeeded.")
}

func expectCancellation<T>(_ body: () throws -> T) throws {
    do { _ = try body() } catch is CancellationError { return }
    throw CheckFailure(message: "Expected cancellation before process launch.")
}

@main struct NativeChecks {
    static func main() async throws {
        let checks: [(String, () throws -> Void)] = [
            ("bulk Trash partial failures and link cleanup", bulkTrashPreservesFailedItemsAndCleansOnlyMatchingLinks),
            ("bulk Trash changed link protection", bulkTrashPreservesALinkChangedDuringRemoval),
            ("bulk Trash stale review", bulkTrashRejectsChangedSkills),
            ("bulk links preserve originals", bulkLinksReportCollisionsWithoutReplacingOriginals),
            ("settings paths and recovery instructions", settingsValidateEveryFolderAndIdentifyInvalidInput),
            ("invalid citation boundaries", invalidCitationNumbersAreRejected),
            ("contradictory no-evidence response", noEvidenceCannotCarryAnUnsupportedClaim),
            ("source identity retained", supportedAnswerRetainsItsOriginalSources),
            ("malformed and empty answers", emptyOrMalformedAnswersAreRejected),
            ("custom profiles and shell quoting", continuationPreservesCustomProfilesAndQuotesShellInput),
            ("unavailable continuation targets", continuationRejectsMissingProjectOrExecutable),
            ("process deadline", processDeadlineStopsAnUnresponsiveCommand),
            ("cancellation before launch", cancellationBeforeLaunchPreventsTheCommand),
        ]
        for (name, check) in checks {
            try check()
            print("PASS: \(name)")
        }
        try await codexAnswerRoundtrip()
        print("PASS: complete cited-answer process boundary")
        print("\(checks.count + 1) native behavior checks passed.")
    }
}

func codexAnswerRoundtrip() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "prumo-roundtrip-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let mock = directory.appendingPathComponent("mock-codex")
    let script = """
        #!/bin/zsh
        output=''
        while (( $# > 0 )); do
          if [[ "$1" == '--output-last-message' ]]; then shift; output="$1"; fi
          shift
        done
        /bin/cat >/dev/null
        print -r -- '{"noEvidence":false,"statements":[{"text":"The timeout was set to 40 seconds.","citations":[1]}]}' > "$output"
        """
    try Data(script.utf8).write(to: mock)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mock.path)
    var settings = AppSettings.defaults
    settings.codexExecutable = mock.path
    let answer = try await AnswerService.answer(
        question: "What timeout was chosen?", sources: sources(), settings: settings)
    try expect(answer.statements.first?.text.contains("40 seconds") == true)
    try expect(answer.sources.first?.session.key == "codex:session-one")
}

private func withSkillFixture(_ body: (URL, SkillStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prumo-skills-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let shared = directory.appendingPathComponent("shared").path
    let codex = directory.appendingPathComponent("codex").path
    let claude = directory.appendingPathComponent("claude").path
    let store = SkillStore(
        roots: [shared, codex, claude], codexSkills: codex, claudeSkills: claude, sharedSkills: shared)
    try body(directory, store)
}

func bulkTrashPreservesFailedItemsAndCleansOnlyMatchingLinks() throws {
    try withSkillFixture { directory, store in
        let root = directory.appendingPathComponent("shared").path
        let first = try store.create(name: "first", text: "First skill", root: root).skill
        let second = try store.create(name: "second", text: "Second skill", root: root).skill
        _ = try store.setLink(id: first.id, agent: "claude", enabled: true)
        _ = try store.setLink(id: second.id, agent: "claude", enabled: true)
        let targets = try store.prepareTrash(ids: [first.id, second.id])
        let review = SkillBulkReview(action: .trash, skills: [first, second], skipped: 0, trashTargets: targets)
        let result = SkillActions.perform(review: review, store: store) { url in
            if url.path == second.path { throw AppFailure(message: "Simulated Trash failure") }
            try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("trashed-first"))
        }
        try expect(result.completed == [first.id])
        try expect(result.failures.count == 1)
        try expect(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("trashed-first/SKILL.md").path))
        try expect(FileManager.default.fileExists(atPath: second.path + "/SKILL.md"))
        try expect(
            (try? FileManager.default.destinationOfSymbolicLink(
                atPath: directory.appendingPathComponent("claude/first").path)) == nil)
        try expect(
            (try? FileManager.default.destinationOfSymbolicLink(
                atPath: directory.appendingPathComponent("claude/second").path)) != nil)
    }
}

func bulkTrashRejectsChangedSkills() throws {
    try withSkillFixture { directory, store in
        let skill = try store.create(
            name: "review", text: "Original", root: directory.appendingPathComponent("shared").path
        ).skill
        let review = SkillBulkReview(
            action: .trash, skills: [skill], skipped: 0, trashTargets: try store.prepareTrash(ids: [skill.id]))
        try Data("External edit".utf8).write(to: URL(fileURLWithPath: skill.path).appendingPathComponent("SKILL.md"))
        let result = SkillActions.perform(review: review, store: store) { _ in
            throw CheckFailure(message: "Stale review reached Trash")
        }
        try expect(result.completed.isEmpty)
        try expect(result.failures.first?.contains("changed") == true)
        let preserved = try String(contentsOfFile: skill.path + "/SKILL.md", encoding: .utf8)
        try expect(preserved == "External edit")
    }
}

func bulkLinksReportCollisionsWithoutReplacingOriginals() throws {
    try withSkillFixture { directory, store in
        let skill = try store.create(
            name: "review", text: "Shared review", root: directory.appendingPathComponent("shared").path
        ).skill
        let original = try store.create(
            name: "review", text: "Claude original", root: directory.appendingPathComponent("claude").path
        ).skill
        let review = SkillBulkReview(action: .linkClaude, skills: [skill], skipped: 0, trashTargets: [])
        let result = SkillActions.perform(review: review, store: store)
        try expect(result.completed.isEmpty)
        try expect(result.failures.count == 1)
        let preserved = try store.detail(id: original.id).text
        try expect(preserved == "Claude original")
        try expect(!SkillBulkAction.unlinkClaude.applies(to: original))
        try expect(!SkillBulkAction.unlinkCodex.applies(to: skill))
    }
}

func bulkTrashPreservesALinkChangedDuringRemoval() throws {
    try withSkillFixture { directory, store in
        let skill = try store.create(
            name: "review", text: "Review", root: directory.appendingPathComponent("shared").path
        ).skill
        let other = try store.create(
            name: "other", text: "Keep this", root: directory.appendingPathComponent("shared").path
        ).skill
        _ = try store.setLink(id: skill.id, agent: "claude", enabled: true)
        let link = directory.appendingPathComponent("claude/review")
        let review = SkillBulkReview(
            action: .trash, skills: [skill], skipped: 0, trashTargets: try store.prepareTrash(ids: [skill.id]))
        let result = SkillActions.perform(review: review, store: store) { url in
            try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("trashed-review"))
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: other.path))
        }
        try expect(result.completed == [skill.id])
        try expect(result.failures.count == 1)
        let remaining = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        try expect(remaining == other.path)
        try expect(FileManager.default.fileExists(atPath: other.path + "/SKILL.md"))
    }
}

func settingsValidateEveryFolderAndIdentifyInvalidInput() throws {
    var settings = AppSettings.defaults
    settings.claudeHome = "~/.claude-work"
    settings.sharedSkills = "/tmp/skills with spaces"
    try settings.validate()
    settings.extraSkillRoots = ["relative/skills"]
    do {
        try settings.validate()
        throw CheckFailure(message: "Relative extra folder was accepted")
    } catch let error as AppFailure {
        try expect(error.message.contains("Additional skill folder"))
        try expect(error.message.contains("absolute path"))
    }
    settings.extraSkillRoots = []
    settings.claudeHome = "  "
    do {
        try settings.validate()
        throw CheckFailure(message: "Empty Claude root was accepted")
    } catch let error as AppFailure {
        try expect(error.message.contains("Claude Code data folder"))
    }
}
