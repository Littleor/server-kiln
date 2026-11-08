import XCTest
@testable import ServerKilnCore

final class SnapshotParserTests: XCTestCase {
    let gpuOutput = """
    @@HOST
    gpu-node-1
    @@OS
    Ubuntu 22.04.4 LTS
    @@UPTIME
    356421.52
    @@NCPU
    64
    @@LOAD
    12.50 11.20 10.03 5/1234 99999
    @@CPU
    cpu  1000 0 1000 8000 0 0 0 0 0 0
    cpu  1600 0 1400 8800 200 0 0 0 0 0
    @@MEM
    MemTotal:       527952936 kB
    MemAvailable:   263976468 kB
    @@DISK
    /dev/nvme0n1p2  1921724676 960862338 863171876  53% /
    @@NET
    1000.5 2000000 500000
    @@GPU
    0, GPU-aaa, NVIDIA GeForce RTX 4090, 98, 22000, 24564, 71, 410.50, 450.00
    1, GPU-bbb, NVIDIA GeForce RTX 4090, 0, 3, 24564, 34, 20.12, 450.00
    @@APPS
    GPU-aaa, 4242, 21980
    @@PS
       4242 ming       7384 99.5 10485760 python train.py --config configs/llama.yaml
    @@TOP
       4242 ming       7384 99.5 10485760 python train.py --config configs/llama.yaml
    @@CWD
    4242 /home/ming/proj with space
    @@END
    """

