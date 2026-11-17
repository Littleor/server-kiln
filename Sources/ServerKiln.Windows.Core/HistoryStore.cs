using System.Runtime.InteropServices;
using System.Text.Json;

namespace ServerKiln.Windows.Core;

public sealed record HistoryPoint(DateTimeOffset Time, int? Gpu, double? Utilization, double? MemoryFraction,
    double? MemoryUsedMiB, double? Cpu, double? Ram);

/// <summary>Uses Windows' built-in SQLite. Serialized access, parameterized queries and atomic snapshots.</summary>
public sealed class HistoryStore : IDisposable
{
    private readonly object gate = new();
    private readonly Dictionary<Guid, DateTimeOffset> lastWrite = [];
    private readonly int minimumIntervalSeconds;
    private IntPtr database;

    public HistoryStore(string path, int minimumIntervalSeconds = 60)
    {
        this.minimumIntervalSeconds = minimumIntervalSeconds;
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        if (Native.sqlite3_open(path, out database) != 0)
        {
            var message = Error();
            if (database != IntPtr.Zero) Native.sqlite3_close(database);
            database = IntPtr.Zero;
            throw new IOException(message);
        }
        try
        {
            Native.sqlite3_busy_timeout(database, 3000);
            Execute("PRAGMA journal_mode=WAL");
            Execute("CREATE TABLE IF NOT EXISTS samples (server TEXT NOT NULL, ts INTEGER NOT NULL, gpu INTEGER NOT NULL, util REAL, mem_used REAL, mem_total REAL, cpu REAL, ram REAL)");
            Execute("CREATE INDEX IF NOT EXISTS samples_server_ts ON samples(server, ts)");
            Execute("CREATE TABLE IF NOT EXISTS task_state (server TEXT PRIMARY KEY, payload TEXT NOT NULL)");
        }
        catch { Dispose(); throw; }
    }

    public void Record(Guid server, ServerSnapshot snapshot, DateTimeOffset now)
    {
        lock (gate)
        {
            if (lastWrite.TryGetValue(server, out var last) && (now - last).TotalSeconds < minimumIntervalSeconds) return;
            var gpus = snapshot.Gpus;
            Execute("BEGIN IMMEDIATE");
            try
            {
                Insert(server, now, -1, gpus.Length == 0 ? null : gpus.Average(g => g.Utilization),
                    gpus.Length == 0 ? null : gpus.Sum(g => g.MemoryUsedMiB),
                    gpus.Length == 0 ? null : gpus.Sum(g => g.MemoryTotalMiB), snapshot.System.CpuUsage, snapshot.System.MemFraction);
                foreach (var gpu in gpus) Insert(server, now, gpu.Index, gpu.Utilization, gpu.MemoryUsedMiB, gpu.MemoryTotalMiB, null, null);
                Execute("COMMIT");
                lastWrite[server] = now;
            }
            catch { Execute("ROLLBACK"); throw; }
        }
    }

    private void Insert(Guid server, DateTimeOffset now, int gpu, double? util, double? used, double? total, double? cpu, double? ram)
    {
        using var statement = Prepare("INSERT INTO samples VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)");
        statement.Bind(1, server.ToString()); statement.Bind(2, now.ToUnixTimeSeconds()); statement.Bind(3, gpu);
        statement.Bind(4, util); statement.Bind(5, used); statement.Bind(6, total); statement.Bind(7, cpu); statement.Bind(8, ram);
        statement.Done();
    }

    public HistoryPoint[] Query(Guid server, DateTimeOffset since, int bucketSeconds = 60, bool perGpu = false)
    {
        lock (gate)
        {
            var bucket = Math.Max(1, bucketSeconds);
            using var statement = Prepare("SELECT (ts / ?1) * ?1 AS b, gpu, AVG(util), AVG(mem_used), AVG(mem_total), AVG(cpu), AVG(ram) FROM samples "
                + "WHERE server = ?2 AND ts >= ?3 AND " + (perGpu ? "gpu >= 0" : "gpu = -1") + " GROUP BY b, gpu ORDER BY b, gpu");
            statement.Bind(1, bucket); statement.Bind(2, server.ToString()); statement.Bind(3, since.ToUnixTimeSeconds());
            List<HistoryPoint> points = [];
            while (statement.Row())
            {
                var gpu = statement.Integer(1);
                var used = statement.Number(3); var total = statement.Number(4);
                points.Add(new HistoryPoint(DateTimeOffset.FromUnixTimeSeconds(statement.Integer(0)).AddSeconds(bucket / 2.0),
                    gpu < 0 ? null : (int)gpu, statement.Number(2), used is not null && total > 0 ? used / total : null,
                    used, statement.Number(5), statement.Number(6)));
            }
            return points.ToArray();
        }
    }

