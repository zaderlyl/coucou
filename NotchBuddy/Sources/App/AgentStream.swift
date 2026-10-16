import Foundation

/// Ce que fait l'agent, lu dans le flux `claude --output-format stream-json`.
enum AgentEvent: Sendable, Equatable {
    /// Fichier créé ou réécrit en entier avec `content`.
    case fileWritten(path: String, content: String)
    /// Fichier modifié : `old` est remplacé par `new` (partout si `replaceAll`).
    case fileEdited(path: String, old: String, new: String, replaceAll: Bool)
    /// Réponse finale de l'agent.
    case finished(text: String, isError: Bool)
}

/// Transforme le flux JSON (une ligne par message) en `AgentEvent`.
struct AgentStreamParser {
    /// Une ligne du flux : renvoie les événements qu'elle contient (vide si elle n'en a pas).
    static func events(fromLine line: String) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        switch json["type"] as? String {
        case "assistant":
            let blocks = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return blocks.compactMap(toolEvent)
        case "result":
            return [.finished(text: json["result"] as? String ?? "", isError: json["is_error"] as? Bool ?? false)]
        default:
            return []
        }
    }

    private static func toolEvent(_ block: [String: Any]) -> AgentEvent? {
        guard block["type"] as? String == "tool_use",
              let input = block["input"] as? [String: Any],
              let path = input["file_path"] as? String else { return nil }
        switch block["name"] as? String {
        case "Write":
            return .fileWritten(path: path, content: input["content"] as? String ?? "")
        case "Edit":
            return .fileEdited(path: path,
                               old: input["old_string"] as? String ?? "",
                               new: input["new_string"] as? String ?? "",
                               replaceAll: input["replace_all"] as? Bool ?? false)
        default:
            return nil
        }
    }
}
