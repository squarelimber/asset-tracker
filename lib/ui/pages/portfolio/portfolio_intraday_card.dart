import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/market_session.dart';
import '../../../core/responsive.dart';
import '../../components/intraday_line_chart.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';
import 'portfolio_intraday.dart';

/// Keeps the live chart close to the balance sheet during the market session.
class PortfolioIntradayCard extends StatelessWidget {
  const PortfolioIntradayCard({
    super.key,
    required this.day,
    required this.session,
  });

  final String day;
  final MarketSession session;

  @override
  Widget build(BuildContext context) {
    if (!session.showsIntradayTrend) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: T.s3),
      child: PortfolioIntradayTrend(day: day),
    );
  }
}

class PortfolioIntradayTrend extends ConsumerWidget {
  const PortfolioIntradayTrend({super.key, required this.day});

  final String day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(portfolioIntradayHistoryProvider(day));
    final samples = ref.watch(portfolioIntradayProvider(day));
    final rebuilt = history.valueOrNull;
    final hasHistory = rebuilt != null && rebuilt.points.isNotEmpty;
    final points = hasHistory
        ? rebuilt.points
        : samples.valueOrNull ?? const [];
    final hidden = ref.watch(hideAmountsProvider);
    return TerminalCard(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: T.s2,
            runSpacing: T.s1,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                '今日盈亏走势',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              Text('盘中估算', style: T.label(color: T.text3)),
            ],
          ),
          const SizedBox(height: T.s2),
          if (points.isEmpty)
            if (history.isLoading || samples.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: T.s4),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      history.hasError || samples.hasError
                          ? '今日分时加载失败'
                          : '暂无可用的今日分时行情',
                      style: T.label(),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      ref.invalidate(portfolioIntradayHistoryProvider(day));
                      ref.invalidate(portfolioIntradayProvider(day));
                    },
                    child: const Text('重试'),
                  ),
                ],
              )
          else ...[
            Wrap(
              spacing: T.s3,
              runSpacing: T.s1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  hidden ? Formats.masked() : _signedMoney(points.last.profit),
                  style: T.mono(
                    size: 22,
                    weight: FontWeight.w700,
                    color: hidden ? T.text2 : T.changeColor(points.last.profit),
                  ),
                ),
                Text(
                  '截至 ${minuteLabel(points.last.minute)} · $day',
                  style: T.label(),
                ),
              ],
            ),
            const SizedBox(height: T.s2),
            if (hidden)
              Text('金额已隐藏', style: T.label())
            else ...[
              IntradayLineChart(
                points: [
                  for (final p in points) (minute: p.minute, value: p.profit),
                ],
                formatValue: _signedMoney,
                formatAxisValue: (v) =>
                    '${v < 0 ? '-' : ''}¥${Formats.num(v.abs())}',
                color: const Color(0xFF8EADCA),
                gridAtBounds: true,
                height: Responsive.isPhone(context) ? 150 : 210,
              ),
              const SizedBox(height: T.s2),
              Text(
                hasHistory
                    ? '按 A 股时段重算，分时行情覆盖 ${rebuilt.covered}/${rebuilt.eligible} 项份额型持仓。其余资产及汇率按固定值估算。'
                    : '根据本机记录的净值点计算，已扣除外部资金进出。',
                style: T.label(),
              ),
            ],
          ],
        ],
      ),
    );
  }

  static String _signedMoney(double value) {
    if (value == 0) return Formats.money(0);
    return '${value > 0 ? '+' : '-'}${Formats.money(value.abs())}';
  }
}