    public void SaveTasks(Guid server, TaskTracker tracker)
    {
        lock (gate)
        {
            using var statement = Prepare("INSERT INTO task_state VALUES (?1, ?2) ON CONFLICT(server) DO UPDATE SET payload = excluded.payload");
            statement.Bind(1, server.ToString()); statement.Bind(2, JsonSerializer.Serialize(tracker, JsonDefaults.Options)); statement.Done();
        }
    }

    public TaskTracker LoadTasks(Guid server)
    {
        lock (gate)
        {
            using var statement = Prepare("SELECT payload FROM task_state WHERE server = ?1");
            statement.Bind(1, server.ToString());
            return statement.Row() ? JsonSerializer.Deserialize<TaskTracker>(statement.Text(0), JsonDefaults.Options) ?? new() : new();
        }
    }

    public void Delete(Guid server)
    {
        lock (gate)
        {
            foreach (var table in new[] { "samples", "task_state" })
            {
                using var statement = Prepare("DELETE FROM " + table + " WHERE server = ?1");
                statement.Bind(1, server.ToString()); statement.Done();
            }
            lastWrite.Remove(server);
        }
    }

    public void Prune(DateTimeOffset now, int retentionDays)
    {
        lock (gate)
        {
            using var statement = Prepare("DELETE FROM samples WHERE ts < ?1");
            statement.Bind(1, now.AddDays(-Math.Clamp(retentionDays, 1, 365)).ToUnixTimeSeconds()); statement.Done();
        }
    }

    private string Error() => "SQLite: " + (Marshal.PtrToStringUTF8(Native.sqlite3_errmsg(database)) ?? "unknown error");
    private void Execute(string sql)
    {
        ObjectDisposedException.ThrowIf(database == IntPtr.Zero, this);
        if (Native.sqlite3_exec(database, sql, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) != 0) throw new IOException(Error());
    }
    private Statement Prepare(string sql)
    {
        ObjectDisposedException.ThrowIf(database == IntPtr.Zero, this);
        if (Native.sqlite3_prepare_v2(database, sql, -1, out var statement, IntPtr.Zero) != 0) throw new IOException(Error());
        return new Statement(statement, this);
    }
    public void Dispose()
    {
        lock (gate)
        {
            if (database != IntPtr.Zero) { Native.sqlite3_close(database); database = IntPtr.Zero; }
        }
    }

    private sealed class Statement(IntPtr handle, HistoryStore store) : IDisposable
    {
        private void Check(int result) { if (result != 0) throw new IOException(store.Error()); }
        public void Bind(int index, string value) => Check(Native.sqlite3_bind_text(handle, index, value, -1, new IntPtr(-1)));
        public void Bind(int index, long value) => Check(Native.sqlite3_bind_int64(handle, index, value));
        public void Bind(int index, double? value) => Check(value is { } number
            ? Native.sqlite3_bind_double(handle, index, number) : Native.sqlite3_bind_null(handle, index));
        public bool Row()
        {
            var code = Native.sqlite3_step(handle);
            return code == 100 ? true : code == 101 ? false : throw new IOException(store.Error());
        }
        public void Done() { if (Row()) throw new IOException("Unexpected SQLite result."); }
        public double? Number(int column) => Native.sqlite3_column_type(handle, column) == 5 ? null : Native.sqlite3_column_double(handle, column);
        public long Integer(int column) => Native.sqlite3_column_int64(handle, column);
        public string Text(int column) => Marshal.PtrToStringUTF8(Native.sqlite3_column_text(handle, column)) ?? "";
        public void Dispose() => Native.sqlite3_finalize(handle);
    }

    private static class Native
    {
        private const string Library = "winsqlite3.dll";
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_open([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out IntPtr db);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_close(IntPtr db);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr sqlite3_errmsg(IntPtr db);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_busy_timeout(IntPtr db, int ms);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_exec(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, IntPtr callback, IntPtr arg, IntPtr error);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_prepare_v2(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, int bytes, out IntPtr statement, IntPtr tail);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_finalize(IntPtr statement);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_step(IntPtr statement);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_bind_text(IntPtr statement, int index, [MarshalAs(UnmanagedType.LPUTF8Str)] string value, int bytes, IntPtr destructor);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_bind_int64(IntPtr statement, int index, long value);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_bind_double(IntPtr statement, int index, double value);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_bind_null(IntPtr statement, int index);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern int sqlite3_column_type(IntPtr statement, int column);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern double sqlite3_column_double(IntPtr statement, int column);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern long sqlite3_column_int64(IntPtr statement, int column);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
    }
}
