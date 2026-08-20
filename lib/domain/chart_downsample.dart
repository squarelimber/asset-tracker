typedef ChartPoint = ({double x, double y});

/// Min-max bucket downsampling for dense line-chart series.
///
/// A long series (hundreds to thousands of daily points) drawn on a phone
/// plot area (~300px wide) becomes an unreadable scribble. Bucketing the x
/// range and keeping only the min and max point of each bucket preserves the
/// visual envelope (peaks and troughs) while cutting the point count to what
/// the screen can actually resolve. Original x values are kept, so
/// index-based lookups (dates, tap targets) continue to work.
class ChartDownsample {
  const ChartDownsample();

  /// Returns [points] unchanged when short enough, otherwise at most
  /// [target] points whose x values are a subset of the input x values.
  /// The first and last points are always kept.
  ///
  /// Points must be sorted by ascending x (chart series always are).
  List<ChartPoint> downsample(
    List<ChartPoint> points, {
    int target = 240,
  }) {
    if (points.length <= target) return points;
    // Reserve two slots so the first and last points always fit.
    final buckets = (target ~/ 2) - 1;
    if (buckets < 1) return [points.first, points.last];
    final per = points.length / buckets;
    final result = <ChartPoint>[];
    for (var b = 0; b < buckets; b++) {
      // Half-open [start, end) so buckets are disjoint and cover the range.
      final start = (b * per).floor();
      final end = b == buckets - 1 ? points.length : ((b + 1) * per).floor();
      if (start >= end) continue;
      var minIdx = start;
      var maxIdx = start;
      for (var i = start + 1; i < end; i++) {
        if (points[i].y < points[minIdx].y) minIdx = i;
        if (points[i].y > points[maxIdx].y) maxIdx = i;
      }
      // Keep x order inside the bucket.
      final first = minIdx < maxIdx ? minIdx : maxIdx;
      final second = minIdx < maxIdx ? maxIdx : minIdx;
      result.add(points[first]);
      if (second != first) result.add(points[second]);
    }
    // The chart must start at the first point and end at the latest point
    // (e.g. today's value); neither is guaranteed to be a bucket extreme.
    if (result.first.x != points.first.x) result.insert(0, points.first);
    if (result.last.x != points.last.x) {
      result.removeLast();
      result.add(points.last);
    }
    return result;
  }
}
