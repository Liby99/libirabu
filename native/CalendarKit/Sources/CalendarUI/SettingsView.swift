// The Settings/Preferences window (opened with ⌘, — see CalendarMac/main.swift).
//
// Three tabs:
//  • Account    — iCloud connectivity (real status, read from the CloudKit layer) plus
//                 Apple Calendar / Google Calendar rows that are visual mockups for now.
//  • Appearance — Light / Dark / Automatic, applied live and persisted (see AppSettings.swift).
//  • API Keys   — a visual mockup of the web app's five LLM services. Nothing entered here is
//                 persisted; the native app has no assistant wired up yet.
//
// Native controls throughout, tinted with the app's red accent (0xff3b6b, as in EventDrawer).

import SwiftUI
import CalendarEngine

private let accent = Color(hex: 0xff3b6b)

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
        }
        .tint(accent)
        .frame(width: 560, height: 480)
    }
}

// ── Account ───────────────────────────────────────────────────────────────────────

private struct AccountTab: View {
    @State private var iCloud: ICloudStatus?   // nil = still probing

    var body: some View {
        Form {
            Section("iCloud") {
                iCloudRow
            }
            Section("Calendars") {
                ConnectRow(icon: "calendar", tint: .red,
                           title: "Apple Calendar",
                           subtitle: "Read events from the Calendar app on this Mac.",
                           button: "Connect")
                ConnectRow(icon: "globe", tint: .blue,
                           title: "Google Calendar",
                           subtitle: "Sign in with Google to sync your Google calendars.",
                           button: "Connect…")
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
            return ("Syncing via iCloud", "Your calendar syncs across every device signed in to the same Apple ID.", .green)
        case .localOnly:
            return ("Local only", "This build isn't set up for iCloud sync — your data stays on this Mac.", .secondary)
        case .noAccount:
            return ("Not signed in", "Sign in to iCloud in System Settings to sync across your devices.", .orange)
        case .restricted:
            return ("Restricted", "iCloud is restricted by a configuration profile or parental controls.", .orange)
        case .unavailable:
            return ("Temporarily unavailable", "iCloud is momentarily unavailable — it'll retry automatically.", .orange)
        case .unknown:
            return ("Unavailable", "Couldn't determine iCloud status.", .orange)
        case nil:
            return ("Checking…", "Determining iCloud status.", .secondary)
        }
    }
}

/// A calendar-source row with an icon, description, and a (visual-only) connect button.
private struct ConnectRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let button: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(button) {}   // visual mockup — not wired up yet
        }
        .padding(.vertical, 2)
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
        }
        .formStyle(.grouped)
    }
}

// ── API Keys ──────────────────────────────────────────────────────────────────────

private struct APIKeysTab: View {
    var body: some View {
        Form {
            Section("LLM providers") {
                APIKeyRow(account: "jhu-gateway",
                          name: "JHU WSE AI Gateway",
                          subtitle: "gateway.engineering.jhu.edu · primary assistant backend",
                          placeholder: "jhu_live_sk_…") {
                    JHUModelPicker()
                }
                APIKeyRow(account: "bedrock",
                          name: "Amazon Bedrock",
                          subtitle: "AWS-hosted models",
                          placeholder: "AWS access key") {
                    BedrockRegionPicker()
                }
                APIKeyRow(account: "openai", name: "OpenAI", subtitle: "GPT models", placeholder: "sk-…") { EmptyView() }
                APIKeyRow(account: "anthropic", name: "Anthropic", subtitle: "Claude models", placeholder: "sk-ant-…") { EmptyView() }
            }
            Section("Web search") {
                APIKeyRow(account: "tavily", name: "Tavily", subtitle: "Web search for the assistant", placeholder: "tvly-…") { EmptyView() }
            }
            Section {
                Text("Keys are stored in your macOS Keychain on this device only — not synced. The native assistant isn’t wired up yet, so they aren’t used elsewhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One provider's row: a masked field + Save/Remove + a status line, with optional trailing
/// picker content (model / region). The secret is persisted to the Keychain (see Keychain.swift).
private struct APIKeyRow<Extra: View>: View {
    let account: String
    let name: String
    let subtitle: String
    let placeholder: String
    @ViewBuilder var extra: () -> Extra

    @State private var value = ""        // what's typed in the field (never shows the stored secret)
    @State private var saved: String?    // the currently-stored secret, for the masked status

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
        if Keychain.set(value, account: account) { saved = value }
        value = ""   // don't leave the raw secret sitting in the field
    }

    private func remove() {
        Keychain.delete(account: account)
        saved = nil
        value = ""
    }
}

/// JHU Gateway model picker (Vendor → Model), mirroring the web app's list.
private struct JHUModelPicker: View {
    private static let models: [(id: String, label: String)] = [
        ("anthropic/claude-sonnet-4.6", "Claude Sonnet 4.6 · Anthropic"),
        ("openai/gpt-5.2", "GPT-5.2 · OpenAI"),
        ("workers-ai/@cf/zai-org/glm-5.2", "GLM-5.2 · Z.ai · open"),
        ("workers-ai/@cf/openai/gpt-oss-120b", "gpt-oss 120B · open weights"),
        ("workers-ai/@cf/openai/gpt-oss-20b", "gpt-oss 20B · smaller/faster"),
        ("workers-ai/@cf/qwen/qwq-32b", "Qwen QwQ 32B · reasoning"),
        ("workers-ai/@cf/qwen/qwen2.5-coder-32b-instruct", "Qwen2.5 Coder 32B · instruct"),
    ]
    // Non-secret config → UserDefaults (not in `syncedPrefKeys`, so it stays local).
    @AppStorage("cc.apikeys.jhu.model") private var model = JHUModelPicker.models[0].id

    var body: some View {
        Picker("Model", selection: $model) {
            ForEach(Self.models, id: \.id) { Text($0.label).tag($0.id) }
        }
    }
}

/// AWS region picker for Bedrock.
private struct BedrockRegionPicker: View {
    private static let regions = ["us-east-1", "us-west-2", "eu-central-1", "eu-west-1", "ap-northeast-1", "ap-southeast-2"]
    @AppStorage("cc.apikeys.bedrock.region") private var region = "us-east-1"

    var body: some View {
        Picker("Region", selection: $region) {
            ForEach(Self.regions, id: \.self) { Text($0).tag($0) }
        }
    }
}
