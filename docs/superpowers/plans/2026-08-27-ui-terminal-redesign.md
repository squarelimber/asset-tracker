# UI 深色终端重设计 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or superpowers:subagent-driven-development) to implement this plan task-by-task.

**Goal:** 将 asset_tracker 全部 12 个页面 + 主题 + 共享组件重写为深色金融终端风格（Bloomberg 风，红涨绿跌），5+2 导航，一次性发版 0.7.0。

**Architecture:** tokens（`T` 类）+ 共享组件库（`lib/ui/components/`）+ 目录重组（`lib/features/` 页面文件移入 `lib/ui/pages/`，私有 widget 跟随页面）。Riverpod providers 接口不变（`lib/app/providers.dart` 零改动），`lib/data/`、`lib/services/`、`lib/core/` 不动。页面私有 provider 改公开命名以便测试 override。

**Tech Stack:** Flutter 3.44.9 / Dart 3.12.2，Riverpod，GoRouter，fl_chart，drift。

**Spec:** `docs/superpowers/specs/2026-08-27-ui-terminal-redesign-design.md`（已批准，含全部设计决策）

## Global Constraints

- 工作目录 `D:\AssetManagement\asset_tracker`。
- **每个 Task 结束必须**：`flutter analyze lib test` 退出码 0（CI 对 info 级也判失败，必须检查 `$LASTEXITCODE`）+ `flutter test` 全绿（基线 256 个测试）+ 1 个 git commit。
- 数据颜色约定不变：涨=红 `#F85149`，跌=绿 `#3FB950`。
- `lib/app/providers.dart`、`lib/data/`、`lib/services/`、`lib/core/` 不改动。
- 断点不变：phone <720，tablet 720–1100，desktop ≥1100（`lib/core/responsive.dart` 的 `Responsive.isDesktop` 等，不改）。
- 不写注释，除非解释非显然逻辑（沿用现有代码风格）。
- 页面私有 provider 重命名规则（去掉下划线，公开供测试 override）：
  - `_summaryProvider` → `summaryProvider`（portfolio_page）
  - `_quotesProvider` → `quotesProvider`（markets_page）
  - `_statsProvider` → `statsProvider`（stats_page）
  - `_earningsProvider` → `earningsProvider`（earnings_calendar_page）
  - `_refreshingProvider` 保持私有（holdings，测试不 override 它）
- 每个页面的主 AppBar 追加 `TerminalAppBarActions`（铃铛+齿轮）；被 push 的详情页（AccountDetailPage、DayDetailSheet 等）不加。

## File Structure

```
lib/
  app/
    app.dart            [MODIFY] 去掉 darkTheme/themeMode，theme: AppTheme.dark()
    router.dart         [MODIFY] 每 Task 迁移一个页面就改对应 import
    theme.dart          [REWRITE] 只留 AppTheme.dark() + UpDownColor，全部用 T
    providers.dart      [UNCHANGED]
  core/                 [UNCHANGED] formats / enums / symbols / responsive
  data/  services/      [UNCHANGED]
  ui/
    tokens.dart         [NEW Task1]
    shell/shell_page.dart            [NEW Task1] 5 个 destination
    components/
      app_bar_actions.dart           [NEW Task1]
      terminal_card.dart             [NEW Task2]
      section_header.dart            [NEW Task2] SectionHeader + StickySectionHeader
      kpi_grid.dart                  [NEW Task2] KpiGrid + StatTile
      delta_text.dart                [NEW Task2]
      data_row.dart                  [NEW Task2]
      allocation_bars.dart           [NEW Task2] AllocationEntry + AllocationBars
      heat_cell.dart                 [NEW Task2]
      quote_table.dart               [NEW Task2] QuoteRow + QuoteTable
      empty_state.dart               [NEW Task2]
      form_fields.dart               [NEW Task2] terminalDecoration + TerminalTextField
      sparkline.dart                 [NEW Task2]
    pages/
      portfolio/
        portfolio_page.dart          [MOVE+REWRITE Task3]
        portfolio_widgets.dart       [MOVE+REWRITE Task3] AllocationBars 版 + 净值图升级
        day_detail_sheet.dart        [MOVE+RESTYLE Task3]
      holdings/
        holdings_page.dart           [MOVE+SPLIT Task4]
        holdings_table.dart          [NEW Task4] desktop 表格
        holding_detail_sheet.dart    [NEW Task4]（从 holdings_page 拆出）
        holding_dialogs.dart         [NEW Task4]（_showAddHoldingDialog 拆出）
        invested_profit_field.dart   [MOVE+RESTYLE Task4]
        purchase_date_field.dart     [MOVE+RESTYLE Task4]
        transaction_dialogs.dart     [MOVE+RESTYLE Task4]（自 features/transactions/）
      accounts/
        accounts_page.dart           [MOVE+REWRITE Task5]
        account_detail_page.dart     [MOVE+RESTYLE Task5]
      markets/markets_page.dart      [MOVE+REWRITE Task6]
      stats/stats_page.dart          [MOVE+REWRITE Task7]
      alerts/alerts_page.dart        [MOVE+REWRITE Task8]
      settings/
        settings_page.dart           [MOVE+REWRITE Task9]
        sync_settings_page.dart      [MOVE+RESTYLE Task9]
      calendar/
        earnings_calendar_page.dart  [MOVE+REWRITE Task10]
        product_earnings_calendar_page.dart [MOVE+REWRITE Task11] sliver 矩阵
  features/                 [DELETE 各 Task 迁移后]
```

测试文件：

```
test/
  ui/
    theme_test.dart               [NEW Task1]
    components_test.dart          [NEW Task2]
    overflow_regression_test.dart [NEW Task2 helper + 各 Task 追加页面用例]
  （既有 256 个测试保持绿色；Task4/Task11 更新 features/ import 路径）
```

---

## Task 1: Tokens + 深色主题 + 5+2 Shell

**Files:**
- Create: `lib/ui/tokens.dart`
- Rewrite: `lib/app/theme.dart`
- Modify: `lib/app/app.dart`
- Create: `lib/ui/shell/shell_page.dart`
- Create: `lib/ui/components/app_bar_actions.dart`
- Delete: `lib/features/shell_page.dart`
- Modify: `lib/app/router.dart`（shell import）
- Modify: 9 个主页面 AppBar 加 `TerminalAppBarActions`（portfolio/holdings/accounts/markets/stats/alerts/settings/两个 calendar 页）
- Create: `test/ui/theme_test.dart`

**Steps:**

1. 写失败测试 `test/ui/theme_test.dart`：

```dart
import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/components/app_bar_actions.dart';
import 'package:asset_tracker/ui/shell/shell_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  test('dark theme uses terminal tokens', () {
    final t = AppTheme.dark();
    expect(t.scaffoldBackgroundColor, const Color(0xFF0A0C0F));
    expect(t.appBarTheme.backgroundColor, const Color(0xFF0A0C0F));
    expect(t.colorScheme.primary, const Color(0xFF58A6FF));
    expect(t.cardTheme.color, const Color(0xFF12151A));
  });

  Future<void> pumpShell(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = GoRouter(
      initialLocation: '/portfolio',
      routes: [
        ShellRoute(
          builder: (context, state, child) => ShellPage(child: child),
          routes: const [
            GoRoute(path: '/portfolio', builder: (_, __) => const Scaffold(body: Text('组合'))),
            GoRoute(path: '/holdings', builder: (_, __) => const Scaffold(body: Text('持仓'))),
            GoRoute(path: '/accounts', builder: (_, __) => const Scaffold(body: Text('账户'))),
            GoRoute(path: '/markets', builder: (_, __) => const Scaffold(body: Text('行情'))),
            GoRoute(path: '/stats', builder: (_, __) => const Scaffold(body: Text('统计'))),
            GoRoute(path: '/alerts', builder: (_, __) => const Scaffold(body: Text('提醒'))),
            GoRoute(path: '/settings', builder: (_, __) => const Scaffold(body: Text('设置'))),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp.router(routerConfig: router, theme: AppTheme.dark()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('phone shell shows 5 bottom destinations', (tester) async {
    await pumpShell(tester, const Size(360, 640));
    final bar = tester.widgetList<NavigationBar>(find.byType(NavigationBar)).single;
    expect(bar.destinations.map((d) => d.label), ['总览', '持仓', '账户', '行情', '统计']);
  });

  testWidgets('desktop shell shows 5 rail destinations', (tester) async {
    await pumpShell(tester, const Size(1400, 900));
    final rail = tester.widgetList<NavigationRail>(find.byType(NavigationRail)).single;
    expect(rail.destinations.map((d) => d.label), ['总览', '持仓', '账户', '行情', '统计']);
  });

  testWidgets('app bar actions show bell and gear', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(theme: AppTheme.dark(), home: TerminalAppBarActions()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });
}
```

2. 运行确认失败：`flutter test test/ui/theme_test.dart`（文件不存在，编译失败）。

3. 创建 `lib/ui/tokens.dart`：

```dart
import 'package:flutter/material.dart';

/// Terminal design tokens (dark only).
class T {
  T._();

  static const Color bg = Color(0xFF0A0C0F);
  static const Color surface = Color(0xFF12151A);
  static const Color surface2 = Color(0xFF1A1F26);
  static const Color border = Color(0xFF262B33);
  static const Color borderSoft = Color(0xFF1C2128);
  static const Color text1 = Color(0xFFE6EDF3);
  static const Color text2 = Color(0xFF8B949E);
  static const Color text3 = Color(0xFF545D68);
  static const Color up = Color(0xFFF85149);
  static const Color down = Color(0xFF3FB950);
  static const Color accent = Color(0xFF58A6FF);
  static const Color warning = Color(0xFFD29922);

  static const double rCard = 8;
  static const double rInput = 6;
  static const double rPill = 999;

  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;

  static TextStyle mono({
    double size = 14,
    Color? color,
    FontWeight weight = FontWeight.w400,
  }) =>
      TextStyle(
        fontSize: size,
        color: color ?? text1,
        fontWeight: weight,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static TextStyle label({double size = 11, Color? color}) => TextStyle(
        fontSize: size,
        color: color ?? text2,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.4,
      );

  /// Red for positive, green for negative (China convention).
  static Color changeColor(double value) => value >= 0 ? up : down;

  /// Heatmap fill for [value] within [min, max]; zero or degenerate range
  /// is transparent.
  static Color heat(double value, double min, double max) {
    if (value == 0 || max <= min) return Colors.transparent;
    final t = ((value - min) / (max - min)).clamp(0.0, 1.0);
    return (value >= 0 ? up : down).withValues(alpha: 0.12 + 0.55 * t);
  }
}
```

4. 重写 `lib/app/theme.dart`（整个文件替换）：

```dart
import 'package:flutter/material.dart';

import '../ui/tokens.dart';

class AppTheme {
  AppTheme._();

  static ThemeData dark() {
    final scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: T.accent,
      onPrimary: Colors.black,
      secondary: T.accent,
      onSecondary: Colors.black,
      surface: T.surface,
      onSurface: T.text1,
      error: T.up,
      onError: Colors.black,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: T.bg,
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: T.bg,
        foregroundColor: T.text1,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: T.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rCard),
          side: const BorderSide(color: T.border),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: T.surface,
        indicatorColor: T.surface2,
        iconTheme: WidgetStatePropertyAll(IconThemeData(color: T.text2)),
        labelTextStyle: WidgetStatePropertyAll(T.label(size: 11)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: T.surface,
        indicatorColor: T.surface2,
        iconTheme: WidgetStatePropertyAll(IconThemeData(color: T.text2)),
        labelTextStyle: WidgetStatePropertyAll(T.label(size: 11)),
      ),
      dividerTheme: const DividerThemeData(color: T.border, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: T.surface2,
        hintStyle: const TextStyle(color: T.text3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rInput),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rInput),
          borderSide: const BorderSide(color: T.accent),
        ),
      ),
      textTheme: TextTheme(
        headlineMedium: T.mono(size: 30, weight: FontWeight.w700),
        titleLarge: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: T.text1),
        titleMedium: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: T.text1),
        bodyMedium: const TextStyle(fontSize: 14, color: T.text1),
        bodySmall: const TextStyle(fontSize: 12, color: T.text2),
      ),
    );
  }
}

extension UpDownColor on BuildContext {
  Color upColor() => T.up;
  Color downColor() => T.down;
  Color changeColor(double value) => T.changeColor(value);
}
```

5. 修改 `lib/app/app.dart`：`theme: AppTheme.dark()`，删除 `darkTheme:` 与 `themeMode:` 参数。

6. 创建 `lib/ui/shell/shell_page.dart`：复制 `lib/features/shell_page.dart` 全部内容，仅改 `_destinations` 为前 5 项（总览/持仓/账户/行情/统计，path 不变：`/portfolio` `/holdings` `/accounts` `/markets` `/stats`），import 改为 `import '../../core/responsive.dart';`。

7. 创建 `lib/ui/components/app_bar_actions.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../tokens.dart';

/// Bell (alerts, with 24h unread badge) + gear (settings) for page AppBars.
class TerminalAppBarActions extends ConsumerWidget {
  const TerminalAppBarActions({super.key});

  @override
  Widget build(BuildContext ref, BuildContext context) {
    final events = ref.watch(alertEventsProvider).value ?? const [];
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final unread =
        events.where((e) => e.triggeredAt.isAfter(cutoff)).length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '提醒',
          icon: Badge(
            isLabelVisible: unread > 0,
            label: Text('$unread'),
            backgroundColor: T.up,
            child: const Icon(Icons.notifications_outlined, color: T.text2),
          ),
          onPressed: () => context.go('/alerts'),
        ),
        IconButton(
          tooltip: '设置',
          icon: const Icon(Icons.settings_outlined, color: T.text2),
          onPressed: () => context.go('/settings'),
        ),
      ],
    );
  }
}
```

8. 删除 `lib/features/shell_page.dart`；`lib/app/router.dart` 第 13 行 import 改为 `import '../ui/shell/shell_page.dart';`。

9. 全局替换 `AppColors.` → `T.`（39 处，`grep -n "AppColors" lib/` 逐一处理）：映射 `AppColors.primary`→`T.accent`、`AppColors.up`→`T.up`、`AppColors.down`→`T.down`、`AppColors.warning`→`T.warning`、`AppColors.background`→`T.bg`、`AppColors.card`→`T.surface`。涉及文件加 `import '../ui/tokens.dart';`（路径按文件位置调整）。`lib/app/theme.dart` 已重写不含 AppColors。

10. 9 个主页面 AppBar 的 `actions:` 列表头部加 `const TerminalAppBarActions(),`（各页面加 import `../ui/components/app_bar_actions.dart`，路径按位置调整）：
    - `lib/features/portfolio/portfolio_page.dart`
    - `lib/features/holdings/holdings_page.dart`
    - `lib/features/accounts/accounts_page.dart`
    - `lib/features/markets/markets_page.dart`
    - `lib/features/stats/stats_page.dart`
    - `lib/features/alerts/alerts_page.dart`
    - `lib/features/settings/settings_page.dart`
    - `lib/features/calendar/earnings_calendar_page.dart`
    - `lib/features/calendar/product_earnings_calendar_page.dart`

11. 运行：`flutter analyze lib test`（退出码必须 0）；`flutter test`（256 全绿）；`flutter test test/ui/theme_test.dart`。

12. Commit：`git add -A; git commit -m "feat(ui): terminal tokens, dark-only theme, 5+2 shell"`

---

## Task 2: 共享组件库

**Files:**
- Create: `lib/ui/components/terminal_card.dart`
- Create: `lib/ui/components/section_header.dart`
- Create: `lib/ui/components/kpi_grid.dart`
- Create: `lib/ui/components/delta_text.dart`
- Create: `lib/ui/components/data_row.dart`
- Create: `lib/ui/components/allocation_bars.dart`
- Create: `lib/ui/components/heat_cell.dart`
- Create: `lib/ui/components/quote_table.dart`
- Create: `lib/ui/components/empty_state.dart`
- Create: `lib/ui/components/form_fields.dart`
- Create: `lib/ui/components/sparkline.dart`
- Create: `test/ui/components_test.dart`
- Create: `test/ui/overflow_regression_test.dart`

