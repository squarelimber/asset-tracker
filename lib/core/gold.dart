/// Gold price model shared by the live quote and the historical price
/// series.
///
/// The single most important property of this file: **both** the live gold
/// quote and the backfilled gold history must derive the CNY-per-gram
/// price from the same instrument with the same formula. Gold is quoted
/// in more than one market — London spot (USD per troy ounce) and the
/// Shanghai contracts (CNY per gram) — and mixing the two between the live
/// and the historical path applies their basis spread (roughly 1%) to
/// whichever day the two paths meet. That day is "today", which is written
/// by the live path and then re-derived from the history series by the next
/// rebuild, so the spread surfaced as a large fake daily return that
/// "fixed itself" a moment later.
///
/// Keeping the conversion in one place is what makes that class of bug
/// structurally impossible: there is no second constant to drift.
library;

/// Troy ounce -> gram (international avoirdupois definition).
const double gramsPerTroyOunce = 31.1034768;

/// Converts a London spot gold price ([usdPerOunce]) and a USD/CNY rate
/// ([usdCny]) into a CNY-per-gram price.
///
/// Both arguments must come from the same instant for the result to be
/// meaningful; the historical series pairs each day's gold close with the
/// latest FX rate on or before that day.
double goldCnyPerGram(double usdPerOunce, double usdCny) =>
    usdPerOunce * usdCny / gramsPerTroyOunce;

/// Display name of the derived gold quote.
///
/// The CNY-per-gram value tracks the Shanghai Au99.99 benchmark that
/// consumer gold-accumulation products settle against, so the label stays
/// the same even though the series is derived from London spot.
const String goldQuoteName = '黄金 (Au99.99)';
