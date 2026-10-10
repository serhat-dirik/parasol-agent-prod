import config from '@app/config';
import { formatAED } from '@app/utils/money';
import {
  Card, CardBody, CardTitle, Gallery, Grid, GridItem, Page, PageSection,
  Text, TextContent, TextVariants, Title,
} from '@patternfly/react-core';
import axios from 'axios';
import * as React from 'react';
import { Link } from 'react-router-dom';

interface RecentEvent { claimNumber: string; eventType: string; note: string; createdAt: string | null; }
interface DashboardData { statusCounts: Record<string, number>; paidCount: number; recentEvents: RecentEvent[]; }
interface Usage { requests: number; tokens: number; }

const Dashboard: React.FunctionComponent = () => {
  const [data, setData] = React.useState<DashboardData | null>(null);
  const [usage, setUsage] = React.useState<Usage | null>(null);

  React.useEffect(() => {
    axios.get(config.backend_api_url + '/dashboard').then(r => setData(r.data)).catch(() => undefined);
    axios.get(config.backend_api_url + '/me/usage').then(r => setUsage(r.data)).catch(() => undefined);
  }, []);

  const counts = data?.statusCounts || {};
  // Card label -> value. "Open" maps to Submitted; "Paid" is the distinct count of paid claims.
  const statCards: { label: string; value: number }[] = [
    { label: 'Open', value: counts['Submitted'] || 0 },
    { label: 'Under review', value: counts['UnderReview'] || 0 },
    { label: 'Approved', value: counts['Approved'] || 0 },
    { label: 'Denied', value: counts['Denied'] || 0 },
    { label: 'Paid', value: data?.paidCount || 0 },
  ];

  const fmtTime = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : '');

  return (
    <Page>
      <PageSection>
        <TextContent><Text component={TextVariants.h1}>Dashboard</Text></TextContent>
      </PageSection>
      <PageSection>
        <Gallery hasGutter minWidths={{ default: '150px' }}>
          {statCards.map(c => (
            <Card key={c.label} isCompact isRounded>
              <CardBody>
                <Title headingLevel="h2" size="3xl">{c.value}</Title>
                <TextContent><Text component={TextVariants.small}>{c.label}</Text></TextContent>
              </CardBody>
            </Card>
          ))}
        </Gallery>
      </PageSection>
      <PageSection>
        <Grid hasGutter>
          <GridItem span={8}>
            <Card isRounded>
              <CardTitle>Recent activity</CardTitle>
              <CardBody>
                {(data?.recentEvents || []).length === 0 && <Text>No recent activity.</Text>}
                {(data?.recentEvents || []).map((e, i) => {
                  const viaAssistant = (e.note || '').toLowerCase().includes('assistant');
                  return (
                    <div key={i} className="dash-event">
                      <Link to={`/ClaimDetail/${e.claimNumber}`}>{e.claimNumber}</Link>
                      {' '}<b>{e.eventType}</b>
                      {viaAssistant && <span className="dash-via"> via assistant</span>}
                      <div className="dash-event-note">{e.note}</div>
                      <div className="dash-event-time">{fmtTime(e.createdAt)}</div>
                    </div>
                  );
                })}
              </CardBody>
            </Card>
          </GridItem>
          <GridItem span={4}>
            <Card isRounded>
              <CardTitle>Assistant today</CardTitle>
              <CardBody>
                <TextContent>
                  <Title headingLevel="h2" size="2xl">{usage ? usage.requests : '—'}</Title>
                  <Text component={TextVariants.small}>assistant requests (you)</Text>
                  <Title headingLevel="h2" size="2xl">{usage ? usage.tokens.toLocaleString() : '—'}</Title>
                  <Text component={TextVariants.small}>tokens used (you)</Text>
                </TextContent>
              </CardBody>
            </Card>
          </GridItem>
        </Grid>
      </PageSection>
    </Page>
  );
};

export { Dashboard };
