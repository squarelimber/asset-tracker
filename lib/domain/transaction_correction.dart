part of 'transaction_service.dart';

class TransactionCorrectionPreview {
  TransactionCorrectionPreview._(
    this._closedPosition, {
    required this.original,
    required this.revised,
    required this.historyFrom,
    required this.historicalGain,
    required List<TransactionRow> rows,
    required List<({HoldingRow before, HoldingRow after})> holdings,
  }) : _rows = List.unmodifiable(rows),
       holdings = List.unmodifiable(holdings);

  final TransactionRow original;
  final TransactionRow revised;
  final DateTime historyFrom;
  final ({String date, double before, double after})? historicalGain;
  final List<({HoldingRow before, HoldingRow after})> holdings;
  final List<TransactionRow> _rows;
  final _ClosedPositionCorrection? _closedPosition;
  int get replayedRows => _rows.length;
  double get reconciledClosedQuantity => _closedPosition?.quantity ?? 0;
  bool get usesSnapshotPrincipal =>
      _closedPosition?.proofSnapshots.isNotEmpty ?? false;
}

/// A narrow reconciliation for a confirmed quantity/price transposition.
/// The corrected, complete share ledger must start and finish at zero.
/// Proof inputs are retained so save cannot use a stale preview.
class _ClosedPositionCorrection {
  _ClosedPositionCorrection({
    required this.holdingId,
    required this.quantity,
    required this.openingQuantity,
    required this.openingCost,
    required List<TransactionRow> proofRows,
    required List<SnapshotRow> proofSnapshots,
  }) : proofRows = List.unmodifiable(proofRows),
       proofSnapshots = List.unmodifiable(proofSnapshots);

  final int holdingId;
  final double quantity;
  final double openingQuantity;
  final double openingCost;
  final List<TransactionRow> proofRows;
  final List<SnapshotRow> proofSnapshots;
}

class _CorrectionPreviewRollback implements Exception {
  const _CorrectionPreviewRollback(this.preview);
  final TransactionCorrectionPreview preview;
}

extension TransactionCorrection on TransactionService {
  /// Replays affected transactions in an isolated SQLite transaction. The
  /// sentinel rolls it back so that no preview writes reach watchers or sync.
  Future<TransactionCorrectionPreview> previewCorrection(
    TransactionRow original, {
    required double amount,
    double? quantity,
    double? price,
  }) async {
    final revised = original.copyWith(
      amount: amount,
      quantity: Value(quantity),
      price: Value(price),
    );
    try {
      return await _dao.transaction<TransactionCorrectionPreview>(() async {
        final preview = await _runCorrection(original, revised);
        throw _CorrectionPreviewRollback(preview);
      });
    } on _CorrectionPreviewRollback catch (rollback) {
      return rollback.preview;
    } catch (error) {
      throw ArgumentError(TransactionService._recordFailMessage(error));
    }
  }

  Future<TransactionResult> saveCorrection(
    TransactionCorrectionPreview preview,
  ) async {
    try {
      await _dao.transaction(
        () => _runCorrection(
          preview.original,
          preview.revised,
          confirmed: preview,
        ),
      );
      return TransactionResult.success;
    } catch (error) {
      return TransactionResult.fail(
        TransactionService._recordFailMessage(error),
      );
    }
  }

