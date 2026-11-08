import Foundation
import ServerKilnCore

/// The sample fleet behind screenshots, the website and the in-app demo
/// (Mac `--snapshot`, iOS `-demo` / 「查看演示」, widget gallery). One place so
/// every surface tells the same story: a busy lab with a mix of top cards.
public enum DemoFleet {
    public struct Machine: Sendable {
        public var name: String
        public var host: String
        public var snapshot: ServerSnapshot?
        public var error: String?
        /// Seen only through a Mac's relay on the phone (read-only).
        public var relayOnly = false
        public var terminal = true
    }

    public static let user = "ming"
    public static let macName = "Studio Mac"

    public static var machines: [Machine] {
        [
            Machine(name: "b200-pod-01", host: "10.8.0.11",
                    snapshot: snap(cards: 8, model: "NVIDIA B200", memGiB: 180, tdp: 1000, busy: 8, load: 0.97,
                                   cpu: 0.58, cores: 224, ramGiB: 2048, ramUsed: 0.61, uptimeDays: 41,
                                   tasks: [task(310_552, 8, "torchrun --nnodes 4 --nproc_per_node 8 pretrain.py --model llama-70b --seq 8192",
                                                "/data/runs/llama-70b", hours: 52, memGiB: 1_330)])),
            Machine(name: "h200-train", host: "10.8.0.12",
                    snapshot: snap(cards: 8, model: "NVIDIA H200", memGiB: 141, tdp: 700, busy: 8, load: 0.93,
                                   cpu: 0.47, cores: 192, ramGiB: 2048, ramUsed: 0.52, uptimeDays: 63,
                                   tasks: [task(88_210, 8, "deepspeed --num_gpus 8 train_rl.py --config configs/qwen3-32b-grpo.yaml",
                                                "/home/ming/projects/reasoning-rl", hours: 19, memGiB: 1_020)])),
            Machine(name: "h100-sxm-a", host: "10.8.0.21",
                    snapshot: snap(cards: 8, model: "NVIDIA H100 80GB HBM3", memGiB: 80, tdp: 700, busy: 6, load: 0.9,
                                   cpu: 0.39, cores: 128, ramGiB: 2048, ramUsed: 0.44, uptimeDays: 112,
                                   tasks: [task(182_331, 4, "torchrun --nproc_per_node 4 train.py --config configs/qwen2.5-14b-sft.yaml",
                                                "/home/ming/projects/llm-sft", hours: 31, memGiB: 298),
                                           task(190_002, 2, "python -m vllm.entrypoints.openai.api_server --model ckpt/step-12000 --tp 2",
                                                "/home/ming/projects/llm-sft", hours: 3, memGiB: 142, first: 4)])),
            Machine(name: "h100-sxm-b", host: "10.8.0.22",
                    snapshot: snap(cards: 8, model: "NVIDIA H100 80GB HBM3", memGiB: 80, tdp: 700, busy: 0, load: 0,
                                   cpu: 0.02, cores: 128, ramGiB: 2048, ramUsed: 0.06, uptimeDays: 112, tasks: [])),
            Machine(name: "rtx6000-ws", host: "10.8.1.5",
                    snapshot: snap(cards: 4, model: "NVIDIA RTX PRO 6000 Blackwell", memGiB: 96, tdp: 600, busy: 3, load: 0.82,
                                   cpu: 0.33, cores: 96, ramGiB: 768, ramUsed: 0.38, uptimeDays: 9,
                                   tasks: [task(52_190, 3, "python train_diffusion.py --model flux-dev --lora --res 1024",
                                                "/home/ming/projects/flux-lora", hours: 6, memGiB: 231)])),
            Machine(name: "5090-lab", host: "192.168.1.40",
                    snapshot: snap(cards: 2, model: "NVIDIA GeForce RTX 5090", memGiB: 32, tdp: 575, busy: 1, load: 0.74,
                                   cpu: 0.18, cores: 32, ramGiB: 256, ramUsed: 0.27, uptimeDays: 4,
                                   tasks: [task(7_731, 1, "python eval.py --ckpt outputs/step-9000 --bench gsm8k,mmlu",
                                                "/home/ming/projects/llm-sft", hours: 1, memGiB: 27)])),
            Machine(name: "a100-cluster", host: "172.16.4.8",
                    snapshot: snap(cards: 8, model: "NVIDIA A100-SXM4-80GB", memGiB: 80, tdp: 400, busy: 8, load: 0.88,
                                   cpu: 0.52, cores: 128, ramGiB: 1024, ramUsed: 0.57, uptimeDays: 201,
                                   tasks: [task(400_118, 8, "torchrun --nproc_per_node 8 train_vlm.py --config configs/internvl-26b.yaml",
                                                "/mnt/share/vlm", hours: 74, memGiB: 590)]),
                    relayOnly: true, terminal: false),
            Machine(name: "data-cpu", host: "10.8.2.3",
                    snapshot: cpuOnly(), terminal: false),
            Machine(name: "gh200-edge", host: "10.9.0.7", error: String(appLocalized: "连接超时")),
        ]
    }

