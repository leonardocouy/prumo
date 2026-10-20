import Foundation
import PrumoCore

enum SkillBulkAction: String, CaseIterable, Identifiable, Sendable {
    case linkCodex, unlinkCodex, linkClaude, unlinkClaude, trash
    var id: Self { self }
    var title: String {
        switch self {
        case .linkCodex: "Link to Codex"
        case .unlinkCodex: "Unlink from Codex"
        case .linkClaude: "Link to Claude Code"
        case .unlinkClaude: "Unlink from Claude Code"
        case .trash: "Move to Trash"
        }
    }
    var agent: String { self == .linkCodex || self == .unlinkCodex ? "codex" : "claude" }
    var enabled: Bool { self == .linkCodex || self == .linkClaude }
    func applies(to skill: SkillRow) -> Bool {
        if self == .trash { return !skill.readOnly }
        let state = agent == "codex" ? skill.codexState : skill.claudeState
        return enabled ? state == "absent" : state == "linked"
    }
}

struct SkillBulkReview: Identifiable, Sendable {
    let id = UUID()
    let action: SkillBulkAction
    let skills: [SkillRow]
    let skipped: Int
    let trashTargets: [SkillTrashTarget]
}

struct SkillActionResult: Sendable {
    var completed: Set<String> = []
    var failures: [String] = []
}

enum SkillActions {
    static func perform(
        review: SkillBulkReview, store: SkillStore,
        moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> SkillActionResult {
        var result = SkillActionResult()
        for skill in review.skills {
            do {
                if review.action == .trash {
                    guard let expected = review.trashTargets.first(where: { $0.id == skill.id }),
                        let current = try store.prepareTrash(ids: [skill.id]).first,
                        current.revision == expected.revision, current.links == expected.links
                    else {
                        throw AppFailure(message: "This skill or its links changed. Review it again before removal.")
                    }
                    try moveToTrash(URL(fileURLWithPath: current.id))
                    result.completed.insert(skill.id)
                    for link in current.links {
                        do {
                            let url = URL(fileURLWithPath: link.path)
                            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
                            if destination == link.destination {
                                try FileManager.default.removeItem(at: url)
                            } else {
                                result.failures.append(
                                    "\(skill.name): folder moved, but a changed link was left in place: \(link.path)")
                            }
                        } catch {
                            result.failures.append(
                                "\(skill.name): folder moved; could not remove link \(link.path): \(error.prumoDescription)"
                            )
                        }
                    }
                } else {
                    _ = try store.setLink(id: skill.id, agent: review.action.agent, enabled: review.action.enabled)
                    result.completed.insert(skill.id)
                }
            } catch { result.failures.append("\(skill.name): \(error.prumoDescription)") }
        }
        return result
    }
}