    func testParsesSystem() {
        let s = SnapshotParser.parse(gpuOutput)
        XCTAssertEqual(s.system.hostname, "gpu-node-1")
        XCTAssertEqual(s.system.os, "Ubuntu 22.04.4 LTS")
        XCTAssertEqual(s.system.cpuCores, 64)
        XCTAssertEqual(s.system.load, [12.5, 11.2, 10.03])
        XCTAssertEqual(s.system.uptimeSeconds ?? 0, 356421.52, accuracy: 0.01)
        XCTAssertEqual(s.system.cpuUsage ?? 0, 0.5, accuracy: 0.001) // Δidle(+iowait)=1000 of Δtotal=2000
        XCTAssertEqual(s.system.memFraction ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(s.system.diskFraction ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(s.system.netRxBytes, 2_000_000)

        var next = s.system
        next.netSampleUptime = 1002.5
        next.netRxBytes = 2_000_000 + 2 * 1_048_576
        next.netTxBytes = 500_000 + 2048
        let r = next.withRates(previous: s.system)
        XCTAssertEqual(r.netRxRate ?? 0, 1_048_576, accuracy: 1)
        XCTAssertEqual(r.netTxRate ?? 0, 1024, accuracy: 1)
        XCTAssertEqual(Format.rate(r.netRxRate), "1.0M")
        XCTAssertEqual(Format.rate(r.netTxRate), "1K")

        // Counter reset keeps the previous rate instead of going negative.
        var reset = next
        reset.netSampleUptime = 1003.5
        reset.netRxBytes = 10
        XCTAssertEqual(reset.withRates(previous: r).netRxRate, r.netRxRate)
    }

    func testParsesGPUsAndTasks() {
        let s = SnapshotParser.parse(gpuOutput)
        XCTAssertTrue(s.isGPUServer)
        XCTAssertEqual(s.gpus.count, 2)
        XCTAssertEqual(s.gpus[0].name, "GeForce RTX 4090")
        XCTAssertEqual(s.gpus[0].utilization, 98)
        XCTAssertEqual(s.gpus[0].powerDraw, 410.5)
        XCTAssertEqual(s.tasks.count, 1)
        XCTAssertEqual(s.tasks[0].pid, 4242)
        XCTAssertEqual(s.tasks[0].user, "ming")
        XCTAssertEqual(s.tasks[0].elapsedSeconds, 7384)
        XCTAssertEqual(s.tasks[0].gpuIndices, [0])
        XCTAssertEqual(s.tasks[0].command, "python train.py --config configs/llama.yaml")
        XCTAssertEqual(s.tasks[0].cpuPercent, 99.5)
        XCTAssertEqual(s.tasks[0].rssKB, 10_485_760)
        XCTAssertEqual(s.tasks[0].cwd, "/home/ming/proj with space")

        let policy = BusyPolicy()
        XCTAssertEqual(policy.busyCount(s), 1)
    }

    func testCPUOnlyServer() {
        let out = """
        @@HOST
        cpu-box
        @@NOGPU
        @@TOP
            1 root 100 0.0 1000 /sbin/init
          200 alice 50 250.0 204800 /usr/bin/python3 preprocess.py
        @@END
        """
        let s = SnapshotParser.parse(out)
        XCTAssertFalse(s.hasNvidiaSMI)
        XCTAssertFalse(s.isGPUServer)
        XCTAssertEqual(s.tasks.map(\.pid), [200])
    }

    func testNvidiaSMIErrorAndNAValues() {
        let out = """
        @@HOST
        broken
        @@GPU
        NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.
        @@APPS
        @@PS
        @@END
        """
        let s = SnapshotParser.parse(out)
        XCTAssertTrue(s.hasNvidiaSMI)
        XCTAssertTrue(s.gpus.isEmpty)
        XCTAssertNotNil(s.gpuError)

        let na = SnapshotParser.parseGPU("0, GPU-x, NVIDIA A100-SXM4-80GB, 0, 1, 81920, 30, [N/A], [N/A]")
        XCTAssertEqual(na?.name, "A100-SXM4-80GB")
        XCTAssertNil(na?.powerDraw)
    }

    func testContainerFallbackWhenAppsHidden() {
        let out = """
        @@HOST
        container
        @@GPU
        0, GPU-a, NVIDIA GeForce RTX 5090, 100, 30000, 32607, 70, 500, 575
        @@APPS
        @@PS
        @@TOP
          321 root 4000 101.0 4096000 /root/miniconda3/bin/python -m torch.distributed.run train.py
          99 root 5000 2.0 8000 sshd: root@notty
        @@END
        """
        let s = SnapshotParser.parse(out)
        XCTAssertEqual(s.tasks.map(\.pid), [321])
        XCTAssertEqual(s.tasks[0].gpuIndices, [])
    }

    func testMultiGPUProcessMerged() {
        let out = """
        @@GPU
        0, GPU-a, A100, 90, 40000, 81920, 60, 300, 400
        1, GPU-b, A100, 90, 40000, 81920, 60, 300, 400
        @@APPS
        GPU-a, 10, 39000
        GPU-b, 10, 39000
        @@PS
           10 bob 60 180.0 2048000 torchrun --nproc 2 train.py
        @@END
        """
        let s = SnapshotParser.parse(out)
        XCTAssertEqual(s.tasks.count, 1)
        XCTAssertEqual(s.tasks[0].gpuIndices, [0, 1])
        XCTAssertEqual(s.tasks[0].memoryMiB, 78000)
    }
}

final class SSHConfigParserTests: XCTestCase {
    func testParse() {
        let text = """
        # comment
        Host 8x4090.local
          HostName 8x4090.local
          User ming
          Port 12346

        Host a b
          HostName shared.example.com
        Host *
          User nobody
        Host github.com
          User git
        Host=eq
          HostName=1.2.3.4
        """
        let hosts = SSHConfigParser.parse(text)
        XCTAssertEqual(hosts.map(\.alias), ["8x4090.local", "a", "b", "eq"])
        XCTAssertEqual(hosts[0].port, 12346)
        XCTAssertEqual(hosts[0].summary, "ming@8x4090.local:12346")
        XCTAssertEqual(hosts[2].hostName, "shared.example.com")
        XCTAssertEqual(hosts[3].hostName, "1.2.3.4")
    }
}

final class TransitionTrackerTests: XCTestCase {
    func testDebounce() {
        var t = TransitionTracker(requiredStreak: 2)
        let id = UUID()
        XCTAssertNil(t.observe(id, .busy))
        XCTAssertNil(t.observe(id, .idle))
        XCTAssertNil(t.observe(id, .busy)) // blip resets
        XCTAssertNil(t.observe(id, .idle))
        XCTAssertEqual(t.observe(id, .idle), ActivityTransition(serverID: id, from: .busy, to: .idle))
        XCTAssertNil(t.observe(id, .idle))
    }
}

final class FormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(Format.duration(30), "30s")
        XCTAssertEqual(Format.duration(3600 * 5 + 60 * 12), "5h 12m")
        XCTAssertEqual(Format.duration(86400 * 3 + 3600 * 4), "3d 4h")
        XCTAssertEqual(Format.mib(22000), "21.5G")
    }
}

