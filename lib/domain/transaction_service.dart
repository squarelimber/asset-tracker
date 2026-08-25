import 'package:drift/drift.dart';

import '../core/enums.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';

/// Outcome of a transaction record/remove operation.
class TransactionResult {
  const TransactionResult({required this.ok, this.message});

  final bool ok;
  final String? message;

  static const success = TransactionResult(ok: true);
  static TransactionResult fail(String message) =>
      TransactionResult(ok: false, message: message);
}

/// Orchestrates transaction records and their effect on holdings.
///
  /// Linkage rules:
  /// - buy:     share holding quantity +q, moving-average cost;
  ///            optional cash source holding -amount, invested moves with it
  ///            so the cash return rate stays undistorted (the money leaves
  ///            the cash pool and enters the security's cost basis).
  /// - sell:    share holding quantity -q (must not go negative); cost
  ///            unchanged; optional cash target holding +amount (invested
  ///            moves with it, mirror of buy).
  /// - transfer: source and target are cash/liability holdings; source -amount,
  ///            target +amount (repaying a liability = transfer to it).
  /// - dividend: cash holding +amount (invested untouched -> counts as gain).
  /// - income:   cash +amount AND invested +amount (capital entering, excluded
  ///            from investment P/L).
  /// - expense:  cash -amount AND invested -amount (consumption).
///
/// Removing a transaction reverses the linkage. Removing a `buy` requires
/// that no later transaction exists for the same share holding (moving
/// average can only be reversed in chronological order).
class TransactionService {
  TransactionService(this._dao);

  final AssetDao _dao;

  // ---------------------------------------------------------------------------
  // Record
  // ---------------------------------------------------------------------------

  Future<TransactionResult> record({
    required int accountId,
    int? holdingId,
    required TransactionType type,
    double? quantity,
    double? price,
    required double amount,
    String currency = 'CNY',
    DateTime? occurredAt,
    int? cashSourceId,
    int? cashTargetId,
    String? note,
  }) async {
    try {
      await _dao.transaction(() async {
        switch (type) {
          case TransactionType.buy:
            await _applyBuy(
              holdingId: holdingId,
              quantity: quantity,
              amount: amount,
              cashSourceId: cashSourceId,
            );
          case TransactionType.sell:
            await _applySell(
              holdingId: holdingId,
              quantity: quantity,
              amount: amount,
              cashTargetId: cashTargetId,
            );
          case TransactionType.transferIn || TransactionType.transferOut:
            await _applyTransfer(
              sourceId: cashSourceId,
              targetId: cashTargetId,
              amount: amount,
            );
          case TransactionType.dividend:
            // Cost-basis method: a cash dividend reduces the holding's cost
            // (a repayment of capital), so the ex-dividend price drop does
            // not show up as a phantom loss in the return rate.
            await _applyDividend(holdingId, amount, cashTargetId);
          case TransactionType.income:
            await _applyCashMove(cashTargetId, amount, invested: true);
          case TransactionType.expense:
            await _applyCashMove(cashTargetId, -amount, invested: true);
          case TransactionType.consume:
            await _applyConsume(holdingId, amount);
          case TransactionType.split:
            await _applySplit(holdingId, amount);
        }

        await _dao.createTransaction(TransactionsCompanion.insert(
          accountId: accountId,
          holdingId: holdingId == null ? const Value.absent() : Value(holdingId),
          cashSourceId: cashSourceId == null ? const Value.absent() : Value(cashSourceId),
          cashTargetId: cashTargetId == null ? const Value.absent() : Value(cashTargetId),
          type: type.storageName,
          quantity: quantity == null ? const Value.absent() : Value(quantity),
          price: price == null ? const Value.absent() : Value(price),
          amount: amount,
          currency: Value(currency),
          occurredAt: occurredAt ?? DateTime.now(),
          note: note == null || note.isEmpty ? const Value.absent() : Value(note),
        ));
      });
      return TransactionResult.success;
    } catch (e) {
      return TransactionResult.fail('操作失败: $e');
    }
  }

  Future<void> _applyBuy({
    required int? holdingId,
    required double? quantity,
    required double amount,
    int? cashSourceId,
  }) async {
    if (holdingId == null || quantity == null || quantity <= 0 || amount <= 0) {
      throw ArgumentError('买入需指定持仓、数量和金额');
    }
    final holding = await _getHolding(holdingId);
    final newQty = holding.quantity + quantity;
    final totalCost = holding.quantity * holding.costPrice + amount;
    await _updateHolding(holding, quantity: newQty, costPrice: totalCost / newQty);
    if (cashSourceId != null) {
      await _applyCashMove(cashSourceId, -amount, invested: true);
    }
  }