**Steps:**

1. 写失败测试 `test/ui/components_test.dart`：

```dart
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/ui/components/allocation_bars.dart';
import 'package:asset_tracker/ui/components/delta_text.dart';
import 'package:asset_tracker/ui/components/heat_cell.dart';
import 'package:asset_tracker/ui/components/terminal_card.dart';
import 'package:asset_tracker/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('top5WithOther merges tail into 其他', () {
    final entries = List.generate(
      7,
      (i) => AllocationEntry(label: 'P$i', color: T.accent, value: (i + 1) * 100, pct: (i + 1) / 28),
    );
    final segs = AllocationBars.top5WithOther(entries);
    expect(segs, hasLength(6));
    expect(segs[5].label, '其他');
    expect(segs[5].pct, closeTo(entries[5].pct + entries[6].pct, 1e-9));
    expect(AllocationBars.top5WithOther(entries.sublist(0, 5)), hasLength(5));
  });

  testWidgets('HeatCell colors by sign and intensity', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SingleChildScrollView(child: HeatCell(value: 100, min: -50, max: 50))));
    var cell = tester.widget<Container>(find.descendant(of: find.byType(HeatCell), matching: find.byType(Container)).first);
    expect(cell.decoration!.color!.values.alpha, greaterThan(0));
    await tester.pumpWidget(const MaterialApp(home: SingleChildScrollView(child: HeatCell(value: -100, min: -50, max: 50))));
    cell = tester.widget<Container>(find.descendant(of: find.byType(HeatCell), matching: find.byType(Container)).first);
    expect(cell.decoration!.color!.values.alpha, greaterThan(0));
    await tester.pumpWidget(const MaterialApp(home: SingleChildScrollView(child: HeatCell(value: 0, min: -50, max: 50))));
    cell = tester.widget<Container>(find.descendant(of: find.byType(HeatCell), matching: find.byType(Container)).first);
    expect(cell.decoration!.color!.opacity, 0);
  });

  testWidgets('DeltaText uses red for positive', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DeltaText(value: 0.012)));
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.style!.color, T.up);
    expect(text.data, Formats.pct1(0.012));
  });

  testWidgets('TerminalCard renders bordered surface', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TerminalCard(child: Text('x'))));
    final container = tester.widget<Container>(
      find.descendant(of: find.byType(TerminalCard), matching: find.byType(Container)).first,
    );
    expect(container.decoration!.color, T.surface);
    expect(container.decoration!.border!.top.color, T.border);
  });
}
```

2. 运行确认失败：`flutter test test/ui/components_test.dart`。

3. 创建组件文件（全部照抄）：

`lib/ui/components/terminal_card.dart`：

```dart
import 'package:flutter/material.dart';

import '../tokens.dart';

class TerminalCard extends StatelessWidget {
  const TerminalCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(T.s3),
    this.margin = const EdgeInsets.only(bottom: T.s3),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: T.border),
      ),
      child: child,
    );
    if (onTap == null) return card;
    return InkWell(
      borderRadius: BorderRadius.circular(T.rCard),
      onTap: onTap,
      child: card,
    );
  }
}
```

`lib/ui/components/section_header.dart`：

```dart
import 'package:flutter/material.dart';

import '../tokens.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.label, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: T.s2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: T.label(size: 12, color: T.text2))),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Pinned section header for CustomScrollView pages.
class StickySectionHeader extends SliverPersistentHeaderDelegate {
  const StickySectionHeader({required this.label, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  double get maxExtent => 36;
  @override
  double get minExtent => 36;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) =>
      Container(color: T.bg, child: SectionHeader(label: label, trailing: trailing));

  @override
  bool shouldRebuild(covariant StickySectionHeader old) =>
      label != old.label || trailing != old.trailing;
}
```

`lib/ui/components/delta_text.dart`：

```dart
import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../tokens.dart';

class DeltaText extends StatelessWidget {
  const DeltaText({super.key, required this.value, this.text, this.size = 13});

  final double value;
  final String? text;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      text ?? Formats.pct1(value),
      style: T.mono(size: size, color: T.changeColor(value), weight: FontWeight.w600),
    );
  }
}
```

`lib/ui/components/kpi_grid.dart`：

```dart
import 'package:flutter/material.dart';

import '../../core/responsive.dart';
import '../tokens.dart';
import 'delta_text.dart';
import 'terminal_card.dart';

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.delta,
    this.color,
  });

  final String label;
  final String value;
  final double? delta;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return TerminalCard(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: T.label()),
          const SizedBox(height: T.s1),
          Text(value, style: T.mono(size: 20, weight: FontWeight.w600, color: color ?? T.text1)),
          if (delta != null) ...[
            const SizedBox(height: T.s1),
            DeltaText(value: delta!),
          ],
        ],
      ),
    );
  }
}

class KpiGrid extends StatelessWidget {
  const KpiGrid({super.key, required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    final columns = Responsive.isDesktop(context) ? 4 : 2;
    return GridView.count(
      crossAxisCount: columns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: T.s3,
      crossAxisSpacing: T.s3,
      childAspectRatio: 2.2,
      children: tiles,
    );
  }
}
```

（`TerminalCard` 已包含 `margin` 参数，默认 `EdgeInsets.only(bottom: T.s3)`；`StatTile` 传 `EdgeInsets.zero`。）

`lib/ui/components/data_row.dart`：

```dart
import 'package:flutter/material.dart';

import '../tokens.dart';

/// One list row: title/subtitle left, mono amount block right.
class DataRow extends StatelessWidget {
  const DataRow({
    super.key,
    required this.title,
    required this.trailing,
    this.subtitle,
    this.leading,
    this.onTap,
    this.showChevron = false,
  });

  final String title;
  final Widget? subtitle;
  final Widget trailing;
  final Widget? leading;
  final VoidCallback? onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: T.s2),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: T.s2)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14, color: T.text1)),
                if (subtitle != null) subtitle!,
              ],
            ),
          ),
          trailing,
          if (showChevron) const Icon(Icons.chevron_right, size: 18, color: T.text3),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}
```

`lib/ui/components/allocation_bars.dart`：

```dart
import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../tokens.dart';

class AllocationEntry {
  const AllocationEntry({
    required this.label,
    required this.color,
    required this.value,
    required this.pct,
  });

  final String label;
  final Color color;
  final double value;
  final double pct;
}

class AllocationBars extends StatelessWidget {
  const AllocationBars({
    super.key,
    required this.entries,
    this.onSelect,
    this.amountFormat,
  });

  final List<AllocationEntry> entries;
  final void Function(AllocationEntry)? onSelect;

  /// Amount text override (e.g. masked `****` when hideAmounts is on).
  final String Function(double)? amountFormat;

  /// Top 5 + merged 其他 (desktop stacked-bar segments).
  static List<AllocationEntry> top5WithOther(List<AllocationEntry> entries) {
    if (entries.length <= 5) return entries;
    final other = AllocationEntry(
      label: '其他',
      color: T.text3,
      value: entries.skip(5).fold(0.0, (a, e) => a + e.value),
      pct: entries.skip(5).fold(0.0, (a, e) => a + e.pct),
    );
    return [...entries.sublist(0, 5), other];
  }

  @override
  Widget build(BuildContext context) {
    return Responsive.isDesktop(context)
        ? _DesktopBars(entries: entries, onSelect: onSelect, amountFormat: amountFormat)
        : _BarList(entries: entries, onSelect: onSelect, amountFormat: amountFormat);
  }
}

class _BarList extends StatelessWidget {
  const _BarList({required this.entries, required this.onSelect, this.amountFormat});

  final List<AllocationEntry> entries;
  final void Function(AllocationEntry)? onSelect;
  final String Function(double)? amountFormat;

  @override
  Widget build(BuildContext context) {
    final fmt = amountFormat ?? Formats.amountCompact;
    return Column(
      children: [
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: T.s3),
            child: InkWell(
              onTap: onSelect == null ? null : () => onSelect!(e),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(e.label, style: const TextStyle(fontSize: 13, color: T.text1))),
                      Text(fmt(e.value), style: T.mono(size: 12, color: T.text2)),
                      const SizedBox(width: T.s2),
                      Text(Formats.pct1(e.pct), style: T.mono(size: 12, color: T.text2)),
                    ],
                  ),
                  const SizedBox(height: T.s1),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: e.pct.clamp(0.0, 1.0),
                      minHeight: 6,
                      backgroundColor: T.surface2,
                      valueColor: AlwaysStoppedAnimation(e.color),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _DesktopBars extends StatelessWidget {
  const _DesktopBars({
    required this.entries,
    required this.onSelect,
    this.amountFormat,
  });

  final List<AllocationEntry> entries;
  final void Function(AllocationEntry)? onSelect;
  final String Function(double)? amountFormat;

  @override
  Widget build(BuildContext context) {
    final segs = AllocationBars.top5WithOther(entries);
    return Column(
      children: [
        SizedBox(
          height: 22,
          child: Row(
            children: [
              for (var i = 0; i < segs.length; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(
                  flex: (segs[i].pct * 1000).round().clamp(1, 1 << 16),
                  child: Container(
                    decoration: BoxDecoration(
                      color: segs[i].color,
                      // Subtle top highlight (spec: 顶部微高光).
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.14),
                          Colors.white.withValues(alpha: 0.02),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    // Segments >= 10% show the pct inline (spec 5.1).
                    alignment: Alignment.center,
                    child: segs[i].pct >= 0.10
                        ? FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              Formats.pct1(segs[i].pct),
                              style: T.mono(size: 11, color: Colors.black.withValues(alpha: 0.75), weight: FontWeight.w700),
                            ),
                          )
                        : null,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: T.s3),
        Wrap(
          spacing: T.s4,
          runSpacing: T.s2,
          children: [
            for (final e in segs)
              InkWell(
                onTap: onSelect == null ? null : () => onSelect!(e),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: e.color, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: T.s1),
                    Text(e.label, style: const TextStyle(fontSize: 12, color: T.text2)),
                    const SizedBox(width: T.s1),
                    Text(Formats.pct1(e.pct), style: T.mono(size: 12, color: T.text1)),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
```

`lib/ui/components/heat_cell.dart`：

```dart
import 'package:flutter/material.dart';

import '../tokens.dart';

/// Calendar heatmap cell. [label] null/empty renders a pure color dot.
class HeatCell extends StatelessWidget {
  const HeatCell({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    this.label,
    this.child,
    this.labelSize = 10,
    this.onTap,
    this.width,
    this.height = 34,
  });

  final double value;
  final double min;
  final double max;
  final String? label;
  /// Custom content (e.g. day number + profit); overrides [label].
  final Widget? child;
  final double labelSize;
  final VoidCallback? onTap;
  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cell = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: T.heat(value, min, max),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: T.borderSoft),
      ),
      alignment: Alignment.center,
      child: child ??
          (label == null || label!.isEmpty
              ? null
              : Text(label!, style: T.mono(size: labelSize, color: T.changeColor(value), weight: FontWeight.w600))),
    );
    if (onTap == null) return cell;
    return InkWell(borderRadius: BorderRadius.circular(4), onTap: onTap, child: cell);
  }
}
```

`lib/ui/components/quote_table.dart`：

```dart
import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../tokens.dart';
import 'data_row.dart';
import 'delta_text.dart';
import 'section_header.dart';
import 'terminal_card.dart';

class QuoteRow {
  const QuoteRow({
    required this.code,
    required this.name,
    required this.price,
    required this.change,
    required this.changePct,
    this.unit,
    this.fxSymbol,
  });

  final String code;
  final String name;
  final double price;
  final double change;
  final double changePct;
  final String? unit;
  final String? fxSymbol;
}

class QuoteTable extends StatelessWidget {
  const QuoteTable({
    super.key,
    required this.group,
    required this.rows,
    this.onQuoteTap,
  });

  final String group;
  final List<QuoteRow> rows;
  final void Function(QuoteRow)? onQuoteTap;

  @override
  Widget build(BuildContext context) {
    return TerminalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(label: group),
          for (final r in rows)
            DataRow(
              title: r.name,
              subtitle: Text(
                r.fxSymbol ?? r.code,
                style: T.mono(size: 11, color: T.text3),
              ),
              trailing: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    r.fxSymbol != null
                        ? r.price.toStringAsFixed(4)
                        : Formats.num(r.price),
                    style: T.mono(size: 14),
                  ),
                  DeltaText(
                    value: r.changePct,
                    text: '${r.changePct >= 0 ? '+' : ''}${Formats.pct1(r.changePct)}',
                  ),
                ],
              ),
              onTap: onQuoteTap == null ? null : () => onQuoteTap!(r),
            ),
        ],
      ),
    );
  }
}
```

`lib/ui/components/empty_state.dart`：

```dart
import 'package:flutter/material.dart';

import '../tokens.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(T.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox_outlined, size: 40, color: T.text3),
            const SizedBox(height: T.s3),
            Text(message, style: const TextStyle(color: T.text2, fontSize: 14)),
            if (action != null) ...[const SizedBox(height: T.s3), action!],
          ],
        ),
      ),
    );
  }
}
```

`lib/ui/components/form_fields.dart`：

```dart
import 'package:flutter/material.dart';

import '../tokens.dart';

InputDecoration terminalDecoration(String label, {String? hint, Widget? suffix}) =>
    InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: T.text2),
      floatingLabelStyle: const TextStyle(color: T.text2),
      hint: hint,
      hintStyle: TextStyle(color: T.text3),
      suffix: suffix,
    );

class TerminalTextField extends StatelessWidget {
  const TerminalTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.keyboardType,
    this.suffix,
    this.onChanged,
    this.obscureText = false,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType? keyboardType;
  final Widget? suffix;
  final ValueChanged<String>? onChanged;
  final bool obscureText;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      maxLines: maxLines,
      keyboardType: keyboardType,
      onChanged: onChanged,
      style: T.mono(),
      decoration: terminalDecoration(label, hint: hint, suffix: suffix),
    );
  }
}
```

`lib/ui/components/sparkline.dart`：

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens.dart';