final class HistoryStoreTests: XCTestCase {
    func testRecordQueryAndPrune() async {
        let path = NSTemporaryDirectory() + "serverkiln-test-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HistoryStore(path: path, minimumInterval: 60, retentionDays: 30)
        let id = UUID()
        var sys = SystemStat()
        sys.cpuUsage = 0.5
        func snap(_ u: Double) -> ServerSnapshot {
            ServerSnapshot(system: sys, hasNvidiaSMI: true, gpus: [
                GPUStat(index: 0, uuid: "a", name: "x", utilization: u, memoryUsedMiB: 50, memoryTotalMiB: 100),
                GPUStat(index: 1, uuid: "b", name: "x", utilization: 0, memoryUsedMiB: 0, memoryTotalMiB: 100),
            ], tasks: [])
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        await store.record(server: id, snapshot: snap(100), at: t0)
        await store.record(server: id, snapshot: snap(0), at: t0.addingTimeInterval(10)) // throttled
        await store.record(server: id, snapshot: snap(60), at: t0.addingTimeInterval(120))

        let agg = await store.query(server: id, since: t0.addingTimeInterval(-1), bucket: 60, perGPU: false)
        XCTAssertEqual(agg.count, 2)
        XCTAssertEqual(agg[0].utilization, 50) // mean of 100 and 0
        XCTAssertEqual(agg[0].memoryFraction ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(agg[0].cpu, 0.5)

        let per = await store.query(server: id, since: t0.addingTimeInterval(-1), bucket: 3600, perGPU: true)
        XCTAssertEqual(per.map(\.gpu), [0, 1])
        XCTAssertEqual(per[0].utilization, 80)

        await store.prune(now: t0.addingTimeInterval(31 * 86400))
        let after = await store.query(server: id, since: .distantPast, bucket: 60, perGPU: false)
        XCTAssertTrue(after.isEmpty)
    }
}

final class RemoteScriptTests: XCTestCase {
    /// The loop script must be valid POSIX sh and answer one snapshot per line.
    func testLoopScriptRunsLocallyUnderSh() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", RemoteScript.loop]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        inPipe.fileHandleForWriting.write(Data("\n\n".utf8))
        try inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(out.components(separatedBy: "@@END").count - 1, 2)
        XCTAssertTrue(out.contains("@@HOST"))
    }

    func testMonitoringToolsAreNotWorkloads() {
        XCTAssertTrue(SnapshotParser.isWorkload("/opt/conda/bin/python -u train.py --lr 1e-4"))
        XCTAssertTrue(SnapshotParser.isWorkload("torchrun --nproc_per_node 8 train.py"))
        XCTAssertFalse(SnapshotParser.isWorkload("/usr/bin/python3 /usr/local/bin/nvitop"))
        XCTAssertFalse(SnapshotParser.isWorkload("python -m gpustat -i 1"))
        XCTAssertFalse(SnapshotParser.isWorkload("/env/bin/python /env/bin/jupyter-lab --port 8888"))
        XCTAssertFalse(SnapshotParser.isWorkload("python -c from multiprocessing.resource_tracker import main;main(5)"))
        XCTAssertFalse(SnapshotParser.isWorkload("/usr/bin/python3 -m ipykernel_launcher -f kernel.json"))
    }

    func testHostPIDsFallBackToVisibleWorkload() {
        let out = """
        @@HOST
        c
        @@GPU
        0, GPU-a, NVIDIA A100, 5, 65361, 81920, 40, 90, 400
        @@APPS
        GPU-a, 439282, 65354
        @@PS

        @@TOP
         563766 ma-user 3000 203.0 5344876 /env/bin/python train.py --cfg a.yaml
              1 ma-user 9000 1.0 50776 /home/ma-user/modelarts/ma-training-toolkit bootstrap run
        @@END
        """
        let s = SnapshotParser.parse(out)
        XCTAssertEqual(s.tasks.map(\.pid), [563766])
        XCTAssertEqual(s.tasks.first?.gpuIndices, [0])
        XCTAssertEqual(s.tasks.first?.memoryMiB, 65354)
    }
}
