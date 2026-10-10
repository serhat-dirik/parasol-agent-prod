import config from '@app/config';
import { faCommentDots, faPaperPlane } from '@fortawesome/free-regular-svg-icons';
import { faPlusCircle } from '@fortawesome/free-solid-svg-icons';
import { FontAwesomeIcon } from '@fortawesome/react-fontawesome';
import { Button, Card, CardBody, CardHeader, Flex, FlexItem, Grid, GridItem, Panel, PanelMain, PanelMainBody, Stack, StackItem, Text, TextArea, TextContent, TextVariants, Tooltip } from '@patternfly/react-core';
import * as React from 'react';
import orb from '@app/assets/bgimages/orb.svg';
import userAvatar from '@app/assets/bgimages/avatar-user.svg';
import { formatAED } from '@app/utils/money';

interface Frame {
    type: string;
    text: string;
    data: string;
}

interface Turn {
    query: string;
    frames: Frame[];
}

// Render a tool's JSON args string compactly, e.g. {"claimNumber":"CLM-1004"} -> claimNumber=CLM-1004
const prettyArgs = (data: string): string => {
    if (!data) return '';
    try {
        const obj = JSON.parse(data);
        return Object.entries(obj).map(([k, v]) => `${k}=${typeof v === 'string' ? v : JSON.stringify(v)}`).join(', ');
    } catch {
        return data;
    }
};

