namespace ServerKiln.Windows;

internal static class DemoData
{
    private const string TrainingCommand = "torchrun --nproc_per_node=2 /workspace/experiments/train.py --config configs/vision_policy.yaml --dataset /datasets/robotics/benchmark/train.jsonl --checkpoint /workspace/checkpoints/baseline/epoch-12 --output /workspace/runs/vision-policy";
    private const string FinishedCommand = "python /workspace/experiments/evaluate.py --checkpoint /workspace/checkpoints/vision-policy/epoch-12 --dataset /datasets/robotics/benchmark/validation.jsonl --batch-size 64 --output /workspace/runs/evaluation/report.json";
    public static AppPreferences Preferences => new()
    {
        Servers = [new ServerConfig { Id = Guid.Parse("10000000-0000-4000-8000-000000000001"), Name = "gpu-01", Target = "gpu-01.example.com" },
            new ServerConfig { Id = Guid.Parse("10000000-0000-4000-8000-000000000002"), Name = "gpu-02", Target = "gpu-02.example.com" },
            new ServerConfig { Id = Guid.Parse("10000000-0000-4000-8000-000000000003"), Name = "cpu-01", Target = "cpu-01.example.com" }]
    };

    public static void Populate(App app)
    {
        var now = DateTimeOffset.UtcNow;
        for (var i = 0; i < app.Preferences.Servers.Length; i++)
        {
            var server = app.Preferences.Servers[i];
            var output = "@@HOST\n" + server.Name.Split(' ')[0].ToLowerInvariant() + "\n@@OS\nUbuntu 24.04.3 LTS\n@@UPTIME\n357892.5\n@@NCPU\n64\n@@CPU\ncpu 100 0 100 800 0 0 0 0\ncpu 145 0 120 835 0 0 0 0\n@@MEM\nMemTotal: 268435456 kB\nMemAvailable: 171798691 kB\n@@DISK\n/dev/nvme0n1p1 2000000000 940000000 1060000000 47% /\n@@NET\n1000 2000000 500000\n1002 6194304 762144\n";
            if (i < 2)
                output += i == 0 ? "@@GPU\n0, GPU-demo-a, NVIDIA RTX 4090, 96, 21840, 24564, 71, 378, 450\n1, GPU-demo-b, NVIDIA RTX 4090, 89, 20200, 24564, 68, 350, 450\n@@APPS\nGPU-demo-a, 4242, 21700\nGPU-demo-b, 4242, 20000\n"
                    : "@@GPU\n0, GPU-demo-c, NVIDIA A100-SXM4-80GB, 0, 12, 81920, 34, 52, 400\n";
            else output += "@@NOGPU\n";
            output += i == 1 ? "@@TOP\n520 researcher 2400 0.5 400000 jupyter-lab --no-browser\n@@CWD\n520 /workspace/notebooks\n@@END\n"
                : "@@PS\n4242 researcher 7384 198.5 10485760 torchrun --nproc_per_node=2 train.py --config configs/run.yaml\n@@TOP\n4242 researcher 7384 198.5 10485760 torchrun --nproc_per_node=2 train.py --config configs/run.yaml\n520 researcher 2400 12.5 400000 python prepare_dataset.py\n@@CWD\n4242 /workspace/training\n520 /workspace/data\n@@END\n";
            output = output.Replace("torchrun --nproc_per_node=2 train.py --config configs/run.yaml", TrainingCommand, StringComparison.Ordinal);
            var snapshot = SnapshotParser.Parse(output, now);
            snapshot = snapshot with { System = snapshot.System with { CpuUsage = i == 1 ? 0.07 : i == 2 ? 0.32 : 0.65, Load = [4.2, 3.8, 3.4] } };
            var lastJob = new TaskRecord(FinishedCommand, "researcher", "/workspace/training", snapshot.Gpus.Take(1).Select(g => g.Index).ToArray(), now.AddHours(-5), now.AddHours(-3));
            var jobs = i == 1 ? new[] { lastJob } : new[] { new TaskRecord(TrainingCommand, "researcher", "/workspace/training", snapshot.Gpus.Select(g => g.Index).ToArray(), now.AddHours(-2)), lastJob };
            app.ViewModel.Apply(new ServerReading(server, snapshot, LastAttempt: now, LastSuccess: now,
                Activity: i == 0 ? ServerActivity.Busy : i == 1 ? ServerActivity.Idle : ServerActivity.CpuOnly, Jobs: jobs));
            for (var n = 0; n < 288; n++)
            {
                var time = now.AddMinutes(-5 * (288 - n));
                var gpus = snapshot.Gpus.Select(g => g with { Utilization = i == 0 ? Math.Clamp(65 + 28 * Math.Sin(n / 11.0 + g.Index * 0.9), 0, 100) : n < 180 ? 70 : 0,
                    MemoryUsedMiB = i == 0 ? 16000 + 5000 * Math.Sin(n / 17.0 + g.Index * 0.7) : n < 180 ? 42000 : 12 }).ToArray();
                app.History.Record(server.Id, snapshot with { Gpus = gpus, System = snapshot.System with { CpuUsage = 0.3 + 0.22 * Math.Sin(n / 13.0), MemAvailableKB = 170000000 + 30000000 * Math.Cos(n / 23.0) } }, time);
            }
            for (var n = 0; n <= 120; n++)
            {
                var time = now.AddSeconds(-600 + n * 5);
                app.Recent.Record(server.Id, snapshot with
                {
                    Gpus = snapshot.Gpus.Select(g => g with
                    {
                        Utilization = i == 0 ? 62 + 30 * Math.Sin(n / 13.0 + g.Index) : 0,
                        MemoryUsedMiB = i == 0 ? 16500 + 4500 * Math.Sin(n / 18.0 + g.Index) : 12
                    }).ToArray(),
                    System = snapshot.System with { CpuUsage = 0.4 + 0.2 * Math.Sin(n / 17.0) }
                }, time);
            }
        }
    }
}
