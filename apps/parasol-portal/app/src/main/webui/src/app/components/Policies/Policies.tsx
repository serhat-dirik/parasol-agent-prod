import config from '@app/config';
import { formatAED } from '@app/utils/money';
import { Card, Label, Page, PageSection, Text, TextContent, TextVariants } from '@patternfly/react-core';
import { Table, Tbody, Td, Th, Thead, Tr } from '@patternfly/react-table';
import axios from 'axios';
import * as React from 'react';

interface Claim { claimant: string; type: string; amount: string; }
interface Policy { policyNumber: string; holder: string; product: string; premium: number; status: string; }

// Lines of business map to products and an indicative annual premium.
const PRODUCT: Record<string, { name: string; premium: number }> = {
  auto: { name: 'Auto Protect', premium: 2400 },
  home: { name: 'Home Shield', premium: 3600 },
  life: { name: 'Life Secure', premium: 1800 },
};
const productColors: Record<string, 'blue' | 'green' | 'purple'> = { auto: 'blue', home: 'green', life: 'purple' };

// Policies are derived from the claims book: one active policy per policyholder + line of business,
// so the directory stays consistent with the claims data (claims-db /api/claims).
const Policies: React.FunctionComponent = () => {
  const [claims, setClaims] = React.useState<Claim[]>([]);

  React.useEffect(() => {
    axios.get(config.backend_api_url + '/claims').then(r => setClaims(r.data)).catch(() => undefined);
  }, []);

  const seen = new Set<string>();
  const policies: Policy[] = [];
  claims.forEach(c => {
    const key = `${c.claimant}|${c.type}`;
    if (seen.has(key)) return;
    seen.add(key);
    const p = PRODUCT[(c.type || '').toLowerCase()] || { name: c.type, premium: 0 };
    // Deterministic policy number from the holder name, so the page is stable across reloads.
    const n = 10000 + ([...key].reduce((a, ch) => (a * 31 + ch.charCodeAt(0)) % 90000, 7));
    policies.push({ policyNumber: `POL-${n}`, holder: c.claimant, product: p.name, premium: p.premium, status: 'Active' });
  });
  policies.sort((a, b) => a.policyNumber.localeCompare(b.policyNumber));

  return (
    <Page>
      <PageSection>
        <TextContent>
          <Text component={TextVariants.h1}>Policies</Text>
          <Text component={TextVariants.p}>Active insurance policies for Parasol policyholders.</Text>
        </TextContent>
      </PageSection>
      <PageSection>
        <Card component="div">
          <Table aria-label="Policies" isStickyHeader>
            <Thead>
              <Tr>
                <Th width={15}>Policy</Th>
                <Th width={30}>Policyholder</Th>
                <Th width={20}>Product</Th>
                <Th width={20}>Annual premium</Th>
                <Th width={15}>Status</Th>
              </Tr>
            </Thead>
            <Tbody>
              {policies.map(p => {
                const key = p.product.toLowerCase().includes('auto') ? 'auto'
                  : p.product.toLowerCase().includes('home') ? 'home'
                    : p.product.toLowerCase().includes('life') ? 'life' : '';
                return (
                  <Tr key={p.policyNumber}>
                    <Td dataLabel="Policy">{p.policyNumber}</Td>
                    <Td dataLabel="Policyholder">{p.holder}</Td>
                    <Td dataLabel="Product"><Label color={productColors[key] || 'grey'}>{p.product}</Label></Td>
                    <Td dataLabel="Annual premium">{p.premium ? formatAED(p.premium) : '—'}</Td>
                    <Td dataLabel="Status"><Label color="green">{p.status}</Label></Td>
                  </Tr>
                );
              })}
              {policies.length === 0 && <Tr><Td colSpan={5}>No policies found.</Td></Tr>}
            </Tbody>
          </Table>
        </Card>
      </PageSection>
    </Page>
  );
};

export { Policies };
