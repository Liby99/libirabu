// Contents of the macOS "AI" menu (hosted by the app via `CommandMenu("AI")`). Kept in CalendarUI so
// it can read the internal model catalog (AssistantModels) and drive the shared AssistantState; the app
// target just drops `AICommands(assistant:)` into its command builder.

import SwiftUI

public struct AICommands: View {
    let assistant: AssistantState
    @Environment(\.openWindow) private var openWindow
    // The model id the assistant uses, shared with the chat window's picker (same @AppStorage key).
    @AppStorage(AssistantModels.defaultsKey) private var model = AssistantModels.fallback

    public init(assistant: AssistantState) { self.assistant = assistant }

    public var body: some View {
        Button("New Conversation") { assistant.newChat(); openWindow(id: "assistant") }
        Button("Current Conversation") { openWindow(id: "assistant") }
        Divider()
        // Renders as a "Model ▸" submenu with a checkmark on the active model.
        Picker("Model", selection: $model) {
            ForEach(AssistantModels.all) { m in Text(m.label).tag(m.id) }
        }
        Divider()
        SettingsLink { Text("Configure API Keys…") }
    }
}