class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.color,
    this.width = 72,
    this.height = 24,
  });

  final List<double> values;
  final Color? color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(width, height),
        painter: _SparklinePainter(values, color ?? T.accent),
      );
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var min = values.reduce(math.min);
    var max = values.reduce(math.max);
    final span = max - min == 0 ? 1.0 : max - min;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final y = size.height - (values[i] - min) / span * (size.height - 4) - 2;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, Paint()
      ..strokeColor = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values || old.color != color;
}
```

4. 创建 `test/ui/overflow_regression_test.dart`（helper，Task 3+ 每页追加用例）：

```dart
import 'dart:async';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps [page] at a fixed logical size with an in-memory DB and bounded
/// pumps (no pumpAndSettle: pages may run repeating animations).
Future<void> pumpPage(
  WidgetTester tester,
  Widget page,
  Size size, {
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      historySyncProvider.overrideWithValue(const AsyncData(null)),
      ...overrides,
    ],
  );
  addTearDown(() async {
    container.dispose();
    await db.close();
  });

  await tester.pumpWidget(
    ProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

/// Fails if a RenderFlex overflow was reported during the last pumps.
void expectNoOverflow(WidgetTester tester) {
  final e = tester.takeException();
  expect(e, isNull, reason: 'RenderFlex overflow');
}

void main() {
  testWidgets('smoke: empty scaffold', (tester) async {
    await pumpPage(tester, const Scaffold(body: Text('x')), const Size(360, 640));
    expectNoOverflow(tester);
  });
}
```

5. 运行：`flutter test test/ui/components_test.dart test/ui/overflow_regression_test.dart` 全绿；`flutter analyze lib test` 退出码 0；`flutter test` 256 全绿。

6. Commit：`git add -A; git commit -m "feat(ui): shared terminal component library"`

---

## Task 3: 总览页（含净值趋势图升级）

**Files:**
- Create: `lib/ui/pages/portfolio/portfolio_page.dart`
- Create: `lib/ui/pages/portfolio/portfolio_widgets.dart`
- Create: `lib/ui/pages/portfolio/day_detail_sheet.dart`
- Delete: `lib/features/portfolio/`（3 个文件）
- Modify: `lib/app/router.dart`（portfolio import → `../ui/pages/portfolio/portfolio_page.dart`）
- Modify: `lib/features/calendar/earnings_calendar_page.dart`（day_detail_sheet import → `../../ui/pages/portfolio/day_detail_sheet.dart`）
- Modify: `test/ui/overflow_regression_test.dart`（追加用例 + imports）

**Steps:**

1. 在 `test/ui/overflow_regression_test.dart` 追加（imports 加 `asset_tracker/ui/pages/portfolio/portfolio_page.dart`、`asset_tracker/domain/portfolio_calculator.dart`、`asset_tracker/core/enums.dart`）：

```dart
testWidgets('portfolio no overflow at phone and desktop', (tester) async {
  final now = DateTime(2026, 8, 27);
  final snaps = List.generate(
    30,
    (i) => SnapshotRow(
      date: now.subtract(Duration(days: 29 - i)).toIso8601String().substring(0, 10),
      currency: 'CNY',
      totalValue: 100000 + i * 500,
      totalCost: 90000,
      liabilities: 10000,
      createdAt: now,
    ),
  );
  const holding = HoldingRow(
    id: 1,
    accountId: 1,
    name: '现金',
    assetType: 'savings',
    marketSource: 'manual',
    quantity: 100,
    costPrice: 900,
    latestPrice: 1000,
    currency: 'CNY',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
  const summary = PortfolioSummary(
    totalAssets: 100000,
    totalLiabilities: 10000,
    totalCost: 90000,
    todayChange: 500,
    todayChangePct: 0.005,
    breakdown: [
      TypeBreakdown(type: AssetType.cash, marketValue: 100000, cost: 90000),
    ],
  );
  final overrides = <Override>[
    summaryProvider.overrideWithValue(const AsyncData(summary)),
    holdingsProvider.overrideWithValue(Stream.value([holding])),
    snapshotsProvider.overrideWithValue(Stream.value(snaps)),
  ];
  await pumpPage(tester, const PortfolioPage(), const Size(360, 640), overrides: overrides);
  expectNoOverflow(tester);
  await pumpPage(tester, const PortfolioPage(), const Size(1280, 800), overrides: overrides);
  expectNoOverflow(tester);
});
```

2. 运行确认失败：`flutter test test/ui/overflow_regression_test.dart`（import 不存在）。

3. 创建 `lib/ui/pages/portfolio/portfolio_page.dart`。骨架（`summaryProvider` 函数体、`_refreshPrices`、historySync listen 与旧 `_summaryProvider`/`_PortfolioPageState` 逐行相同，仅 `_summaryProvider` → `summaryProvider`）：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../domain/portfolio_calculator.dart';
import '../../../services/history_backfill_service.dart';
import '../../../services/market/market_service.dart';
import '../../components/app_bar_actions.dart';
import '../../components/empty_state.dart';
import '../../components/kpi_grid.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';
import 'portfolio_widgets.dart';

final summaryProvider = FutureProvider<PortfolioSummary>((ref) async {
  // …与旧 _summaryProvider 完全相同…
});

class PortfolioPage extends ConsumerStatefulWidget {
  const PortfolioPage({super.key});

  @override
  ConsumerState<PortfolioPage> createState() => _PortfolioPageState();
}

class _PortfolioPageState extends ConsumerState<PortfolioPage> {
  final _refreshing = ValueNotifier<bool>(false);

  // initState / dispose / _refreshPrices：与旧实现相同（_refreshing + marketService + ensureTodaySnapshot + cnyRates invalidate）

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(summaryProvider);
    final holdings = ref.watch(holdingsProvider);
    ref.watch(historySyncProvider);
    ref.listen<AsyncValue<BackfillResult?>>(historySyncProvider, (prev, next) {
      // 与旧实现相同
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('总览'),
        actions: [
          const TerminalAppBarActions(),
          // 隐藏金额 toggle + 刷新按钮：与旧实现相同（图标色用 T.text2）
        ],
      ),
      body: holdings.when(
        data: (list) => list.isEmpty
            ? const EmptyState(message: '还没有持仓数据\n去"持仓"页添加你的第一笔资产吧')
            : ResponsiveShell(
                child: summary.when(
                  data: (s) => ListView(
                    padding: const EdgeInsets.all(T.s3),
                    children: [
                      _KpiRow(summary: s),
                      const SizedBox(height: T.s3),
                      if (Responsive.isPhone(context)) ...[
                        NetWorthChart(),
                        const SizedBox(height: T.s3),
                        AllocationCard(summary: s),
                      ] else ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 2, child: NetWorthChart()),
                            const SizedBox(width: T.s3),
                            Expanded(flex: 1, child: AllocationCard(summary: s)),
                          ],
                        ),
                        const SizedBox(height: T.s3),
                      ],
                      _CalendarEntries(),
                    ],
                  ),
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('计算失败: $e')),
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }
}

class _KpiRow extends ConsumerWidget {
  const _KpiRow({required this.summary});

  final PortfolioSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(hideAmountsProvider);
    String amount(double v) => hidden ? Formats.masked() : Formats.amount(v);
    final todayEarning = ref.watch(todayEarningProvider);
    final todayProfit = todayEarning?.profit ?? 0.0;
    return KpiGrid(
      tiles: [
        StatTile(label: '总资产', value: amount(summary.totalAssets)),
        StatTile(label: '总负债', value: amount(summary.totalLiabilities), color: T.text2),
        StatTile(label: '净资产', value: amount(summary.netWorth), delta: todayEarning?.pct),
        StatTile(
          label: '今日盈亏',
          value: '${todayProfit >= 0 ? '+' : ''}${amount(todayProfit)}',
          color: T.changeColor(todayProfit),
        ),
      ],
    );
  }
}

class _CalendarEntries extends StatelessWidget {
  const _CalendarEntries();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _EntryTile(
            icon: Icons.calendar_month_outlined,
            label: '收益日历',
            onTap: () => context.go('/earnings-calendar'),
          ),
        ),
        const SizedBox(width: T.s3),
        Expanded(
          child: _EntryTile(
            icon: Icons.table_chart_outlined,
            label: '产品收益日历',
            onTap: () => context.go('/product-earnings'),
          ),
        ),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TerminalCard(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: T.accent),
          const SizedBox(width: T.s2),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14, color: T.text1))),
          const Icon(Icons.chevron_right, size: 18, color: T.text3),
        ],
      ),
    );
  }
}
```

4. 创建 `lib/ui/pages/portfolio/portfolio_widgets.dart`。文件头 imports 至少包含：`package:flutter/material.dart`、`package:flutter_riverpod/flutter_riverpod.dart`、`package:go_router/go_router.dart`、`package:fl_chart/fl_chart.dart`、`../../../core/formats.dart`、`../../../core/responsive.dart`、`../../../data/database.dart`、`../../../domain/portfolio_calculator.dart`、`../../components/allocation_bars.dart`、`../../components/section_header.dart`、`../../components/terminal_card.dart`、`../../tokens.dart`，以及旧 `portfolio_widgets.dart` 中 benchmark/downsample 所需的 imports。规则：

    a. **AllocationCard 重写**（类型维度，spec 5.1；风险维度移除）：

```dart
class AllocationCard extends ConsumerWidget {
  const AllocationCard({super.key, required this.summary});

  final PortfolioSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(hideAmountsProvider);
    final breakdown = summary.breakdown.where((b) => b.marketValue > 0).toList()
      ..sort((a, b) => b.marketValue.compareTo(a.marketValue));
    if (breakdown.isEmpty) {
      return const TerminalCard(
        child: Text('暂无资产配置数据', style: TextStyle(color: T.text3)),
      );
    }
    final total = summary.totalAssets;
    final entries = [
      for (final b in breakdown)
        AllocationEntry(
          label: b.type.label,
          color: HSLColor.fromColor(b.type.color).lighten(0.1).color,
          value: b.marketValue,
          pct: total == 0 ? 0 : b.marketValue / total,
        ),
    ];
    return TerminalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(label: '资产配置'),
          AllocationBars(
            entries: entries,
            amountFormat: hidden ? (_) => Formats.masked() : null,
            onSelect: (e) => context.go('/holdings', extra: e.label),
          ),
        ],
      ),
    );
  }
}
```

   b. **NetWorthChart**：保留旧类全部逻辑（`_range`/`RangeOption`/`_view`/`_benchSelected`/`_benchData`/`_showBenchmarkPanel`/`_showRangeMenu`/`_customFrom`/`_customTo`/stats 行/`_showDayDetail`），仅改：
      - 外层 `Card(color: Colors.transparent, child: Padding(...))` → `TerminalCard(padding: const EdgeInsets.fromLTRB(T.s3, T.s2, T.s3, T.s3), child: ...)`
      - `_NetWorthToolbar` 的 `calendar` 参数与两个日历 IconButton 删除（入口已移到页面底部 tile），toolbar 只剩 title + trailing
      - 所有 `Theme.of(context).textTheme.*` → `T.mono`/`T.label`/`T.text*`；`AppColors.up`（图例"资产"）→ `T.accent`
      - 空数据文案样式 → `TextStyle(color: T.text3)`

    c. **_TrendChart 升级**（保留点计算段：`final color = ...` 到 `final benchSeries = ...` 不动，仅按以下修改；fl_chart 1.2.0 没有 `FlCrosshairData`，十字线和端点脉冲用 plot-area overlay 自绘）：
       - `final color = AppColors.up;` → `final color = T.accent;`
       - `_TrendChart` 由 StatelessWidget 改 StatefulWidget，并加 `SingleTickerProviderStateMixin`：

```dart
class _TrendChart extends StatefulWidget {
  const _TrendChart({
    required this.list,
    required this.view,
    required this.rates,
    required this.hideAmounts,
    this.benchmarks = const {},
    this.onDayTap,
  });

  // 原字段保持不变。
  @override
  State<_TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<_TrendChart> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();
  final _hoverIndex = ValueNotifier<int?>(null);

  @override
  void dispose() {
    _pulse.dispose();
    _hoverIndex.dispose();
    super.dispose();
  }

  // 原 build 移入 State，并在 build 开头保留局部别名：
  // final list = widget.list;
  // final view = widget.view;
  // final rates = widget.rates;
  // final hideAmounts = widget.hideAmounts;
  // 这样后续代码片段中的 `list` / `view` / `rates` / `hideAmounts` 可直接使用。
}
```

       - `gridData.getDrawingHorizontalLine` 改为 `FlLine(color: T.borderSoft, strokeWidth: 1, dashArray: const [4, 4])`
       - `leftTitles`/`bottomTitles` 的 `getTitlesWidget` 样式 → `T.mono(size: 10, color: T.text3)`
       - `touchTooltipData`：`getTooltipColor: (_) => T.surface2`；`tooltipBorder: const BorderSide(color: T.border)`；`getTooltipItems` 改为：

```dart
getTooltipItems: (spots) {
  final items = <LineTooltipItem>[
    for (final spot in spots)
      LineTooltipItem(
        '${Formats.date(DateTime.parse(list[spot.x.toInt()].date))}\n${tooltipText(spot.y)}',
        T.mono(size: 12, color: T.text1, weight: FontWeight.w600),
      ),
  ];
  if (spots.isNotEmpty) {
    final i = spots.first.x.toInt();
    if (i > 0 && i < list.length) {
      final delta = list[i].totalValue - list[i - 1].totalValue;
      items.add(
        LineTooltipItem(
          '较前日 ${hideAmounts ? Formats.masked() : '${delta >= 0 ? '+' : ''}${Formats.money(delta)}'}',
          T.mono(size: 11, color: T.changeColor(delta), weight: FontWeight.w600),
        ),
      );
    }
  }
  return items;
},
```

       - `touchCallback` 改为同时维护 hover 索引和原 tap 行为：

```dart
touchCallback: (event, response) {
  final spots = response?.lineBarSpots;
  final idx = (spots != null && spots.isNotEmpty) ? spots.first.x.toInt() : null;
  if (idx != null && idx >= 0 && idx < list.length) {
    _hoverIndex.value = idx;
  } else if (event is FlPanEndEvent ||
      event is FlPanCancelEvent ||
      event is FlPointerExitEvent ||
      event is FlTapCancelEvent) {
    _hoverIndex.value = null;
  }

  if (event is FlTapUpEvent && response != null) {
    final tapped = response.lineBarSpots;
    if (tapped != null && tapped.isNotEmpty) {
      final i = tapped.first.x.toInt();
      if (i >= 0 && i < list.length) onDayTap?.call(list[i].date);
    }
  }
},
```

       - `lineBarsData` 首位插入辉光层（主 bar 之下）：

```dart
LineChartBarData(
  spots: points,
  isCurved: !dense,
  curveSmoothness: 0.25,
  color: color.withValues(alpha: 0.12),
  barWidth: 6,
  dotData: const FlDotData(show: false),
),
```

       - 主 bar 保持 `dotData: const FlDotData(show: false)`；端点脉冲改由 overlay 绘制。
       - 将原来的 `SizedBox(height: ..., child: LineChart(...))` 改为 plot-area overlay 结构（`LineChart` 本体不包在 pulse `AnimatedBuilder` 里，避免整图每帧重建）：

```dart
final chartHeight = Responsive.isPhone(context) ? 280.0 : 240.0;
const plotLeft = 48.0;
const plotBottom = 28.0;
final plotSize = Size(
  (constraints.maxWidth - plotLeft).clamp(0.0, double.infinity),
  (chartHeight - plotBottom).clamp(0.0, double.infinity),
);
final isRate = view == _TrendView.returnRate;
final rateBase = isRate && rates.isNotEmpty ? rates.first : 0.0;
final lastValue = isRate
    ? (rates.isEmpty ? 0.0 : rates.last - rateBase)
    : list.last.totalValue;

return SizedBox(
  height: chartHeight,
  child: Stack(
    children: [
      LineChart(/* 上面的 LineChartData */),
      if (points.isNotEmpty)
        Positioned(
          left: plotLeft,
          top: 0,
          width: plotSize.width,
          height: plotSize.height,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: Listenable.merge([_pulse, _hoverIndex]),
              builder: (context, _) => CustomPaint(
                size: plotSize,
                painter: _TrendOverlayPainter(
                  hoverIndex: _hoverIndex.value,
                  pulse: _pulse.value,
                  list: list,
                  view: view,
                  rates: rates,
                  axisMin: axisMin,
                  axisMax: axisMax,
                  firstX: points.first.x,
                  xSpan: points.last.x - points.first.x,
                  lastX: points.last.x,
                  lastValue: lastValue,
                ),
              ),
            ),
          ),
        ),
    ],
  ),
);
```

       - 新增 `_TrendOverlayPainter`（同文件内私有类）：

```dart
class _TrendOverlayPainter extends CustomPainter {
  const _TrendOverlayPainter({
    required this.hoverIndex,
    required this.pulse,
    required this.list,
    required this.view,
    required this.rates,
    required this.axisMin,
    required this.axisMax,
    required this.firstX,
    required this.xSpan,
    required this.lastX,
    required this.lastValue,
  });

  final int? hoverIndex;
  final double pulse;
  final List<SnapshotRow> list;
  final _TrendView view;
  final List<double> rates;
  final double axisMin;
  final double axisMax;
  final double firstX;
  final double xSpan;
  final double lastX;
  final double lastValue;

  @override
  void paint(Canvas canvas, Size size) {
    final ySpan = axisMax - axisMin;
    if (ySpan == 0 || xSpan <= 0) return;

    double xOf(double x) => ((x - firstX) / xSpan).clamp(0.0, 1.0) * size.width;
    double yOf(double value) =>
        (1 - (value - axisMin) / ySpan).clamp(0.0, 1.0) * size.height;

    final lastPoint = Offset(xOf(lastX), yOf(lastValue));
    canvas.drawCircle(
      lastPoint,
      3,
      Paint()..color = T.accent.withValues(alpha: 0.9),
    );
    canvas.drawCircle(
      lastPoint,
      5 + 4 * pulse,
      Paint()..color = T.accent.withValues(alpha: 0.35 * (1 - pulse)),
    );

    final idx = hoverIndex;
    if (idx == null || idx < 0 || idx >= list.length) return;
    final isRate = view == _TrendView.returnRate;
    final rateBase = isRate && rates.isNotEmpty ? rates.first : 0.0;
    final value = isRate ? rates[idx] - rateBase : list[idx].totalValue;

    final paint = Paint()
      ..color = T.text3.withValues(alpha: 0.5)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final x = xOf(idx.toDouble());
    final y = yOf(value);
    _dashedLine(canvas, Offset(0, y), Offset(size.width, y), paint);
    _dashedLine(canvas, Offset(x, 0), Offset(x, size.height), paint);
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    final delta = b - a;
    final dist = delta.distance;
    if (dist == 0) return;
    final dir = Offset(delta.dx / dist, delta.dy / dist);
    const dash = 4.0;
    const gap = 4.0;
    for (var t = 0.0; t < dist; t += dash + gap) {
      final end = (t + dash).clamp(0.0, dist);
      canvas.drawLine(a + dir * t, a + dir * end, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TrendOverlayPainter old) =>
      old.hoverIndex != hoverIndex ||
      old.pulse != pulse ||
      old.list != list ||
      old.view != view ||
      old.rates != rates ||
      old.axisMin != axisMin ||
      old.axisMax != axisMax ||
      old.firstX != firstX ||
      old.xSpan != xSpan ||
      old.lastX != lastX ||
      old.lastValue != lastValue;
}
```

       - `_LegendDot` 的 `AppColors.up` → `T.accent`；文字样式 → `T.mono(size: 11, color: T.text2)`

5. 创建 `lib/ui/pages/portfolio/day_detail_sheet.dart`：整体复制旧文件，改 import 路径（`../../../app/...`、`../../../core/...`、`../../../domain/holding_details.dart`），样式替换：`Theme.of(context).textTheme.titleMedium` → `const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: T.text1)`；`bodySmall` → `T.mono(size: 12, color: T.text2)`；`bodyMedium`（名称）→ `const TextStyle(fontSize: 14, color: T.text1)`；金额行 → `T.mono(size: 14, weight: FontWeight.w600, color: changeCny == null ? T.text3 : T.changeColor(changeCny))`；`Divider` → `Divider(color: T.border, height: 16)`；加 `import '../../tokens.dart';`。`dayDetailProvider` 保持公开（earnings calendar 也 import 此文件）。

6. 删除 `lib/features/portfolio/` 整个目录。

7. 更新 `lib/app/router.dart`：`import '../features/portfolio/portfolio_page.dart';` → `import '../ui/pages/portfolio/portfolio_page.dart';`。更新 `lib/features/calendar/earnings_calendar_page.dart` 第 9 行：`import '../portfolio/day_detail_sheet.dart';` → `import '../../ui/pages/portfolio/day_detail_sheet.dart';`。

8. 运行：`flutter analyze lib test`（退出码 0）；`flutter test`（256 + 新用例全绿）。

9. Commit：`git add -A; git commit -m "feat(ui): portfolio page with terminal KPIs and upgraded trend chart"`

---

## Task 4: 持仓页（拆分 + 表格化）

**Files:**
- Create: `lib/ui/pages/holdings/holdings_page.dart`
- Create: `lib/ui/pages/holdings/holdings_table.dart`
- Create: `lib/ui/pages/holdings/holding_detail_sheet.dart`
- Create: `lib/ui/pages/holdings/holding_dialogs.dart`
- Create: `lib/ui/pages/holdings/invested_profit_field.dart`
- Create: `lib/ui/pages/holdings/purchase_date_field.dart`
- Create: `lib/ui/pages/transaction_dialogs.dart`（自 `lib/features/transactions/transaction_dialogs.dart` 移入，供 holdings + accounts 共用）
- Delete: `lib/features/holdings/`（4 文件）、`lib/features/transactions/`
- Modify: `lib/app/router.dart`（holdings import + builder 传 `initialQuery`）
- Modify: `test/add_holding_flow_test.dart`、`test/invested_profit_field_test.dart`、`test/invested_profit_edit_test.dart`、`test/today_profit_test.dart`（import 路径）
- Modify: `test/ui/overflow_regression_test.dart`（追加用例）

**拆分映射（行为不变，先拆后改样式）：**

| 旧 `lib/features/holdings/holdings_page.dart` 内容 | 新位置 |
|---|---|
| `_refreshingProvider`、`HoldingSort`、`_holdingMarketValue`、`todayProfitOf`、`todayChangePctOf`、`assetTotalOf`、`liabilityTotalOf`、`_editFxRateValue`（顶层纯函数） | `ui/pages/holdings/holdings_page.dart`（保持顶层，`today_profit_test` 依赖） |
| `HoldingsPage` + `_HoldingsPageState`（build 重写；`_section` 类型来自 `holdings_table.dart` 的 `HoldingSection`） | `ui/pages/holdings/holdings_page.dart` |
| `HoldingSection`（原 `_HoldingSection` 公开化）+ `HoldingsTable` | `ui/pages/holdings/holdings_table.dart` |
| `_showAddHoldingDialog`（317–681 行）+ 其私有 helper | `ui/pages/holdings/holding_dialogs.dart`（改公开 `showAddHoldingDialog`） |
| `_HoldingCard`（736–1314）、`_HoldingDetailSheet`（1316–1436）、`_InfoRow`、`_TransactionTile`（1471–1568） | `ui/pages/holdings/holding_detail_sheet.dart`（sheet + InfoRow + TransactionTile）；`_HoldingCard` 拆为 `holdings_table.dart` 中的行 widget |
| `_SectionHeader`、`_EmptyHoldings` | `holdings_page.dart`（用 `SectionHeader`/`EmptyState` 替代） |
| `invested_profit_field.dart`、`purchase_date_field.dart` | 原样移入 `ui/pages/holdings/`，样式改 T tokens |
| `lib/features/transactions/transaction_dialogs.dart` | `ui/pages/transaction_dialogs.dart`，样式改 T tokens |

**Steps:**

1. 追加溢出回归测试（imports 加 `ui/pages/holdings/holdings_page.dart`）：

```dart
testWidgets('holdings no overflow at phone and desktop', (tester) async {
  final now = DateTime(2026, 8, 27);
  const a = HoldingRow(
    id: 1, accountId: 1, name: '现金', assetType: 'savings', marketSource: 'manual',
    quantity: 100, costPrice: 900, latestPrice: 1000, currency: 'CNY',
    createdAt: DateTime(2026, 1, 1), updatedAt: DateTime(2026, 1, 1),
  );
  const b = HoldingRow(
    id: 2, accountId: 1, name: '某股票', assetType: 'stock', marketSource: 'manual',
    symbol: '600000', quantity: 1000, costPrice: 10, latestPrice: 12, currency: 'CNY',
    createdAt: DateTime(2026, 1, 1), updatedAt: DateTime(2026, 1, 1),
  );
  const c = HoldingRow(
    id: 3, accountId: 1, name: '信用卡', assetType: 'liability', marketSource: 'manual',
    quantity: 5000, costPrice: 0, latestPrice: 0, currency: 'CNY',
    createdAt: DateTime(2026, 1, 1), updatedAt: DateTime(2026, 1, 1),
  );
  final overrides = <Override>[
    holdingsProvider.overrideWithValue(Stream.value([a, b, c])),
  ];
  await pumpPage(tester, const HoldingsPage(), const Size(360, 640), overrides: overrides);
  expectNoOverflow(tester);
  await pumpPage(tester, const HoldingsPage(), const Size(1280, 800), overrides: overrides);
  expectNoOverflow(tester);
});
```

2. 运行确认失败：`flutter test test/ui/overflow_regression_test.dart`。

3. 按拆分映射移动代码（先纯移动 + import 修正，analyze 绿后再改样式）。`holdings_page.dart` 关键改动：

   a. `HoldingsPage` 增加 `initialQuery` 参数（总览 Allocation 下钻用）：

```dart
class HoldingsPage extends ConsumerStatefulWidget {
  const HoldingsPage({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  ConsumerState<HoldingsPage> createState() => _HoldingsPageState();
}
```

   `_HoldingsPageState.initState` 中：`if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) { _query = widget.initialQuery!; _searchCtrl.text = _query; _searching = true; }`

   b. **build 重写**（spec 6.2）：保留 AppBar（搜索/排序/刷新 + `TerminalAppBarActions`）与 FAB；body 数据分支改为：

```dart
return ResponsiveShell(
  child: Responsive.isDesktop(context)
      ? HoldingsTable(
          section: _section,
          assets: assets,
          liabilities: liabilities,
          rates: rates,
          onHoldingTap: (h) => showHoldingDetailSheet(context, ref, h),
        )
      : ListView(
          padding: const EdgeInsets.all(T.s3),
          children: [
            SegmentedButton<HoldingSection>(
              segments: const [
                ButtonSegment(value: HoldingSection.assets, label: Text('资产')),
                ButtonSegment(value: HoldingSection.liabilities, label: Text('负债')),
              ],
              selected: {_section},
              onSelectionChanged: (s) => setState(() => _section = s.first),
              showSelectedIcon: false,
            ),
            const SizedBox(height: T.s3),
            if (isAssets) ...[
              SectionHeader(label: '资产', trailing: Text(Formats.amount(assetTotalOf(assets, rates)), style: T.mono(size: 13, weight: FontWeight.w600))),
              if (assets.isEmpty)
                const EmptyState(message: '暂无资产')
              else
                for (final h in assets)
                  _HoldingRowCard(holding: h, onTap: () => showHoldingDetailSheet(context, ref, h)),
            ] else ...[
              SectionHeader(label: '负债', trailing: Text(Formats.amount(liabilityTotalOf(liabilities, rates)), style: T.mono(size: 13, weight: FontWeight.w600, color: T.down))),
              if (liabilities.isEmpty)
                const EmptyState(message: '暂无负债')
              else
                for (final h in liabilities)
                  _HoldingRowCard(holding: h, onTap: () => showHoldingDetailSheet(context, ref, h)),
            ],
          ],
        ),
);
```

   c. `_HoldingRowCard`（手机 DataRow 卡片，放 `holdings_page.dart`）：`TerminalCard` 内 `DataRow`——title=名称（+ 类型 icon leading），subtitle=代码/类型 label，trailing=Column[市值 `T.mono(14)` + `DeltaText`（今日盈亏，`todayProfitOf(priceCache, quantity)` 为 null 时显示 `--`）]；`showChevron: true`。

    d. `holdings_table.dart`（桌面表格，spec 6.2）：文件头 imports 至少包含 `package:flutter/material.dart`、`package:flutter_riverpod/flutter_riverpod.dart`、`../../../app/providers.dart`、`../../../core/enums.dart`、`../../../core/formats.dart`、`../../../data/database.dart`、`../../components/delta_text.dart`、`../../components/empty_state.dart`、`../../tokens.dart`。

```dart
enum HoldingSection { assets, liabilities }

class HoldingsTable extends ConsumerWidget {
  const HoldingsTable({
    required this.section,
    required this.assets,
    required this.liabilities,
    required this.rates,
    required this.onHoldingTap,
  });

  final HoldingSection section;
  final List<HoldingRow> assets;
  final List<HoldingRow> liabilities;
  final Map<String, double> rates;
  final void Function(HoldingRow) onHoldingTap;

  static const _cols = ['名称', '代码', '数量', '成本', '最新', '盈亏 / 收益率'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = section == HoldingSection.assets ? assets : liabilities;
    if (list.isEmpty) {
      return const EmptyState(message: '暂无数据');
    }
    return CustomScrollView(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _TableHeaderDelegate(),
        ),
        SliverToBoxAdapter(
          child: Column(
            children: [
              for (final h in list) _TableRow(h: h, onHoldingTap: onHoldingTap),
            ],
          ),
        ),
      ],
    );
  }
}

class _TableHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _TableHeaderDelegate();

  @override
  double get maxExtent => 40;
  @override
  double get minExtent => 40;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: T.surface2,
      padding: const EdgeInsets.symmetric(horizontal: T.s3),
      child: Row(
        children: [
          for (final c in HoldingsTable._cols)
            Expanded(
              flex: c == '名称' ? 3 : (c == '盈亏 / 收益率' ? 3 : 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(c, style: T.label(size: 11, color: T.text2)),
              ),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TableHeaderDelegate old) => false;
}
```

   `_TableRow`：`InkWell` + `Container(height: 44, decoration: 底部 1px T.borderSoft 分隔线)` + `Row`，列与表头同 flex：名称（14px text1 + 类型 icon）、代码（`T.mono(12, T.text3)`）、数量/成本/最新（`T.mono(13)` 右对齐）、盈亏列（`DeltaText` + 市值）。金额用 `hideAmountsProvider` mask。数量/成本/最新对 amount-based 类型（现金类）显示 `--`（沿用旧 `_HoldingCard` 的判断逻辑 `AssetType.fromStorage(h.assetType).isAmountBased`）。

   e. `holding_detail_sheet.dart`：`showHoldingDetailSheet(BuildContext, WidgetRef, HoldingRow)`（原 `_HoldingDetailSheet` 的 showModalBottomSheet 包装，公开）+ `HoldingDetailSheet` widget + `InfoRow` + `TransactionTile`（原样移动，样式改 T：sheet 背景 `T.bg`，行 `T.mono`，涨跌 `T.changeColor`）。

   f. `holding_dialogs.dart`：`showAddHoldingDialog(BuildContext, WidgetRef)`（原 `_showAddHoldingDialog` 公开化）；内部表单字段用 `TerminalTextField`/`terminalDecoration`；`InvestedProfitField`/`PurchaseDateField` import 改为同目录。

   g. `invested_profit_field.dart` / `purchase_date_field.dart`：import 路径更新 + `AppColors`/theme 样式 → T tokens（输入框用 `terminalDecoration`）。

   h. `ui/pages/transaction_dialogs.dart`：整体移入 + 样式改 T（`MoneyDropdown`、`showHoldingTransactionDialog`、`showAccountTransactionDialog`、`syncAmount` 逻辑不变）。

4. 删除 `lib/features/holdings/` 与 `lib/features/transactions/`。

5. 更新 `lib/app/router.dart`：

```dart
import '../ui/pages/holdings/holdings_page.dart';
// …
GoRoute(
  path: '/holdings',
  builder: (context, state) => HoldingsPage(
    initialQuery: state.extra as String?,
  ),
),
```

6. 更新 4 个测试的 import：
   - `test/add_holding_flow_test.dart:10` → `import 'package:asset_tracker/ui/pages/holdings/holdings_page.dart';`
   - `test/invested_profit_field_test.dart:4`、`test/invested_profit_edit_test.dart:4` → `import 'package:asset_tracker/ui/pages/holdings/invested_profit_field.dart';`
   - `test/today_profit_test.dart:5` → `import 'package:asset_tracker/ui/pages/holdings/holdings_page.dart';`

7. 运行：`flutter analyze lib test`（退出码 0）；`flutter test`（全绿，含 add_holding_flow 2 用例 + invested_profit 8 用例 + today_profit）。

8. Commit：`git add -A; git commit -m "feat(ui): holdings page split with desktop table and DataRow cards"`

---

## Task 5: 账户 + 账户详情

**Files:**
- Create: `lib/ui/pages/accounts/accounts_page.dart`
- Create: `lib/ui/pages/accounts/account_detail_page.dart`
- Delete: `lib/features/accounts/`
- Modify: `lib/app/router.dart`（accounts + account_detail import）
- Modify: `test/ui/overflow_regression_test.dart`（追加用例）

**Steps:**

1. 追加溢出回归测试（imports 加 `ui/pages/accounts/accounts_page.dart`）：

```dart
testWidgets('accounts no overflow at phone and desktop', (tester) async {
  const account = AccountRow(
    id: 1,
    name: '测试账户',
    type: 'general',
    currency: 'CNY',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
  final overrides = <Override>[
    accountsProvider.overrideWithValue(Stream.value([account])),
    holdingsProvider.overrideWithValue(Stream.value(<HoldingRow>[])),
  ];
  await pumpPage(tester, const AccountsPage(), const Size(360, 640), overrides: overrides);
  expectNoOverflow(tester);
  await pumpPage(tester, const AccountsPage(), const Size(1280, 800), overrides: overrides);
  expectNoOverflow(tester);
});
```

（`AccountRow` 字段以 `lib/data/tables.dart` 的 `Accounts` 表为准：id/name/type/currency/note?/createdAt/updatedAt，nullable 字段省略。）

2. 运行确认失败。

3. 创建 `lib/ui/pages/accounts/accounts_page.dart`（spec 6.3）：
   - AppBar：title 账户 + `TerminalAppBarActions`
   - body：`KpiGrid`（2 tile：账户数 / 总余额 CNY 折算）+ 账户列表：每账户 `TerminalCard` 内 `SectionHeader`（账户名 + 类型 label）+ 账户内持仓 mini 行（`DataRow`：名称/市值/今日，复用旧 `_HoldingMiniTile` 逻辑，onTap → `showHoldingTransactionDialog`，import `../transaction_dialogs.dart`）+ 底部「账户详情 →」`DataRow(showChevron: true)` → `context.go('/accounts/${account.id}')`
   - 空状态 `EmptyState`；`hideAmountsProvider` mask
   - 旧 `_AccountCard`/`_HoldingMiniTile`/`_EmptyAccounts` 逻辑并入

4. 创建 `lib/ui/pages/accounts/account_detail_page.dart`（spec 6.3）：
   - AppBar：账户名 + `TerminalAppBarActions`（GoRouter 自动返回键保留）
   - 持仓 section：`SectionHeader('持仓')` + `DataRow` 列表（onTap → `showHoldingTransactionDialog`）
   - 交易流水 section：`SectionHeader('交易流水')` + `TransactionTile` 风格 DataRow（类型 icon + 日期 + 金额 mono，涨跌/收支着色）
   - 数据：`accountProvider(id)` + `holdingsByAccountProvider(id)` + `transactionsByAccountProvider(id)`（均为 `lib/app/providers.dart` 现有 provider，接口不变）
   - 新增交易按钮：`showAccountTransactionDialog(context, ref, accountId)`（import `../transaction_dialogs.dart`）

5. 删除 `lib/features/accounts/`；更新 `lib/app/router.dart` 两个 import。

6. 运行：`flutter analyze lib test`（退出码 0）；`flutter test` 全绿。

7. Commit：`git add -A; git commit -m "feat(ui): accounts pages with terminal rows"`

---

## Task 6: 行情页（spec 6.4）

**Files:**
- Create: `lib/ui/pages/markets/markets_page.dart`
- Delete: `lib/features/markets/markets_page.dart`
- Modify: `lib/app/router.dart`（1 个 import）
- Modify: `test/ui/overflow_regression_test.dart`（追加 1 用例）

**Steps:**

1. `test/ui/overflow_regression_test.dart` 追加 import（`markets_page.dart`、`services/market/global_quote_source.dart`）与用例：

```dart
  testWidgets('markets: no overflow', (tester) async {
    final overrides = <Override>[
      quotesProvider.overrideWithValue(
        const AsyncData([
          GlobalQuote(code: '000001', name: '上证指数', group: 'A股', price: 3200.5, change: 12.3, changePct: 0.0039),
          GlobalQuote(code: 'USD', name: '美元', group: '货币', price: 7.25, change: -0.01, changePct: -0.0014, fxSymbol: 'USD'),
        ]),
      ),
    ];
    await pumpPage(tester, const MarketsPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const MarketsPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
  });
```

2. 运行确认失败（import 不存在）。

3. 创建 `lib/ui/pages/markets/markets_page.dart`：
   - `_quotesProvider` → `quotesProvider`（公开，供测试 override）；数据源保持 `GlobalQuoteSource().fetch()` 不变
   - AppBar：title 行情 + 上次刷新时间（`T.mono(size: 11, color: T.text3)`，`ref.listen` 在 provider 出数据时记录 `DateTime.now()`）+ 刷新 IconButton（`ref.invalidate(quotesProvider)`）+ `TerminalAppBarActions`
   - 数据分组逻辑保持（`groupNames = ['A股', '亚太', '欧美', '大宗商品', '货币']`，`GlobalQuote` → `QuoteRow` 映射）
   - **桌面**：5 张 `QuoteTable` 卡分 2 列（按组数均分两列 `Column`，`Row` + `Expanded`，避免 GridView 等高问题）
   - **手机**：每组一张 `QuoteTable`（即紧凑行：名称+代码 / 最新+涨跌%）
   - 行点击 → `_showQuoteDetail(QuoteRow)`：`showModalBottomSheet` 底部弹层（名称 / 代码 mono / 大价格 mono 26 / `DeltaText` 涨跌 / fx 行 `1 USD = 7.2500 CNY`）
   - 空状态保持文案「行情加载失败，请检查网络后刷新」；页脚「数据来自新浪财经公开接口，仅供参考。」`T.label()`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../services/market/global_quote_source.dart';
import '../../components/delta_text.dart';
import '../../components/quote_table.dart';
import '../../components/app_bar_actions.dart';
import '../../tokens.dart';

final quotesProvider = FutureProvider<List<GlobalQuote>>((ref) async {
  return GlobalQuoteSource().fetch();
});

class MarketsPage extends ConsumerStatefulWidget {
  const MarketsPage({super.key});

  @override
  ConsumerState<MarketsPage> createState() => _MarketsPageState();
}

class _MarketsPageState extends ConsumerState<MarketsPage> {
  DateTime? _lastRefreshAt;

  @override
  Widget build(BuildContext context) {
    final quotes = ref.watch(quotesProvider);
    ref.listen<AsyncValue<List<GlobalQuote>>>(quotesProvider, (prev, next) {
      if (next is AsyncData && next.value.isNotEmpty) {
        setState(() => _lastRefreshAt = DateTime.now());
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('行情'),
        actions: [
          if (_lastRefreshAt != null)
            Padding(
              padding: const EdgeInsets.only(right: T.s2),
              child: Text(
                '更新于 ${Formats.dateTime(_lastRefreshAt!)}',
                style: T.mono(size: 11, color: T.text3),
              ),
            ),
          IconButton(
            tooltip: '刷新行情',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(quotesProvider),
          ),
          const TerminalAppBarActions(),
        ],
      ),
      body: quotes.when(
        data: (list) {
          if (list.isEmpty) {
            return const Center(child: Text('行情加载失败，请检查网络后刷新'));
          }
          final groups = <String, List<GlobalQuote>>{};
          for (final q in list) {
            groups.putIfAbsent(q.group, () => []).add(q);
          }
          final groupNames = ['A股', '亚太', '欧美', '大宗商品', '货币'];
          final tables = [
            for (final name in groupNames)
              if (groups.containsKey(name))
                (name, [
                  for (final q in groups[name]!)
                    QuoteRow(
                      code: q.code,
                      name: q.name,
                      price: q.price,
                      change: q.change,
                      changePct: q.changePct,
                      unit: q.unit,
                      fxSymbol: q.fxSymbol,
                    ),
                ]),
          ];
          return ResponsiveShell(
            child: ListView(
              children: [
                if (Responsive.isDesktop(context))
                  _GroupGrid(tables: tables, onQuoteTap: _showQuoteDetail)
                else
                  for (final (name, rows) in tables)
                    QuoteTable(group: name, rows: rows, onQuoteTap: _showQuoteDetail),
                const SizedBox(height: T.s2),
                Text('数据来自新浪财经公开接口，仅供参考。', style: T.label()),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }

  void _showQuoteDetail(QuoteRow r) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(T.s4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: T.text1)),
            const SizedBox(height: 2),
            Text(r.code, style: T.mono(size: 12, color: T.text3)),
            const SizedBox(height: T.s3),
            Text(
              r.fxSymbol != null ? r.price.toStringAsFixed(4) : Formats.num(r.price),
              style: T.mono(size: 26, weight: FontWeight.w700),
            ),
            const SizedBox(height: T.s2),
            DeltaText(
              value: r.changePct,
              text:
                  '${r.changePct >= 0 ? '+' : ''}${Formats.pct(r.changePct)}  '
                  '${r.change >= 0 ? '+' : ''}${Formats.amount(r.change)}',
            ),
            if (r.fxSymbol != null) ...[
              const SizedBox(height: T.s2),
              Text(
                '1 ${r.fxSymbol} = ${r.price.toStringAsFixed(4)} CNY',
                style: T.mono(size: 12, color: T.text2),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Desktop: group quote tables in two balanced columns.
class _GroupGrid extends StatelessWidget {
  const _GroupGrid({required this.tables, required this.onQuoteTap});

  final List<(String, List<QuoteRow>)> tables;
  final void Function(QuoteRow) onQuoteTap;

  @override
  Widget build(BuildContext context) {
    final mid = (tables.length + 1) ~/ 2;
    Widget column(List<(String, List<QuoteRow>)> items) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (name, rows) in items)
              QuoteTable(group: name, rows: rows, onQuoteTap: onQuoteTap),
          ],
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: column(tables.take(mid).toList())),
        const SizedBox(width: T.s3),
        Expanded(child: column(tables.skip(mid).toList())),
      ],
    );
  }
}
```

4. 删除 `lib/features/markets/`；更新 `lib/app/router.dart` import：`../features/markets/markets_page.dart` → `../ui/pages/markets/markets_page.dart`。

5. 运行：`flutter analyze lib test`（退出码 0）；`flutter test` 全绿。

6. Commit：`git add -A; git commit -m "feat(ui): markets page with grouped quote tables"`

---

## Task 7: 统计页（spec 6.5）

**Files:**
- Create: `lib/ui/pages/stats/stats_page.dart`
- Delete: `lib/features/stats/stats_page.dart`
- Modify: `lib/app/router.dart`（1 个 import）
- Modify: `test/ui/overflow_regression_test.dart`（追加 1 用例）

**Steps:**

1. 追加 import（`stats_page.dart`、`domain/trade_stats.dart`）与用例：

```dart
  testWidgets('stats: no overflow', (tester) async {
    final overrides = <Override>[
      statsProvider.overrideWithValue(
        const AsyncData(
          TradeStats(
            boughtTotal: 100000,
            soldTotal: 20000,
            incomeTotal: 50000,
            expenseTotal: 12000,
            dividendTotal: 3000,
            realizedProfit: 8000,
            monthlyCashflow: {'2026-07': -12000, '2026-08': 5000},
          ),
        ),
      ),
    ];
    await pumpPage(tester, const StatsPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const StatsPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
  });
```

2. 运行确认失败。

3. 创建 `lib/ui/pages/stats/stats_page.dart`：
   - `_statsProvider` → `statsProvider`（公开）；计算逻辑保持 `const TradeStatsCalculator().compute(txns, holdings, cnyRates: rates)`
   - AppBar：title 统计 + `TerminalAppBarActions`
   - `KpiGrid` 7 个 `StatTile`：净现金流（`color: T.changeColor(s.cashflow)`）/ 已落袋收益（`color: T.changeColor(s.realizedProfit)`）/ 累计分红 / 累计买入 / 累计卖出 / 累计收入 / 累计支出（金额 mono，`¥` 前缀去掉改由 `Formats.amount` 呈现）
   - `SectionHeader('月度现金流')` + `TerminalCard` 内 `_CashflowChart`（fl_chart `BarChart` 深色化：柱色 `T.changeColor(v)`、宽 14、圆角 3；底部轴标签 `T.mono(size: 10, color: T.text3)` 显示 `MM`；左轴虚线网格 `T.borderSoft`；tooltip mono）
   - 空数据：`TerminalCard` + 「暂无流水数据，先记一笔交易吧」
   - 页脚说明文案保持，`T.label()`

```dart
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../domain/trade_stats.dart';
import '../../components/kpi_grid.dart';
import '../../components/section_header.dart';
import '../../components/app_bar_actions.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';

final statsProvider = FutureProvider<TradeStats>((ref) async {
  final txns = await ref.watch(transactionsProvider.future);
  final holdings = await ref.watch(holdingsProvider.future);
  final rates = await ref.watch(cnyRatesProvider.future);
  return const TradeStatsCalculator().compute(txns, holdings, cnyRates: rates);
});

class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(statsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('统计'),
        actions: const [TerminalAppBarActions()],
      ),
      body: ResponsiveShell(
        child: stats.when(
          data: (s) => ListView(
            children: [
              KpiGrid(
                tiles: [
                   StatTile(
                     label: '净现金流',
                     value: '${s.cashflow >= 0 ? '+' : ''}${Formats.amount(s.cashflow)}',
                     color: T.changeColor(s.cashflow),
                   ),
                   StatTile(
                     label: '已落袋收益',
                     value: '${s.realizedProfit >= 0 ? '+' : ''}${Formats.amount(s.realizedProfit)}',
                     color: T.changeColor(s.realizedProfit),
                   ),
                  StatTile(label: '累计分红', value: Formats.amount(s.dividendTotal)),
                  StatTile(label: '累计买入', value: Formats.amount(s.boughtTotal)),
                  StatTile(label: '累计卖出', value: Formats.amount(s.soldTotal)),
                  StatTile(label: '累计收入', value: Formats.amount(s.incomeTotal)),
                  StatTile(label: '累计支出', value: Formats.amount(s.expenseTotal)),
                ],
              ),
              const SizedBox(height: T.s4),
              const SectionHeader(label: '月度现金流'),
              if (s.monthlyCashflow.isEmpty)
                const TerminalCard(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(T.s4),
                      child: Text('暂无流水数据，先记一笔交易吧'),
                    ),
                  ),
                )
              else
                TerminalCard(
                  child: SizedBox(height: 220, child: _CashflowChart(months: s.monthlyCashflow)),
                ),
              const SizedBox(height: T.s3),
              Text(
                '已落袋收益为卖出（卖出价 − 当前成本价）× 数量 的估算；'
                '买入后成本变动时会略有偏差。',
                style: T.label(),
              ),
            ],
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载失败: $e')),
        ),
      ),
    );
  }
}

/// Dark terminal-style bar chart of monthly net cash flow.
class _CashflowChart extends StatelessWidget {
  const _CashflowChart({required this.months});

  final Map<String, double> months;

  @override
  Widget build(BuildContext context) {
    final keys = months.keys.toList()..sort();
    final values = [for (final k in keys) months[k]!];
    return BarChart(
      BarChartData(
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => T.surface2,
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final v = values[groupIndex];
              return BarTooltipItem(
                '${keys[groupIndex]}  ${v >= 0 ? '+' : ''}${Formats.amount(v)}',
                T.mono(size: 12, color: T.text1),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= keys.length) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(keys[i].substring(5), style: T.mono(size: 10, color: T.text3)),
                );
              },
            ),
          ),
        ),
        axisData: [
          const FlAxisData(show: false),
          const FlAxisData(show: false),
          const FlAxisData(show: false),
          FlAxisData(
            drawsGridLines: true,
            gridLineStyle: const BorderSide(color: T.borderSoft, width: 1, strokeCap: StrokeCap.dash),
            axisLine: const FlAxisLine(show: false),
            tickMarks: const FlTickMarks(show: false),
          ),
        ],
        barGroups: [
          for (var i = 0; i < keys.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: values[i],
                  width: 14,
                  borderRadius: BorderRadius.circular(3),
                  color: T.changeColor(values[i]),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
```

4. 删除 `lib/features/stats/`；更新 router import。

5. 运行：`flutter analyze lib test`（退出码 0）；`flutter test` 全绿。

6. Commit：`git add -A; git commit -m "feat(ui): stats page with KPI grid and cashflow chart"`

---

## Task 8: 提醒页（spec 6.6）

**Files:**
- Create: `lib/ui/pages/alerts/alerts_page.dart`
- Delete: `lib/features/alerts/alerts_page.dart`
- Modify: `lib/app/router.dart`（1 个 import）
- Modify: `test/ui/overflow_regression_test.dart`（追加 1 用例）

**Steps:**

1. 追加 import（`alerts_page.dart`、`data/database.dart`）与用例：

```dart
  testWidgets('alerts: no overflow', (tester) async {
    final overrides = <Override>[
      alertRulesProvider.overrideWithValue(Stream.value([
        AlertRuleRow(
          id: 1,
          type: 'concentration',
          name: '集中度风险',
          params: '{"threshold":0.3}',
          enabled: true,
          createdAt: DateTime(2026, 8, 1),
          updatedAt: DateTime(2026, 8, 1),
        ),
      ])),
      alertEventsProvider.overrideWithValue(Stream.value([
        AlertEventRow(
          id: 1,
          ruleId: 1,
          title: '集中度风险',
          message: '单笔持仓占比 42% 超过阈值',
          triggeredAt: DateTime(2026, 8, 20, 9, 30),
        ),
      ])),
    ];
    await pumpPage(tester, const AlertsPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const AlertsPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
  });
```

2. 运行确认失败。

3. 创建 `lib/ui/pages/alerts/alerts_page.dart`：
   - `alertServiceProvider` 保留在本文件（无外部引用）
   - AppBar：title 提醒 + ⚡ 立即检查 IconButton（`_running` 时显示 spinner，逻辑保持）+ `TerminalAppBarActions`
   - `SectionHeader('最近提醒')` + 事件 `DataRow`：`leading` 为彩色圆形 icon（按 title 着色：单日跌幅预警→`T.up`、集中度风险→`T.warning`、配置比例偏离→`T.accent`、其他→`T.text2`），`title: event.title`，`subtitle: Text('${event.message}\n${Formats.dateTime(event.triggeredAt.toLocal())}')`，`trailing: const SizedBox.shrink()`
   - `SectionHeader('提醒规则')` + 规则 `DataRow`：`leading` 类型 icon（`_iconFor`），`title: rule.name`，`subtitle: _paramsSummary(rule)`，`trailing: Row(mainAxisSize: min, [Switch(value: rule.enabled, onChanged: onToggle), IconButton(delete_outline, onDelete)])`
   - 空状态：`EmptyState`（事件：「暂无提醒，点击右上角 ⚡ 立即检查」；规则：「暂无规则，点击右下角添加\n如：集中度风险、配置比例、跌幅预警、现金流提醒」）
   - FAB「添加规则」保持；添加规则 dialog 重样式：`InputDecoration` 全部换 `terminalDecoration(...)`（`form_fields.dart`），保存按钮 `FilledButton`
   - 删除确认 dialog：`FilledButton.styleFrom(backgroundColor: T.up)`
   - `_paramsSummary`/`_decodeParams`/`_iconFor`/`_colorFor` 逻辑保持；`_colorFor` 中 `AppColors.warning/primary/up` → `T.warning/T.accent/T.up`，`Colors.teal` → `T.accent`

4. 删除 `lib/features/alerts/`；更新 router import。

5. 运行：`flutter analyze lib test`（退出码 0）；`flutter test` 全绿。

6. Commit：`git add -A; git commit -m "feat(ui): alerts page with terminal rows"`

---

## Task 9: 设置 + 同步设置（spec 6.7）

**Files:**
- Create: `lib/ui/pages/settings/settings_page.dart`
- Create: `lib/ui/pages/settings/sync_settings_page.dart`
- Delete: `lib/features/settings/`
- Modify: `lib/app/router.dart`（1 个 import）
- Modify: `test/ui/overflow_regression_test.dart`（追加 1 用例）

**Steps:**

1. 追加 import（`settings_page.dart`）与用例（设置页 build 不触 dao，无需额外 override）：

```dart
  testWidgets('settings: no overflow', (tester) async {
    await pumpPage(tester, const SettingsPage(), const Size(360, 640));
    expectNoOverflow(tester);
    await pumpPage(tester, const SettingsPage(), const Size(1280, 800));
    expectNoOverflow(tester);
  });
```

2. 运行确认失败。

3. 创建 `lib/ui/pages/settings/settings_page.dart`：
   - `backupServiceProvider` 保留在本文件（无外部引用）
   - `_isMobilePlatform`、`_export`、`_exportFile`、`_import`、`_exportCsv` 逻辑**全部保持**（含平台分支 share sheet vs 文件保存、UTF-8 显式解码注释）
   - 布局：4 组 `SectionHeader` + 说明文字（`T.label()`）+ `TerminalCard` 内 `DataRow` 行：
     - 数据备份：导出备份（`Icons.upload_file`）/ 导入备份（`Icons.download`，icon 色 `T.warning`）
     - 导出数据：导出持仓 CSV（`Icons.table_chart_outlined`）/ 导出流水 CSV（`Icons.receipt_long_outlined`）
     - 数据同步：同步设置（`Icons.sync`，`showChevron: true`，onTap → `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SyncSettingsPage()))`）
     - 关于：`DataRow`（`Icons.info_outline` + 三行说明文字）
   - `AppColors.up` → `T.up`（覆盖导入按钮 / 失败 SnackBar）

4. 创建 `lib/ui/pages/settings/sync_settings_page.dart`：
   - `syncServiceProvider` 保留在本文件
   - `_load`/`_save`/`_syncNow`/`_formatTime` 逻辑**全部保持**（含 `ref.invalidate(historySyncProvider)`）
   - 重样式：`TextField` → `TerminalTextField`（服务器地址 hint `http://192.168.1.100:8787` / 访问令牌 `obscureText: true`）；说明文字 `T.label()`；`Switch` 行保持；错误文字色 `T.up`；`Colors.grey` → `T.text3`；「上次同步」`DataRow`（`Icons.schedule`）
   - AppBar 保持（GoRouter/Material 自动返回键）

5. 删除 `lib/features/settings/`；更新 router import（settings 页）。

6. 运行：`flutter analyze lib test`（退出码 0）；`flutter test` 全绿。

7. Commit：`git add -A; git commit -m "feat(ui): settings and sync settings pages"`

---

## Task 10: 收益日历（spec 6.8）

**Files:**
- Create: `lib/ui/pages/calendar/earnings_calendar_page.dart`
- Delete: `lib/features/calendar/earnings_calendar_page.dart`
- Modify: `lib/app/router.dart`（1 个 import）
- Modify: `test/ui/overflow_regression_test.dart`（追加 1 用例）

**Interfaces:**
- Consumes: `TerminalAppBarActions`、`HeatCell`、`TerminalCard`、`DayDetailSheet`、`ResponsiveShell`、`DailyEarningsCalculator`、`snapshotsProvider`、`historySyncProvider`。
- Produces: `earningsProvider`（public `FutureProvider<List<DailyEarning>>`，供测试 override）与 `EarningsCalendarPage`（`lib/ui/pages/calendar/earnings_calendar_page.dart`）。

**Steps:**

1. `test/ui/overflow_regression_test.dart` 追加 import（`asset_tracker/domain/daily_earnings.dart`、`asset_tracker/ui/pages/calendar/earnings_calendar_page.dart`）与用例：

```dart
  testWidgets('earnings calendar no overflow at phone and desktop', (tester) async {
    final now = DateTime.now();
    final d1 = DateTime(now.year, now.month, 10);
    final d2 = DateTime(now.year, now.month, 11);
    final overrides = <Override>[
      earningsProvider.overrideWithValue(AsyncData([
        DailyEarning(
          date: d1.toIso8601String().substring(0, 10),
          profit: 120,
          totalValue: 100000,
          totalCost: 99880,
          liabilities: 0,
        ),
        DailyEarning(
          date: d2.toIso8601String().substring(0, 10),
          profit: -80,
          totalValue: 99920,
          totalCost: 99880,
          liabilities: 0,
        ),
      ])),
      alertEventsProvider.overrideWithValue(Stream.value(<AlertEventRow>[])),
    ];
    await pumpPage(tester, const EarningsCalendarPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const EarningsCalendarPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
  });
```

2. 运行确认失败：`flutter test test/ui/overflow_regression_test.dart`（新 import 不存在）。

3. 创建 `lib/ui/pages/calendar/earnings_calendar_page.dart`（一个文件，包含下面两段代码，按顺序拼接）：

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../domain/daily_earnings.dart';
import '../../components/app_bar_actions.dart';
import '../../components/heat_cell.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';
import '../portfolio/day_detail_sheet.dart';

final earningsProvider = FutureProvider<List<DailyEarning>>((ref) async {
  final snapshots = ref.watch(snapshotsProvider).value ?? const [];
  return const DailyEarningsCalculator().compute(snapshots);
});

class EarningsCalendarPage extends ConsumerStatefulWidget {
  const EarningsCalendarPage({super.key});

  @override
  ConsumerState<EarningsCalendarPage> createState() => _EarningsCalendarPageState();
}

enum _CalView { month, year }

class _EarningsCalendarPageState extends ConsumerState<EarningsCalendarPage> {
  final _calc = const DailyEarningsCalculator();
  late int _year;
  late int _month;
  _CalView _view = _CalView.month;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
  }

  @override
  Widget build(BuildContext context) {
    final earnings = ref.watch(earningsProvider);
    ref.watch(historySyncProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('收益日历'),
        actions: const [TerminalAppBarActions()],
      ),
      body: earnings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (list) => _CalendarBody(
          earnings: list,
          year: _year,
          month: _month,
          view: _view,
          calc: _calc,
          onPrev: () => _shift(-1),
          onNext: () => _shift(1),
          onOpenMonth: (m) {
            setState(() {
              _month = m;
              _view = _CalView.month;
            });
          },
          onViewChanged: (v) => setState(() => _view = v),
        ),
      ),
    );
  }

  void _shift(int delta) {
    setState(() {
      if (_view == _CalView.month) {
        _month += delta;
        if (_month < 1) {
          _month = 12;
          _year--;
        } else if (_month > 12) {
          _month = 1;
          _year++;
        }
      } else {
        _year += delta;
      }
    });
  }
}

