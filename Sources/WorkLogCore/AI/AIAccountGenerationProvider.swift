/// Optional account binding for queued AI work. Reading the generation must not read credentials.
public protocol AIAccountGenerationProvider: AIProvider {
    func accountGeneration() async -> Int
    /// Enforce the submitted generation when obtaining credentials, across every suspension.
    func run(_ input: AIJobInput, expectedAccountGeneration: Int) async throws -> AIJobOutput
}
