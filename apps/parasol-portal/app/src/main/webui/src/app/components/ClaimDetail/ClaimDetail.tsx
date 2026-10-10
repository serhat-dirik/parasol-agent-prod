import config from '@app/config';
import { faCommentDots, faFileLines } from '@fortawesome/free-regular-svg-icons';
import { faCaretDown, faShieldHalved, faUser } from '@fortawesome/free-solid-svg-icons';
import { FontAwesomeIcon } from '@fortawesome/react-fontawesome';
import { Breadcrumb, BreadcrumbItem, Button, Card, CardBody, Divider, Flex, FlexItem, Grid, GridItem, Label, Page, PageSection, Tab, Tabs, TabTitleText, Text, TextContent, TextVariants, Title } from '@patternfly/react-core';
import axios from 'axios';
import * as React from 'react';
import { useParams } from 'react-router-dom';
import { Chat } from '../Chat/Chat';

interface ClaimDoc {
  filename: string;
  vendor: string;
  visibleText: string;
  hiddenNote: string | null;
}

interface HistoryEntry {
  eventType: string;
  note: string;
  createdAt: string | null;
}

const labelColors: Record<string, 'green' | 'red' | 'gold' | 'blue'> = {
  'Approved': 'green',
  'Denied': 'red',
  'UnderReview': 'gold',
  'Submitted': 'blue',
};

