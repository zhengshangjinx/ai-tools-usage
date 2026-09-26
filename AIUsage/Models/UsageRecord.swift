import Foundation
import SwiftUI

/// 一次 LLM 请求的 token 用量，已跨工具归一化。
/// `inputUncached` 不含缓存读/写（OpenAI 的 input_tokens 含 cached，解析时已扣除）。
/// 对于本地只能拿到会话、拿不到 token 的工具（数据加密），允许 total == 0 的"仅会话"记录。
struct UsageRecord: Hashable, Codable {
    let provider: ProviderKind
    let sessionId: String
    let model: String
    let timestamp: Date
    let inputUncached: Int
    let cacheRead: Int
    let cacheWrite: Int
    let output: Int

    var total: Int { inputUncached + cacheRead + cacheWrite + output }

    func with(model: String) -> UsageRecord {
        UsageRecord(provider: provider, sessionId: sessionId, model: model, timestamp: timestamp,
                    inputUncached: inputUncached, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output)
    }
}

/// UI 上的"环境"。Codex Desktop/IDE 与 Codex CLI 共用数据源但分开展示。
enum ProviderKind: String, CaseIterable, Codable, Identifiable, Hashable {
    case codex, codexCLI, claudeCode, devin, cursor, windsurf, antigravity, qoder, trae, codebuddy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .codexCLI: return "Codex CLI"
        case .claudeCode: return "Claude Code"
        case .devin: return "Devin"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .antigravity: return "Antigravity"
        case .qoder: return "Qoder"
        case .trae: return "TRAE"
        case .codebuddy: return "CodeBuddy"
        }
    }

    var symbol: String {
        switch self {
        case .codex: return "circle.hexagongrid"
        case .codexCLI: return "terminal"
        case .claudeCode: return "sparkle"
        case .devin: return "brain"
        case .cursor: return "cursorarrow.rays"
        case .windsurf: return "wind"
        case .antigravity: return "arrow.up.circle"
        case .qoder: return "q.circle"
        case .trae: return "t.circle"
        case .codebuddy: return "person.2"
        }
    }

    var source: SourceKind {
        switch self {
        case .codex, .codexCLI: return .codex
        case .claudeCode: return .claudeCode
        case .devin: return .devin
        case .cursor: return .cursor
        case .windsurf: return .windsurf
        case .antigravity: return .antigravity
        case .qoder: return .qoder
        case .trae: return .trae
        case .codebuddy: return .codebuddy
        }
    }
}

/// 数据源在本地能提供的统计粒度
enum SourceCapability {
    /// 每次请求的 token 明细，可计费
    case tokens
    /// 本地会话数据加密或不含 token，只能统计会话数与活跃日期
    case sessionsOnly
    /// 本地无可读数据
    case unavailable

    var label: String {
        switch self {
        case .tokens: return "Token 明细 + 费用"
        case .sessionsOnly: return "仅会话数（本地数据不含 token）"
        case .unavailable: return "本地数据不可读"
        }
    }
}

/// 磁盘上的一个数据源，可在设置中配置路径与开关。
enum SourceKind: String, CaseIterable, Codable, Identifiable {
    case claudeCode, codex, devin, cursor, qoder, codebuddy, windsurf, antigravity, trae

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex（Desktop / IDE / CLI）"
        case .devin: return "Devin"
        case .cursor: return "Cursor"
        case .qoder: return "Qoder"
        case .codebuddy: return "CodeBuddy Code"
        case .windsurf: return "Windsurf"
        case .antigravity: return "Antigravity"
        case .trae: return "TRAE"
        }
    }

    var capability: SourceCapability {
        switch self {
        case .claudeCode, .codex, .devin, .cursor, .qoder, .codebuddy: return .tokens
        case .windsurf, .antigravity: return .sessionsOnly
        case .trae: return .unavailable
        }
    }

    var pathHint: String {
        switch self {
        case .claudeCode: return "包含 <project>/<session>.jsonl 的目录"
        case .codex: return "包含 rollout-*.jsonl 的目录（递归扫描）"
        case .devin: return "sessions.db 文件路径"
        case .cursor: return "Cursor 的 globalStorage/state.vscdb 文件路径"
        case .qoder: return "Qoder 的 SharedClientCache/cache/db/local.db 文件路径"
        case .codebuddy: return "包含 <project>/<session>.jsonl 的目录（与 Claude Code 同格式）"
        case .windsurf: return "cascade 会话目录（*.pb，本地加密，仅统计会话数）"
        case .antigravity: return "conversations 目录（*.pb，本地加密，仅统计会话数）"
        case .trae: return "TRAE 本地库为 SQLCipher 加密，暂无法读取"
        }
    }

    var defaultPaths: [String] {
        let home = NSHomeDirectory()
        let appSupport = "\(home)/Library/Application Support"
        switch self {
        case .claudeCode: return ["\(home)/.claude/projects", "\(home)/.config/claude/projects"]
        case .codex: return ["\(home)/.codex/sessions", "\(home)/.codex/archived_sessions"]
        case .devin: return ["\(home)/.local/share/devin/cli/sessions.db"]
        case .cursor: return ["\(appSupport)/Cursor/User/globalStorage/state.vscdb"]
        case .qoder: return ["\(appSupport)/Qoder/SharedClientCache/cache/db/local.db", "\(home)/.qoder/shared_client/cache/db/local.db"]
        case .codebuddy: return ["\(home)/.codebuddy/projects"]
        case .windsurf: return ["\(home)/.codeium/windsurf/cascade"]
        case .antigravity: return ["\(home)/.gemini/antigravity/conversations", "\(home)/.gemini/antigravity-ide/conversations"]
        case .trae: return ["\(appSupport)/Trae/ModularData/ai-agent", "\(appSupport)/Trae CN/ModularData/ai-agent"]
        }
    }

    /// 本机是否检测到该工具（任一默认路径存在）
    var isDetected: Bool {
        defaultPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    func makeProvider() -> UsageProvider {
        switch self {
        case .claudeCode: return ClaudeCodeProvider(kind: .claudeCode)
        case .codebuddy: return ClaudeCodeProvider(kind: .codebuddy)
        case .codex: return CodexProvider()
        case .devin: return DevinProvider()
        case .cursor: return CursorProvider()
        case .qoder: return QoderProvider()
        case .windsurf: return SessionFilesProvider(kind: .windsurf, fileExtension: "pb")
        case .antigravity: return SessionFilesProvider(kind: .antigravity, fileExtension: "pb")
        case .trae: return EmptyProvider()
        }
    }
}

struct SourceConfig: Codable, Equatable {
    var enabled: Bool = true
    var paths: [String]
}
