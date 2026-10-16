import Foundation

/// Branche le lanceur d'agent sur le chat de l'île, sans toucher à ses vues :
/// `/agent <demande>` choisit l'IA (claude, gemini ou codex) selon la demande et la lance en lecture seule ;
/// `/claude`, `/gemini` et `/codex <demande>` en imposent une. `/agent! <demande>` lance Claude avec le droit
/// d'écrire et d'éditer des fichiers (jamais de shell) dans le projet choisi ; jamais activé par défaut. `/stop` annule,
/// `/projet` liste les projets (ceux ouverts dans VS Code d'abord) et `/projet <n° ou nom>` en choisit un.
/// Le projet choisi est gardé dans la clé `agentProjectPath`.
@MainActor
enum AgentChat {
    static let command = "/agent "
    static let writeCommand = "/agent! "
    static let stopCommand = "/stop"
    static let projectCommand = "/projet"
    static let endCommand = "/fin"
    /// Conversation Claude en cours : tant qu'elle existe, les messages sans « / » lui sont envoyés.
    private static var conversationID: UUID?
    /// La conversation en cours a été ouverte avec `/agent!` : ses suites gardent le droit d'écrire.
    private static var conversationWritable = false
    private static let projectKey = "agentProjectPath"
    private static let githubRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/GitHub")
    private static let launcher = AgentLauncher()

    /// `/claude`, `/gemini`, `/codex` : choisit l'IA sans passer par le routeur.
    private static func forcedProvider(_ query: String) -> (AgentProvider, String)? {
        for provider in AgentProvider.allCases {
            let prefix = "/\(provider.rawValue) "
            if query.hasPrefix(prefix) { return (provider, String(query.dropFirst(prefix.count))) }
        }
        return nil
    }

    static func handles(_ query: String) -> Bool {
        (conversationID != nil && !query.hasPrefix("/"))
            || query == endCommand
            || forcedProvider(query) != nil
            || query.hasPrefix(command) || query.hasPrefix(writeCommand) || query == stopCommand
            || query == projectCommand || query.hasPrefix(projectCommand + " ")
    }

    /// Dossiers ouverts dans VS Code (le premier est la fenêtre active), puis les autres projets de ~/Documents/GitHub.
    static func availableProjects() -> [URL] {
        var result: [URL] = []
        func add(_ url: URL) {
            let u = url.standardizedFileURL
            if !result.contains(u) { result.append(u) }
        }
        let storage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/globalStorage/storage.json")
        if let data = try? Data(contentsOf: storage),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let windows = json["windowsState"] as? [String: Any] {
            var entries: [[String: Any]] = []
            if let last = windows["lastActiveWindow"] as? [String: Any] { entries.append(last) }
            entries += (windows["openedWindows"] as? [[String: Any]]) ?? []
            for entry in entries {
                if let folder = entry["folder"] as? String, let url = URL(string: folder), url.isFileURL {
                    add(url)
                }
            }
        }
        let others = (try? FileManager.default.contentsOfDirectory(
            at: githubRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for url in others.sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }) {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               !url.lastPathComponent.hasSuffix(".glb") {
                add(url)
            }
        }
        return result
    }

    static var projectURL: URL {
        if let path = UserDefaults.standard.string(forKey: projectKey), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return githubRoot
    }

