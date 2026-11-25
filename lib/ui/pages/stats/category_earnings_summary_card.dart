import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/category_earnings_provider.dart';
import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../domain/category_earnings.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';

class CategoryEarningsSummaryCard extends ConsumerWidget {
  const CategoryEarningsSummaryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final period = (
      from: todayKey(DateTime(now.year, now.month)),
      to: todayKey(now),
    );
    final report = ref.watch(categoryEarningsProvider(period));
    final hidden = ref.watch(hideAmountsProvider);
    return TerminalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('本月分类收益', style: T.label(size: 12))),
              TextButton(
                onPressed: () => context.push('/category-earnings'),
                child: const Text('查看全部'),
              ),
            ],
          ),
          report.when(
            loading: () => Text('正在加载分类收益…', style: T.label()),
            error: (_, _) => Row(
              children: [
                Expanded(child: Text('分类收益加载失败', style: T.label())),
                TextButton(
                  onPressed: () {
                    ref.invalidate(snapshotsProvider);
                    ref.invalidate(holdingsProvider);
                    ref.invalidate(transactionsProvider);
                    ref.invalidate(categoryEarningsProvider(period));
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
            data: (value) {
              if (!value.verified) {
                return Text(
                  '本月分类收益待核对，查看详情处理。',
                  style: T.label(color: T.warning),
                );
              }
              if (value.isEmpty || value.categories.isEmpty) {
                return Text('本月暂无可展示的分类收益', style: T.label());
              }
              return Column(
                children: [
                  for (final category in value.categories.take(3))
                    _CategorySummaryRow(category: category, hidden: hidden),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CategorySummaryRow extends StatelessWidget {
  const _CategorySummaryRow({required this.category, required this.hidden});

  final CategoryEarning category;
  final bool hidden;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(T.rInput),
    onTap: () => context.push(
      '/category-earnings?category=${category.category.storageName}',
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Icon(
            category.category.icon,
            color: category.category.color,
            size: 16,
          ),
          const SizedBox(width: T.s2),
          Expanded(
            child: Text(category.category.label, style: T.label(size: 12)),
          ),
          Flexible(
            child: Text(
              hidden
                  ? '****'
                  : '${category.profit >= 0 ? '+' : '-'}${Formats.money(category.profit.abs())}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: T.mono(
                size: 13,
                color: hidden ? T.text2 : T.changeColor(category.profit),
              ),
            ),
          ),
          const SizedBox(width: T.s2),
          const Icon(Icons.chevron_right, size: 16, color: T.text3),
        ],
      ),
    ),
  );
}
