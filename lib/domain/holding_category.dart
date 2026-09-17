import '../core/enums.dart';
import '../data/database.dart';

/// The allocation category a holding actually counts towards: its manual
/// [HoldingRow.categoryOverride] when set, otherwise the one implied by its
/// asset type ([AssetType.category]).
///
/// The two are deliberately separate fields. A holding's *asset type* decides
/// how it is recorded and priced — an ETF is share-based and quoted by Sina —
/// while its *category* decides where it sits in the allocation view, the
/// 配置比例偏离 alert and the holdings-list category filter. For any fund that
/// tracks something other than equities the two disagree: a 豆粕ETF is an
/// 场内基金 with 商品 exposure, a 黄金ETF is an 场内基金 with 黄金 exposure.
/// Deriving the category from the type silently files those under 权益.
///
/// Use this everywhere a holding's category is needed; never read
/// `AssetType.category` directly for a holding.
AssetCategory effectiveCategoryOf(HoldingRow h) {
  final type = AssetType.fromStorage(h.assetType);
  // Liabilities are deducted from net worth instead of being allocated, and
  // the dialogs refuse to store an override for them — guard here so a
  // hand-edited or foreign value can never file a debt under 权益.
  if (type == AssetType.liability) return type.category;
  return AssetCategory.fromStorageOrNull(h.categoryOverride) ?? type.category;
}

/// Whether the holding's category is derived rather than overridden — i.e.
/// the stored [HoldingRow.categoryOverride] is absent or unreadable (written
/// by a newer app version).
bool hasCategoryOverride(HoldingRow h) =>
    AssetCategory.fromStorageOrNull(h.categoryOverride) != null;
