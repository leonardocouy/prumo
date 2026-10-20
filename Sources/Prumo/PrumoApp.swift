import SwiftUI
import AppKit

@main
struct PrumoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 1050, minHeight: 680)
                .tint(PrumoTheme.accent)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1380, height: 880)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Library") { Task { await model.refresh() } }.keyboardShortcut("r")
                Button("Ask Your History") { model.askFromSearch() }.keyboardShortcut("k")
            }
        }
        Settings {
            SettingsView(model: model)
                .tint(PrumoTheme.accent).preferredColorScheme(.light)
        }
        .windowResizability(.contentSize)
    }
}