    static func handle(_ query: String, state: AppState) async {
        if query == stopCommand {
            launcher.cancel()
            return
        }
        if query == endCommand {
            conversationID = nil
            conversationWritable = false
            reply("Conversation avec l'agent terminée.", state: state)
            return
        }
        if query == projectCommand || query.hasPrefix(projectCommand + " ") {
            conversationID = nil
            conversationWritable = false
            chooseProject(String(query.dropFirst(projectCommand.count)).trimmingCharacters(in: .whitespaces), state: state)
            return
        }
        let continuing = conversationID != nil && !query.hasPrefix("/")
        let writeRequested = !continuing && query.hasPrefix(writeCommand)
        let writable = continuing ? conversationWritable : writeRequested
        // `/agent!` impose Claude, seul capable d'écrire ici.
        let forced = continuing ? nil : (writeRequested ? (AgentProvider.claude, String(query.dropFirst(writeCommand.count))) : forcedProvider(query))
        let prompt = (continuing ? query : (forced?.1 ?? String(query.dropFirst(command.count))))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            reply("Usage : /agent <demande> (ou /claude, /gemini, /codex ; /agent! pour autoriser l'écriture). Dossier : \(projectURL.path)", state: state)
            return
        }
        let provider = continuing ? .claude : (forced?.0 ?? AgentRouter.provider(for: prompt))
        // Seul Claude garde le fil : une nouvelle demande ouvre une nouvelle session, la suite la reprend.
        let session: AgentProvider.Session?
        if continuing, let id = conversationID {
            session = .resume(id)
        } else if provider == .claude {
            session = .start(UUID())
        } else {
            session = nil
        }
        if !continuing { conversationID = nil; conversationWritable = false }
        state.stateOverride = .thinking
        state.agentChanges = []
        do {
            let answer = try await launcher.run(prompt: prompt, provider: provider, session: session, writable: writable,
                                                onEvent: { event in
                                                    guard let change = AgentChange.from(event) else { return }
                                                    Task { @MainActor in show(change, state: state) }
                                                },
                                                in: projectURL)
            finish(answer, provider: provider, session: session, writable: writable, state: state)
        } catch AgentLauncher.LaunchError.cancelled {
            reply("Agent annulé.", state: state)
        } catch {
            // Repli sur Claude seulement si le routeur a choisi gemini/codex : une IA imposée par l'utilisateur n'est pas remplacée.
            guard !continuing, forced == nil, provider != .claude else {
                reply(error.localizedDescription, state: state)
                return
            }
            let id = UUID()
            do {
                let answer = try await launcher.run(prompt: prompt, provider: .claude, session: .start(id), writable: false, in: projectURL)
                finish(answer, provider: .claude, session: .start(id), note: "\(provider.rawValue) indisponible → ", state: state)
            } catch AgentLauncher.LaunchError.cancelled {
                reply("Agent annulé.", state: state)
            } catch let fallbackError {
                reply("\(error.localizedDescription)\n\nRepli sur claude échoué : \(fallbackError.localizedDescription)", state: state)
            }
        }
    }

    /// Ajoute le fichier que l'agent vient de modifier à la fenêtre et l'ouvre.
    private static func show(_ change: AgentChange, state: AppState) {
        state.agentChanges.append(change)
        state.agentSelected = change.id
        AgentFileWindow.shared.show(state: state)
    }

    private static func finish(_ answer: String, provider: AgentProvider, session: AgentProvider.Session?,
                               writable: Bool = false, note: String = "", state: AppState) {
        var text = "[\(note)\(provider.rawValue)] " + (answer.isEmpty ? "(réponse vide)" : answer)
        if case .start(let id)? = session {
            conversationID = id
            conversationWritable = writable
            text += "\n\n(Réponds directement pour continuer, /fin pour terminer.)"
        }
        reply(text, state: state)
    }

    private static func chooseProject(_ argument: String, state: AppState) {
        let projects = availableProjects()
        if argument.isEmpty {
            let lines = projects.prefix(30).enumerated().map { "\($0.offset + 1). \($0.element.lastPathComponent)" }
            reply("Projet actuel : \(projectURL.lastPathComponent)\n" + lines.joined(separator: "\n")
                  + "\nChoisis avec /projet <n° ou nom>.", state: state)
            return
        }
        let match: URL?
        if let index = Int(argument), projects.indices.contains(index - 1) {
            match = projects[index - 1]
        } else {
            let wanted = argument.lowercased()
            match = projects.first { $0.lastPathComponent.lowercased() == wanted }
                ?? projects.first { $0.lastPathComponent.lowercased().contains(wanted) }
        }
        guard let chosen = match else {
            reply("Projet introuvable : \(argument). Tape /projet pour la liste.", state: state)
            return
        }
        UserDefaults.standard.set(chosen.path, forKey: projectKey)
        reply("Projet choisi : \(chosen.lastPathComponent)", state: state)
    }

    private static func reply(_ text: String, state: AppState) {
        state.chatHistory.append(ChatMessage(role: .assistant, content: text))
        state.stateOverride = nil
        state.view = .prompt
    }
}
