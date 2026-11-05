import 'package:asset_tracker/ui/pages/portfolio/portfolio_widgets.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selects asset point even when a benchmark sorts first', () {
    const asset = FlSpot(2, 1);
    const benchmark = FlSpot(1, 4);
    final assetSpot = LineBarSpot(LineChartBarData(spots: [asset]), 0, asset);
    final benchmarkSpot = LineBarSpot(
      LineChartBarData(spots: [benchmark]), 1, benchmark,
    );
    expect(trendAssetSpotIndex([benchmarkSpot, assetSpot]), 2);
    expect(trendAssetSpotIndex([benchmarkSpot]), isNull);
    expect(trendAssetSpotIndex(null), isNull);
  });
}