class _CalendarBody extends StatelessWidget {
  const _CalendarBody({
    required this.earnings,
    required this.year,
    required this.month,
    required this.view,
    required this.calc,
    required this.onPrev,
    required this.onNext,
    required this.onOpenMonth,
    required this.onViewChanged,
  });

  final List<DailyEarning> earnings;
  final int year;
  final int month;
  final _CalView view;
  final DailyEarningsCalculator calc;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final ValueChanged<int> onOpenMonth;
  final ValueChanged<_CalView> onViewChanged;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  static const _monthNames = [
    '1月', '2月', '3月', '4月', '5月', '6月',
    '7月', '8月', '9月', '10月', '11月', '12月',
  ];

  @override
  Widget build(BuildContext context) {
    final byDate = {for (final e in earnings) e.date: e};
    final monthSummary = calc.monthOf(earnings, year, month);
    final firstDay = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final leadingBlanks = firstDay.weekday - 1;
    final isYearView = view == _CalView.year;
    final yearSummary = isYearView ? calc.yearOf(earnings, year) : null;
    final prefix = '$year-${month.toString().padLeft(2, '0')}';
    final profits = earnings
        .where((e) => e.date.startsWith(prefix) && e.profit != 0)
        .map((e) => e.profit)
        .toList();
    final minProfit = profits.isEmpty ? 0.0 : profits.reduce(math.min);
    final maxProfit = profits.isEmpty ? 0.0 : profits.reduce(math.max);

    return ResponsiveShell(
      child: ListView(
        padding: const EdgeInsets.all(T.s3),
        children: [
          Center(
            child: SegmentedButton<_CalView>(
              segments: const [
                ButtonSegment(value: _CalView.month, label: Text('月')),
                ButtonSegment(value: _CalView.year, label: Text('年')),
              ],
              selected: {view},
              onSelectionChanged: (s) => onViewChanged(s.first),
            ),
          ),
          const SizedBox(height: T.s3),
          if (isYearView) ...[
            _YearSummary(year: yearSummary!),
            const SizedBox(height: T.s2),
            _navRow('$year年'),
            const SizedBox(height: T.s2),
            _YearGrid(year: year, earnings: earnings, onTapMonth: onOpenMonth),
          ] else ...[
            _MonthSummary(month: monthSummary),
            const SizedBox(height: T.s2),
            _navRow('$year年$month月'),
            const SizedBox(height: T.s2),
            Row(
              children: [
                for (final w in _weekdays)
                  Expanded(child: Center(child: Text(w, style: T.label()))),
              ],
            ),
            const SizedBox(height: T.s1),
            _buildGrid(
              context,
              leadingBlanks: leadingBlanks,
              daysInMonth: daysInMonth,
              byDate: byDate,
              minProfit: minProfit,
              maxProfit: maxProfit,
            ),
          ],
          const SizedBox(height: T.s3),
          Text('盈亏 = 当日净资产 − 前日净资产；负债变化计入当日盈亏', style: T.label()),
        ],
      ),
    );
  }

