import {
  Card, CardBody, DataList, DataListCell, DataListItem, DataListItemCells,
  DataListItemRow, Page, PageSection, Switch, Text, TextContent, TextVariants,
} from '@patternfly/react-core';
import * as React from 'react';

interface Sub { id: string; name: string; description: string; defaultOn: boolean; }

const SUBS: Sub[] = [
  { id: 'claim-updates', name: 'Claim status updates', description: 'Email me when a claim I own changes status.', defaultOn: true },
  { id: 'payout-alerts', name: 'Payout alerts', description: 'Notify me when a payment is issued on my claims.', defaultOn: true },
  { id: 'policy-renewals', name: 'Policy renewals', description: 'Remind me 30 days before a policy renews.', defaultOn: true },
  { id: 'doc-requests', name: 'Document requests', description: 'Tell me when a customer uploads a requested document.', defaultOn: false },
  { id: 'product-news', name: 'Product news', description: 'Occasional news about new Parasol products.', defaultOn: false },
  { id: 'assistant-digest', name: 'Assistant weekly digest', description: 'A weekly summary of my assistant activity.', defaultOn: false },
];

// Subscription preferences. Toggles are local UI state (upstream-style settings surface); they do
// not persist to a backend, matching the demo's read-only portal.
const Subscriptions: React.FunctionComponent = () => {
  const [state, setState] = React.useState<Record<string, boolean>>(
    Object.fromEntries(SUBS.map(s => [s.id, s.defaultOn])),
  );

  return (
    <Page>
      <PageSection>
        <TextContent>
          <Text component={TextVariants.h1}>Subscriptions</Text>
          <Text component={TextVariants.p}>Choose which notifications you receive.</Text>
        </TextContent>
      </PageSection>
      <PageSection>
        <Card component="div">
          <CardBody>
            <DataList aria-label="Subscription preferences">
              {SUBS.map(s => (
                <DataListItem key={s.id}>
                  <DataListItemRow>
                    <DataListItemCells dataListCells={[
                      <DataListCell key="label">
                        <TextContent>
                          <Text component={TextVariants.h4}>{s.name}</Text>
                          <Text component={TextVariants.small}>{s.description}</Text>
                        </TextContent>
                      </DataListCell>,
                      <DataListCell key="toggle" alignRight isFilled={false}>
                        <Switch
                          id={`sub-${s.id}`}
                          aria-label={s.name}
                          isChecked={state[s.id]}
                          onChange={(_e, checked) => setState(prev => ({ ...prev, [s.id]: checked }))}
                          label="On"
                          labelOff="Off"
                        />
                      </DataListCell>,
                    ]} />
                  </DataListItemRow>
                </DataListItem>
              ))}
            </DataList>
          </CardBody>
        </Card>
      </PageSection>
    </Page>
  );
};

export { Subscriptions };
