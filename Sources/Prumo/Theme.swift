import SwiftUI
import AppKit

enum PrumoTheme {
    static let accent = Color(red: 0.141, green: 0.243, blue: 0.318)
    static let copper = Color(red: 0.663, green: 0.396, blue: 0.247)
    static let canvas = Color(red: 1, green: 0.996, blue: 0.980)
    static let panel = Color(red: 0.957, green: 0.949, blue: 0.929)
    static let card = Color(red: 0.929, green: 0.918, blue: 0.890)
    static let line = Color(red: 0.871, green: 0.855, blue: 0.820)
    static let text = accent
    static let secondary = Color(red: 0.333, green: 0.384, blue: 0.420)
    static let muted = Color(red: 0.373, green: 0.424, blue: 0.459)
    static let selection = accent.opacity(0.08)
    static let codex = Color(red: 0.20, green: 0.35, blue: 0.58)
    static let inset: CGFloat = 16
    static let contentInset: CGFloat = 24
    static let gap: CGFloat = 12
    static let sectionGap: CGFloat = 24
    static let radius: CGFloat = 10
    static let title = Font.system(size: 24, weight: .semibold)
    static let heading = Font.system(size: 20, weight: .semibold)
    static let body = Font.system(size: 14)
    static let row = Font.system(size: 13, weight: .medium)
    static let meta = Font.system(size: 12)

    static func rowDetailStyle(selected: Bool) -> AnyShapeStyle {
        selected ? AnyShapeStyle(.primary) : AnyShapeStyle(secondary)
    }
}

struct PrumoMark: View {
    var size: CGFloat = 32
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct AgentBadge: View {
    let agent: String
    var compact = false
    private var name: String { agent == "claude" ? "Claude Code" : "Codex" }
    var body: some View {
        Label(name, systemImage: agent == "claude" ? "asterisk" : "terminal")
            .labelStyle(AgentLabelStyle(compact: compact))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(agent == "claude" ? PrumoTheme.copper : PrumoTheme.codex)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(PrumoTheme.card, in: .rect(cornerRadius: 5))
            .accessibilityElement(children: .ignore).accessibilityLabel(name)
    }
}

private struct AgentLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            if !compact { configuration.title }
        }
    }
}

struct EmptyPanel: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message).foregroundStyle(PrumoTheme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PrumoTheme.contentInset)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(PrumoTheme.secondary)
    }
}

extension View {
    func prumoPrimaryAction() -> some View {
        buttonStyle(.borderedProminent).tint(PrumoTheme.accent)
    }
}
