import Foundation

/// A file change made by the CLI agent, with what is needed to undo it.
struct AgentChange: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// File created or rewritten; `previous` is its content before (nil: it did not exist).
        case write(previous: String?)
        case edit(old: String, new: String, replaceAll: Bool)
    }

    enum UndoError: Error, LocalizedError {
        case notFound
        case ambiguous
        var errorDescription: String? {
            switch self {
            case .notFound: return "Impossible d'annuler : le fichier a changé depuis."
            case .ambiguous: return "Impossible d'annuler : le passage modifié apparaît plusieurs fois."
            }
        }
    }

    let id = UUID()
    var diff: FileDiff
    var kind: Kind
    var undone = false

    /// Builds the change for a file event. Call it as soon as the event arrives, before the agent's
    /// tool runs, so that the previous content of a rewritten file can still be read.
    static func from(_ event: AgentEvent) -> AgentChange? {
        switch event {
        case .fileWritten(let path, let content):
            let previous = try? String(contentsOfFile: path, encoding: .utf8)
            return AgentChange(diff: previous.map { DiffEngine.fromEdit(old: $0, new: content, path: path) }
                                   ?? DiffEngine.fromNew(content: content, path: path),
                               kind: .write(previous: previous))
        case .fileEdited(let path, let old, let new, let replaceAll):
            return AgentChange(diff: DiffEngine.fromEdit(old: old, new: new, path: path),
                               kind: .edit(old: old, new: new, replaceAll: replaceAll))
        case .finished:
            return nil
        }
    }

    /// Puts the file back as it was. A new file goes to the Trash.
    func undo() throws {
        let url = URL(fileURLWithPath: diff.path)
        switch kind {
        case .write(let previous):
            if let previous {
                try previous.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        case .edit(let old, let new, let replaceAll):
            guard !new.isEmpty, let text = try? String(contentsOf: url, encoding: .utf8) else { throw UndoError.notFound }
            let count = text.components(separatedBy: new).count - 1
            guard count > 0 else { throw UndoError.notFound }
            guard replaceAll || count == 1 else { throw UndoError.ambiguous }
            try text.replacingOccurrences(of: new, with: old).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
