import { formatAED } from '@app/utils/money';
import { Card, Label, Page, PageSection, Text, TextContent, TextVariants } from '@patternfly/react-core';
import { Table, Tbody, Td, Th, Thead, Tr } from '@patternfly/react-table';
import * as React from 'react';

interface Annuity { name: string; type: string; rate: string; term: string; minContribution: number; status: string; }

// Static, upstream-style catalogue of Parasol annuity products.
const ANNUITIES: Annuity[] = [
  { name: 'Parasol Fixed 5', type: 'Fixed', rate: '4.25%', term: '5 years', minContribution: 50000, status: 'Open' },
  { name: 'Parasol Fixed 10', type: 'Fixed', rate: '4.75%', term: '10 years', minContribution: 50000, status: 'Open' },
  { name: 'Parasol Indexed Growth', type: 'Indexed', rate: '2.0% + index', term: '7 years', minContribution: 100000, status: 'Open' },
  { name: 'Parasol Variable Select', type: 'Variable', rate: 'Market-linked', term: 'Flexible', minContribution: 150000, status: 'Open' },
  { name: 'Parasol Immediate Income', type: 'Immediate', rate: '5.10%', term: 'Lifetime', minContribution: 250000, status: 'Closed to new' },
];

const typeColors: Record<string, 'blue' | 'green' | 'gold' | 'purple'> = {
  Fixed: 'blue', Indexed: 'green', Variable: 'purple', Immediate: 'gold',
};

const Annuities: React.FunctionComponent = () => (
  <Page>
    <PageSection>
      <TextContent>
        <Text component={TextVariants.h1}>Annuities</Text>
        <Text component={TextVariants.p}>Retirement income products available to Parasol customers.</Text>
      </TextContent>
    </PageSection>
    <PageSection>
      <Card component="div">
        <Table aria-label="Annuities" isStickyHeader>
          <Thead>
            <Tr>
              <Th width={25}>Product</Th>
              <Th width={15}>Type</Th>
              <Th width={15}>Rate</Th>
              <Th width={15}>Term</Th>
              <Th width={15}>Minimum</Th>
              <Th width={15}>Availability</Th>
            </Tr>
          </Thead>
          <Tbody>
            {ANNUITIES.map(a => (
              <Tr key={a.name}>
                <Td dataLabel="Product">{a.name}</Td>
                <Td dataLabel="Type"><Label color={typeColors[a.type] || 'grey'}>{a.type}</Label></Td>
                <Td dataLabel="Rate">{a.rate}</Td>
                <Td dataLabel="Term">{a.term}</Td>
                <Td dataLabel="Minimum">{formatAED(a.minContribution)}</Td>
                <Td dataLabel="Availability">
                  <Label color={a.status === 'Open' ? 'green' : 'orange'}>{a.status}</Label>
                </Td>
              </Tr>
            ))}
          </Tbody>
        </Table>
      </Card>
    </PageSection>
  </Page>
);

export { Annuities };
