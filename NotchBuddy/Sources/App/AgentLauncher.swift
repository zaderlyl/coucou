import Foundation

/// Les IA en ligne de commande que Coucou sait lancer, chacune en lecture seule.
enum AgentProvider: String, CaseIterable, Sendable {
    case claude, gemini, codex

    var binary: String { rawValue }

    /// Arguments pour répondre à `prompt` sans rien modifier dans le projet.
    func arguments(prompt: String) -> [String] {
        switch self {
        case .claude: return ["-p", prompt, "--permission-mode", "plan"]
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

    /// Exécute la demande dans `directory`, en lecture seule.
    func run(prompt: String, provider: AgentProvider = .claude, in directory: URL) async throws -> String {
        guard let executable = Self.executableURL(for: provider) else { throw LaunchError.notFound(provider) }

        let task = Process()
        task.executableURL = executable
        task.arguments = provider.arguments(prompt: prompt)
        task.currentDirectoryURL = directory
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
                        continuation.resume(throwing: LaunchError.failed(code: finished.terminationStatus, output: text))
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
