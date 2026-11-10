// Display helper: format a numeric amount as USD with thousands separators, e.g. 84000 -> "USD 84,000".
// Keep the raw number for logic; use this only for display (claims list, detail, timeline, chat).
const usd = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  currencyDisplay: 'code',
  maximumFractionDigits: 0,
});

export function formatUSD(amount: number | string | null | undefined): string {
  if (amount === null || amount === undefined || amount === '') {
    return '';
  }
  const n = typeof amount === 'string' ? Number(amount) : amount;
  if (Number.isNaN(n)) {
    return String(amount);
  }
  return usd.format(n);
}
