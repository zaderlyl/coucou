import Foundation

/// Les IA en ligne de commande que Coucou sait lancer, chacune en lecture seule.
enum AgentProvider: String, CaseIterable, Sendable {
    case claude, gemini, codex

    var binary: String { rawValue }

    /// Conversation de Claude : `start` ouvre une session au `id` donné, `resume` la reprend.
    enum Session: Sendable {
        case start(UUID)
        case resume(UUID)
    }

    /// Arguments pour répondre à `prompt`. Sans `writable`, rien n'est modifié dans le projet ;
    /// avec, Claude peut aussi écrire et éditer des fichiers (jamais de shell).
    func arguments(prompt: String, session: Session? = nil, writable: Bool = false) -> [String] {
        switch self {
        case .claude:
            var args = ["-p", prompt, "--model", "sonnet"]
            args += writable ? ["--tools=Read,Grep,Glob,Write,Edit", "--permission-mode", "acceptEdits"]
                             : ["--tools=Read,Grep,Glob"]
            switch session {
            case .start(let id): args += ["--session-id", id.uuidString]
            case .resume(let id): args += ["--resume", id.uuidString]
            case nil: break
            }
            return args
        case .gemini: return ["-p", prompt]
        case .codex: return ["exec", "--sandbox", "read-only", prompt]
        }
    }
}

/// Lance une IA en ligne de commande (claude, gemini, codex) dans un dossier de projet,
/// en lecture seule, et renvoie sa réponse. Aucune interface : utilisé par le chat de l'île.
final class AgentLauncher: @unchecked Sendable {
    enum LaunchError: Error, LocalizedError {
        case notFound(AgentProvider)
        case failed(code: Int32, output: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notFound(let provider): return "Commande `\(provider.binary)` introuvable."
            case .failed(let code, let output): return "L'agent a échoué (code \(code)) : \(output)"
            case .cancelled: return "Annulé."
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var wasCancelled = false

    /// Une app lancée depuis le Finder n'a pas le PATH du terminal : on cherche aux emplacements usuels.
    static func executableURL(for provider: AgentProvider) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let name = provider.binary
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)"
        ]
        if provider == .claude { candidates.append("\(home)/.claude/local/claude") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Exécute la demande dans `directory`, en lecture seule sauf si `writable` (Claude uniquement).
    func run(prompt: String, provider: AgentProvider = .claude, session: AgentProvider.Session? = nil, writable: Bool = false, in directory: URL) async throws -> String {
        guard let executable = Self.executableURL(for: provider) else { throw LaunchError.notFound(provider) }

        let task = Process()
        task.executableURL = executable
        task.arguments = provider.arguments(prompt: prompt, session: session, writable: writable)
        task.currentDirectoryURL = directory
        // Lancée hors terminal, l'appli n'a pas de TERM : on évite l'avertissement « 256-color » de gemini.
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["NO_COLOR"] = "1"
        task.environment = environment
        let out = Pipe()
        task.standardOutput = out
        task.standardError = out

        lock.withLock {
            process = task
            wasCancelled = false
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Lecture en continu pour ne pas bloquer le processus si la sortie est longue.
            let reader = Task.detached { () -> Data in
                (try? out.fileHandleForReading.readToEnd()) ?? Data()
            }
            task.terminationHandler = { [weak self] finished in
                Task {
                    let data = await reader.value
                    let text = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let cancelled = self?.consumeCancelled() ?? false
                    if cancelled {
                        continuation.resume(throwing: LaunchError.cancelled)
                    } else if finished.terminationStatus == 0 {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: LaunchError.failed(code: finished.terminationStatus, output: String(text.suffix(600))))
                    }
                }
            }
            do {
                try task.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        let task = lock.withLock { () -> Process? in
            wasCancelled = true
            return process
        }
        task?.terminate()
    }

    private func consumeCancelled() -> Bool {
        lock.withLock { wasCancelled }
    }
}
