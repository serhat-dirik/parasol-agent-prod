import {
  Card, CardBody, CardTitle, Gallery, Grid, GridItem, Label, Page, PageSection,
  Text, TextContent, TextVariants, Title,
} from '@patternfly/react-core';
import { Table, Tbody, Td, Th, Thead, Tr } from '@patternfly/react-table';
import * as React from 'react';

interface User { name: string; username: string; role: string; group: string; }

// Realm directory (Keycloak `parasol` realm), shown read-only for the Admin console.
const USERS: User[] = [
  { name: 'Rebecca Torres', username: 'rebecca', role: 'Claims adjuster', group: 'adjusters' },
  { name: 'Marcus Lee', username: 'marcus', role: 'Claims manager', group: 'claims-managers' },
  { name: 'Dev Patel', username: 'dev', role: 'Developer', group: 'developers' },
  { name: 'Tom Becker', username: 'tom.becker', role: 'Policyholder', group: 'policyholders' },
];

const groupColors: Record<string, 'blue' | 'green' | 'purple' | 'orange'> = {
  adjusters: 'blue', 'claims-managers': 'green', developers: 'purple', policyholders: 'orange',
};

const STATUS = [
  { label: 'Identity provider', value: 'Keycloak', ok: true },
  { label: 'Claims service', value: 'Online', ok: true },
  { label: 'Assistant', value: 'Available', ok: true },
  { label: 'Users', value: String(USERS.length), ok: true },
];

const Admin: React.FunctionComponent = () => (
  <Page>
    <PageSection>
      <TextContent>
        <Text component={TextVariants.h1}>Admin</Text>
        <Text component={TextVariants.p}>Users, roles and service status for this Parasol workspace.</Text>
      </TextContent>
    </PageSection>
    <PageSection>
      <Gallery hasGutter minWidths={{ default: '180px' }}>
        {STATUS.map(s => (
          <Card key={s.label} isCompact isRounded>
            <CardBody>
              <Title headingLevel="h2" size="2xl">{s.value}</Title>
              <TextContent><Text component={TextVariants.small}>{s.label}</Text></TextContent>
            </CardBody>
          </Card>
        ))}
      </Gallery>
    </PageSection>
    <PageSection>
      <Grid hasGutter>
        <GridItem span={12}>
          <Card isRounded>
            <CardTitle>User directory</CardTitle>
            <CardBody>
              <Table aria-label="Users">
                <Thead>
                  <Tr>
                    <Th width={30}>Name</Th>
                    <Th width={20}>Username</Th>
                    <Th width={25}>Role</Th>
                    <Th width={25}>Group</Th>
                  </Tr>
                </Thead>
                <Tbody>
                  {USERS.map(u => (
                    <Tr key={u.username}>
                      <Td dataLabel="Name">{u.name}</Td>
                      <Td dataLabel="Username">{u.username}</Td>
                      <Td dataLabel="Role">{u.role}</Td>
                      <Td dataLabel="Group"><Label color={groupColors[u.group] || 'grey'}>{u.group}</Label></Td>
                    </Tr>
                  ))}
                </Tbody>
              </Table>
            </CardBody>
          </Card>
        </GridItem>
      </Grid>
    </PageSection>
  </Page>
);

export { Admin };
