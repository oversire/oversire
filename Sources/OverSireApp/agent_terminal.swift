import OverSireCore

/// The terminal side of the agent runtime: open an agent terminal in a checkout, then show it.
protocol AgentTerminal {
    func openTerminal(path: String, title: String, command: String, prompt: String) async throws -> SessionRef
    func reveal(_ s: SessionRef) async throws
}