  Future<void> _applySell({
    required int? holdingId,
    required double? quantity,
    required double amount,
    int? cashTargetId,
  }) async {
    if (holdingId == null || quantity == null || quantity <= 0 || amount <= 0) {
      throw ArgumentError('卖出需指定持仓、数量和金额');
    }
    final holding = await _getHolding(holdingId);
    if (quantity > holding.quantity) {
      throw ArgumentError('卖出数量超过持仓数量（当前 ${holding.quantity}）');
    }
    final newQty = holding.quantity - quantity;
    // Keep the unit cost after a full sell-out: the realized-gain estimate
    // reads the holding's current cost, and a later buy overwrites it
    // (moving average with oldQty = 0 is just the new purchase price).
    await _updateHolding(holding, quantity: newQty);
    if (cashTargetId != null) {
      await _applyCashMove(cashTargetId, amount, invested: true);
    }
  }

  Future<void> _applyTransfer({
    required int? sourceId,
    required int? targetId,
    required double amount,
    bool moveCost = true,
  }) async {
    if (sourceId == null || targetId == null || amount <= 0) {
      throw ArgumentError('转账需指定源和目标持仓');
    }
    await _applyBalanceMove(sourceId, -amount, moveCost: moveCost);
    await _applyBalanceMove(targetId, amount, moveCost: moveCost);
  }

  /// Moves [delta] on a cash or liability holding. For liabilities the
  /// direction is inverted: receiving money repays debt (balance falls),
  /// paying out increases the debt.
  ///
  /// Cash holdings move their invested amount (costPrice) together with the
  /// balance (when [moveCost] is set), so internal transfers (repayment,
  /// moving money between accounts) never distort the capital-gains return
  /// rate: value and cost change by the same amount. Liabilities have no
  /// cost basis and only move the outstanding balance.
  Future<void> _applyBalanceMove(
    int holdingId,
    double delta, {
    bool moveCost = true,
  }) async {
    final holding = await _getHolding(holdingId);
    final type = AssetType.fromStorage(holding.assetType);
    if (!type.isAmountBased && type != AssetType.liability) {
      throw ArgumentError('目标持仓不是现金/负债类资产');
    }
    final effective = type == AssetType.liability ? -delta : delta;
    final newCost = type.isAmountBased && moveCost
        ? (holding.costPrice + delta).clamp(0.0, double.infinity)
        : holding.costPrice;
    await _updateHolding(
      holding,
      quantity: holding.quantity + effective,
      costPrice: newCost,
    );
  }

  /// Records consumption on a liability holding (e.g. credit-card spend):
  /// the outstanding balance (quantity) increases by [amount]. No cash
  /// holding is involved. A negative [amount] reverses the effect.
  Future<void> _applyConsume(int? holdingId, double amount) async {
    if (holdingId == null) {
      throw ArgumentError('消费需指定负债持仓');
    }
    final holding = await _getHolding(holdingId);
    if (AssetType.fromStorage(holding.assetType) != AssetType.liability) {
      throw ArgumentError('消费只能记在负债类持仓上');
    }
    await _updateHolding(holding, quantity: holding.quantity + amount);
  }

  /// Unit split / reverse split on a share holding: quantity x ratio,
  /// costPrice / ratio (market value and total cost stay unchanged).
  /// Removal applies the inverse ratio.
  Future<void> _applySplit(int? holdingId, double ratio) async {
    if (holdingId == null) {
      throw ArgumentError('份额折算需指定持仓');
    }
    if (ratio <= 0) {
      throw ArgumentError('折算比例必须大于 0');
    }
    final holding = await _getHolding(holdingId);
    final type = AssetType.fromStorage(holding.assetType);
    if (type.isAmountBased || type == AssetType.liability) {
      throw ArgumentError('份额折算只适用于份额类持仓');
    }
    await _updateHolding(
      holding,
      quantity: holding.quantity * ratio,
      costPrice: holding.costPrice / ratio,
    );
  }

  /// Cash dividend on a share holding (cost-basis method):
  /// - the cash target receives [amount] (invested untouched: it is a gain);
  /// - the holding's unit cost is reduced by [amount] / quantity, so the
  ///   ex-dividend price drop does not distort the return rate.
  /// A negative [amount] reverses the effect (removal).
  Future<void> _applyDividend(int? holdingId, double amount, int? cashTargetId) async {
    await _applyCashMove(cashTargetId, amount, invested: false);
    if (holdingId == null) return;
    final holding = await _getHolding(holdingId);
    final type = AssetType.fromStorage(holding.assetType);
    if (type.isAmountBased || type == AssetType.liability) return;
    if (holding.quantity <= 0) return;
    final newCost = (holding.costPrice - amount / holding.quantity)
        .clamp(0.0, double.infinity);
    await _updateHolding(
      holding,
      quantity: holding.quantity,
      costPrice: newCost,
    );
  }

