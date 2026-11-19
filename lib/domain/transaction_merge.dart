part of 'transaction_service.dart';

extension ConcurrentLedgerMerge on TransactionService {
  /// Run inside the transaction that installs the merged rows. A common
  /// opening balance must be recoverable from both devices before replay.
  Future<({List<HoldingRow> holdings, List<TransactionRow> transactions})?>
  reconcileConcurrentFlows({
    required Map<int, HoldingRow> localHoldings,
    required Map<int, HoldingRow> remoteHoldings,
    required Map<int, TransactionRow> localTransactions,
    required Map<int, TransactionRow> remoteTransactions,
    required List<TransactionRow> mergedTransactions,
  }) async {
    final localOnly = <TransactionRow>[];
    final remoteOnly = <TransactionRow>[];
    for (final row in mergedTransactions) {
      final local = localTransactions.containsKey(row.id);
      final remote = remoteTransactions.containsKey(row.id);
      if (local && !remote) localOnly.add(row);
      if (remote && !local) remoteOnly.add(row);
    }
    final remoteIds = remoteOnly.expand(_correctionHoldingIds).toSet();
    final affected = {
      for (final id in localOnly.expand(_correctionHoldingIds))
        if (remoteIds.contains(id) &&
            localHoldings.containsKey(id) &&
            remoteHoldings.containsKey(id))
          id,
    };
    if (affected.isEmpty) return null;

    final all = [
      ...localTransactions.values,
      ...remoteTransactions.values,
      ...mergedTransactions,
    ];
    final concurrent =
        [...localOnly, ...remoteOnly]
            .where((row) => _correctionHoldingIds(row).any(affected.contains))
            .toList()
          ..sort(compareTransactionEntryOrder);
    var first = concurrent.first;
    // Expand through linked cash balances and redemption pairs. Include
    // either leg together, even when its entry order straddles the cutoff.
    var expanded = true;
    while (expanded) {
      final size = affected.length;
      final previousFirst = first;
      for (final row in [...localOnly, ...remoteOnly]) {
        if (compareTransactionEntryOrder(row, first) < 0 &&
            _correctionHoldingIds(row).any(affected.contains)) {
          first = row;
        }
      }
      for (final row in all) {
        final ids = _correctionHoldingIds(row);
        if (compareTransactionEntryOrder(row, first) < 0 ||
            !ids.any(affected.contains)) {
          continue;
        }
        affected.addAll(ids);
        if (isRedemptionLeg(row)) {
          for (final other in all.where(
            (other) => hasSameRedemption(row, other),
          )) {
            affected.addAll(_correctionHoldingIds(other));
            if (compareTransactionEntryOrder(other, first) < 0) first = other;
          }
        }
      }
      expanded = affected.length != size || first != previousFirst;
    }

    bool relevant(TransactionRow row) =>
        compareTransactionEntryOrder(row, first) >= 0 &&
        _correctionHoldingIds(row).any(affected.contains);

    final merged = mergedTransactions.where(relevant).toList();
    final templates = {for (final id in affected) id: await _getHolding(id)};
    for (final row in merged) {
      if (await _dao.getTransaction(row.id) == null) {
        throw ArgumentError('关联流水有重复或缺失记录');
      }
    }

    Future<List<HoldingRow>> rewind(
      Map<int, HoldingRow> holdings,
      Map<int, TransactionRow> transactions,
    ) async {
      final tail = transactions.values.where(relevant).toList();
      for (final template in templates.values) {
        final branch = holdings[template.id];
        if (branch == null) {
          final opening = merged.any(
            (row) => row.holdingId == template.id && _isOpening(row),
          );
          if (!opening ||
              tail.any(
                (row) => _correctionHoldingIds(row).contains(template.id),
              )) {
            throw ArgumentError('「${template.name}」缺少同步前的持仓');
          }
          await _dao.updateHolding(
            template.copyWith(quantity: 0, costPrice: 0, costRecorded: true),
          );
        } else {
          if (branch.assetType != template.assetType ||
              branch.currency != template.currency ||
              branch.costFxRate != template.costFxRate) {
            throw ArgumentError('「${template.name}」的估值口径在两台设备上不同');
          }
          await _dao.updateHolding(
            template.copyWith(
              quantity: branch.quantity,
              costPrice: branch.costPrice,
              costRecorded: branch.costRecorded,
            ),
          );
        }
      }
      final operations = _mergeOperations(tail);
      final uncertainBasis = <int>{};
      for (final operation in operations.reversed) {
        for (final row in operation.reversed) {
          await _undoCorrectionRow(row, uncertainBasis);
        }
      }
      return [for (final id in affected) await _getHolding(id)];
    }

    final localOpening = await rewind(localHoldings, localTransactions);
    final remoteOpening = await rewind(remoteHoldings, remoteTransactions);
    var writeAt = DateTime.now();
    void includeVersion(DateTime version) {
      if (writeAt.millisecondsSinceEpoch ~/ 1000 <=
          version.millisecondsSinceEpoch ~/ 1000) {
        writeAt = version.add(const Duration(seconds: 1));
      }
    }

    for (final (index, local) in localOpening.indexed) {
      final remote = remoteOpening[index];
      final amountBased = AssetType.fromStorage(local.assetType).isAmountBased;
      final localCost = amountBased
          ? effectiveCostOf(local)
          : local.quantity * local.costPrice;
      final remoteCost = amountBased
          ? effectiveCostOf(remote)
          : remote.quantity * remote.costPrice;
      if (!_correctionClose(local.quantity, remote.quantity) ||
          !_correctionClose(localCost, remoteCost)) {
        throw ArgumentError('「${local.name}」的期初余额或成本无法核对');
      }
      final l = localHoldings[local.id];
      final r = remoteHoldings[local.id];
      if (l != null) includeVersion(l.updatedAt);
      if (r != null) includeVersion(r.updatedAt);
      await _dao.updateHolding(local);
    }

    final replayed = await _replayCorrection(
      _mergeOperations(merged),
      const {},
    );
    final changedTransactions = <TransactionRow>[];
    for (final row in merged) {
      final next = replayed[row.id]!;
      if (next == row) continue;
      includeVersion(row.updatedAt);
      final updated = next.copyWith(
        updatedAt: writeAt,
        ledgerUpdatedAt: Value(DateTime.now()),
      );
      await _dao.updateTransaction(updated, now: writeAt);
      changedTransactions.add(updated);
    }
    final changedHoldings = <HoldingRow>[];
    for (final template in templates.values) {
      final holding = await _getHolding(template.id);
      final next = template.copyWith(
        quantity: holding.quantity,
        costPrice: holding.costPrice,
        costRecorded: holding.costRecorded,
      );
      final updated = next == template
          ? template
          : next.copyWith(updatedAt: writeAt);
      await _dao.updateHolding(updated, now: updated.updatedAt);
      if (updated != template) changedHoldings.add(updated);
    }
    return (holdings: changedHoldings, transactions: changedTransactions);
  }

  List<List<TransactionRow>> _mergeOperations(List<TransactionRow> flows) {
    flows.sort(compareTransactionEntryOrder);
    final paired = <int>{};
    return [
      for (final row in flows)
        if (!paired.contains(row.id)) _mergeOperation(row, flows, paired),
    ];
  }

  List<TransactionRow> _mergeOperation(
    TransactionRow row,
    List<TransactionRow> flows,
    Set<int> paired,
  ) {
    if (!isRedemptionLeg(row)) return [row];
    final partner = redemptionPartner(row, flows);
    if (partner == null || compareTransactionEntryOrder(partner, row) < 0) {
      throw ArgumentError('关联的赎回与买入流水不完整');
    }
    final ids = {
      ..._correctionHoldingIds(row),
      ..._correctionHoldingIds(partner),
    };
    if (flows.any(
      (other) =>
          compareTransactionEntryOrder(other, row) > 0 &&
          compareTransactionEntryOrder(other, partner) < 0 &&
          _correctionHoldingIds(other).any(ids.contains),
    )) {
      throw ArgumentError('关联赎回之间存在其他资金变动');
    }
    paired.add(partner.id);
    return [row, partner];
  }
}
