import SwiftUI

@main
@MainActor
struct MeetingAssistantApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MeetingsListView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.processor.kick()
            }
        }
    }
}
