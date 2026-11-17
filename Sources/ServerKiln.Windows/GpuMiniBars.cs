namespace ServerKiln.Windows;

/// Compact memory columns with utilization ticks, matching the Mac fleet list.
public sealed class GpuMiniBars : FrameworkElement
{
    public static readonly DependencyProperty SnapshotProperty = DependencyProperty.Register(
        nameof(Snapshot), typeof(ServerSnapshot), typeof(GpuMiniBars),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender | FrameworkPropertyMetadataOptions.AffectsMeasure));
    public ServerSnapshot? Snapshot { get => (ServerSnapshot?)GetValue(SnapshotProperty); set => SetValue(SnapshotProperty, value); }

    protected override Size MeasureOverride(Size availableSize) => new(Math.Min(200, Math.Max(2, Snapshot?.Gpus.Length ?? 0) * 13), 36);
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        if (Snapshot is not { } snapshot) return;
        var values = snapshot.IsGpuServer
            ? snapshot.Gpus.Select(g => (Memory: g.MemoryFraction, Use: g.Utilization / 100)).ToArray()
            : new[] { (Memory: snapshot.System.CpuUsage ?? 0, Use: 0.0), (Memory: snapshot.System.MemFraction ?? 0, Use: 0.0) };
        var step = Math.Min(13, ActualWidth / Math.Max(1, values.Length));
        var width = Math.Max(1, step - 4);
        var track = (Brush)FindResource("RaisedBrush");
        for (var i = 0; i < values.Length; i++)
        {
            var (memory, use) = values[i];
            memory = Math.Clamp(memory, 0, 1); use = Math.Clamp(use, 0, 1);
            var x = i * step;
            dc.DrawRoundedRectangle(track, null, new Rect(x, 0, width, 28), 2, 2);
            if (memory > 0) dc.DrawRoundedRectangle(LoadColors.Strong(memory * 100), null, new Rect(x, 28 * (1 - memory), width, 28 * memory), 2, 2);
            dc.DrawRoundedRectangle(track, null, new Rect(x, 32, width, 3), 1, 1);
            if (use > 0) dc.DrawRoundedRectangle(LoadColors.Strong(use * 100), null, new Rect(x, 32, width * use, 3), 1, 1);
        }
    }
}