  Widget _navRow(String label) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
        SizedBox(
          width: 96,
          child: Center(
            child: Text(label, style: T.mono(size: 14, weight: FontWeight.w600)),
          ),
        ),
        IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right)),
      ],
    );
  }

  Widget _buildGrid(
    BuildContext context, {
    required int leadingBlanks,
    required int daysInMonth,
    required Map<String, DailyEarning> byDate,
    required double minProfit,
    required double maxProfit,
  }) {
    final rows = <TableRow>[];
    var day = 1;
    final cellCount = leadingBlanks + daysInMonth;
    final weekCount = (cellCount + 6) ~/ 7;
    for (var w = 0; w < weekCount; w++) {
      final cells = <Widget>[];
      for (var c = 0; c < 7; c++) {
        final index = w * 7 + c;
        if (index < leadingBlanks || day > daysInMonth) {
          cells.add(const SizedBox.shrink());
        } else {
          final date = DateTime(year, month, day);
          final dateStr = date.toIso8601String().substring(0, 10);
          final earning = byDate[dateStr];
          cells.add(
            _DayCell(
              day: day,
              earning: earning,
              date: date,
              minProfit: minProfit,
              maxProfit: maxProfit,
              onTap: earning == null ? null : () => _openDay(context, date),
            ),
          );
          day++;
        }
      }
      rows.add(TableRow(children: cells));
    }
    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: {
        for (var i = 0; i < 7; i++) i: const FlexColumnWidth(),
      },
      children: rows,
    );
  }

  void _openDay(BuildContext context, DateTime date) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => DayDetailSheet(date: date),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.earning,
    required this.date,
    required this.minProfit,
    required this.maxProfit,
    this.onTap,
  });

  final int day;
  final DailyEarning? earning;
  final DateTime date;
  final double minProfit;
  final double maxProfit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isToday = _isToday(date);
    final hasEarning = earning != null && earning!.profit != 0;
    final profit = earning?.profit ?? 0;
    return HeatCell(
      value: profit,
      min: minProfit,
      max: maxProfit,
      height: 44,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$day',
            style: T.mono(
              size: 11,
              weight: isToday ? FontWeight.w700 : FontWeight.w400,
              color: isToday ? T.accent : T.text2,
            ),
          ),
          const SizedBox(height: T.s1),
          Text(
            earning == null
                ? ''
                : hasEarning
                    ? '${profit >= 0 ? '+' : ''}${Formats.amountCompact(profit)}'
                    : '0',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.mono(
              size: 10,
              color: hasEarning ? T.changeColor(profit) : T.text3,
            ),
          ),
        ],
      ),
    );
  }

  static bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }
}