  Future<TransactionCorrectionPreview> _runCorrection(
    TransactionRow original,
    TransactionRow revised, {
    TransactionCorrectionPreview? confirmed,
  }) async {
    TransactionService._validateNumbers(
      amount: revised.amount,
      quantity: revised.quantity,
      price: revised.price,
    );
    if (await _dao.getTransaction(original.id) != original) {
      throw ArgumentError('原流水已变化，请重新打开交易详情');
    }
    if (original == revised) throw ArgumentError('请先修改交易数值');
    final type = TransactionType.fromStorage(original.type);
    if (type == TransactionType.buy || type == TransactionType.sell) {
      final holdingId = original.holdingId;
      if (holdingId == null) throw ArgumentError('原流水缺少关联持仓');
      final holding = await _getHolding(holdingId);
      if (AssetType.fromStorage(holding.assetType).isAmountBased) {
        revised = revised.copyWith(
          quantity: Value(revised.amount),
          price: const Value(1.0),
        );
      } else if ((revised.quantity ?? 0) <= 0) {
        throw ArgumentError('请填写有效的成交数量');
      }
    }

    final all = await _dao.getTransactions();
    final group = await _dao.getRedemptionPartner(original);
    final first =
        group != null && compareTransactionEntryOrder(group, original) < 0
        ? group
        : original;
    final remaining = all.where(
      (row) => compareTransactionEntryOrder(row, first) >= 0,
    );
    final affected = _correctionHoldingIds(original);
    if (group != null) affected.addAll(_correctionHoldingIds(group));
    final operations = <List<TransactionRow>>[];
    final redemptions = <Object, List<TransactionRow>>{};
    for (final row in all.where(isRedemptionLeg)) {
      (redemptions[row.redemptionGroup ?? row.occurredAt] ??= []).add(row);
    }
    final paired = <int>{};
    for (final row in remaining) {
      if (paired.contains(row.id)) continue;
      final ids = _correctionHoldingIds(row);
      final candidates =
          redemptions[row.redemptionGroup ?? row.occurredAt] ?? const [];
      if (!ids.any(affected.contains) && row.id != original.id) {
        if (!isRedemptionLeg(row) ||
            !candidates.any(
              (other) =>
                  hasSameRedemption(row, other) &&
                  _correctionHoldingIds(other).any(affected.contains),
            )) {
          continue;
        }
      }
      final partner = redemptionPartner(row, candidates);
      if (partner != null) ids.addAll(_correctionHoldingIds(partner));
      if (row.id != original.id && !ids.any(affected.contains)) continue;
      if (isRedemptionLeg(row) && partner == null) {
        throw ArgumentError('关联的赎回与买入记录不完整，无法安全更正');
      }
      if (partner != null) {
        if (compareTransactionEntryOrder(partner, row) < 0 ||
            remaining.any(
              (other) =>
                  compareTransactionEntryOrder(other, row) > 0 &&
                  compareTransactionEntryOrder(other, partner) < 0 &&
                  _correctionHoldingIds(other).any(ids.contains),
            )) {
          throw ArgumentError('两条赎回关联记录之间有其他变更，无法安全重放');
        }
      }
      final rows = [row, ?partner];
      if (partner != null) paired.add(partner.id);
      operations.add(rows);
      affected.addAll(ids);
    }
    final rows = operations.expand((operation) => operation).toList();
    final before = [for (final id in affected) await _getHolding(id)];
    final closedPosition = group == null
        ? await _closedPositionCorrection(original, revised, all)
        : null;
    if (confirmed != null &&
        (confirmed._rows.length != rows.length ||
            rows.indexed.any(
              (entry) => entry.$2 != confirmed._rows[entry.$1],
            ) ||
            confirmed.holdings.length != before.length ||
            before.indexed.any(
              (entry) => entry.$2 != confirmed.holdings[entry.$1].before,
            ) ||
            !_sameClosedPositionProof(
              confirmed._closedPosition,
              closedPosition,
            ))) {
      throw ArgumentError('关联流水或持仓已变化，请重新预览');
    }

    // A bad historical quantity may already have been manually closed out.
    // Restore its proven old-ledger residual only inside this transaction,
    // so the ordinary reverse/replay validation still checks every old cost.
    final baseline = [
      for (final holding in before)
        holding.id == closedPosition?.holdingId
            ? holding.copyWith(
                quantity: holding.quantity + closedPosition!.quantity,
              )
            : holding,
    ];
    if (closedPosition != null) {
      await _dao.updateHolding(
        baseline.singleWhere((h) => h.id == closedPosition.holdingId),
      );
    }

    final uncertainBasis = <int>{};
    for (final operation in operations.reversed) {
      for (final row in operation.reversed) {
        await _undoCorrectionRow(row, uncertainBasis);
      }
    }
    final opening = [for (final id in affected) await _getHolding(id)];

    // Verify that the preserved history reproduces the current ledger before
    // changing anything. Old rows with lost principal data can fail safely.
    final replayedOriginal = await _replayCorrection(operations, const {});
    if (rows.any(
      (row) =>
          (row.costMovedAmount != null &&
              replayedOriginal[row.id]!.costMovedAmount !=
                  row.costMovedAmount) ||
          (row.externalSellPrincipal != null &&
              !_correctionClose(
                replayedOriginal[row.id]!.externalSellPrincipal ?? double.nan,
                row.externalSellPrincipal!,
              )),
    )) {
      throw ArgumentError('原流水的资金成本无法核对，请检查关联流水');
    }
    for (final old in baseline) {
      final restored = await _getHolding(old.id);
      final amountBased = AssetType.fromStorage(old.assetType).isAmountBased;
      if (!_correctionClose(old.quantity, restored.quantity) ||
          !_correctionClose(
            amountBased ? effectiveCostOf(old) : old.costPrice,
            amountBased ? effectiveCostOf(restored) : restored.costPrice,
          )) {
        throw ArgumentError('现有流水与「${old.name}」的余额或成本不一致，无法安全重放');
      }
    }
    for (final holding in opening) {
      await _dao.updateHolding(
        holding.id == closedPosition?.holdingId
            ? holding.copyWith(
                quantity: closedPosition!.openingQuantity,
                costPrice:
                    closedPosition.openingCost / closedPosition.openingQuantity,
              )
            : holding,
      );
    }

    final edits = <int, TransactionRow>{original.id: revised};
    if (group != null && original.amount != revised.amount) {
      final holding = await _getHolding(group.holdingId!);
      final amountBased = AssetType.fromStorage(
        holding.assetType,
      ).isAmountBased;
      final oldQuantity = group.quantity ?? 0;
      if (oldQuantity <= 0 || group.amount <= 0) {
        throw ArgumentError('关联流水缺少有效的份额或金额');
      }
      edits[group.id] = group.copyWith(
        amount: revised.amount,
        quantity: Value(
          amountBased
              ? revised.amount
              : oldQuantity * revised.amount / group.amount,
        ),
      );
    }
    final updated = await _replayCorrection(operations, edits);
    final after = [for (final old in before) await _getHolding(old.id)];
    if (closedPosition != null &&
        before.indexed.any(
          (entry) =>
              !_correctionClose(entry.$2.quantity, after[entry.$1].quantity),
        )) {
      throw ArgumentError('清仓流水更正后的持仓或现金余额无法核对，账本未修改');
    }
    final impacts = [
      for (final (index, previous) in before.indexed)
        (before: previous, after: after[index]),
    ];
    final historicalGain = await _historicalGainPreview(impacts, rows);
    var historyFrom = original.occurredAt;
    for (final row in rows) {
      if (row != updated[row.id] && row.occurredAt.isBefore(historyFrom)) {
        historyFrom = row.occurredAt;
      }
    }
    final now = DateTime.now();
    for (final row in rows) {
      final next = updated[row.id]!;
      if (row != next) {
        await _dao.updateTransaction(
          next.copyWith(ledgerUpdatedAt: const Value(null)),
          now: now,
        );
      }
    }
    if (confirmed != null) {
      for (final (index, old) in before.indexed) {
        final next = after[index];
        if (next.copyWith(updatedAt: old.updatedAt) == old) {
          await _dao.updateHolding(old, now: old.updatedAt);
        }
      }
      await _dao.setSetting(historyFullRebuildKey, '1');
      await _dao.setSetting(historySyncDirtyKey, historyDirtySet);
    }
    return TransactionCorrectionPreview._(
      closedPosition,
      original: original,
      revised: revised,
      historyFrom: historyFrom,
      historicalGain: historicalGain,
      rows: rows,
      holdings: impacts,
    );
  }

