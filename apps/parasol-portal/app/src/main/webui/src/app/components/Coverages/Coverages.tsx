import { formatAED } from '@app/utils/money';
import {
  Card, CardBody, CardTitle, DescriptionList, DescriptionListDescription,
  DescriptionListGroup, DescriptionListTerm, Gallery, Label, Page, PageSection,
  Text, TextContent, TextVariants,
} from '@patternfly/react-core';
import * as React from 'react';

interface Coverage { name: string; limit: number; deductible: number; }
interface Product { product: string; color: 'blue' | 'green' | 'purple'; coverages: Coverage[]; }

// Reference catalogue of what each Parasol product covers. Static, upstream-style content.
const PRODUCTS: Product[] = [
  {
    product: 'Auto Protect', color: 'blue', coverages: [
      { name: 'Collision', limit: 150000, deductible: 1000 },
      { name: 'Third-party liability', limit: 500000, deductible: 0 },
      { name: 'Fire & theft', limit: 150000, deductible: 1500 },
      { name: 'Personal accident', limit: 200000, deductible: 0 },
    ],
  },
  {
    product: 'Home Shield', color: 'green', coverages: [
      { name: 'Buildings', limit: 2000000, deductible: 2500 },
      { name: 'Contents', limit: 500000, deductible: 1000 },
      { name: 'Water damage', limit: 250000, deductible: 2000 },
      { name: 'Personal liability', limit: 1000000, deductible: 0 },
    ],
  },
  {
    product: 'Life Secure', color: 'purple', coverages: [
      { name: 'Term life', limit: 1000000, deductible: 0 },
      { name: 'Critical illness', limit: 500000, deductible: 0 },
      { name: 'Total permanent disability', limit: 750000, deductible: 0 },
    ],
  },
];

const Coverages: React.FunctionComponent = () => (
  <Page>
    <PageSection>
      <TextContent>
        <Text component={TextVariants.h1}>Coverages</Text>
        <Text component={TextVariants.p}>Standard coverage limits and deductibles by product line.</Text>
      </TextContent>
    </PageSection>
    <PageSection>
      <Gallery hasGutter minWidths={{ default: '320px' }}>
        {PRODUCTS.map(p => (
          <Card key={p.product} isRounded>
            <CardTitle><Label color={p.color}>{p.product}</Label></CardTitle>
            <CardBody>
              <DescriptionList isCompact isHorizontal>
                {p.coverages.map(c => (
                  <DescriptionListGroup key={c.name}>
                    <DescriptionListTerm>{c.name}</DescriptionListTerm>
                    <DescriptionListDescription>
                      {formatAED(c.limit)}
                      <Text component={TextVariants.small}>
                        {c.deductible ? ` · deductible ${formatAED(c.deductible)}` : ' · no deductible'}
                      </Text>
                    </DescriptionListDescription>
                  </DescriptionListGroup>
                ))}
              </DescriptionList>
            </CardBody>
          </Card>
        ))}
      </Gallery>
    </PageSection>
  </Page>
);

export { Coverages };
