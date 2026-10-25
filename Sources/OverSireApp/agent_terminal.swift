import OverSireCore

/// The terminal side of the agent runtime: open an agent terminal in a checkout, then show it.
protocol AgentTerminal {
    /// `launch` holds the resolved command.
    func openTerminal(path: String, title: String, launch: AgentLaunch, prompt: String) async throws -> SessionRef
    /// Shows the session in the runtime UI. A runtime on another machine does nothing.
    func show(_ s: SessionRef) async throws
}
