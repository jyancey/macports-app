import Testing

@testable import PortsKit

@Suite struct DiagnoseLiveTests {
  @Test(.timeLimit(.minutes(1))) func diagnoseReturns() async throws {
    let client = PortClient()
    guard client.isAvailable else { return }
    _ = try await client.diagnoseFindings()
  }
}
