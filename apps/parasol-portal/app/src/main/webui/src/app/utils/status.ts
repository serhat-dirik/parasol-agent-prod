// Claim workflow statuses as claims-db stores them, and how the portal shows them.
// ReadyForPayment: two-stage approval (secured), the claim is approved and waits for a claims manager to release the payment.
export const statusLabel = (status: string | undefined): string =>
    status === 'ReadyForPayment' ? 'Ready for payment' : String(status ?? '');

export const statusColors: Record<string, 'green' | 'red' | 'gold' | 'blue' | 'cyan'> = {
    'Approved': 'green',
    'Denied': 'red',
    'UnderReview': 'gold',
    'ReadyForPayment': 'cyan',
    'Submitted': 'blue',
};
