import '../../core/enums.dart';

/// Largest price ratio accepted between two consecutive refreshes of the
/// same instrument. A genuine market move never multiplies (or divides) a
/// listed price by ten between two refreshes; a tenfold jump means the
/// quote came from a *different* instrument wearing the same symbol.
const _maxRefreshRatio = 10.0;

/// Sources whose instruments cannot legitimately move by a multiple between
/// refreshes. Crypto is excluded on purpose: a coin really can multiply over
/// a long enough gap, and a rejected quote silently freezes a holding at its
/// last price, so the guard stays where it is provably safe.
const _ratioGuardedSources = {
  MarketSource.sina,
  MarketSource.eastmoney,
  MarketSource.sge,
  MarketSource.forex,
};

/// Whether [newPrice] is a plausible next value for a holding whose last
/// known price was [previousPrice].
///
/// This is the last line of defence against *code collisions*. Security
/// identifiers are only six digits and are shared across markets — an
/// off-exchange fund code (400030 = 东方添益债券, NAV 1.4553) also exists on
/// the third-board market (400030 = 蓝璟5, 0.063). When a quote is fetched
/// from the wrong market it is internally consistent (a real price, a real
/// daily change), so nothing inside the payload looks wrong; only the
/// magnitude relative to the holding's own history gives it away. In that
/// incident the ratio was 23x, which this rejects, keeping the valid NAV.
///
/// [previousPrice] <= 0 means the holding has no price yet (fresh holding, or
/// one whose price was never recorded) — there is nothing to compare against,
/// so the quote is accepted.
///
/// The band is deliberately an order of magnitude wide. A 2-5x gap is still
/// inside the range a 北交所 stock or a fresh listing can cover legitimately,
/// so it is not rejected here; that class of collision is prevented
/// structurally instead, by never asking a stock endpoint about a fund. What
/// this catches is a quote that is *orders of magnitude* off, which no market
/// move produces.
bool isPlausiblePriceRefresh({
  required MarketSource source,
  required double previousPrice,
  required double newPrice,
}) {
  if (newPrice <= 0 || !newPrice.isFinite) return false;
  if (previousPrice <= 0 || !previousPrice.isFinite) return true;
  if (!_ratioGuardedSources.contains(source)) return true;
  final ratio = newPrice / previousPrice;
  return ratio <= _maxRefreshRatio && ratio >= 1 / _maxRefreshRatio;
}