  Future<_ClosedPositionCorrection?> _closedPositionCorrection(
    TransactionRow original,
    TransactionRow revised,
    List<TransactionRow> all,
  ) async {
    final id = original.holdingId;
    if (original.type != 'sell' ||
        id == null ||
        isRedemptionLeg(original) ||
        original.quantity == null ||
        original.price == null ||
        revised.quantity == null ||
        revised.price == null ||
        original.quantity! <= 0 ||
        original.price! <= original.quantity! ||
        !_correctionClose(revised.quantity!, original.price!) ||
        !_correctionClose(revised.price!, original.quantity!) ||
        !_correctionClose(original.amount, revised.amount) ||
        !_correctionClose(
          original.quantity! * original.price!,
          original.amount,
        )) {
      return null;
    }
    final holding = await _getHolding(id);
    final type = AssetType.fromStorage(holding.assetType);
    if (type.isAmountBased ||
        type == AssetType.liability ||
        holding.quantity != 0) {
      return null;
    }
    final events =
        all.where((row) => _correctionHoldingIds(row).contains(id)).toList()
          ..sort(compareTransactionEntryOrder);
    final prior = <TransactionRow>[];
    var oldBalance = 0.0;
    var correctedBalance = 0.0;
    var found = false;
    for (final row in events) {
      if (row.holdingId != id ||
          row.cashSourceId == id ||
          row.cashTargetId == id ||
          (row.type != 'buy' && row.type != 'sell') ||
          row.currency.toUpperCase() != holding.currency.toUpperCase() ||
          row.quantity == null ||
          !row.quantity!.isFinite ||
          row.quantity! <= 0) {
        throw ArgumentError('清仓记录存在无法核对的份额变动，无法安全更正');
      }
      if (row.id == original.id) found = true;
      if (!found) {
        if (row.type != 'buy' || row.occurredAt.isAfter(original.occurredAt)) {
          throw ArgumentError('清仓记录缺少可完整核对的买入基线，无法安全更正');
        }
        prior.add(row);
      } else if (row.type != 'sell' ||
          row.occurredAt.isBefore(original.occurredAt)) {
        throw ArgumentError('清仓卖出后存在其他份额变动，无法安全更正');
      }
      final sign = row.type == 'buy' ? 1.0 : -1.0;
      oldBalance += sign * row.quantity!;
      correctedBalance +=
          sign * (row.id == original.id ? revised.quantity! : row.quantity!);
      if (correctedBalance < -1e-8) {
        throw ArgumentError('更正后的卖出份额超过已记录买入，账本未修改');
      }
    }
    final difference = revised.quantity! - original.quantity!;
    if (!found ||
        prior.isEmpty ||
        !_correctionClose(correctedBalance, 0) ||
        !_correctionClose(oldBalance, difference)) {
      throw ArgumentError('更正后的全部买卖份额仍未归零，请核对是否有遗漏流水');
    }

    final needsSnapshot = prior.any(
      (row) =>
          (row.cashSourceId != null || row.internalMove) &&
          row.costMovedAmount == null,
    );
    final snapshots = needsSnapshot
        ? await _dao.getSnapshots()
        : <SnapshotRow>[];
    final resolved = needsSnapshot
        ? resolveLegacyTransferPrincipal(snapshots, all)
        : all;
    final byId = {for (final row in resolved) row.id: row};
    var openingQuantity = 0.0;
    var openingCost = 0.0;
    for (final raw in prior) {
      final row = byId[raw.id]!;
      final cost = row.cashSourceId != null || row.internalMove
          ? row.costMovedAmount
          : row.amount;
      if (cost == null || !cost.isFinite || cost < 0) {
        throw ArgumentError('清仓记录的买入本金无法核对，请先补齐成本记录');
      }
      openingQuantity += row.quantity!;
      openingCost += cost;
    }
    if (!openingCost.isFinite || openingCost <= 0) {
      throw ArgumentError('清仓记录缺少有效的买入成本，无法安全更正');
    }
    return _ClosedPositionCorrection(
      holdingId: id,
      quantity: difference,
      openingQuantity: openingQuantity,
      openingCost: openingCost,
      proofRows: all,
      proofSnapshots: snapshots,
    );
  }

