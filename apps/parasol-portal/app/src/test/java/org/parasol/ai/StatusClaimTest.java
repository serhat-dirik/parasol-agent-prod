package org.parasol.ai;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import java.util.Map;
import java.util.function.Function;

import org.junit.jupiter.api.Test;
import org.parasol.model.ClaimDtos.ClaimDto;

class StatusClaimTest {

    /** The records the user may read (claims-db seed); anything else is unreadable (null). */
    static final Function<String, ClaimDto> RECORDS = Map.of(
            "CLM-1006", new ClaimDto("CLM-1006", "Michael Turner", "auto", "UnderReview", "11800.00", "2026-01-20", "Rebecca Torres"),
            "CLM-1004", new ClaimDto("CLM-1004", "Omar Haddad", "auto", "Denied", "8400.00", "2026-01-10", "Rebecca Torres"))::get;

    @Test
    void misreportedStatusGetsTheNote() {
        assertEquals("Platform note: the claims record shows CLM-1006 as UnderReview, not the status stated above.",
                AgentService.statusMismatchNote("CLM-1006 is Closed. The inspection report lists front-end damage.", RECORDS));
        assertEquals(String.format(AgentService.STATUS_NOTE, "CLM-1006", "UnderReview"),
                AgentService.statusMismatchNote("The claim CLM-1006 has been approved for payment.", RECORDS));
    }

    @Test
    void answerNamingTheRecordStatusGetsNone() {
        assertNull(AgentService.statusMismatchNote("CLM-1006 is UnderReview, amount 11,800.00 USD.", RECORDS));
        assertNull(AgentService.statusMismatchNote("CLM-1006 is under review; the document says it is Closed.", RECORDS));
        assertNull(AgentService.statusMismatchNote("CLM-1006 is currently In Review.", RECORDS));
        // no status stated, or a claim the user may not read: nothing to compare
        assertNull(AgentService.statusMismatchNote("The documents on CLM-1006 describe front-end damage.", RECORDS));
        assertNull(AgentService.statusMismatchNote("CLM-1016 is Approved.", RECORDS));
        assertNull(AgentService.statusMismatchNote("A claims manager must approve it.", RECORDS));
        // a history told in the past tense is not a status claim
        assertNull(AgentService.statusMismatchNote("CLM-1006 was submitted on 2026-01-20; documents were requested "
                + "and have been submitted since.", RECORDS));
        assertNull(AgentService.statusMismatchNote(null, RECORDS));
    }

    @Test
    void amountsOnlyWhenStatedExplicitly() {
        assertEquals(String.format(AgentService.AMOUNT_NOTE, "CLM-1004", "8400.00"),
                AgentService.statusMismatchNote("For CLM-1004 the claimed amount is 84,000 and it is Denied.", RECORDS));
        assertEquals(String.format(AgentService.AMOUNT_NOTE, "CLM-1004", "8400.00"),
                AgentService.statusMismatchNote("CLM-1004 (Denied): the customer claimed $84,000.", RECORDS));
        assertNull(AgentService.statusMismatchNote("CLM-1004 is Denied; the amount is 8,400.00 USD.", RECORDS));
        // a figure from a document, or another currency, is not a stated record amount
        assertNull(AgentService.statusMismatchNote("CLM-1004 is Denied. The estimate shows a total of 84,000.", RECORDS));
        assertNull(AgentService.statusMismatchNote("CLM-1004 is Denied; a garage quote in dirhams claimed AED 84,000.", RECORDS));
    }
}
