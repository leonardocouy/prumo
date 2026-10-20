import Foundation
import PrumoCore

struct AppSettings: Codable, Equatable, Sendable {
    var codexHome: String
    var claudeHome: String
    var sharedSkills: String
    var extraSkillRoots: [String]
    var codexExecutable: String
    var claudeExecutable: String
    var answerModel: String

    static var defaults: AppSettings {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environment = ProcessInfo.processInfo.environment
        let claudeWork = home + "/.claude-work"
        return AppSettings(
            codexHome: environment["CODEX_HOME"] ?? home + "/.codex",
            claudeHome: environment["CLAUDE_CONFIG_DIR"]
                ?? (FileManager.default.fileExists(atPath: claudeWork) ? claudeWork : home + "/.claude"),
            sharedSkills: home + "/.agents/skills", extraSkillRoots: [],
            codexExecutable: Executables.locate("codex"),
            claudeExecutable: Executables.locate("claude"), answerModel: ""
        )
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
            let value = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return defaults }
        return value
    }

    func validate() throws {
        let folders =
            [
                ("Codex data folder", codexHome), ("Claude Code data folder", claudeHome),
                ("Shared skills folder", sharedSkills),
            ]
            + extraSkillRoots.map { ("Additional skill folder", $0) }
        for (name, path) in folders {
            guard expanded(path).hasPrefix("/") else {
                throw AppFailure(message: "\(name): enter an absolute path or a path beginning with ~/.")
            }
        }
    }

    func save() throws {
        UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: "settings")
    }

    func expanded(_ path: String) -> String {
        NSString(string: path.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
    }

    var sources: [AgentSource] {
        [
            AgentSource(agent: "codex", root: expanded(codexHome)),
            AgentSource(agent: "claude", root: expanded(claudeHome)),
        ]
    }

    var skillRoots: [String] {
        Array(
            Set(
                ([sharedSkills, expanded(codexHome) + "/skills", expanded(claudeHome) + "/skills"] + extraSkillRoots)
                    .map(expanded))
        ).sorted()
    }

    func makeSkillStore() -> SkillStore {
        SkillStore(
            roots: skillRoots, codexSkills: expanded(codexHome) + "/skills",
            claudeSkills: expanded(claudeHome) + "/skills", sharedSkills: expanded(sharedSkills))
    }
}

enum Executables {
    static func locate(_ name: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories =
            ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return directories.map { $0 + "/" + name }.first(where: FileManager.default.isExecutableFile) ?? name
    }
}

extension SessionRow {
    public var id: String { key }
    var agentName: String { agent == "claude" ? "Claude Code" : "Codex" }
    var projectName: String { project.isEmpty ? "No project" : URL(fileURLWithPath: project).lastPathComponent }
    var updated: Date { Date(timeIntervalSince1970: Double(updatedMs) / 1000) }
}

extension SearchHit {
    public var id: String { session.key }
}

extension SessionMessage {
    public var id: UInt32 { index }
}

extension SkillRow {
    var addedDate: Date? { addedMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    var addedDateLabel: String {
        addedDate.map { "Added ≈ \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Added date unavailable"
    }
    var addedDateExplanation: String {
        "Approximate date from the original skill folder’s creation date. Copying or restoring the folder can change it."
    }
}