const ClaimDetail: React.FunctionComponent = () => {

  // claimNumber is the claim number, e.g. CLM-1004
  const { claimNumber } = useParams<{ claimNumber: string }>();
  const [claim, setClaim] = React.useState<any>({});
  const [documents, setDocuments] = React.useState<ClaimDoc[]>([]);
  const [history, setHistory] = React.useState<HistoryEntry[]>([]);

  // Bumped whenever a chat turn completes, to re-fetch claim + timeline (a payout may have changed them).
  const [refreshKey, setRefreshKey] = React.useState(0);

  React.useEffect(() => {
    axios.get(config.backend_api_url + `/claims/${claimNumber}`)
      .then((response) => setClaim(response.data))
      .catch(error => console.error(error));
    axios.get(config.backend_api_url + `/claims/${claimNumber}/history`)
      .then((response) => setHistory(response.data))
      .catch(error => console.error(error));
  }, [claimNumber, refreshKey]);

  // Documents don't change across a turn, so fetch once per claim.
  React.useEffect(() => {
    axios.get(config.backend_api_url + `/claims/${claimNumber}/documents`)
      .then((response) => setDocuments(response.data))
      .catch(error => console.error(error));
  }, [claimNumber]);

  // Tabs control
  const [activeTabKey, setActiveTabKey] = React.useState<string | number>(0);
  const handleTabClick = (
    _event: React.MouseEvent<any> | React.KeyboardEvent | MouseEvent,
    tabIndex: string | number
  ) => setActiveTabKey(tabIndex);

  // Chat panel
  const [isChatOpen, setIsChatOpen] = React.useState(false);
  const handleChatToggle = (_event: KeyboardEvent | React.MouseEvent) => setIsChatOpen(!isChatOpen);

  return (
    <Page>
      <PageSection>
        <Breadcrumb ouiaId="BasicBreadcrumb" className='simple-padding'>
          <BreadcrumbItem to="/ClaimsList">&lt; Back to claims</BreadcrumbItem>
        </Breadcrumb>
        <Grid span={12} hasGutter className='padding-top-25'>
          <GridItem span={12}>
            <Card isRounded={true} className='width-100'>
              <CardBody>
                <Flex className='padding-bottom-25'>
                  <FlexItem>
                    <Title headingLevel="h1" size="2xl">
                      <FontAwesomeIcon className='colored-item-blue' icon={faFileLines} />&nbsp;{claim.claimNumber}
                    </Title>
                  </FlexItem>
                  <FlexItem>
                    <Label color={labelColors[String(claim.status)] || 'grey'}>{claim.status}</Label>
                  </FlexItem>
                  <FlexItem align={{ default: 'alignRight' }}>
                    <TextContent>
                      <Text className='colored-item-blue'>
                        <FontAwesomeIcon icon={faUser} />&nbsp;{claim.claimant || 'No claimant specified'}
                      </Text>
                    </TextContent>
                  </FlexItem>
                  <Divider orientation={{ default: 'vertical' }} />
                  <FlexItem>
                    <TextContent>
                      <Text className='colored-item-blue'>
                        <FontAwesomeIcon icon={faShieldHalved} />&nbsp;{claim.type || 'No type specified'}
                      </Text>
                    </TextContent>
                  </FlexItem>
                </Flex>
                <Flex className='padding-bottom-25'>
                  <FlexItem><TextContent><Text><b>Amount:</b> {claim.amount}</Text></TextContent></FlexItem>
                  <FlexItem><TextContent><Text><b>Adjuster:</b> {claim.adjuster}</Text></TextContent></FlexItem>
                  <FlexItem><TextContent><Text><b>Incident date:</b> {claim.incidentDate}</Text></TextContent></FlexItem>
                </Flex>
                <Flex>
                  <FlexItem className='width-100'>
                    <Tabs
                      activeKey={activeTabKey}
                      onSelect={handleTabClick}
                      aria-label="Tab navigation"
                      role="region"
                    >
                      <Tab eventKey={0} title={<TabTitleText>Documents</TabTitleText>} aria-label="Documents">
                        <div className='padding-top-25'>
                          {documents.length === 0 && <Text>No documents attached.</Text>}
                          {documents.map((doc, i) => (
                            <div key={i} className='padding-bottom-25'>
                              <TextContent>
                                <Text component={TextVariants.h3}>{doc.filename}</Text>
                                <Text component={TextVariants.small}>Vendor: {doc.vendor}</Text>
                              </TextContent>
                              {/* The hidden note is appended inside the same selectable block, styled
                                  white so that Select-All (Ctrl/Cmd-A) reveals it. */}
                              <pre className='doc-visible-text'>{doc.visibleText}{doc.hiddenNote ? <span className='doc-hidden-note'>{'\n' + doc.hiddenNote}</span> : null}</pre>
                              <Text className='doc-caption'>Customer upload</Text>
                            </div>
                          ))}
                        </div>
                      </Tab>
                      <Tab eventKey={1} title={<TabTitleText>Timeline</TabTitleText>} aria-label="Timeline">
                        <div className='padding-top-25'>
                          {history.length === 0 && <Text>No history yet.</Text>}
                          <ol>
                            {history.map((h, i) => (
                              <li key={i}>
                                <TextContent>
                                  <Text><b>{h.eventType}</b> — {h.note} {h.createdAt && <Text component={TextVariants.small}>({new Date(h.createdAt).toLocaleString()})</Text>}</Text>
                                </TextContent>
                              </li>
                            ))}
                          </ol>
                        </div>
                      </Tab>
                    </Tabs>
                  </FlexItem>
                </Flex>
              </CardBody>
            </Card>
          </GridItem>
        </Grid>
        <Flex>
          <FlexItem>
            <Button variant="link" onClick={handleChatToggle} className='icon-chat-button' aria-label='OpenChat'>
              {!isChatOpen ? <FontAwesomeIcon icon={faCommentDots} className='icon-chat' /> : <FontAwesomeIcon icon={faCaretDown} className='icon-chat' />}
            </Button>
          </FlexItem>
        </Flex>
        <Flex className={isChatOpen ? 'chat-fadeIn' : 'chat-fadeOut'}>
          <FlexItem className='chat-panel'>
            <Chat claimNumber={claim.claimNumber} onTurnComplete={() => setRefreshKey(k => k + 1)} />
          </FlexItem>
        </Flex>
      </PageSection>
    </Page>
  );
}

export { ClaimDetail };