class _MonthSummary extends StatelessWidget {
  const _MonthSummary({required this.month});

  final MonthlyEarnings month;

  @override
  Widget build(BuildContext context) {
    final rate = month.rate;
    final hasEarning = month.total != 0;
    return TerminalCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('本月收益', style: T.label()),
                const SizedBox(height: T.s1),
                Text(
                  '${month.total >= 0 ? '+' : ''}${Formats.amount(month.total)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.mono(
                    size: 22,
                    weight: FontWeight.w700,
                    color: hasEarning ? T.changeColor(month.total) : T.text3,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('月收益率', style: T.label()),
              const SizedBox(height: T.s1),
              Text(
                rate == null ? '--' : Formats.pct(rate),
                style: T.mono(
                  size: 18,
                  weight: FontWeight.w700,
                  color: rate == null ? T.text3 : T.changeColor(rate),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _YearSummary extends StatelessWidget {
  const _YearSummary({required this.year});

  final YearlyEarnings year;

  @override
  Widget build(BuildContext context) {
    final rate = year.rate;
    final hasEarning = year.total != 0;
    return TerminalCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('本年收益', style: T.label()),
                const SizedBox(height: T.s1),
                Text(
                  '${year.total >= 0 ? '+' : ''}${Formats.amount(year.total)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.mono(
                    size: 22,
                    weight: FontWeight.w700,
                    color: hasEarning ? T.changeColor(year.total) : T.text3,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('年收益率', style: T.label()),
              const SizedBox(height: T.s1),
              Text(
                rate == null ? '--' : Formats.pct(rate),
                style: T.mono(
                  size: 18,
                  weight: FontWeight.w700,
                  color: rate == null ? T.text3 : T.changeColor(rate),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _YearGrid extends StatelessWidget {
  const _YearGrid({
    required this.year,
    required this.earnings,
    required this.onTapMonth,
  });

  final int year;
  final List<DailyEarning> earnings;
  final ValueChanged<int> onTapMonth;

  static const _monthNames = [
    '1月', '2月', '3月', '4月', '5月', '6月',
    '7月', '8月', '9月', '10月', '11月', '12月',
  ];

  @override
  Widget build(BuildContext context) {
    final calc = const DailyEarningsCalculator();
    final byMonth = {
      for (var m = 1; m <= 12; m++) m: calc.monthOf(earnings, year, m),
    };
    final maxAbs = byMonth.values.map((m) => m.total.abs()).reduce(math.max);
    final rows = <TableRow>[];
    for (var r = 0; r < 4; r++) {
      final cells = <Widget>[];
      for (var c = 0; c < 3; c++) {
        final m = r * 3 + c + 1;
        final agg = byMonth[m]!;
        cells.add(
          _MonthTile(
            label: _monthNames[m - 1],
            month: agg,
            maxAbs: maxAbs,
            onTap: agg.days > 0 ? () => onTapMonth(m) : null,
          ),
        );
      }
      rows.add(TableRow(children: cells));
    }
    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: {
        for (var i = 0; i < 3; i++) i: const FlexColumnWidth(),
      },
      children: rows,
    );
  }
}

class _MonthTile extends StatelessWidget {
  const _MonthTile({
    required this.label,
    required this.month,
    required this.maxAbs,
    this.onTap,
  });

  final String label;
  final MonthlyEarnings month;
  final double maxAbs;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasData = month.days > 0;
    final hasEarning = hasData && month.total != 0;
    final frac = maxAbs == 0
        ? 0.0
        : (month.total.abs() / maxAbs).clamp(0.0, 1.0);
    return TerminalCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: T.s2, vertical: T.s2),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: T.label()),
          const SizedBox(height: T.s1),
          Text(
            !hasData
                ? '--'
                : hasEarning
                    ? '${month.total >= 0 ? '+' : ''}${Formats.amountCompact(month.total)}'
                    : '0',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.mono(
              size: 12,
              weight: FontWeight.w600,
              color: hasEarning ? T.changeColor(month.total) : T.text3,
            ),
          ),
          const SizedBox(height: T.s2),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: T.s1,
              backgroundColor: T.surface2,
              valueColor: AlwaysStoppedAnimation(
                hasEarning ? T.changeColor(month.total) : T.text3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

4. 删除旧页并更新 router：

```powershell
git rm lib/features/calendar/earnings_calendar_page.dart
```

`lib/app/router.dart` 第 7 行：

```dart
// 旧
import '../features/calendar/earnings_calendar_page.dart';
// 新
import '../ui/pages/calendar/earnings_calendar_page.dart';
```

5. 验证：`flutter analyze lib test`（退出码 0）+ `flutter test`（全绿）。

6. Commit：`git add -A; git commit -m "feat(ui): earnings calendar with heat grid"`

---

## Task 11: 产品收益日历（spec 6.9，sliver 矩阵）

**Files:**
- Create: `lib/ui/pages/calendar/product_earnings_calendar_page.dart`
- Delete: `lib/features/calendar/product_earnings_calendar_page.dart`
- Modify: `lib/app/router.dart`（1 个 import）
- Modify: `test/product_earnings_calendar_test.dart`（重写 import、`_pump`、断言）
- Modify: `test/ui/overflow_regression_test.dart`（追加 1 用例）

**Interfaces:**
- Consumes: `TerminalAppBarActions`、`Sparkline`、`TerminalCard`、`ResponsiveShell`、`ProductEarningsCalculator`、`productEarningsProvider`、`alertEventsProvider`。
- Produces: `ProductEarningsCalendarPage`（`lib/ui/pages/calendar/product_earnings_calendar_page.dart`）。
- 使用单个横向 `ScrollController` 驱动网格，月份头通过 `Transform.translate` 跟随该 controller（不再用双 controller 同步 hack）；用 `SliverPersistentHeader` 固定表头，删除 `IntrinsicHeight`。

**Steps:**

1. `test/ui/overflow_regression_test.dart` 追加 import（`asset_tracker/core/enums.dart`、`asset_tracker/domain/product_monthly_earnings.dart`、`asset_tracker/ui/pages/calendar/product_earnings_calendar_page.dart`）与用例：

```dart
  testWidgets('product earnings calendar no overflow at phone and desktop', (tester) async {
    final now = DateTime.now();
    final products = [
      _pe('产品甲', 100, now.year),
      _pe('产品乙', -50, now.year),
    ];
    final overrides = <Override>[
      productEarningsProvider(now.year).overrideWithValue(AsyncData(products)),
      alertEventsProvider.overrideWithValue(Stream.value(<AlertEventRow>[])),
    ];
    await pumpPage(tester, const ProductEarningsCalendarPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const ProductEarningsCalendarPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
  });

  ProductEarnings _pe(String name, double profit, int year) {
    final daily = <({String date, double value, double cost})>[];
    var value = 10000.0;
    for (var m = 1; m <= 12; m++) {
      final mm = m.toString().padLeft(2, '0');
      daily.add((date: '$year-$mm-01', value: value, cost: 10000));
      value += profit;
      daily.add((date: '$year-$mm-15', value: value, cost: 10000));
    }
    return ProductEarnings(
      name: name,
      type: AssetType.mutualFund,
      closed: false,
      daily: daily,
    );
  }
```

2. 运行确认失败：`flutter test test/ui/overflow_regression_test.dart`（新 import 不存在）。

3. 创建 `lib/ui/pages/calendar/product_earnings_calendar_page.dart`（一个文件，包含下面三段代码，按顺序拼接）：

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../domain/product_monthly_earnings.dart';
import '../../components/app_bar_actions.dart';
import '../../components/sparkline.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';

class ProductEarningsCalendarPage extends ConsumerStatefulWidget {
  const ProductEarningsCalendarPage({super.key});

  @override
  ConsumerState<ProductEarningsCalendarPage> createState() =>
      _ProductEarningsCalendarPageState();
}

enum _PEView { year, month }

enum _PEFilter { all, held }

class _ProductEarningsCalendarPageState
    extends ConsumerState<ProductEarningsCalendarPage> {
  late int _year;
  late int _month;
  _PEView _view = _PEView.year;
  _PEFilter _filter = _PEFilter.all;
  int _mobileMonths = 6;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
  }

  void _shiftYear(int delta) => setState(() => _year += delta);

  void _shiftMonth(int delta) {
    setState(() {
      final d = DateTime(_year, _month + delta, 1);
      _year = d.year;
      _month = d.month;
    });
  }

  void _openMonth(int month) => setState(() {
        _month = month;
        _view = _PEView.month;
      });

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productEarningsProvider(_year));
    return Scaffold(
      appBar: AppBar(
        title: const Text('产品收益日历'),
        actions: const [TerminalAppBarActions()],
      ),
      body: products.when(
        data: (list) => _PEBody(
          products: list,
          year: _year,
          month: _month,
          view: _view,
          filter: _filter,
          mobileMonths: _mobileMonths,
          onShiftYear: _shiftYear,
          onShiftMonth: _shiftMonth,
          onOpenMonth: _openMonth,
          onViewChanged: (v) => setState(() => _view = v),
          onFilterChanged: (f) => setState(() => _filter = f),
          onMobileMonthsChanged: (n) => setState(() => _mobileMonths = n),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }
}

class _PEBody extends StatelessWidget {
  const _PEBody({
    required this.products,
    required this.year,
    required this.month,
    required this.view,
    required this.filter,
    required this.mobileMonths,
    required this.onShiftYear,
    required this.onShiftMonth,
    required this.onOpenMonth,
    required this.onViewChanged,
    required this.onFilterChanged,
    required this.onMobileMonthsChanged,
  });

  final List<ProductEarnings> products;
  final int year;
  final int month;
  final _PEView view;
  final _PEFilter filter;
  final int mobileMonths;
  final ValueChanged<int> onShiftYear;
  final ValueChanged<int> onShiftMonth;
  final ValueChanged<int> onOpenMonth;
  final ValueChanged<_PEView> onViewChanged;
  final ValueChanged<_PEFilter> onFilterChanged;
  final ValueChanged<int> onMobileMonthsChanged;

  List<ProductEarnings> get _filtered => filter == _PEFilter.all
      ? products
      : products.where((p) => !p.closed).toList();

  @override
  Widget build(BuildContext context) {
    final isPhone = Responsive.isPhone(context);
    final isYearView = view == _PEView.year;
    final calc = const ProductEarningsCalculator();

    final rows = _filtered
        .map((p) => (p: p, months: calc.yearOf(p, year)))
        .toList()
      ..sort((a, b) {
        final ra = calc.yearlyRate(a.months, a.p, year);
        final rb = calc.yearlyRate(b.months, b.p, year);
        if (ra == null && rb == null) {
          return calc.yearlyProfit(b.months).compareTo(calc.yearlyProfit(a.months));
        }
        if (ra == null) return 1;
        if (rb == null) return -1;
        return rb.compareTo(ra);
      });

    final monthRows = _filtered
        .map((p) => (p: p, m: calc.monthOf(p, year, month)))
        .where((r) => r.m.days > 0)
        .toList()
      ..sort((a, b) {
        if (a.m.rate == null && b.m.rate == null) {
          return b.m.profit.compareTo(a.m.profit);
        }
        if (a.m.rate == null) return 1;
        if (b.m.rate == null) return -1;
        return b.m.rate!.compareTo(a.m.rate!);
      });

    return ResponsiveShell(
      child: Column(
        children: [
          Center(
            child: SegmentedButton<_PEView>(
              segments: const [
                ButtonSegment(value: _PEView.year, label: Text('年')),
                ButtonSegment(value: _PEView.month, label: Text('月')),
              ],
              selected: {view},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onSelectionChanged: (s) => onViewChanged(s.first),
            ),
          ),
          const SizedBox(height: T.s3),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: isYearView ? '上一年' : '上一月',
                icon: const Icon(Icons.chevron_left),
                onPressed: isYearView ? () => onShiftYear(-1) : () => onShiftMonth(-1),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    isYearView ? '$year年' : '$year年$month月',
                    style: T.mono(size: 15, weight: FontWeight.w600),
                  ),
                ),
              ),
              IconButton(
                tooltip: isYearView ? '下一年' : '下一月',
                icon: const Icon(Icons.chevron_right),
                onPressed: isYearView ? () => onShiftYear(1) : () => onShiftMonth(1),
              ),
            ],
          ),
          const SizedBox(height: T.s2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SegmentedButton<_PEFilter>(
                segments: const [
                  ButtonSegment(value: _PEFilter.all, label: Text('全部')),
                  ButtonSegment(value: _PEFilter.held, label: Text('仅持有中')),
                ],
                selected: {filter},
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onSelectionChanged: (s) => onFilterChanged(s.first),
              ),
              if (isYearView && isPhone) ...[
                const SizedBox(width: T.s3),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 6, label: Text('近6月')),
                    ButtonSegment(value: 12, label: Text('12月')),
                  ],
                  selected: {mobileMonths},
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onSelectionChanged: (s) => onMobileMonthsChanged(s.first),
                ),
              ],
            ],
          ),
          const SizedBox(height: T.s3),
          Expanded(
            child: isYearView
                ? _YearMatrix(
                    rows: rows,
                    year: year,
                    requestedMonths: mobileMonths,
                    onTapMonth: onOpenMonth,
                  )
                : SingleChildScrollView(
                    child: _MonthList(rows: monthRows, year: year, month: month),
                  ),
          ),
          const SizedBox(height: T.s3),
          Text(
            '收益为成本法口径：已剔除申赎等本金进出影响；已清仓产品按流水回放保留完整历史，清仓月收益为已实现收益。',
            style: T.label(),
          ),
        ],
      ),
    );
  }
}

