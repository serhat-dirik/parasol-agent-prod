import config from '@app/config';
import {
  Card, CardBody, CardTitle, DescriptionList, DescriptionListDescription,
  DescriptionListGroup, DescriptionListTerm, Form, FormGroup, FormSelect, FormSelectOption,
  Grid, GridItem, Label, Page, PageSection, Text, TextContent, TextVariants,
} from '@patternfly/react-core';
import axios from 'axios';
import * as React from 'react';

interface Me { username?: string; name?: string; role?: string; groups?: string[]; }

const Settings: React.FunctionComponent = () => {
  const [me, setMe] = React.useState<Me>({});
  const [theme, setTheme] = React.useState('System');
  const [language, setLanguage] = React.useState('English');
  const [density, setDensity] = React.useState('Comfortable');

  React.useEffect(() => {
    axios.get(config.backend_api_url + '/me').then(r => setMe(r.data)).catch(() => undefined);
  }, []);

  const groups = (me.groups || []).map(g => (g.startsWith('/') ? g.substring(1) : g));

  return (
    <Page>
      <PageSection>
        <TextContent>
          <Text component={TextVariants.h1}>Settings</Text>
          <Text component={TextVariants.p}>Your profile and portal preferences.</Text>
        </TextContent>
      </PageSection>
      <PageSection>
        <Grid hasGutter>
          <GridItem span={6}>
            <Card isRounded>
              <CardTitle>Profile</CardTitle>
              <CardBody>
                <DescriptionList isHorizontal>
                  <DescriptionListGroup>
                    <DescriptionListTerm>Name</DescriptionListTerm>
                    <DescriptionListDescription>{me.name || me.username || '—'}</DescriptionListDescription>
                  </DescriptionListGroup>
                  <DescriptionListGroup>
                    <DescriptionListTerm>Username</DescriptionListTerm>
                    <DescriptionListDescription>{me.username || '—'}</DescriptionListDescription>
                  </DescriptionListGroup>
                  <DescriptionListGroup>
                    <DescriptionListTerm>Role</DescriptionListTerm>
                    <DescriptionListDescription>{me.role || '—'}</DescriptionListDescription>
                  </DescriptionListGroup>
                  <DescriptionListGroup>
                    <DescriptionListTerm>Groups</DescriptionListTerm>
                    <DescriptionListDescription>
                      {groups.length ? groups.map(g => <Label key={g} className="simple-padding">{g}</Label>) : '—'}
                    </DescriptionListDescription>
                  </DescriptionListGroup>
                </DescriptionList>
              </CardBody>
            </Card>
          </GridItem>
          <GridItem span={6}>
            <Card isRounded>
              <CardTitle>Preferences</CardTitle>
              <CardBody>
                <Form>
                  <FormGroup label="Theme" fieldId="pref-theme">
                    <FormSelect id="pref-theme" value={theme} onChange={(_e, v) => setTheme(v)} aria-label="Theme">
                      {['System', 'Light', 'Dark'].map(o => <FormSelectOption key={o} value={o} label={o} />)}
                    </FormSelect>
                  </FormGroup>
                  <FormGroup label="Language" fieldId="pref-lang">
                    <FormSelect id="pref-lang" value={language} onChange={(_e, v) => setLanguage(v)} aria-label="Language">
                      {['English', 'العربية', 'Français'].map(o => <FormSelectOption key={o} value={o} label={o} />)}
                    </FormSelect>
                  </FormGroup>
                  <FormGroup label="Table density" fieldId="pref-density">
                    <FormSelect id="pref-density" value={density} onChange={(_e, v) => setDensity(v)} aria-label="Table density">
                      {['Comfortable', 'Compact'].map(o => <FormSelectOption key={o} value={o} label={o} />)}
                    </FormSelect>
                  </FormGroup>
                </Form>
              </CardBody>
            </Card>
          </GridItem>
        </Grid>
      </PageSection>
    </Page>
  );
};

export { Settings };
