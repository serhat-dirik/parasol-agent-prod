import config from '@app/config';
import { formatAED } from '@app/utils/money';
import {
  Card, CardBody, CardTitle, Gallery, Grid, GridItem, Page, PageSection,
  Progress, ProgressMeasureLocation, Text, TextContent, TextVariants, Title,
} from '@patternfly/react-core';
import axios from 'axios';
import * as React from 'react';

interface Claim { claimNumber: string; claimant: string; type: string; status: string; amount: string; }

const STATUS_COLORS: Record<string, 'blue' | 'gold' | 'green' | 'red'> = {
  Submitted: 'blue', UnderReview: 'gold', Approved: 'green', Denied: 'red',
};
const STATUS_ORDER = ['Submitted', 'UnderReview', 'Approved', 'Denied'];

// Reports aggregates the same claims-db data the Claims list and Dashboard use, so the numbers
// always agree. No extra backend endpoint: the breakdowns are computed from /api/claims client-side.
const Reports: React.FunctionComponent = () => {
  const [claims, setClaims] = React.useState<Claim[]>([]);

  React.useEffect(() => {
    axios.get(config.backend_api_url + '/claims').then(r => setClaims(r.data)).catch(() => undefined);
  }, []);

  const total = claims.length;
  const amount = (c: Claim) => Number(c.amount) || 0;
  const totalClaimed = claims.reduce((s, c) => s + amount(c), 0);

  const byStatus = STATUS_ORDER.map(s => ({ status: s, count: claims.filter(c => c.status === s).length }));

  const types = Array.from(new Set(claims.map(c => c.type))).sort();
  const byType = types.map(t => {
    const rows = claims.filter(c => c.type === t);
    return { type: t, count: rows.length, sum: rows.reduce((s, c) => s + amount(c), 0) };
  });
  const maxTypeSum = Math.max(1, ...byType.map(t => t.sum));

  const stat = [
    { label: 'Total claims', value: String(total) },
    { label: 'Open', value: String(claims.filter(c => c.status === 'Submitted' || c.status === 'UnderReview').length) },
    { label: 'Approved', value: String(claims.filter(c => c.status === 'Approved').length) },
    { label: 'Denied', value: String(claims.filter(c => c.status === 'Denied').length) },
    { label: 'Total claimed', value: formatAED(totalClaimed) },
  ];

  return (
    <Page>
      <PageSection>
        <TextContent>
          <Text component={TextVariants.h1}>Reports</Text>
          <Text component={TextVariants.p}>Portfolio overview across all claims in the book.</Text>
        </TextContent>
      </PageSection>
      <PageSection>
        <Gallery hasGutter minWidths={{ default: '150px' }}>
          {stat.map(c => (
            <Card key={c.label} isCompact isRounded>
              <CardBody>
                <Title headingLevel="h2" size="2xl">{c.value}</Title>
                <TextContent><Text component={TextVariants.small}>{c.label}</Text></TextContent>
              </CardBody>
            </Card>
          ))}
        </Gallery>
      </PageSection>
      <PageSection>
        <Grid hasGutter>
          <GridItem span={6}>
            <Card isRounded>
              <CardTitle>Claims by status</CardTitle>
              <CardBody>
                {byStatus.map(s => (
                  <Progress
                    key={s.status}
                    title={s.status}
                    value={s.count}
                    min={0}
                    max={Math.max(1, total)}
                    label={`${s.count}`}
                    measureLocation={ProgressMeasureLocation.outside}
                    variant={s.status === 'Denied' ? 'danger' : s.status === 'Approved' ? 'success' : undefined}
                  />
                ))}
              </CardBody>
            </Card>
          </GridItem>
          <GridItem span={6}>
            <Card isRounded>
              <CardTitle>Claimed amount by line of business</CardTitle>
              <CardBody>
                {byType.map(t => (
                  <Progress
                    key={t.type}
                    title={`${t.type} (${t.count})`}
                    value={t.sum}
                    min={0}
                    max={maxTypeSum}
                    label={formatAED(t.sum)}
                    measureLocation={ProgressMeasureLocation.outside}
                  />
                ))}
                {byType.length === 0 && <Text>No claims to report.</Text>}
              </CardBody>
            </Card>
          </GridItem>
        </Grid>
      </PageSection>
    </Page>
  );
};

export { Reports };
