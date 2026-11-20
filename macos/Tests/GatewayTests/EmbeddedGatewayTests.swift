import Foundation
import XCTest
@testable import Gateway

final class EmbeddedGatewayTests: XCTestCase {
    func testCatalogOnlyShowsAvailableModelsWithTools() throws {
        let fixture = #"""
        {"data":[
          {"id":"auto","name":"Auto","available":true},
          {"id":"z","name":"Z model","available":true,"supported_parameters":["tools"]},
          {"id":"z","name":"Duplicate","available":true,"supported_parameters":["tools"]},
          {"id":"offline","name":"Unavailable","available":false,"supported_parameters":["tools"]},
          {"id":"a","name":"A model","available":true,"supported_parameters":["temperature","tools"]},
          {"id":"chat","name":"Chat","available":true,"supported_parameters":["temperature"]}
        ]}
        """#
        XCTAssertEqual(try GatewayModel.ready(from: Data(fixture.utf8)).map(\.id), ["a", "z"])
    }

    private func makeResources(nodeScript: String) throws -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gateway-test-\(UUID().uuidString)")
        let resources = base.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let node = resources.appendingPathComponent("node")
        try nodeScript.write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
        for name in ["gateway-entry.mjs", "server.mjs"] {
            try "".write(to: resources.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return (base, resources)
    }

    func testCancellationInterruptsHandshakeAndAllowsRestart() async throws {
        let (base, resources) = try makeResources(nodeScript: "#!/bin/sh\nread ignored\n")
        defer { try? FileManager.default.removeItem(at: base) }
        let gateway = EmbeddedGateway(resourcesDirectory: resources, dataDirectory: base.appendingPathComponent("data"))
        let startup = Task { try await gateway.start() }
        try await Task.sleep(nanoseconds: 150_000_000)
        startup.cancel()
        let finished = expectation(description: "cancelled startup returns promptly")
        Task {
            do {
                _ = try await startup.value
                XCTFail("Expected cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)

        let script = "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"ready\",\"port\":12345,\"token\":\"test\"}'\nread ignored\n"
        try script.write(to: resources.appendingPathComponent("node"), atomically: false, encoding: .utf8)
        let connection = try await gateway.start()
        XCTAssertEqual(connection.endpoint.port, 12345)
        XCTAssertEqual(connection.apiKey, "test")
        await gateway.stop()
    }

    func testConcurrentCallersShareHandshake() async throws {
        let script = "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"ready\",\"port\":12345,\"token\":\"test\"}'\nread ignored\n"
        let (base, resources) = try makeResources(nodeScript: script)
        defer { try? FileManager.default.removeItem(at: base) }
        let gateway = EmbeddedGateway(resourcesDirectory: resources, dataDirectory: base.appendingPathComponent("data"))
        async let first = gateway.start()
        async let second = gateway.start()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.endpoint, b.endpoint)
        XCTAssertEqual(a.apiKey, b.apiKey)
        await gateway.stop()
    }

    func testCancellingOneWaiterDoesNotStopOthers() async throws {
        let script = """
        #!/bin/sh
        while [ ! -f "$2/allow-ready" ]; do /bin/sleep 0.02; done
        printf '%s\\n' '{"type":"ready","port":12345,"token":"test"}'
        read ignored

        """
        let (base, resources) = try makeResources(nodeScript: script)
        defer { try? FileManager.default.removeItem(at: base) }
        let data = base.appendingPathComponent("data")
        let gateway = EmbeddedGateway(resourcesDirectory: resources, dataDirectory: data)
        let first = Task { try await gateway.start() }
        let second = Task { try await gateway.start() }
        try await Task.sleep(nanoseconds: 150_000_000)
        first.cancel()
        let cancelled = expectation(description: "first waiter cancels before gateway is ready")
        Task {
            do { _ = try await first.value; XCTFail("Expected cancellation") }
            catch is CancellationError {}
            catch { XCTFail("Unexpected error: \(error)") }
            cancelled.fulfill()
        }
        await fulfillment(of: [cancelled], timeout: 2)
        try "".write(to: data.appendingPathComponent("allow-ready"), atomically: true, encoding: .utf8)
        let result = try await second.value
        XCTAssertEqual(result.endpoint.port, 12345)
        await gateway.stop()
    }

    func testStopInterruptsAllWaitingCallers() async throws {
        let (base, resources) = try makeResources(nodeScript: "#!/bin/sh\nread ignored\n")
        defer { try? FileManager.default.removeItem(at: base) }
        let gateway = EmbeddedGateway(resourcesDirectory: resources, dataDirectory: base.appendingPathComponent("data"))
        let first = Task { try await gateway.start() }
        let second = Task { try await gateway.start() }
        try await Task.sleep(nanoseconds: 150_000_000)
        await gateway.stop()
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError {}
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testAnotherGatewayUsingSameDataDirectoryFailsWithoutWaiting() async throws {
        let (base, resources) = try makeResources(nodeScript: "#!/bin/sh\nread ignored\n")
        defer { try? FileManager.default.removeItem(at: base) }
        let data = base.appendingPathComponent("data")
        let firstGateway = EmbeddedGateway(resourcesDirectory: resources, dataDirectory: data)
        let secondGateway = EmbeddedGateway(resourcesDirectory: resources, dataDirectory: data)
        let first = Task { try await firstGateway.start() }
        try await Task.sleep(nanoseconds: 150_000_000)
        do {
            _ = try await secondGateway.start()
            XCTFail("Expected an immediate conflict")
        } catch GatewayError.alreadyRunning {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await firstGateway.stop()
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
    }
}
