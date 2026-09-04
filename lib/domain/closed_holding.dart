import '../core/enums.dart';
import '../data/database.dart';

/// Whether a holding is fully exited: sold out, redeemed, or repaid.
///
/// Sold-out rows keep their transactions (and their earnings-calendar
/// history); they are just no longer active positions.
bool isHoldingClosed(HoldingRow h) => h.quantity <= 0;

/// Badge label for a fully exited holding.
String closedHoldingLabel(HoldingRow h) {
  final type = AssetType.fromStorage(h.assetType);
  if (type == AssetType.liability) return '已还清';
  return type.isAmountBased ? '已结清' : '清仓';
}