  /// Reuses the most recent stored unit valuations when its holding amounts
  /// and cost can be reconciled to the pre-edit ledger. No new quotes are used.
  Future<({String date, double before, double after})?> _historicalGainPreview(
    List<({HoldingRow before, HoldingRow after})> holdings,
    List<TransactionRow> rows,
  ) async {
    final snapshot = await _dao.getLatestSnapshot('CNY');
    if (snapshot == null ||
        rows.any(
          (row) =>
              row.historyUpdatedAt.isAfter(snapshot.createdAt) ||
              todayKey(row.occurredAt.toLocal()).compareTo(snapshot.date) > 0,
        )) {
      return null;
    }
    final recorded = snapshotHoldingValues(snapshot);
    if (recorded == null) return null;
    final values = {for (final row in recorded) row.holdingId: row};
    var oldGain = 0.0;
    var newGain = 0.0;
    var checked = 0;
    for (final (:before, :after) in holdings) {
      final type = AssetType.fromStorage(before.assetType);
      if (type == AssetType.liability) continue;
      if (before.currency.toUpperCase() != 'CNY' ||
          before.updatedAt.isAfter(snapshot.createdAt)) {
        return null;
      }
      final old = values[before.id];
      final oldCost = type.isAmountBased
          ? effectiveCostOf(before)
          : before.quantity * before.costPrice;
      final newCost = type.isAmountBased
          ? effectiveCostOf(after)
          : after.quantity * after.costPrice;
      if (!_correctionClose(old?.cost ?? 0, oldCost) ||
          (old != null && old.type != type)) {
        return null;
      }
      final oldValue = old?.value ?? 0;
      final double newValue;
      if (type.isAmountBased) {
        if (!_correctionClose(oldValue, before.quantity)) return null;
        newValue = after.quantity;
      } else if (before.quantity > 0 && oldValue > 0) {
        newValue = (oldValue / before.quantity) * after.quantity;
      } else if (before.quantity == 0 && after.quantity == 0 && oldValue == 0) {
        newValue = 0;
      } else {
        return null;
      }
      oldGain += oldValue - oldCost;
      newGain += newValue - newCost;
      checked++;
    }
    return checked == 0 || !oldGain.isFinite || !newGain.isFinite
        ? null
        : (date: snapshot.date, before: oldGain, after: newGain);
  }

