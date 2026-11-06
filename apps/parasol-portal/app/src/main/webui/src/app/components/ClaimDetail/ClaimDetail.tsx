import config from '@app/config';
import carAccident1 from '@app/assets/images/claims/car-accident-1.jpg';
import carAccident2 from '@app/assets/images/claims/car-accident-2.jpg';
import carAccident3 from '@app/assets/images/claims/car-accident-3.jpg';
import carWreck from '@app/assets/images/claims/car-wreck.jpg';
import floodDamage from '@app/assets/images/claims/flood-damage.jpg';
import roofDamage from '@app/assets/images/claims/roof-damage.jpg';
import stormHouse from '@app/assets/images/claims/storm-house.jpg';
import { formatUSD } from '@app/utils/money';
import { faCalendar, faCommentDots, faFileLines } from '@fortawesome/free-regular-svg-icons';
import { faCaretDown, faLocationDot, faPaperclip, faShieldHalved, faUser } from '@fortawesome/free-solid-svg-icons';
import { FontAwesomeIcon } from '@fortawesome/react-fontawesome';
import { Breadcrumb, BreadcrumbItem, Button, Card, CardBody, DescriptionList, DescriptionListDescription, DescriptionListGroup, DescriptionListTerm, Divider, Flex, FlexItem, Grid, GridItem, Label, Page, PageSection, Tab, Tabs, TabTitleText, Text, TextContent, TextVariants, Title } from '@patternfly/react-core';
import axios from 'axios';
import * as React from 'react';
import { useParams } from 'react-router-dom';
import { Chat } from '../Chat/Chat';

// The photos claims-db names in a claim's details (file name -> bundled asset).
const photoUrls: Record<string, string> = {
  'car-accident-1.jpg': carAccident1,
  'car-accident-2.jpg': carAccident2,
  'car-accident-3.jpg': carAccident3,
  'car-wreck.jpg': carWreck,
  'flood-damage.jpg': floodDamage,
  'roof-damage.jpg': roofDamage,
  'storm-house.jpg': stormHouse,
};