const Chat: React.FunctionComponent<{ claimNumber: string, onTurnComplete?: () => void }> = ({ claimNumber, onTurnComplete }) => {

    const [queryText, setQueryText] = React.useState('');
    const [turns, setTurns] = React.useState<Turn[]>([]);
    const [isBusy, setIsBusy] = React.useState(false);
    const [isManager, setIsManager] = React.useState(false);
    const [approvedKeys, setApprovedKeys] = React.useState<Record<number, string>>({});

    React.useEffect(() => {
        fetch(config.backend_api_url + '/me')
            .then(r => r.json())
            .then(me => setIsManager((me.groups || []).some((g: string) => g.replace(/^\//, '') === 'claims-managers')))
            .catch(() => undefined);
    }, []);

    // A2 "Act": a claims manager approves the proposed payout. The write happens here, on the click,
    // against the real approve_payout MCP tool with the manager's token (403 for anyone else).
    const approve = (key: number, proposed: number | null) => {
        const url = config.backend_api_url + `/claims/${claimNumber}/approve` + (proposed ? `?amount=${proposed}` : '');
        setApprovedKeys(prev => ({ ...prev, [key]: 'pending' }));
        fetch(url, { method: 'POST' })
            .then(r => r.json().then(body => ({ ok: r.ok, body })))
            .then(({ ok, body }) => {
                setApprovedKeys(prev => ({ ...prev, [key]: ok ? 'done' : (body.error || 'failed') }));
                if (ok) { onTurnComplete && onTurnComplete(); }
            })
            .catch(() => setApprovedKeys(prev => ({ ...prev, [key]: 'failed' })));
    };

    const wsUrl = config.backend_api_url.replace(/http/, 'ws').replace(/\/api$/, '/ws');
    const connection = React.useRef<WebSocket | null>(null);
    const chatBotAnswer = React.useRef<HTMLDivElement | null>(null);

    React.useEffect(() => {
        const ws = new WebSocket(wsUrl + '/query');

        ws.onopen = () => console.log('opened ws connection');
        ws.onclose = (e) => console.log('close ws connection: ', e.code, e.reason);

        ws.onmessage = (event) => {
            const data: Frame = JSON.parse(event.data);
            if (data.type === 'done') {
                setIsBusy(false);
                onTurnComplete && onTurnComplete();
                return;
            }
            // Append the frame to the current (last) turn.
            setTurns(prev => {
                if (prev.length === 0) return prev;
                const next = [...prev];
                const last = next[next.length - 1];
                next[next.length - 1] = { ...last, frames: [...last.frames, data] };
                return next;
            });
        };

        connection.current = ws;
        return () => {
            ws.close();
            console.log('WebSocket connection closed');
        };
    }, []);

    React.useEffect(() => {
        if (chatBotAnswer.current) {
            chatBotAnswer.current.scrollTop = chatBotAnswer.current.scrollHeight;
        }
    }, [turns]);

    const send = (query: string) => {
        if (connection.current?.readyState !== WebSocket.OPEN || !query) return;
        setTurns(prev => [...prev, { query, frames: [] }]);
        setIsBusy(true);
        connection.current.send(JSON.stringify({ claimNumber, query }));
    };

    const sendQueryText = () => {
        send(queryText.trim());
        setQueryText('');
    };

    const resetMessageHistory = () => {
        setTurns([]);
        setIsBusy(false);
    };

    const renderFrame = (frame: Frame, key: number) => {
        switch (frame.type) {
            case 'tool':
                return (
                    <div key={key}>
                        <span className='tool-chip'>
                            called <span className='tool-chip-name'>{frame.text}</span>({prettyArgs(frame.data)})
                        </span>
                    </div>
                );
            case 'guardrail':
                return (
                    <div key={key} className='guardrail-banner'>
                        Guardrails: {frame.text}{frame.data ? ` (${frame.data})` : ''}
                    </div>
                );
            case 'mask':
                return (
                    <div key={key}>
                        <span className='mask-chip'>{frame.text}</span>
                    </div>
                );
            case 'error':
                return (
                    <div key={key}>
                        <span className='error-chip'>{frame.text}</span>
                    </div>
                );
            case 'propose': {
                let proposed: number | null = null;
                let claimed: number | null = null;
                try { const o = JSON.parse(frame.data || '{}'); proposed = o.proposed; claimed = o.claimed; } catch { /* ignore */ }
                const multiplier = (proposed && claimed) ? Math.round(proposed / claimed) : null;
                const state = approvedKeys[key];
                return (
                    <div key={key} className='propose-card'>
                        <div className='propose-title'>Payout proposed for {frame.text} — needs a claims manager</div>
                        <div className='propose-row'>Proposed: <b>{formatAED(proposed)}</b></div>
                        {claimed != null && <div className='propose-row'>Claimed: {formatAED(claimed)}{multiplier && multiplier > 1 ? ` — exceeds by ${multiplier}x` : ''}</div>}
                        {state === 'done'
                            ? <div className='propose-approved'>Approved by manager via assistant</div>
                            : isManager
                                ? <Button variant="primary" size="sm" isDisabled={state === 'pending'}
                                    onClick={() => approve(key, proposed)}>Approve</Button>
                                : <div className='propose-norole'>You do not have approval rights for this.</div>}
                        {state && state !== 'done' && state !== 'pending' && <div className='error-chip'>{state}</div>}
                    </div>
                );
            }
            case 'answer':
                return (
                    <Text key={key} component={TextVariants.p} className='chat-answer-text'>{frame.text}</Text>
                );
            case 'trace':
                return (
                    <div key={key} className='trace-footer' title='Open this turn in MLflow / Tempo'>
                        trace {frame.text}
                    </div>
                );
            default:
                return null;
        }
    };

    return (
        <Card isRounded className='chat-card'>
            <CardHeader className='chat-card-header'>
                <TextContent>
                    <Text component={TextVariants.h3} className='chat-card-header-title'><FontAwesomeIcon icon={faCommentDots} />&nbsp;Parasol Assistant</Text>
                </TextContent>
            </CardHeader>
            <CardBody className='chat-card-body'>
                <Stack>
                    <StackItem isFilled className='chat-bot-answer'>
                        <div ref={chatBotAnswer} style={{ height: '100%', overflowY: 'auto' }}>
                            <TextContent>
                                <Grid className='chat-item'>
                                    <GridItem span={1} className='grid-item-orb'><img src={orb} className='orb' /></GridItem>
                                    <GridItem span={11}>
                                        <Text component={TextVariants.p} className='chat-answer-text'>Hi! I am Parasol Assistant. How can I help you today?</Text>
                                    </GridItem>
                                </Grid>
                                {turns.map((turn, ti) => (
                                    <React.Fragment key={ti}>
                                        <Grid className='chat-item'>
                                            <GridItem span={1} className='grid-item-orb'><img src={userAvatar} className='user-avatar' /></GridItem>
                                            <GridItem span={11}>
                                                <Text component={TextVariants.p} className='chat-question-text'>{turn.query}</Text>
                                            </GridItem>
                                        </Grid>
                                        <Grid className='chat-item'>
                                            <GridItem span={1} className='grid-item-orb'><img src={orb} className='orb' /></GridItem>
                                            <GridItem span={11}>
                                                {turn.frames.map((frame, fi) => renderFrame(frame, fi))}
                                            </GridItem>
                                        </Grid>
                                    </React.Fragment>
                                ))}
                            </TextContent>
                        </div>
                    </StackItem>
                    <StackItem className='chat-input-panel'>
                        <Panel variant="raised">
                            <PanelMain>
                                <PanelMainBody className='chat-input-panel-body'>
                                    <TextArea
                                        value={queryText}
                                        type="text"
                                        onChange={(_event, queryText) => setQueryText(queryText)}
                                        aria-label="query text input"
                                        placeholder='Ask me anything...'
                                        isDisabled={isBusy}
                                        onKeyPress={event => {
                                            if (event.key === 'Enter') {
                                                event.preventDefault();
                                                sendQueryText();
                                            }
                                        }}
                                    />
                                    <Flex>
                                        <FlexItem>
                                            <Tooltip content={<div>Start a new chat</div>}>
                                                <Button variant="link" onClick={resetMessageHistory} aria-label='StartNewChat'><FontAwesomeIcon icon={faPlusCircle} /></Button>
                                            </Tooltip>
                                        </FlexItem>
                                        <FlexItem align={{ default: 'alignRight' }}>
                                            <Tooltip content={<div>Send your query</div>}>
                                                <Button variant="link" onClick={sendQueryText} aria-label='SendQuery' isDisabled={isBusy}><FontAwesomeIcon icon={faPaperPlane} /></Button>
                                            </Tooltip>
                                        </FlexItem>
                                    </Flex>
                                </PanelMainBody>
                            </PanelMain>
                        </Panel>
                    </StackItem>
                    <StackItem>
                        <TextContent>
                            <Text className='chat-disclaimer'>Powered by AI. It may display inaccurate info, so please double-check the responses.</Text>
                        </TextContent>
                    </StackItem>
                </Stack>
            </CardBody>
        </Card >
    );
}

export { Chat };