  /// Moves [delta] on a cash holding (buy deduction, sell credit,
  /// dividend, income, expense). Liabilities are not allowed here —
  /// their flows go through transfers (repayment/borrowing).
  Future<void> _applyCashMove(int? holdingId, double delta, {required bool invested}) async {
    if (holdingId == null) {
      throw ArgumentError('需要指定现金持仓');
    }
    final holding = await _getHolding(holdingId);
    final type = AssetType.fromStorage(holding.assetType);
    if (!type.isAmountBased) {
      throw ArgumentError('目标持仓不是现金类资产');
    }
    await _updateHolding(
      holding,
      quantity: holding.quantity + delta,
      costPrice: invested
          ? (holding.costPrice + delta).clamp(0, double.infinity)
          : holding.costPrice,
    );
  }

  Future<HoldingRow> _getHolding(int id) async {
    final holding = await _dao.getHolding(id);
    if (holding == null) throw ArgumentError('持仓不存在');
    return holding;
  }

  Future<void> _updateHolding(
    HoldingRow holding, {
    required double quantity,
    double? costPrice,
  }) {
    return _dao.updateHolding(
      holding.copyWith(quantity: quantity, costPrice: costPrice ?? holding.costPrice),
    );
  }

  // ---------------------------------------------------------------------------
  // Remove (reverse linkage)
  // ---------------------------------------------------------------------------

  Future<TransactionResult> remove(int transactionId) async {
    try {
      await _dao.transaction(() async {
        final txn = await _dao.getTransaction(transactionId);
        if (txn == null) throw ArgumentError('流水不存在');
        final type = TransactionType.fromStorage(txn.type);

        switch (type) {
          case TransactionType.buy:
            await _reverseBuy(txn);
          case TransactionType.sell:
            await _reverseSell(txn);
          case TransactionType.transferIn || TransactionType.transferOut:
            // Reversing a transfer swaps the source and target; rolling the
            // same direction back would deduct twice. Legacy transfers did
            // not move the cash cost, so that is only rolled back when the
            // original recording did (costMoved).
            await _applyTransfer(
              sourceId: txn.cashTargetId,
              targetId: txn.cashSourceId,
              amount: txn.amount,
              moveCost: txn.costMoved,
            );
          case TransactionType.dividend:
            await _applyDividend(txn.holdingId, -txn.amount, txn.cashTargetId);
          case TransactionType.income:
            await _applyCashMove(txn.cashTargetId, -txn.amount, invested: true);
          case TransactionType.expense:
            await _applyCashMove(txn.cashTargetId, txn.amount, invested: true);
          case TransactionType.consume:
            await _applyConsume(txn.holdingId, -txn.amount);
          case TransactionType.split:
            await _applySplit(txn.holdingId, 1 / txn.amount);
        }

        await _dao.deleteTransaction(transactionId);
      });
      return TransactionResult.success;
    } catch (e) {
      return TransactionResult.fail(e is ArgumentError ? e.message.toString() : '删除失败: $e');
    }
  }

  Future<void> _reverseBuy(TransactionRow txn) async {
    final holdingId = txn.holdingId;
    if (holdingId == null) throw ArgumentError('买入流水缺少持仓');
    final holding = await _getHolding(holdingId);

    // Moving average can only be reversed when this is the latest
    // transaction of the holding.
    final newer = await _dao.hasNewerTransaction(holdingId, txn.id);
    if (newer) {
      throw ArgumentError('该持仓存在更晚的交易，请先删除更晚的流水');
    }
    final qty = txn.quantity ?? 0;
    if (qty <= 0) throw ArgumentError('买入流水数量无效');
    if (qty > holding.quantity) {
      // Already reversed or inconsistent data; just zero the quantity.
      await _updateHolding(holding, quantity: 0);
    } else {
      final newQty = holding.quantity - qty;
      // A full reversal keeps the unit cost (same invariant as a full
      // sell-out) so realized gains stay computable.
      final cost = newQty == 0
          ? holding.costPrice
          : (holding.quantity * holding.costPrice - txn.amount) / newQty;
      await _updateHolding(holding, quantity: newQty, costPrice: cost < 0 ? 0.0 : cost);
    }
    if (txn.cashSourceId != null) {
      await _applyCashMove(txn.cashSourceId, txn.amount, invested: true);
    }
  }

  Future<void> _reverseSell(TransactionRow txn) async {
    final holdingId = txn.holdingId;
    if (holdingId == null) throw ArgumentError('卖出流水缺少持仓');
    final holding = await _getHolding(holdingId);
    final qty = txn.quantity ?? 0;
    await _updateHolding(holding, quantity: holding.quantity + qty);
    if (txn.cashTargetId != null) {
      await _applyCashMove(txn.cashTargetId, -txn.amount, invested: true);
    }
  }
}
