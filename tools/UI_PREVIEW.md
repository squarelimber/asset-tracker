# 设计预览

从项目根目录运行：

```powershell
flutter run -d chrome -t tools/ui_preview.dart
```

或启动本地 Web 预览服务器：

```powershell
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5192 -t tools/ui_preview.dart
```

打开 <http://127.0.0.1:5192>。

该入口使用名为 `asset_tracker_design_preview` 的独立数据库，首次启动写入模拟账户、持仓与 90 天净值数据，并在右上角标明“演示数据”。它不读取正式应用的资产数据库，也不执行启动同步和迁移服务。持仓报价刷新使用固定的演示适配器，历史回填被关闭，以保持视觉检查稳定。

演示快照同时保存逐持仓市值与成本，总览、收益日历和产品收益使用相同记录；净资产为资产减负债。演示数据不能用于验证真实账户收益。

正式入口仍为 `lib/main.dart`。界面规范及参考来源见 [DESIGN.md](../DESIGN.md)，收益口径与旧数据处理见 [earnings-consistency.md](../docs/earnings-consistency.md)。