    // MARK: Builders

    private static func task(_ pid: Int, _ cards: Int, _ command: String, _ cwd: String, hours: Double,
                             memGiB: Double, first: Int = 0) -> (GPUTask, ClosedRange<Int>) {
        let range = first...(first + cards - 1)
        return (GPUTask(pid: pid, user: user, elapsedSeconds: Int(hours * 3600) + 1_240,
                        command: "/opt/conda/bin/" + command, gpuIndices: Array(range), memoryMiB: memGiB * 1024,
                        cpuPercent: Double(cards) * 101, rssKB: Double(cards) * 9_000_000, cwd: cwd), range)
    }

    private static func snap(cards: Int, model: String, memGiB: Double, tdp: Double, busy: Int, load: Double,
                             cpu: Double, cores: Int, ramGiB: Double, ramUsed: Double, uptimeDays: Double,
                             tasks: [(GPUTask, ClosedRange<Int>)]) -> ServerSnapshot {
        var sys = SystemStat()
        sys.hostname = model.lowercased().replacingOccurrences(of: " ", with: "-")
        sys.os = "Ubuntu 24.04.1 LTS"
        sys.cpuCores = cores
        sys.cpuUsage = cpu
        sys.load = [cpu * Double(cores) * 0.9, cpu * Double(cores) * 0.85, cpu * Double(cores) * 0.8]
        sys.memTotalKB = ramGiB * 1_048_576
        sys.memAvailableKB = ramGiB * 1_048_576 * (1 - ramUsed)
        sys.diskTotalKB = 15 * 1_073_741_824
        sys.diskUsedKB = 9.6 * 1_073_741_824
        sys.uptimeSeconds = uptimeDays * 86_400 + 18_000
        sys.netRxRate = busy > 0 ? 1.4e9 * load : 18_000
        sys.netTxRate = busy > 0 ? 1.1e9 * load : 9_000
        let total = memGiB * 1024
        let gpus = (0..<cards).map { g -> GPUStat in
            // Deterministic jitter so cards don't look copy-pasted.
            let j = Double((g * 37 + cards * 11) % 9) - 4
            let on = g < busy
            let util = on ? min(100, load * 100 + j) : 0
            let mem = on ? total * min(0.97, 0.86 + j / 100) : 0.6 * 1024
            return GPUStat(index: g, uuid: "GPU-demo-\(cards)-\(g)", name: model, utilization: util,
                           memoryUsedMiB: mem, memoryTotalMiB: total,
                           temperature: on ? 66 + j + load * 8 : 31 + j / 2,
                           powerDraw: on ? tdp * (0.72 + load * 0.2) + j * 4 : tdp * 0.1, powerLimit: tdp)
        }
        return ServerSnapshot(system: sys, hasNvidiaSMI: true, gpus: gpus, tasks: tasks.map(\.0))
    }

    private static func cpuOnly() -> ServerSnapshot {
        var sys = SystemStat()
        sys.hostname = "data-cpu"
        sys.os = "Debian GNU/Linux 12"
        sys.cpuCores = 192
        sys.cpuUsage = 0.76
        sys.load = [141, 138, 129]
        sys.memTotalKB = 1536 * 1_048_576
        sys.memAvailableKB = 1536 * 1_048_576 * 0.31
        sys.diskTotalKB = 60 * 1_073_741_824
        sys.diskUsedKB = 41 * 1_073_741_824
        sys.uptimeSeconds = 86_400 * 88
        sys.netRxRate = 2.1e9
        sys.netTxRate = 1.7e9
        let procs = [
            GPUTask(pid: 9_921, user: "data", elapsedSeconds: 7_200, command: "/usr/bin/python tokenize_shards.py --shards 4096 --workers 128",
                    cpuPercent: 12_800, rssKB: 412_000_000),
            GPUTask(pid: 812, user: "postgres", elapsedSeconds: 900_000, command: "/usr/lib/postgresql/16/bin/postgres -D /data/pg",
                    cpuPercent: 240, rssKB: 310_000_000),
            GPUTask(pid: 4_410, user: "root", elapsedSeconds: 50_000, command: "/usr/bin/dockerd -H fd://",
                    cpuPercent: 12, rssKB: 1_400_000),
        ]
        return ServerSnapshot(system: sys, hasNvidiaSMI: false, gpus: [], tasks: [], processes: procs)
    }
}
