import Foundation

/// Choisit l'IA qui traite une demande, par mots-clés. Le premier groupe qui correspond gagne,
/// sinon Claude. Les règles sont ici en dur pour l'instant.
enum AgentRouter {
    private static let rules: [(provider: AgentProvider, keywords: [String])] = [
        (.gemini, ["diagramme", "schéma", "schema", "mermaid", "architecture", "cartographie", "vue d'ensemble"]),
        (.codex, ["test", "bug", "refactor", "revue", "review", "corrige", "optimise"])
    ]

    static func provider(for prompt: String) -> AgentProvider {
        let text = prompt.lowercased()
        for rule in rules where rule.keywords.contains(where: { text.contains($0) }) {
            return rule.provider
        }
        return .claude
    }
}