  Future<void> _undoCorrectionRow(
    TransactionRow row,
    Set<int> uncertainBasis,
  ) async {
    final type = TransactionType.fromStorage(row.type);
    final holding = row.holdingId == null
        ? null
        : await _getHolding(row.holdingId!);
    if (_isOpeningDebt(row)) {
      await _applyConsume(row.holdingId, -row.amount);
      return;
    }
    final needsRecordedPrincipal =
        isRedemptionLeg(row) ||
        (type == TransactionType.buy && row.cashSourceId != null) ||
        (type == TransactionType.sell && row.cashTargetId != null) ||
        type == TransactionType.expense ||
        ((type == TransactionType.transferIn ||
                type == TransactionType.transferOut) &&
            row.costMoved);
    if (needsRecordedPrincipal && row.costMovedAmount == null) {
      throw ArgumentError('关联流水缺少原始本金记录，无法安全重放');
    }
    if (holding != null &&
        !AssetType.fromStorage(holding.assetType).isAmountBased) {
      if (type == TransactionType.sell && uncertainBasis.remove(holding.id)) {
        final principal = isExternalSale(row)
            ? row.externalSellPrincipal
            : row.costMovedAmount;
        final quantity = row.quantity ?? 0;
        if (principal == null || quantity <= 0) {
          throw ArgumentError('「${holding.name}」清仓前的成本缺失，无法安全重放');
        }
        await _updateHolding(
          holding,
          quantity: holding.quantity,
          costPrice: principal / quantity,
        );
      }
      if (type == TransactionType.dividend && holding.costPrice <= 0) {
        throw ArgumentError('「${holding.name}」分红前的成本缺失，无法安全重放');
      }
      if (type == TransactionType.buy &&
          _correctionClose(holding.quantity, row.quantity ?? 0)) {
        uncertainBasis.add(holding.id);
      }
    }
    await _reverseTransaction(row, checkNewer: false);
  }

