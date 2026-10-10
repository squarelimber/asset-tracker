/// 持久化的 UI 偏好：setting key、默认值与可选档位。
library;

/// 总览页焦点滚轮卡每面停留的时长（毫秒）。
///
/// 存进 `settings` 表（key-value），由 `spotlightHoldMsProvider` 监听，
/// 设置页改完立即生效。集中在这里是为了让写入方和读取方共用同一个字符串
/// 常量 —— 一边手拼 `'spotlight_hold_ms'`、另一边少一个字母，设置就会静默
/// 失效（且双向都不报错）。
const String spotlightHoldMsKey = 'spotlight_hold_ms';

/// 未设置时使用的停留时长。与原硬编码值一致，因此升级后观感不变。
const int defaultSpotlightHoldMs = 2300;

/// 「滚动卡停留时间」的可选档位（毫秒）。
///
/// 下限 1.5s 是留出余量用的：翻转动画本身要 0.9s，停留若更短就没有
/// 「停顿」感，看起来像一直在转。
const List<int> spotlightHoldChoicesMs = <int>[1500, 2300, 3500, 5000, 8000];

/// 档位的展示文案：整秒不带小数（2000 → 「2 秒」），否则保留一位。
String spotlightHoldLabel(int ms) {
  final seconds = ms / 1000;
  return seconds == seconds.roundToDouble()
      ? '${seconds.toInt()} 秒'
      : '${seconds.toStringAsFixed(1)} 秒';
}
