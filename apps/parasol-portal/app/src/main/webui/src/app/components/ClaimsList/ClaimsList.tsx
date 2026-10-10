import config from '@app/config';
import { Card, Flex, FlexItem, FormSelect, FormSelectOption, Label, Page, PageSection, Text, TextContent, TextInput, TextVariants } from '@patternfly/react-core';
import SearchIcon from '@patternfly/react-icons/dist/esm/icons/search-icon';
import { Table, Tbody, Td, Th, Thead, ThProps, Tr } from '@patternfly/react-table';
import axios from 'axios';
import * as React from 'react';
import { Link } from 'react-router-dom';
import { formatAED } from '@app/utils/money';

interface Row {
    claimNumber: string;
    claimant: string;
    type: string;
    amount: string;
    adjuster: string;
    status: string;
}

const labelColors: Record<string, 'green' | 'red' | 'gold' | 'blue'> = {
    'Approved': 'green',
    'Denied': 'red',
    'UnderReview': 'gold',
    'Submitted': 'blue',
};

const ClaimsList: React.FunctionComponent = () => {

    // Claims data
    const [claims, setClaims] = React.useState<any[]>([]);
    React.useEffect(() => {
        axios.get(config.backend_api_url + '/claims')
            .then(response => {
                setClaims(response.data);
            })
            .catch(error => {
                console.error(error);
            });
    }, []);

    const rows: Row[] = claims.map((claim: any) => ({
        claimNumber: claim.claimNumber,
        claimant: claim.claimant,
        type: claim.type,
        amount: claim.amount,
        adjuster: claim.adjuster,
        status: claim.status,
    }));

    // Filter and sort
    const [searchText, setSearchText] = React.useState('');
    const [formSelectValueStatus, setFormSelectValueStatus] = React.useState('Any status');

    const onChangeStatus = (_event: React.FormEvent<HTMLSelectElement>, value: string) => {
        setFormSelectValueStatus(value);
    };

    const filteredRows = rows.filter(row =>
        Object.values(row)
            .some(val => val?.toString().toLowerCase().includes(searchText.toLowerCase())) // Search all fields with the search text
        && (
            row.status === formSelectValueStatus || formSelectValueStatus === 'Any status' // Filter by status
        )
    );

    const columnNames = {
        claimNumber: 'Claim Number',
        claimant: 'Claimant',
        type: 'Type',
        amount: 'Amount',
        adjuster: 'Adjuster',
        status: 'Status'
    }

    // Index of the currently sorted column
    const [activeSortIndex, setActiveSortIndex] = React.useState<number | null>(null);

    // Sort direction of the currently sorted column
    const [activeSortDirection, setActiveSortDirection] = React.useState<'asc' | 'desc' | null>(null);

    // Since OnSort specifies sorted columns by index, we need sortable values for our object by column index.
    const getSortableRowValues = (row: Row): string[] => {
        const { claimNumber, claimant, type, amount, adjuster, status } = row;
        return [claimNumber, claimant, type, amount, adjuster, status];
    };

    let sortedRows = filteredRows;
    if (activeSortIndex !== null) {
        sortedRows = [...filteredRows].sort((a, b) => {
            const aValue = getSortableRowValues(a)[activeSortIndex as number] ?? '';
            const bValue = getSortableRowValues(b)[activeSortIndex as number] ?? '';
            if (activeSortDirection === 'asc') {
                return aValue.localeCompare(bValue);
            }
            return bValue.localeCompare(aValue);
        });
    }

    const getSortParams = (columnIndex: number): ThProps['sort'] => ({
        sortBy: {
            // @ts-ignore
            index: activeSortIndex,
            // @ts-ignore
            direction: activeSortDirection,
            defaultDirection: 'asc'
        },
        onSort: (_event, index, direction) => {
            setActiveSortIndex(index);
            setActiveSortDirection(direction);
        },
        columnIndex
    });

    return (
        <Page>
            <PageSection>
                <TextContent>
                    <Text component={TextVariants.h1}>Claims</Text>
                </TextContent>
            </PageSection>
            <PageSection>
                <Flex>
                    <FlexItem>
                        <TextInput
                            value={searchText}
                            type="search"
                            onChange={(_event, searchText) => setSearchText(searchText)}
                            aria-label="search text input"
                            placeholder="Search claims"
                            customIcon={<SearchIcon />}
                            className='claims-list-filter-search'
                        />
                    </FlexItem>
                    <FlexItem align={{ default: 'alignRight' }}>
                        <FormSelect
                            value={formSelectValueStatus}
                            onChange={onChangeStatus}
                            aria-label="FormSelect Input"
                            ouiaId="BasicFormSelectStatus"
                            className="claims-list-filter-select"
                        >
                            <FormSelectOption key={0} value="Any status" label="Any status" />
                            <FormSelectOption key={1} value="Submitted" label="Submitted" />
                            <FormSelectOption key={2} value="UnderReview" label="Under Review" />
                            <FormSelectOption key={3} value="Approved" label="Approved" />
                            <FormSelectOption key={4} value="Denied" label="Denied" />
                        </FormSelect>
                    </FlexItem>
                </Flex>
            </PageSection>
            <PageSection>
                <Card component="div">
                    <Table aria-label="Claims list" isStickyHeader>
                        <Thead>
                            <Tr>
                                <Th sort={getSortParams(0)} width={15}>{columnNames.claimNumber}</Th>
                                <Th sort={getSortParams(1)} width={20}>{columnNames.claimant}</Th>
                                <Th sort={getSortParams(2)} width={10}>{columnNames.type}</Th>
                                <Th sort={getSortParams(3)} width={10}>{columnNames.amount}</Th>
                                <Th sort={getSortParams(4)} width={20}>{columnNames.adjuster}</Th>
                                <Th sort={getSortParams(5)} width={10}>{columnNames.status}</Th>
                            </Tr>
                        </Thead>
                        <Tbody>
                            {sortedRows.map((row, rowIndex) => (
                                <Tr key={rowIndex}>
                                    <Td dataLabel={columnNames.claimNumber}>
                                        <Link to={`/ClaimDetail/${row.claimNumber}`}>{row.claimNumber}</Link>
                                    </Td>
                                    <Td dataLabel={columnNames.claimant}>{row.claimant}</Td>
                                    <Td dataLabel={columnNames.type}>{row.type}</Td>
                                    <Td dataLabel={columnNames.amount}>{formatAED(row.amount)}</Td>
                                    <Td dataLabel={columnNames.adjuster}>{row.adjuster}</Td>
                                    <Td dataLabel={columnNames.status}><Label color={labelColors[row.status] || 'grey'}>{row.status}</Label></Td>
                                </Tr>
                            ))}
                        </Tbody>
                    </Table>
                </Card>
            </PageSection>
        </Page>
    )
}

export { ClaimsList };
