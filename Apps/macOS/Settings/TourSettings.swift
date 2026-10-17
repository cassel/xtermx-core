import SwiftUI

/// Settings › Tour: the first-launch welcome, on demand.
struct TourSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsPage(section: .tour) {
            SettingsCard("Welcome steps",
                         "The four steps from the first launch: agent hooks, chat and notices, other screens, and a list of what XTermX does. Nothing changes unless you change it there.") {
                Button {
                    openWindow(id: "main")
                    model.tourVisible = true
                } label: { Label("Show the welcome again", systemImage: "play.circle") }
            }
        }
    }
}
