// Display helper: format a numeric amount as AED with thousands separators, e.g. 84000 -> "AED 84,000".
// Keep the raw number for logic; use this only for display (claims list, detail, timeline, chat, propose card).
const aed = new Intl.NumberFormat('en-AE', {
  style: 'currency',
  currency: 'AED',
  maximumFractionDigits: 0,
});

export function formatAED(amount: number | string | null | undefined): string {
  if (amount === null || amount === undefined || amount === '') {
    return '';
  }
  const n = typeof amount === 'string' ? Number(amount) : amount;
  if (Number.isNaN(n)) {
    return String(amount);
  }
  return aed.format(n);
}
