using System.Globalization;

namespace ServerKiln.Windows;

public sealed class HistoryChart : FrameworkElement
{
    private HistoryPoint[] points = [];
    private DateTimeOffset since = DateTimeOffset.UtcNow.AddDays(-1), until = DateTimeOffset.UtcNow;
    private int bucketSeconds = 300;
    private bool perGpu;
    private GpuHistoryMetric metric;
    private static readonly Color[] Palette = [Color.FromRgb(36, 91, 219), Color.FromRgb(40, 122, 85),
        Color.FromRgb(155, 75, 32), Color.FromRgb(28, 125, 137), Color.FromRgb(176, 62, 115), Color.FromRgb(106, 106, 52),
        Color.FromRgb(137, 111, 20), Color.FromRgb(178, 66, 54)];

    public void SetPoints(HistoryPoint[] value, DateTimeOffset start, DateTimeOffset end, int bucket = 300,
        bool byGpu = false, GpuHistoryMetric gpuMetric = GpuHistoryMetric.Utilization)
    {
        points = value; since = start; until = end; bucketSeconds = bucket; perGpu = byGpu; metric = gpuMetric; InvalidateVisual();
    }

    protected override void OnRender(DrawingContext context)
    {
        base.OnRender(context);
        if (ActualWidth < 100 || ActualHeight < 100 || until <= since) return;
        var textBrush = (Brush)FindResource("MutedBrush");
        var typeface = new Typeface((FontFamily)FindResource("UiFontFamily"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        var border = new Pen((Brush)FindResource("ChartGridBrush"), 1);
        var palette = Palette;
        var series = new List<(HistoryPoint[] Points, Func<HistoryPoint, double?> Value, Color Color, string Label)>();
        if (perGpu)
        {
            foreach (var group in points.Where(p => p.Gpu is not null).GroupBy(p => p.Gpu!.Value).OrderBy(g => g.Key))
                series.Add((group.OrderBy(p => p.Time).ToArray(), metric == GpuHistoryMetric.Utilization ? p => p.Utilization / 100 : p => p.MemoryFraction,
                    palette[series.Count % palette.Length], "GPU " + group.Key));
        }
        else
        {
            var overall = points.Where(p => p.Gpu is null).OrderBy(p => p.Time).ToArray();
            series.Add((overall, p => p.Utilization / 100, palette[1], "GPU"));
            series.Add((overall, p => p.MemoryFraction, palette[2], Localizer.Current["Vram"]));
            series.Add((overall, p => p.Cpu, palette[0], "CPU"));
            series.Add((overall, p => p.Ram, palette[3], Localizer.Current["Ram"]));
        }
        void Text(string text, double x, double y, Brush? brush = null) => context.DrawText(new FormattedText(text,
            CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, typeface, 13,
            brush ?? textBrush, VisualTreeHelper.GetDpi(this).PixelsPerDip), new Point(x, y));
        var legendColumns = Math.Max(1, (int)(ActualWidth - 60) / 110);
        var legendRows = Math.Max(1, (series.Count + legendColumns - 1) / legendColumns);
        var top = 16 + legendRows * 18;
        var bounds = new Rect(42, top, ActualWidth - 60, Math.Max(40, ActualHeight - top - 34));
        for (var index = 0; index < series.Count; index++)
        {
            var x = bounds.Left + index % legendColumns * 110;
            var y = index / legendColumns * 18;
            context.DrawRoundedRectangle(new SolidColorBrush(series[index].Color), null, new Rect(x, y + 4, 12, 3), 1.5, 1.5);
            Text(series[index].Label, x + 19, y);
        }
        for (var n = 0; n <= 4; n++)
        {
            var y = bounds.Top + n * bounds.Height / 4;
            context.DrawLine(border, new Point(bounds.Left, y), new Point(bounds.Right, y));
            Text($"{100 - n * 25}%", 0, y - 7);
            var time = since + (until - since) * (n / 4.0);
            var x = bounds.Left + bounds.Width * n / 4;
            Text((until - since).TotalDays > 1.1 ? time.LocalDateTime.ToString("MM-dd") : time.LocalDateTime.ToString("HH:mm"), x - 15, bounds.Bottom + 12);
        }
        if (points.Length == 0)
        {
            Text(Localizer.Current[perGpu ? "NoGpuHistory" : "NoHistory"], bounds.Left + 8, bounds.Top + bounds.Height / 2);
            return;
        }
        context.PushClip(new RectangleGeometry(bounds));
        foreach (var (samples, getValue, color, _) in series)
        {
            var pen = new Pen(new SolidColorBrush(color), 2) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
            Point? previous = null;
            DateTimeOffset? previousTime = null;
            foreach (var sample in samples)
            {
                if (getValue(sample) is not { } value) { previous = null; previousTime = null; continue; }
                var p = new Point(bounds.Left + (sample.Time - since).TotalSeconds / (until - since).TotalSeconds * bounds.Width,
                    bounds.Bottom - Math.Clamp(value, 0, 1) * bounds.Height);
                if (previous is { } last && (sample.Time - previousTime!.Value).TotalSeconds <= bucketSeconds * 2.5)
                    context.DrawLine(pen, last, p);
                else context.DrawEllipse(pen.Brush, null, p, 2.3, 2.3);
                previous = p; previousTime = sample.Time;
            }
        }
        context.Pop();
    }
}