interface ClaimDetails {
  eventTime: string;
  location: string;
  summary: string;
  clientEmail: string;
  clientPhone: string;
  policyNumber: string;
  coverage: string;
  deductible: string;
  coverageLimit: string;
  photos: string[];
}

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
  // Secured: claims-db refuses a claim outside the user's records (403); the page then shows the refusal, no data.
  const [refusal, setRefusal] = React.useState<string | null>(null);

  // Bumped whenever a chat turn completes, to re-fetch claim + timeline (a payout may have changed them).
  const [refreshKey, setRefreshKey] = React.useState(0);

  React.useEffect(() => {
    axios.get(config.backend_api_url + `/claims/${claimNumber}`)
      .then((response) => { setClaim(response.data); setRefusal(null); })
      .catch(error => {
        if (error?.response?.status === 403) {
          setRefusal(error.response.data?.message || 'This claim is not assigned to you.');
        } else {
          console.error(error);
        }
      });
    axios.get(config.backend_api_url + `/claims/${claimNumber}/history`)
      .then((response) => setHistory(response.data))
      .catch(() => setHistory([]));
  }, [claimNumber, refreshKey]);

  // Documents and details don't change across a turn, so fetch once per claim.
  const [details, setDetails] = React.useState<ClaimDetails | null>(null);
  const [photo, setPhoto] = React.useState(0);
  React.useEffect(() => {
    axios.get(config.backend_api_url + `/claims/${claimNumber}/documents`)
      .then((response) => setDocuments(response.data))
      .catch(() => setDocuments([]));
    axios.get(config.backend_api_url + `/claims/${claimNumber}/details`)
      .then((response) => { setDetails(response.data); setPhoto(0); })
      .catch(() => setDetails(null));
  }, [claimNumber]);
  const photos = (details?.photos || []).map((p) => photoUrls[p]).filter(Boolean);

  // Tabs control
  const [activeTabKey, setActiveTabKey] = React.useState<string | number>(0);
  const handleTabClick = (
    _event: React.MouseEvent<any> | React.KeyboardEvent | MouseEvent,
    tabIndex: string | number
  ) => setActiveTabKey(tabIndex);

  // Chat panel
  const [isChatOpen, setIsChatOpen] = React.useState(false);
  const handleChatToggle = (_event: KeyboardEvent | React.MouseEvent) => setIsChatOpen(!isChatOpen);

  if (refusal) {
    return (
      <Page>
        <PageSection>
          <Breadcrumb ouiaId="RefusedBreadcrumb" className='simple-padding'>
            <BreadcrumbItem to="/ClaimsList">&lt; Back to claims</BreadcrumbItem>
          </Breadcrumb>
          <Card isRounded={true} className='width-100 padding-top-25'>
            <CardBody>
              <Title headingLevel="h1" size="2xl">
                <FontAwesomeIcon className='colored-item-blue' icon={faShieldHalved} />&nbsp;{claimNumber} is not assigned to you
              </Title>
              <TextContent className='padding-top-25'>
                <Text>{refusal}</Text>
                <Text component={TextVariants.small}>Decided by claims-db from your identity: the same rule the assistant's tools get.</Text>
              </TextContent>
            </CardBody>
          </Card>
        </PageSection>
      </Page>
    );
  }

  return (
    <Page>
      <PageSection>
        <Breadcrumb ouiaId="BasicBreadcrumb" className='simple-padding'>
          <BreadcrumbItem to="/ClaimsList">&lt; Back to claims</BreadcrumbItem>
        </Breadcrumb>
        <Grid hasGutter className='padding-top-25'>
          <GridItem span={12}>
            <Card isRounded={true} className='width-100'>
              <CardBody>
                <Flex alignItems={{ default: 'alignItemsCenter' }}>
                  <FlexItem>
                    <Title headingLevel="h1" size="2xl">
                      <FontAwesomeIcon className='colored-item-blue' icon={faFileLines} />&nbsp;{claim.claimNumber}
                    </Title>
                  </FlexItem>
                  <FlexItem>
                    <Label color={labelColors[String(claim.status)] || 'grey'}>{claim.status}</Label>
                  </FlexItem>
                  <Divider orientation={{ default: 'vertical' }} />
                  <FlexItem>
                    <Text className='colored-item-blue'><FontAwesomeIcon icon={faUser} />&nbsp;{claim.claimant || 'No claimant specified'}</Text>
                  </FlexItem>
                  {details?.policyNumber && <>
                    <Divider orientation={{ default: 'vertical' }} />
                    <FlexItem>
                      <Text className='colored-item-blue'><FontAwesomeIcon icon={faShieldHalved} />&nbsp;{details.policyNumber}</Text>
                    </FlexItem>
                  </>}
                </Flex>
                <Flex className='padding-top-25'>
                  <FlexItem><TextContent><Text><b>Amount:</b> {formatUSD(claim.amount)}</Text></TextContent></FlexItem>
                  <FlexItem><TextContent><Text><b>Adjuster:</b> {claim.adjuster}</Text></TextContent></FlexItem>
                  <FlexItem><TextContent><Text><b>Incident date:</b> {claim.incidentDate}</Text></TextContent></FlexItem>
                  <FlexItem><TextContent><Text><b>Type:</b> {claim.type}</Text></TextContent></FlexItem>
                </Flex>
              </CardBody>
            </Card>
          </GridItem>
          <GridItem span={12} lg={photos.length ? 8 : 12}>
            <Card isRounded={true} className='width-100'>
              <CardBody>
                <Tabs activeKey={activeTabKey} onSelect={handleTabClick} aria-label="Claim sections" role="region">
                  <Tab eventKey={0} title={<TabTitleText>Summary</TabTitleText>} aria-label="Summary">
                    <div className='padding-top-25'>
                      <div className='claim-fact'>
                        <FontAwesomeIcon icon={faCalendar} className='claim-fact-icon' />
                        <TextContent><Text component={TextVariants.h4}>Date and time</Text><Text>{details?.eventTime || claim.incidentDate}</Text></TextContent>
                      </div>
                      {details?.location && <div className='claim-fact'>
                        <FontAwesomeIcon icon={faLocationDot} className='claim-fact-icon' />
                        <TextContent><Text component={TextVariants.h4}>Location of event</Text><Text>{details.location}</Text></TextContent>
                      </div>}
                      {details?.summary && <div className='claim-fact'>
                        <FontAwesomeIcon icon={faFileLines} className='claim-fact-icon' />
                        <TextContent><Text component={TextVariants.h4}>Summary</Text><Text>{details.summary}</Text></TextContent>
                      </div>}
                      <div className='claim-fact'>
                        <FontAwesomeIcon icon={faPaperclip} className='claim-fact-icon' />
                        <div className='width-100'>
                          <TextContent><Text component={TextVariants.h4}>Attachments</Text></TextContent>
                          {documents.length === 0 && <Text>No documents attached.</Text>}
                          {documents.map((doc, i) => (
                            <div key={i} className='padding-top-25'>
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
                      </div>
                    </div>
                  </Tab>
                  <Tab eventKey={1} title={<TabTitleText>Insurance</TabTitleText>} aria-label="Insurance">
                    <DescriptionList className='padding-top-25' isHorizontal>
                      <DescriptionListGroup><DescriptionListTerm>Policy number</DescriptionListTerm><DescriptionListDescription>{details?.policyNumber || '-'}</DescriptionListDescription></DescriptionListGroup>
                      <DescriptionListGroup><DescriptionListTerm>Policyholder</DescriptionListTerm><DescriptionListDescription>{claim.claimant}</DescriptionListDescription></DescriptionListGroup>
                      <DescriptionListGroup><DescriptionListTerm>Line of business</DescriptionListTerm><DescriptionListDescription>{claim.type}</DescriptionListDescription></DescriptionListGroup>
                      <DescriptionListGroup><DescriptionListTerm>Coverage</DescriptionListTerm><DescriptionListDescription>{details?.coverage || '-'}</DescriptionListDescription></DescriptionListGroup>
                      <DescriptionListGroup><DescriptionListTerm>Deductible</DescriptionListTerm><DescriptionListDescription>{details?.deductible || '-'}</DescriptionListDescription></DescriptionListGroup>
                      <DescriptionListGroup><DescriptionListTerm>Coverage limit</DescriptionListTerm><DescriptionListDescription>{details?.coverageLimit || '-'}</DescriptionListDescription></DescriptionListGroup>
                      <DescriptionListGroup><DescriptionListTerm>Email</DescriptionListTerm><DescriptionListDescription>{details?.clientEmail || '-'}</DescriptionListDescription></DescriptionListGroup>
                      <DescriptionListGroup><DescriptionListTerm>Phone</DescriptionListTerm><DescriptionListDescription>{details?.clientPhone || '-'}</DescriptionListDescription></DescriptionListGroup>
                    </DescriptionList>
                  </Tab>
                  <Tab eventKey={2} title={<TabTitleText>History</TabTitleText>} aria-label="History">
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
              </CardBody>
            </Card>
          </GridItem>
          {photos.length > 0 && <GridItem span={12} lg={4}>
            <Card isRounded={true} className='width-100'>
              <CardBody>
                <img className='claim-photo' src={photos[Math.min(photo, photos.length - 1)]} alt={`Photo ${photo + 1} attached to ${claim.claimNumber}`} />
                <Flex className='padding-top-25'>
                  {photos.map((p, i) => (
                    <FlexItem key={i}>
                      <img className={'claim-thumb' + (i === photo ? ' claim-thumb-active' : '')} src={p} alt={`Thumbnail ${i + 1}`} onClick={() => setPhoto(i)} />
                    </FlexItem>
                  ))}
                </Flex>
              </CardBody>
            </Card>
          </GridItem>}
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
