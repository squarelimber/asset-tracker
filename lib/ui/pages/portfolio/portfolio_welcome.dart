import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../domain/portfolio_calculator.dart';
import '../../tokens.dart';
import 'target_allocation_dialog.dart';

/// Setup belongs to the workspace, with the same row vocabulary as data views.
class PortfolioWelcome extends StatelessWidget {
  const PortfolioWelcome({super.key, this.hasAccounts = false});
  final bool hasAccounts;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            const Text(
              '暂无持仓',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text(
              '录入持仓后，可查看资产分布、净值趋势与每日收益。',
              style: TextStyle(fontSize: 13, color: T.text2, height: 1.7),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () =>
                      context.go(hasAccounts ? '/holdings' : '/accounts'),
                  icon: const Icon(Icons.add, size: 17),
                  label: Text(hasAccounts ? '添加第一笔持仓' : '创建第一个账户'),
                ),
                OutlinedButton.icon(
                  onPressed: () => context.push('/settings'),
                  icon: const Icon(Icons.file_upload_outlined, size: 17),
                  label: const Text('导入已有备份'),
                ),
                OutlinedButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const TargetAllocationDialog(
                      summary: PortfolioSummary(
                        totalAssets: 0,
                        totalLiabilities: 0,
                        totalCost: 0,
                        todayChange: 0,
                        todayChangePct: null,
                        breakdown: [],
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.tune, size: 17),
                  label: const Text('设置资产配置目标'),
                ),
              ],
            ),
            const SizedBox(height: 40),
            Container(
              decoration: BoxDecoration(
                color: T.surface,
                border: Border.all(color: T.border),
                borderRadius: BorderRadius.circular(T.rCard),
              ),
              child: Column(
                children: [
                  _row(
                    context,
                    Icons.account_balance_wallet_outlined,
                    '账户',
                    '按银行、券商或平台归集资产',
                    '/accounts',
                  ),
                  const Divider(height: 1, color: T.borderSoft),
                  _row(
                    context,
                    Icons.pie_chart_outline,
                    '持仓',
                    '记录数量、成本与最新价格',
                    '/holdings',
                  ),
                  const Divider(height: 1, color: T.borderSoft),
                  _row(
                    context,
                    Icons.receipt_long_outlined,
                    '交易流水',
                    '查看买卖、分红与资金变动',
                    '/transactions',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _row(
    BuildContext context,
    IconData icon,
    String title,
    String description,
    String path,
  ) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: () =>
          path == '/transactions' ? context.push(path) : context.go(path),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            Icon(icon, size: 19, color: T.text2),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 12,
                      color: T.text3,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.chevron_right, size: 16, color: T.text3),
          ],
        ),
      ),
    ),
  );
}