  Future<Map<int, TransactionRow>> _replayCorrection(
    List<List<TransactionRow>> operations,
    Map<int, TransactionRow> edits,
  ) async {
    final updated = <int, TransactionRow>{};
    for (final rows in operations) {
      if (rows.length == 2) {
        final sell = rows.firstWhere(
          (row) => row.type == TransactionType.sell.storageName,
        );
        final buy = rows.firstWhere(
          (row) => row.type == TransactionType.buy.storageName,
        );
        final debit = edits[sell.id] ?? sell;
        final credit = edits[buy.id] ?? buy;
        final source = await _getHolding(debit.holdingId!);
        final target = await _getHolding(credit.holdingId!);
        _assertSameCurrency(source, target);
        final quantity = debit.quantity ?? 0;
        if (!_correctionClose(debit.amount, credit.amount) ||
            quantity <= 0 ||
            quantity > source.quantity + 1e-9) {
          throw ArgumentError('「${source.name}」可赎回份额不足，或两笔关联金额不一致');
        }
        final principal = await _applyRedemption(
          source,
          AssetType.fromStorage(source.assetType),
          debit.amount,
          quantity,
        );
        if (_isOpening(credit) &&
            AssetType.fromStorage(target.assetType).isAmountBased) {
          await _applyCashMove(
            target.id,
            credit.amount,
            invested: true,
            costCredit: principal,
          );
        } else {
          await _applyBuy(
            holdingId: credit.holdingId,
            quantity: credit.quantity,
            amount: credit.amount,
            costBasis: principal,
          );
        }
        updated[sell.id] = _correctionMovedCost(sell, debit, principal);
        updated[buy.id] = _correctionMovedCost(buy, credit, principal);
        continue;
      }
      final original = rows.single;
      final row = edits[original.id] ?? original;
      final type = TransactionType.fromStorage(row.type);
      final double moved;
      if (_isOpeningDebt(row)) {
        await _applyConsume(row.holdingId, row.amount);
        moved = row.amount;
      } else if (row.holdingId == row.cashTargetId &&
          type == TransactionType.income &&
          _isOpening(row)) {
        final principal = original.costMovedAmount ?? original.amount;
        moved = await _applyCashMove(
          row.cashTargetId,
          row.amount,
          invested: true,
          costCredit: principal * row.amount / original.amount,
        );
      } else if (type == TransactionType.buy &&
          row.amount == 0 &&
          row.cashSourceId == null &&
          _isOpening(row)) {
        final holding = await _getHolding(row.holdingId!);
        final quantity = holding.quantity + row.quantity!;
        await _updateHolding(
          holding,
          quantity: quantity,
          costPrice: holding.quantity * holding.costPrice / quantity,
        );
        moved = 0;
      } else {
        moved = await _applyFlow(
          type: type,
          holdingId: row.holdingId,
          quantity: row.quantity,
          amount: row.amount,
          cashSourceId: row.cashSourceId,
          cashTargetId: row.cashTargetId,
          moveCost: row.costMoved,
        );
      }
      final tracked =
          type == TransactionType.buy &&
              _isOpening(row) &&
              row.cashSourceId == null
          ? row.amount
          : moved;
      updated[row.id] = isExternalSale(row)
          ? row.copyWith(externalSellPrincipal: Value(moved))
          : _correctionMovedCost(original, row, tracked);
    }
    return updated;
  }

  bool _isOpening(TransactionRow row) =>
      row.opensHolding ?? (row.note?.startsWith('新建持仓：') ?? false);

  bool _isOpeningDebt(TransactionRow row) =>
      _isOpening(row) &&
      row.type == TransactionType.transferOut.storageName &&
      row.holdingId != null &&
      row.holdingId == row.cashSourceId &&
      row.holdingId == row.cashTargetId;

  TransactionRow _correctionMovedCost(
    TransactionRow original,
    TransactionRow row,
    double moved,
  ) {
    final before = original.costMovedAmount;
    if (before != null && _correctionClose(before, moved)) return row;
    if (before == null && moved == 0 && original == row) return row;
    return row.copyWith(costMovedAmount: Value(moved));
  }
}

Set<int> _correctionHoldingIds(TransactionRow row) => {
  ?row.holdingId,
  ?row.cashSourceId,
  ?row.cashTargetId,
};

bool _correctionClose(double a, double b) =>
    a.isFinite &&
    b.isFinite &&
    (a - b).abs() <= 1e-8 + a.abs() * 1e-12 + b.abs() * 1e-12;

bool _sameClosedPositionProof(
  _ClosedPositionCorrection? a,
  _ClosedPositionCorrection? b,
) {
  if (a == null || b == null) return a == b;
  return a.holdingId == b.holdingId &&
      a.quantity == b.quantity &&
      a.openingQuantity == b.openingQuantity &&
      a.openingCost == b.openingCost &&
      a.proofRows.length == b.proofRows.length &&
      a.proofRows.indexed.every((e) => e.$2 == b.proofRows[e.$1]) &&
      a.proofSnapshots.length == b.proofSnapshots.length &&
      a.proofSnapshots.indexed.every((e) => e.$2 == b.proofSnapshots[e.$1]);
}