class _YearMatrix extends StatefulWidget {
  const _YearMatrix({
    required this.rows,
    required this.year,
    required this.requestedMonths,
    required this.onTapMonth,
  });

  final List<({ProductEarnings p, List<ProductMonthEarning> months})> rows;
  final int year;
  final int requestedMonths;
  final ValueChanged<int> onTapMonth;

  @override
  State<_YearMatrix> createState() => _YearMatrixState();
}

class _YearMatrixState extends State<_YearMatrix> {
  static const double _headerHeight = 28;
  static const double _rowHeight = 44;

  final ScrollController _hCtrl = ScrollController();

  @override
  void dispose() {
    _hCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPhone = Responsive.isPhone(context);
    final isTablet = Responsive.isTablet(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth;
        final nameWidth = isPhone ? 92.0 : (isTablet ? 120.0 : 150.0);
        final count = isPhone
            ? widget.requestedMonths
            : (isTablet
                ? ((contentWidth - nameWidth) / 12 >= 52 ? 12 : 6)
                : 12);
        final months = _monthsWindow(widget.year, count);
        final colWidth = isPhone
            ? 52.0
            : math.max(52.0, (contentWidth - nameWidth) / (months.length + 1));
        final showText = MediaQuery.sizeOf(context).width >= 360;
        final calc = const ProductEarningsCalculator();

        final bestByMonth = <int, String>{};
        for (final m in months) {
          double? bestRate;
          String? bestName;
          for (final row in widget.rows) {
            final agg = _aggOf(row, m);
            if (agg == null || agg.rate == null) continue;
            if (bestRate == null || agg.rate! > bestRate) {
              bestRate = agg.rate;
              bestName = row.p.name;
            }
          }
          if (bestName != null) bestByMonth[m] = bestName;
        }

        final headerChild = Row(
          children: [
            SizedBox(
              width: nameWidth,
              height: _headerHeight,
              child: Center(child: Text('产品', style: T.label())),
            ),
            Container(width: 1, height: _headerHeight, color: T.border),
            Expanded(
              child: ClipRect(
                child: AnimatedBuilder(
                  animation: _hCtrl,
                  builder: (context, _) => Transform.translate(
                    offset: Offset(-(_hCtrl.hasClients ? _hCtrl.offset : 0), 0),
                    child: SizedBox(
                      height: _headerHeight,
                      width: (months.length + 1) * colWidth,
                      child: Row(
                        children: [
                          for (final m in months)
                            SizedBox(
                              width: colWidth,
                              child: Center(child: Text('$m月', style: T.label())),
                            ),
                          SizedBox(
                            width: colWidth,
                            child: Center(
                              child: Text(
                                '全年',
                                style: T.mono(
                                  size: 11,
                                  weight: FontWeight.w600,
                                  color: T.text2,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );

        final nameColumn = SizedBox(
          width: nameWidth,
          child: Column(
            children: [
              for (final row in widget.rows)
                SizedBox(
                  height: _rowHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: T.s2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            row.p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, color: T.text1),
                          ),
                        ),
                        if (row.p.closed) const _ClosedBadge(),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );

        final gridRows = <Widget>[];
        for (final row in widget.rows) {
          final cells = <Widget>[];
          for (final m in months) {
            final agg = _aggOf(row, m);
            cells.add(
              SizedBox(
                width: colWidth,
                child: _MatrixCell(
                  agg: agg,
                  isBest: agg != null && bestByMonth[m] == row.p.name,
                  showText: showText,
                  onTap: agg != null && agg.days > 0
                      ? () => widget.onTapMonth(m)
                      : null,
                ),
              ),
            );
          }
          cells.add(
            SizedBox(
              width: colWidth,
              child: _YearlyCell(
                profit: calc.yearlyProfit(row.months),
                rate: calc.yearlyRate(row.months, row.p, widget.year),
              ),
            ),
          );
          gridRows.add(SizedBox(height: _rowHeight, child: Row(children: cells)));
        }

        return CustomScrollView(
          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: _HeaderDelegate(height: _headerHeight, child: headerChild),
            ),
            const SliverToBoxAdapter(
              child: SizedBox(height: 1, child: Container(color: T.border)),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: widget.rows.isEmpty ? 0 : widget.rows.length * _rowHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    nameColumn,
                    Container(width: 1, color: T.border),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _hCtrl,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: (months.length + 1) * colWidth,
                          height: widget.rows.length * _rowHeight,
                          child: Column(children: gridRows),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  List<int> _monthsWindow(int year, int count) {
    final now = DateTime.now();
    if (year != now.year) return List.generate(12, (i) => i + 1);
    final start = math.max(1, now.month - count + 1);
    return List.generate(now.month - start + 1, (i) => start + i);
  }

  ProductMonthEarning? _aggOf(
      ({ProductEarnings p, List<ProductMonthEarning> months}) row, int month) {
    for (final m in row.months) {
      if (m.month == month) return m;
    }
    return null;
  }
}

class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  const _HeaderDelegate({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  double get maxExtent => height;

  @override
  double get minExtent => height;

  @override
  bool shouldRebuild(covariant _HeaderDelegate old) =>
      old.height != height || old.child != child;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) =>
      child;
}

class _MatrixCell extends StatelessWidget {
  const _MatrixCell({
    required this.agg,
    required this.isBest,
    required this.showText,
    this.onTap,
  });

  final ProductMonthEarning? agg;
  final bool isBest;
  final bool showText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasData = agg != null && agg!.days > 0;
    final rate = agg?.rate;
    final hasRate = hasData && rate != null;
    final profit = agg?.profit ?? 0;
    final hasProfit = hasData && profit != 0;
    final bg = hasRate
        ? T.heat(rate!, -0.10, 0.10)
        : (hasData ? T.surface2 : T.surface);
    final fg = hasRate ? T.changeColor(rate!) : T.text3;
    return Padding(
      padding: const EdgeInsets.all(T.s1),
      child: InkWell(
        borderRadius: BorderRadius.circular(T.rInput),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(T.rInput),
            border: isBest ? Border.all(color: T.accent, width: 1.6) : null,
          ),
          child: Stack(
            children: [
              Center(
                child: showText
                    ? Text(
                        !hasData
                            ? '--'
                            : hasProfit
                                ? '${profit >= 0 ? '+' : ''}${Formats.amountCompact(profit)}'
                                : '0',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.mono(
                          size: 10,
                          weight: FontWeight.w600,
                          color: fg,
                        ),
                      )
                    : Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: hasRate
                              ? (rate! >= 0 ? T.up : T.down)
                              : T.text3,
                          shape: BoxShape.circle,
                        ),
                      ),
              ),
              if (agg?.closed == true)
                const Positioned(top: 0, right: 0, child: _ClosedBadge(compact: true)),
            ],
          ),
        ),
      ),
    );
  }
}

class _YearlyCell extends StatelessWidget {
  const _YearlyCell({required this.profit, required this.rate});

  final double profit;
  final double? rate;

  @override
  Widget build(BuildContext context) {
    final hasRate = rate != null;
    return Padding(
      padding: const EdgeInsets.all(T.s1),
      child: Container(
        decoration: BoxDecoration(
          color: T.surface2,
          borderRadius: BorderRadius.circular(T.rInput),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              hasRate
                  ? '${rate! >= 0 ? '+' : ''}${Formats.pct1(rate!)}'
                  : '--',
              maxLines: 1,
              style: T.mono(
                size: 11,
                weight: FontWeight.w700,
                color: hasRate ? T.changeColor(rate!) : T.text3,
              ),
            ),
            Text(
              Formats.amountCompact(profit),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: T.mono(size: 10, color: T.text3),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClosedBadge extends StatelessWidget {
  const _ClosedBadge({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: T.s1),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 3 : T.s1,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: T.surface2,
        borderRadius: BorderRadius.circular(T.rInput),
        border: Border.all(color: T.border),
      ),
      child: Text(
        compact ? '清' : '清仓',
        style: TextStyle(fontSize: compact ? 8 : 9, color: T.text2),
      ),
    );
  }
}

class _MonthList extends StatelessWidget {
  const _MonthList({required this.rows, required this.year, required this.month});

  final List<({ProductEarnings p, ProductMonthEarning m})> rows;
  final int year;
  final int month;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const TerminalCard(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(T.s4),
            child: Text('本月暂无数据', style: TextStyle(color: T.text3)),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final row in rows)
          TerminalCard(
            margin: const EdgeInsets.only(bottom: T.s2),
            padding: const EdgeInsets.symmetric(horizontal: T.s3, vertical: T.s2),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              row.p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, color: T.text1),
                            ),
                          ),
                          if (row.p.closed) const _ClosedBadge(),
                        ],
                      ),
                      const SizedBox(height: T.s1),
                      Text(
                        row.m.rate == null
                            ? '收益率 --'
                            : '收益率 ${row.m.rate! >= 0 ? '+' : ''}${Formats.pct(row.m.rate!)}',
                        style: T.mono(
                          size: 12,
                          weight: FontWeight.w600,
                          color: row.m.rate == null
                              ? T.text3
                              : T.changeColor(row.m.rate!),
                        ),
                      ),
                      const SizedBox(height: T.s1),
                      Text(
                        '收益 ${Formats.signedAmount(row.m.profit)}',
                        style: T.mono(size: 11, color: T.text2),
                      ),
                    ],
                  ),
                ),
                Sparkline(
                  values: _netSeries(row.p),
                  color: T.changeColor(row.m.profit),
                  width: 84,
                  height: 36,
                ),
              ],
            ),
          ),
      ],
    );
  }

