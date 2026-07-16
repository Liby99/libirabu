// Model catalog + transcript view types for the assistant panel.

import Foundation

// ── Model catalog ─────────────────────────────────────────────────────────────────
// Mirrors src/lib/assistant/models.ts. The gateway routes these provider-prefixed ids.

struct AssistantModel: Identifiable, Hashable {
    var id: String
    var label: String
    var note: String
}

enum AssistantModels {
    static let all: [AssistantModel] = [
        .init(id: "anthropic/claude-sonnet-4.6", label: "Claude Sonnet 4.6", note: "Anthropic"),
        .init(id: "openai/gpt-5.2", label: "GPT-5.2", note: "OpenAI"),
        .init(id: "workers-ai/@cf/zai-org/glm-5.2", label: "GLM-5.2", note: "Z.ai · open"),
        .init(id: "workers-ai/@cf/openai/gpt-oss-120b", label: "gpt-oss 120B", note: "open weights"),
        .init(id: "workers-ai/@cf/qwen/qwq-32b", label: "Qwen QwQ 32B", note: "reasoning"),
    ]
    static let fallback = all[0].id
    static let defaultsKey = "cc.assistant.model"

    static func label(for id: String) -> String { all.first { $0.id == id }?.label ?? id }
}

// ── Transcript view model ───────────────────────────────────────────────────────────

/// One rendered row in the transcript. `.typing` is a transient placeholder shown while the
/// assistant's reply is in flight.
struct ChatTurn: Identifiable {
    enum Role { case user, assistant, typing }
    let id = UUID()
    var role: Role
    var text: String
}

// ── Minimal JSON value (for Phase-2 tool JSON Schemas) ──────────────────────────────
// Codable arbitrary JSON so ToolDef.parameters can carry a schema. Unused in v1.

indirect enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
