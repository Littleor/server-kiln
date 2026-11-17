import Foundation
import XCTest
@testable import ServerKilnCore

/// Both desktop clients consume these same synthetic inputs and expected results.
final class CrossPlatformContractTests: XCTestCase {
    private struct Fixture: Decodable {
        var name: String
        var output: String
        var hostname: String
        var gpuCount: Int
        var busyCount: Int
        var cpuUsage: Double?
        var taskPids: [Int]
        var taskMemory: Double?
        var hasGpuError: Bool
    }

    func testSharedSnapshotContract() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("SharedFixtures/snapshots.json")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        XCTAssertFalse(fixtures.isEmpty)
        for fixture in fixtures {
            let snapshot = SnapshotParser.parse(fixture.output)
            XCTAssertEqual(snapshot.system.hostname, fixture.hostname, fixture.name)
            XCTAssertEqual(snapshot.gpus.count, fixture.gpuCount, fixture.name)
            XCTAssertEqual(BusyPolicy().busyCount(snapshot), fixture.busyCount, fixture.name)
            XCTAssertEqual(snapshot.tasks.map(\.pid), fixture.taskPids, fixture.name)
            XCTAssertEqual(snapshot.gpuError != nil, fixture.hasGpuError, fixture.name)
            if let cpu = fixture.cpuUsage {
                XCTAssertEqual(snapshot.system.cpuUsage ?? -1, cpu, accuracy: 0.0001, fixture.name)
            }
            if let memory = fixture.taskMemory {
                XCTAssertEqual(snapshot.tasks.first?.memoryMiB, memory, fixture.name)
            }
        }
    }
}
