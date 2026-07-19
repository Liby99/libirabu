// The Settings/Preferences window (opened with ⌘, — see CalendarMac/main.swift).
//
// Three tabs:
//  • Account    — iCloud connectivity (real status, read from the CloudKit layer); a live
//                 macOS Apple Calendar connection (EventKit) with a per-calendar checklist; and a
//                 Google Calendar row that's a visual mockup for now.
//  • Appearance — Light / Dark / Automatic, applied live and persisted (see AppSettings.swift).
//  • API Keys   — the assistant's credentials (JHU Gateway for chat, Tavily for web search),
//                 stored in the macOS Keychain (see Keychain.swift); local to this device.
//
// Native controls throughout, tinted with the app's red accent (0xff3b6b, as in EventDrawer).

import CalendarEngine
import SwiftUI

private var accent: Color { Theme.accent }

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            AccountTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            APIKeysTab()
                .tabItem { Label("API Keys", systemImage: "key") }
            DeveloperTab()
                .tabItem { Label("Developer", systemImage: "hammer") }
        }
        .tint(accent)
        .frame(width: 560, height: 480)
    }
}

// ── Account ───────────────────────────────────────────────────────────────────────

private struct AccountTab: View {
    @State private var iCloud: ICloudStatus? // nil = still probing

    var body: some View {
        Form {
            Section("iCloud") {
                iCloudRow
            }
            Section("macOS Apple Calendar") {
                AppleCalendarRows()
            }
            Section("Google Calendar") {
                HStack(spacing: 10) {
                    Text("Sign in with Google to sync your Google calendars.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect…") {} // visual mockup — not wired up yet
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .task { iCloud = await CalendarEngine.iCloudStatus() }
    }

    private var iCloudRow: some View {
        let (title, detail, color) = Self.describe(iCloud)
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// Human title, one-line detail, and dot color for each status. `nil` = still probing.
    private static func describe(_ s: ICloudStatus?) -> (String, String, Color) {
        switch s {
        case .available:
            ("Syncing via iCloud", "Your calendar syncs across every device signed in to the same Apple ID.", .green)
        case .localOnly:
            ("Local only", "This build isn't set up for iCloud sync — your data stays on this Mac.", .secondary)
        case .noAccount:
            ("Not signed in", "Sign in to iCloud in System Settings to sync across your devices.", .orange)
        case .restricted:
            ("Restricted", "iCloud is restricted by a configuration profile or parental controls.", .orange)
        case .unavailable:
            ("Temporarily unavailable", "iCloud is momentarily unavailable — it'll retry automatically.", .orange)
        case .unknown:
            ("Unavailable", "Couldn't determine iCloud status.", .orange)
        case nil:
            ("Checking…", "Determining iCloud status.", .secondary)
        }
    }
}

/// ── Apple Calendar connection (EventKit) ────────────────────────────────────────────
/// The Settings window is isolated from the running engine, so this talks to EventKit directly and
/// shares state with the engine through UserDefaults + a `.appleCalendarSettingsChanged` notification.
private struct AppleCalendarRows: View {
    // Apple subscription state is per MagiCal calendar; key both by the active calendar id (read from
    // UserDefaults, which the engine keeps in sync). Fixed for this Settings session.
    private static let calId = PrefKeys.currentCalendarId
    @AppStorage(PrefKeys.appleEnabled(AppleCalendarRows.calId)) private var enabled = false
    @Environment(\.openURL) private var openURL
    @State private var access = CalendarEngine.appleAccess
    @State private var calendars: [AppleCalendarInfo] = []
    @State private var selected: Set<String> = []
    @State private var busy = false
    private let importer = AppleCalendarImporter()

    var body: some View {
        // Connection status + action (the section header already names it "macOS Apple Calendar").
        HStack(spacing: 10) {
            Text(statusText).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
        .onAppear {
            selected = Set(UserDefaults.standard.stringArray(forKey: PrefKeys.appleCalendars(Self.calId)) ?? [])
            access = CalendarEngine.appleAccess
            if access == .authorized {
                calendars = importer.calendars()
            }
        }

        // The user's calendars, once connected — a compact, indented checklist in the same group:
        //   [checkbox · color dot · name] left-aligned  ·  account name right-aligned.
        if enabled, access == .authorized {
            if calendars.isEmpty {
                Text("No calendars found.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(calendars) { c in
                    Toggle(isOn: toggle(c.id)) {
                        HStack(spacing: 8) {
                            Circle().fill(dot(c.colorHex)).frame(width: 8, height: 8)
                            Text(c.title).lineLimit(1)
                            Spacer(minLength: 10)
                            Text(c.source).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.callout)
                        .padding(.leading, 7) // breathing room between the checkbox and the color dot
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .padding(.leading, 16) // indent the calendars under the connection row
                }
            }
        }
    }

    private var statusText: String {
        switch access {
        case .denied: "Calendar access is off — turn it on in System Settings ▸ Privacy."
        case .notDetermined: "Read events from the Calendar app on this Mac."
        case .authorized: enabled ? "\(selected.count) calendar\(selected.count == 1 ? "" : "s") importing." : "Choose which calendars to import."
        }
    }

    @ViewBuilder private var trailing: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else if access == .denied {
            Button("Open Settings…") {
                openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
        } else if enabled {
            Button("Disconnect") { enabled = false; notifyEngine() }
        } else {
            Button("Connect") { connect() }
        }
    }

    private func connect() {
        busy = true
        Task {
            let ok = await importer.requestAccess()
            if ok {
                // Trust the grant result — authorizationStatus can still read stale for a beat, which
                // would hide the calendar list. Drive the UI off `ok` and ask the store directly.
                access = .authorized
                calendars = importer.calendars()
                if selected.isEmpty {
                    selected = Set(calendars.map(\.id))
                } // default: import all
                enabled = true
                save()
            } else {
                access = CalendarEngine.appleAccess // denied / restricted
            }
            busy = false
        }
    }

    private func toggle(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: {
                    on in if on {
                        selected.insert(id)
                    } else {
                        selected.remove(id)
                    }; save()
                })
    }

    private func save() {
        UserDefaults.standard.set(Array(selected), forKey: PrefKeys.appleCalendars(Self.calId))
        notifyEngine()
    }

    private func notifyEngine() {
        NotificationCenter.default.post(name: .appleCalendarSettingsChanged, object: nil)
    }

    private func dot(_ hex: String) -> Color {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        return UInt32(s, radix: 16).map { Color(hex: $0) } ?? .secondary
    }
}

// ── Appearance ────────────────────────────────────────────────────────────────────

private struct AppearanceTab: View {
    @AppStorage(appearanceDefaultsKey) private var raw = AppearanceMode.auto.rawValue

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $raw) {
                    ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: raw) { _, v in
                    applyAppearance(AppearanceMode(rawValue: v) ?? .auto)
                }
                Text("“Automatic” follows your macOS system setting. Light and Dark override it for this app only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Accent Color") {
                AccentColorRows()
            }
        }
        .formStyle(.grouped)
    }
}

/// The accent picker: the default on its own row, the alternatives on a second row.
private struct AccentColorRows: View {
    @State private var selected: UInt32 = AccentPref.hex

    var body: some View {
        HStack(spacing: 10) {
            swatch(AccentPref.defaultHex)
            Text("MagiCal Red")
            Text("default").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        HStack(spacing: 12) {
            ForEach(AccentPref.alternatives, id: \.hex) { opt in
                swatch(opt.hex).help(opt.name)
            }
            Spacer()
        }
        Text("Colors the now-line, today pill, selection, and controls across the app.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func swatch(_ hex: UInt32) -> some View {
        Button {
            selected = hex
            AccentPref.set(hex)
        } label: {
            ZStack {
                Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                if selected == hex {
                    Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 2)
                        .frame(width: 28, height: 28)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }
}

// ── API Keys ──────────────────────────────────────────────────────────────────────

private struct APIKeysTab: View {
    @State private var selected: ProviderID? = ProviderStore.active

    var body: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $selected) {
                    Text("None").tag(ProviderID?.none)
                    ForEach(ProviderID.allCases) { id in
                        Text(id.label).tag(Optional(id))
                    }
                }
                .onChange(of: selected) { _, v in ProviderStore.active = v }
                if selected == nil {
                    Text("Pick a provider to configure it. The assistant activates once the selected provider passes Test Connection. Configurations for every provider are kept, so switching back is instant.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let id = selected {
                ProviderConfigSection(id: id).id(id) // .id resets the section state per provider
            }
            Section("Web search") {
                APIKeyRow(
                    account: "tavily",
                    name: "Tavily",
                    subtitle: "Web search for the assistant",
                    placeholder: "tvly-…"
                ) { EmptyView() }
            }
            Section {
                Text("Keys are stored in your macOS Keychain on this device only — not synced. The assistant talks to whichever provider is selected AND tested above; the Tavily key powers web search.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One provider's full configuration: its secret(s), provider-specific fields, the supported-LLM
/// picker (+ custom id escape hatch), and Test Connection. Any edit clears the tested flag —
/// the assistant only runs against a config that passed a test as-is.
private struct ProviderConfigSection: View {
    let id: ProviderID
    @State private var cfg: ProviderSettings = .init()
    @State private var customModel = ""
    @State private var testing = false
    @State private var testError: String?

    var body: some View {
        Section(id.label) {
            // ── Secrets ──
            switch id {
            case .gateway:
                TextField("Base URL", text: $cfg.baseURL, prompt: Text(LLMClient.defaultBaseURL))
                    .onChange(of: cfg.baseURL) { _, _ in invalidate() }
                Text("Any OpenAI-compatible gateway (LiteLLM-style). Default: JHU WSE AI Gateway; requests go to {base}/compat/chat/completions.")
                    .font(.caption).foregroundStyle(.secondary)
                keyRow("API Key", field: "key", placeholder: "jhu_live_sk_… / gateway key")
            case .openai:
                keyRow("API Key", field: "key", placeholder: "sk-…")
            case .anthropic:
                keyRow("API Key", field: "key", placeholder: "sk-ant-…")
            case .bedrock:
                keyRow("Access Key ID", field: "akid", placeholder: "AKIA…")
                keyRow("Secret Access Key", field: "secret", placeholder: "AWS secret access key")
                keyRow("Session Token (optional)", field: "session", placeholder: "temporary-credentials only")
                TextField("Region", text: $cfg.region, prompt: Text("us-east-1"))
                    .onChange(of: cfg.region) { _, _ in invalidate() }
            }

            // ── Supported LLMs ──
            Picker("Model", selection: $cfg.model) {
                ForEach(id.supportedModels, id: \.id) { m in
                    Text(m.label).tag(m.id)
                }
                if !customModel.isEmpty || !id.supportedModels.contains(where: { $0.id == cfg.model }) {
                    Text("Custom: \(cfg.model)").tag(cfg.model)
                }
            }
            .onChange(of: cfg.model) { _, _ in invalidate() }
            HStack {
                TextField("Custom model id (optional)", text: $customModel)
                    .textFieldStyle(.roundedBorder).font(.caption)
                Button("Use") {
                    let m = customModel.trimmingCharacters(in: .whitespaces)
                    if !m.isEmpty { cfg.model = m; invalidate() }
                }
                .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // ── Test Connection ──
            HStack(spacing: 10) {
                Button {
                    runTest()
                } label: {
                    if testing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Testing…") }
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(testing)
                if cfg.testedOK {
                    Label("Tested — the assistant can use this provider", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                } else {
                    Label("Not tested — the assistant won't use it yet", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange).font(.caption)
                }
            }
            if let testError {
                Text(testError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onAppear { cfg = ProviderStore.settings(id) }
    }

    private func keyRow(_ name: String, field: String, placeholder: String) -> some View {
        APIKeyRow(account: ProviderStore.secretAccount(id, field: field), name: name,
                  subtitle: "", placeholder: placeholder, onChanged: { invalidate() }) { EmptyView() }
    }

    /// Any config edit → this exact combination is untested again.
    private func invalidate() {
        cfg.testedOK = false
        testError = nil
        ProviderStore.save(id, cfg)
    }

    private func runTest() {
        testing = true; testError = nil
        ProviderStore.save(id, cfg)
        let id = id
        let model = cfg.model
        Task { @MainActor in
            do {
                try await ProviderStore.provider(id).testConnection(model: model)
                cfg.testedOK = true
                ProviderStore.save(id, cfg)
            } catch {
                cfg.testedOK = false
                ProviderStore.save(id, cfg)
                testError = error.localizedDescription
            }
            testing = false
        }
    }
}

/// One provider's row: a masked field + Save/Remove + a status line, with optional trailing
/// picker content (model / region). The secret is persisted to the Keychain (see Keychain.swift).
private struct APIKeyRow<Extra: View>: View {
    let account: String
    let name: String
    let subtitle: String
    let placeholder: String
    var onChanged: () -> Void = {}
    @ViewBuilder var extra: () -> Extra

    @State private var value = "" // what's typed in the field (never shows the stored secret)
    @State private var saved: String? // the currently-stored secret, for the masked status

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(saved == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
            HStack(spacing: 8) {
                SecureField(saved == nil ? placeholder : "Enter a new key to replace", text: $value)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { save() }.disabled(value.isEmpty)
                Button("Remove") { remove() }.disabled(saved == nil)
            }
            extra()
        }
        .padding(.vertical, 4)
        .onAppear { saved = Keychain.get(account: account) }
    }

    /// "••••LAST4" when a key is stored, else "Not set".
    private var statusText: String {
        guard let saved, !saved.isEmpty else { return "Not set" }
        return "••••" + String(saved.suffix(4))
    }

    private func save() {
        // Trim whitespace/newlines — a stray trailing newline from a paste would make
        // URLRequest silently drop the "Authorization: Bearer …" header (→ gateway 401).
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if Keychain.set(clean, account: account) {
            saved = clean
        }
        value = "" // don't leave the raw secret sitting in the field
        onChanged()
    }

    private func remove() {
        Keychain.delete(account: account)
        saved = nil
        value = ""
        onChanged()
    }
}


// ── Developer ─────────────────────────────────────────────────────────────────────

private struct DeveloperTab: View {
    @AppStorage("cc.fpsHUD") private var fpsHUD = false

    var body: some View {
        Form {
            Section("Performance") {
                Toggle("Show frame rate HUD", isOn: $fpsHUD)
                    .toggleStyle(.switch)
                Text("Overlays live render-loop frame timing in the calendar window's corner. " +
                    "The render loop pauses when the calendar is idle, so read it while scrolling or animating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
