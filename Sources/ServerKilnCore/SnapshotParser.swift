import Foundation

/// Parses the output of `RemoteScript` into a `ServerSnapshot`.
public enum SnapshotParser {
    /// Process names that typically indicate a training / evaluation job.
    static let workloadKeywords = [
        "python", "torchrun", "deepspeed", "accelerate", "vllm", "sglang",
        "llamafactory", "swift", "megatron", "colossalai", "horovodrun", "mpirun", "jupyter",
    ]

    public static func parse(_ output: String, now: Date = Date()) -> ServerSnapshot {
        let sections = splitSections(output)
        var sys = SystemStat()

        sys.hostname = sections["HOST"]?.first?.trimmed ?? ""
        sys.os = sections["OS"]?.first?.trimmed ?? ""
        sys.uptimeSeconds = sections["UPTIME"]?.first.flatMap { Double($0.trimmed) }
        sys.cpuCores = sections["NCPU"]?.first.flatMap { Int($0.trimmed) }
        if let load = sections["LOAD"]?.first {
            sys.load = load.split(separator: " ").prefix(3).compactMap { Double($0) }
        }
        if let cpu = sections["CPU"] { sys.cpuUsage = parseCPU(cpu) }
        for line in sections["MEM"] ?? [] {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == ":" })
            guard parts.count >= 2, let v = Double(parts[1]) else { continue }
            if parts[0] == "MemTotal" { sys.memTotalKB = v }
            if parts[0] == "MemAvailable" { sys.memAvailableKB = v }
        }
        if let disk = sections["DISK"]?.first {
            let p = disk.split(separator: " ", omittingEmptySubsequences: true)
            if p.count >= 3 {
                sys.diskTotalKB = Double(p[1])
                sys.diskUsedKB = Double(p[2])
            }
        }

        // One line normally; two on a session's first request (start, end).
        let netSamples = (sections["NET"] ?? []).map { $0.split(separator: " ").compactMap { Double($0) } }.filter { $0.count == 3 }
        if let last = netSamples.last {
            sys.netSampleUptime = last[0]
            sys.netRxBytes = last[1]
            sys.netTxBytes = last[2]
            if netSamples.count >= 2 {
                var first = SystemStat()
                first.netSampleUptime = netSamples[0][0]
                first.netRxBytes = netSamples[0][1]
                first.netTxBytes = netSamples[0][2]
                sys = sys.withRates(previous: first)
            }
        }

        let hasSMI = sections["GPU"] != nil
        var gpus: [GPUStat] = []
        var gpuError: String?
        for line in sections["GPU"] ?? [] where !line.trimmed.isEmpty {
            if let gpu = parseGPU(line) {
                gpus.append(gpu)
            } else if gpuError == nil {
                gpuError = line.trimmed
            }
        }

        var cwd: [Int: String] = [:]
        for line in sections["CWD"] ?? [] {
            let p = line.split(separator: " ", maxSplits: 1).map(String.init)
            if p.count == 2, let pid = Int(p[0]) { cwd[pid] = p[1] }
        }
        let ps = parsePS(sections["PS"] ?? [])
        var tasks: [GPUTask] = []
        var byPID: [Int: GPUTask] = [:]
        let indexByUUID = Dictionary(gpus.map { ($0.uuid, $0.index) }, uniquingKeysWith: { a, _ in a })
        for line in sections["APPS"] ?? [] {
            let f = line.split(separator: ",").map { String($0).trimmed }
            guard f.count >= 3, let pid = Int(f[1]) else { continue }
            let mem = Double(f[2])
            let gpuIdx = indexByUUID[f[0]]
            if var t = byPID[pid] {
                if let g = gpuIdx, !t.gpuIndices.contains(g) { t.gpuIndices.append(g) }
                t.memoryMiB = (t.memoryMiB ?? 0) + (mem ?? 0)
                byPID[pid] = t
            } else {
                let info = ps[pid]
                byPID[pid] = GPUTask(
                    pid: pid,
                    user: info?.user ?? "?",
                    elapsedSeconds: info?.elapsedSeconds,
                    command: info?.command ?? String(appLocalized: "(进程不可见)"),
                    gpuIndices: gpuIdx.map { [$0] } ?? [],
                    memoryMiB: mem,
                    cpuPercent: info?.cpuPercent,
                    rssKB: info?.rssKB,
                    cwd: cwd[pid]
                )
            }
        }
        tasks = byPID.values.sorted { ($0.gpuIndices.first ?? .max, $0.pid) < ($1.gpuIndices.first ?? .max, $1.pid) }

        // Containers often hide GPU processes from nvidia-smi (or report host
        // PIDs we can't see). Fall back to the top CPU consumers that look
        // like ML workloads, keeping the GPU memory nvidia-smi attributed.
        let invisible = !tasks.isEmpty && tasks.allSatisfy { $0.command == String(appLocalized: "(进程不可见)") }
        if tasks.isEmpty || invisible {
            let gpuMem = invisible ? tasks.compactMap(\.memoryMiB).reduce(0, +) : nil
            let gpuIdx = invisible ? Array(Set(tasks.flatMap(\.gpuIndices))).sorted() : []
            let top = parsePS(sections["TOP"] ?? []).values
            tasks = top
                .filter { isWorkload($0.command) && ($0.cpuPercent ?? 0) >= 1 }
                .sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
                .prefix(8)
                .map { t in
                    var t = t
                    t.cwd = cwd[t.pid]
                    return t
                }
            if invisible {
                if tasks.isEmpty {
                    // Nothing recognisable: keep the "invisible" GPU entries.
                    tasks = byPID.values.sorted { $0.pid < $1.pid }
                } else if let gpuMem {
                    // Attribute the GPUs to the busiest workload.
                    tasks[0].gpuIndices = gpuIdx
                    tasks[0].memoryMiB = gpuMem
                }
            }
        }

        // Top CPU and memory users, without our own collector / ssh noise.
        let candidates = parsePS((sections["TOP"] ?? []) + (sections["TOPMEM"] ?? []) + (sections["PS"] ?? []))
            .values.filter { !isCollectorNoise($0.command) }
        let byCPU = candidates.sorted { ($0.cpuPercent ?? 0, -$0.pid) > ($1.cpuPercent ?? 0, -$1.pid) }
        let byMem = candidates.sorted { ($0.rssKB ?? 0, -$0.pid) > ($1.rssKB ?? 0, -$1.pid) }
        var seen: Set<Int> = []
        let processes = (byCPU.prefix(6) + byMem.prefix(6))
            .filter { seen.insert($0.pid).inserted }
            .map { p -> GPUTask in
                var p = p
                p.cwd = cwd[p.pid]
                return p
            }

        return ServerSnapshot(system: sys, hasNvidiaSMI: hasSMI, gpus: gpus, gpuError: gpus.isEmpty ? gpuError : nil, tasks: tasks,
                              fetchedAt: now, processes: processes)
    }

    // MARK: - Helpers

    static func splitSections(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).replacingOccurrences(of: "\r", with: "")
            if line.hasPrefix("@@") {
                current = String(line.dropFirst(2)).trimmed
                result[current!, default: []] = result[current!] ?? []
            } else if let c = current, !line.isEmpty {
                result[c, default: []].append(line)
            }
        }
        return result
    }

    static func parseCPU(_ lines: [String]) -> Double? {
        func fields(_ s: String) -> [Double] {
            s.split(separator: " ").dropFirst().compactMap { Double($0) }
        }
        guard lines.count >= 2 else { return nil }
        let a = fields(lines[0]), b = fields(lines[1])
        guard a.count >= 4, b.count >= 4 else { return nil }
        // idle + iowait
        let idleA = a[3] + (a.count > 4 ? a[4] : 0)
        let idleB = b[3] + (b.count > 4 ? b[4] : 0)
        let totalA = a.prefix(8).reduce(0, +), totalB = b.prefix(8).reduce(0, +)
        let dt = totalB - totalA
        guard dt > 0 else { return nil }
        return min(1, max(0, 1 - (idleB - idleA) / dt))
    }

    static func parseGPU(_ line: String) -> GPUStat? {
        let f = line.split(separator: ",").map { String($0).trimmed }
        guard f.count >= 6, let idx = Int(f[0]) else { return nil }
        func num(_ i: Int) -> Double? { i < f.count ? Double(f[i]) : nil }
        return GPUStat(
            index: idx,
            uuid: f[1],
            name: f[2].replacingOccurrences(of: "NVIDIA ", with: ""),
            utilization: num(3) ?? 0,
            memoryUsedMiB: num(4) ?? 0,
            memoryTotalMiB: num(5) ?? 0,
            temperature: num(6),
            powerDraw: num(7),
            powerLimit: num(8)
        )
    }

    /// Parses `ps -o pid=,user=,etimes=,pcpu=,rss=,args=` output.
    static func parsePS(_ lines: [String]) -> [Int: GPUTask] {
        var out: [Int: GPUTask] = [:]
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 6, let pid = Int(parts[0]) else { continue }
            out[pid] = GPUTask(
                pid: pid,
                user: parts[1],
                elapsedSeconds: Int(parts[2]),
                command: parts[5],
                cpuPercent: Double(parts[3]),
                rssKB: Double(parts[4])
            )
        }
        return out
    }

    /// Monitoring, notebook and editor helpers that are Python (or run under
    /// it) but never the user's training job.
    /// Matched against the program and script names (basename of each
    /// argument), never against directories like `/root/miniconda3/…`.
    static let toolKeywords = [
        "nvitop", "gpustat", "nvtop", "nvidia-smi", "glances", "htop", "btop", "py-spy", "tensorboard",
        "jupyter", "ipykernel", "ipython", "kernelgateway", "debugpy", "pip", "pip3", "conda", "mamba",
        "wandb-service", "wandb_service", "supervisord", "multiprocessing.resource_tracker",
    ]

    /// Our own `ps`/collector shell and the ssh session carrying it.
    static func isCollectorNoise(_ command: String) -> Bool {
        let exe = command.split(separator: " ").first.map { String($0.split(separator: "/").last ?? "") } ?? ""
        return exe == "ps" || exe.hasPrefix("sshd") || command.contains("serverkiln/collect.sh")
            || command.hasPrefix("sh -c eval") || command.contains("base64 -d")
    }

    public static func isWorkload(_ command: String) -> Bool {
        let exe = command.split(separator: " ").first.map { String($0.split(separator: "/").last ?? "") }?.lowercased() ?? ""
        if exe.hasPrefix("ps") || exe.hasPrefix("sshd") { return false }
        guard workloadKeywords.contains(where: { exe.hasPrefix($0) }) else { return false }
        // `python …/bin/nvitop`, `python -m gpustat`, jupyter kernels, …
        let words = command.lowercased().split(separator: " ").prefix(6).map { word -> String in
            let base = String(word.split(separator: "/").last ?? word)
            return base.hasSuffix(".py") ? String(base.dropLast(3)) : base
        }
        return !words.dropFirst().contains { w in toolKeywords.contains { w == $0 || w.hasPrefix($0 + "-") || w.hasPrefix($0 + "_") } }
            && !command.contains("resource_tracker import")
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