  List<double> _netSeries(ProductEarnings p) {
    final prefix = '$year-${month.toString().padLeft(2, '0')}';
    final nets = <double>[];
    double? prevNet;
    for (final d in p.daily) {
      if (!d.date.startsWith(prefix)) {
        if (d.date.compareTo(prefix) < 0) {
          prevNet = d.value - d.cost;
        }
        continue;
      }
      final net = d.value - d.cost;
      if (prevNet != null) nets.add(net - prevNet);
      prevNet = net;
    }
    return nets;
  }

}
```

4. 重写 `test/product_earnings_calendar_test.dart`（整个文件替换为下面代码）：

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/product_monthly_earnings.dart';
import 'package:asset_tracker/ui/components/sparkline.dart';
import 'package:asset_tracker/ui/pages/calendar/product_earnings_calendar_page.dart';

/// A product with one baseline day and one profit day per month of [year],
/// so every month has data (days = 2) and a deterministic rate. The value
/// carries over between months (it never resets), so each month's profit is
/// exactly [monthlyProfits][m-1] and the yearly rates stay distinct.
ProductEarnings _product(String name, List<double> monthlyProfits, int year) {
  final daily = <({String date, double value, double cost})>[];
  var value = 10000.0;
  for (var m = 1; m <= 12; m++) {
    final mm = m.toString().padLeft(2, '0');
    daily.add((date: '$year-$mm-01', value: value, cost: 10000));
    value += monthlyProfits[m - 1];
    daily.add((date: '$year-$mm-15', value: value, cost: 10000));
  }
  return ProductEarnings(
    name: name,
    type: AssetType.mutualFund,
    closed: false,
    daily: daily,
  );
}

Future<void> _pump(
  WidgetTester tester,
  List<ProductEarnings> products, {
  int year = 2025,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final nowYear = DateTime.now().year;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      alertEventsProvider.overrideWithValue(Stream.value(<AlertEventRow>[])),
      // The page starts on the current year; keep it empty so the real
      // provider (and its DB access) is never evaluated. Sync overrides skip
      // the loading state (no infinite spinner for pumpAndSettle).
      if (nowYear != year)
        productEarningsProvider(nowYear).overrideWith((ref) => const []),
      productEarningsProvider(year).overrideWith((ref) => products),
    ],
    child: const MaterialApp(home: ProductEarningsCalendarPage()),
  ));
  await tester.pump();
}

void main() {
  testWidgets('name column stays pinned while the grid scrolls horizontally',
      (tester) async {
    await _pump(tester, [
      _product('产品甲', [100, 200, 300, 400, 500, 600, 0, 0, 0, 0, 0, 0], 2025),
      _product('产品乙', [10, 20, 30, 40, 50, 60, 0, 0, 0, 0, 0, 0], 2025),
    ]);
    // Navigate to 2025 so the full 12-month window is shown.
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();

    final amount = '+${Formats.amountCompact(100)}';
    final name = find.text('产品甲');
    expect(name, findsOneWidget);
    final nameBefore = tester.getTopLeft(name);
    final headerBefore = tester.getTopLeft(find.text('1月'));
    final cellBefore = tester.getTopLeft(find.text(amount));

    final gridScroll = find
        .ancestor(of: find.text(amount), matching: find.byType(SingleChildScrollView))
        .first;
    await tester.drag(gridScroll, const Offset(-200, 0));
    await tester.pumpAndSettle();

    // The product name did not move.
    expect(tester.getTopLeft(name), nameBefore);
    // The grid scrolled left ...
    final cellAfter = tester.getTopLeft(find.text(amount));
    expect(cellAfter.dx, lessThan(cellBefore.dx - 100));
    // ... and the month header followed it.
    final headerAfter = tester.getTopLeft(find.text('1月'));
    expect(headerAfter.dx, lessThan(headerBefore.dx - 100));
  });

  testWidgets('month header stays pinned while rows scroll vertically',
      (tester) async {
    // Distinct yearly rates keep the row order deterministic (desc).
    final products = List.generate(
      25,
      (i) => _product('产品${i + 1}', [
        100 * (i + 1),
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0
      ], 2025),
    );
    await _pump(tester, products);
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();

    final headerBefore = tester.getTopLeft(find.text('1月'));
    final firstRow = find.text('产品25');
    expect(firstRow, findsOneWidget);
    final firstRowBefore = tester.getTopLeft(firstRow);
    expect(firstRowBefore.dy, greaterThan(headerBefore.dy));

    final vScroll =
        find.ancestor(of: firstRow, matching: find.byType(CustomScrollView)).first;
    final vTopLeft = tester.getTopLeft(vScroll);
    await tester.dragFrom(
      vTopLeft + const Offset(40, 30),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();

    // The header stayed put ...
    expect(tester.getTopLeft(find.text('1月')), headerBefore);
    // ... while the rows scrolled up.
    final firstRowAfter = tester.getTopLeft(firstRow);
    expect(firstRowAfter.dy, lessThan(firstRowBefore.dy - 100));
  });

  testWidgets('month header follows the grid but is not independently scrollable',
      (tester) async {
    await _pump(tester, [
      _product('产品甲', [100, 200, 300, 400, 500, 600, 0, 0, 0, 0, 0, 0], 2025),
    ]);
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();

    final amount = '+${Formats.amountCompact(100)}';
    final cellBefore = tester.getTopLeft(find.text(amount));
    final headerTransform = find
        .ancestor(of: find.text('1月'), matching: find.byType(Transform))
        .first;
    await tester.drag(headerTransform, const Offset(-150, 0));
    await tester.pumpAndSettle();

    final cellAfter = tester.getTopLeft(find.text(amount));
    expect(cellAfter, cellBefore);
  });

  testWidgets('month view lists each product with its sparkline', (tester) async {
    await _pump(tester, [
      _product('产品甲', [100, 200, 300, 400, 500, 600, 0, 0, 0, 0, 0, 0], 2025),
      _product('产品乙', [10, 20, 30, 40, 50, 60, 0, 0, 0, 0, 0, 0], 2025),
    ]);
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('月', findRichText: true).last);
    await tester.pumpAndSettle();

    expect(find.text('产品甲'), findsOneWidget);
    expect(find.text('产品乙'), findsOneWidget);
    expect(find.byType(Sparkline), findsNWidgets(2));
  });
}
```

5. 删除旧页：`git rm lib/features/calendar/product_earnings_calendar_page.dart`。

6. `lib/app/router.dart` import 行 8 改为 `import '../ui/pages/calendar/product_earnings_calendar_page.dart';`。

7. 验证：`flutter analyze lib test`（退出码 0）+ `flutter test`（全绿）。

8. Commit：`git add -A; git commit -m "feat(ui): product earnings calendar with sliver matrix"`

---

## Task 12: 清理 `lib/features/` 与版本号（spec 收尾）

**Files:**
- Delete: `lib/features/`（目录，git 不跟踪空目录）
- Modify: `pubspec.yaml`（版本行）

**Steps:**

1. 确认 `lib/features/` 为空：`Get-ChildItem -Recurse lib/features` 无文件；若为空，`Remove-Item -Recurse -Force lib/features`（空目录无需单独 commit）。

2. 残留检查（目标 0 命中）：
   - `Get-ChildItem -Path lib/ui -Recurse -Filter *.dart | Select-String -Pattern 'AppColors'`
   - `Get-ChildItem -Path lib/ui -Recurse -Filter *.dart | Select-String -Pattern 'features/'`
   - `Get-ChildItem -Path lib/ui -Recurse -Filter *.dart | Select-String -Pattern 'Colors\.(teal|grey|white)'`
   - `Get-ChildItem -Path lib/ui -Recurse -Filter *.dart | Select-String -Pattern 'Theme\.of\(context\)\.textTheme'`

3. `pubspec.yaml` 第 19 行：`version: 0.6.6+13` → `version: 0.7.0+14`。

4. 验证：`flutter analyze lib test`（退出码 0）+ `flutter test`（全绿）。

5. Commit：`git add -A; git commit -m "chore(ui): remove features dir and bump version to 0.7.0"`

6. 发版（人工，按 AGENTS.md）：
   - `git tag v0.7.0` + `git push origin v0.7.0`
   - 构建 4 个资产（Windows zip + universal/arm64/arm APK）
   - `gh release create v0.7.0 --title "v0.7.0" --notes-file <md> <4 个资产>`
   - `git tag -f latest v0.7.0` + `git push origin latest -f`

---

## 自查笔记（Spec 覆盖）

- **§3 tokens / theme / shell**：Task 1 建 `T`、`AppTheme.dark()`、`ResponsiveShell`、`TerminalAppBarActions`。
- **§4 导航**：Shell 5 个目的地（总览/持仓/账户/行情/统计）；9 个主页面 AppBar 使用 `TerminalAppBarActions`（含两个日历页，虽然它们是顶层路由）。
- **§5 共享组件**：Task 2 建 `TerminalCard`、`DataRow`、`QuoteTable`、`SectionHeader`、`DeltaText`、`StatTile`、`KpiGrid`、`EmptyState`、`Sparkline`、`HeatCell`、`terminalDecoration`、`TerminalTextField`。
- **§6.1 总览**：Task 3。
- **§6.2 持仓**：Task 4。
- **§6.3 账户**：Task 5。
- **§6.4 行情**：Task 6。
- **§6.5 统计**：Task 7。
- **§6.6 提醒**：Task 8。
- **§6.7 设置/同步**：Task 9。
- **§6.8 收益日历**：Task 10。
- **§6.9 产品收益日历**：Task 11。
- **§8 测试**：Task 2 建 `test/ui/overflow_regression_test.dart` 基线；Task 3–11 每页追加 overflow 用例；Task 11 适配 `test/product_earnings_calendar_test.dart`。
- **§9 版本**：Task 12 升到 `0.7.0+14`。

**已知偏差：**
1. §6.9 删除 `IntrinsicHeight` 和双 controller 同步 hack，改用 `SliverPersistentHeader` + 固定行高 + 单个横向 `ScrollController` 驱动网格；月份头通过 `Transform.translate` 跟随该 controller，因此只有网格可横向拖动，月份头只跟随不独立滚动。
2. §6.9 `colWidth` 使用 `months.length + 1`（含“全年”列），避免列宽偏大。
3. §6.9 `<360px` 的 dot 降级按**屏幕宽度**判断（非内容宽度），保证 390px 现有测试仍显示金额文字。
4. §6.4 行情详情用 bottom sheet 实现（spec 允许）。
5. 两个日历页在 shell 外，但仍按 plan 加 `TerminalAppBarActions`。
6. 只把 4 个私有页面 provider 公开：`summaryProvider`、`quotesProvider`、`statsProvider`、`earningsProvider`；`_refreshingProvider` 仍私有。
7. 测试数：基线 256 + 新增 UI/theme/component/overflow 用例。
