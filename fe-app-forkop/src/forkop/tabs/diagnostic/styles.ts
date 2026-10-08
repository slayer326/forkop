// language=CSS
import { FORKOP_UCI_PACKAGE as FORKOP_CBI_PREFIX } from '../../../constants';

export const styles = `
#cbi-${FORKOP_CBI_PREFIX}-diagnostic-_mount_node {
    display: block;
    width: 100%;
    margin: 0;
    padding: 0;
}

#cbi-${FORKOP_CBI_PREFIX}-diagnostic-_mount_node > .cbi-value-title {
    display: none;
}

#cbi-${FORKOP_CBI_PREFIX}-diagnostic-_mount_node > .cbi-value-field {
    display: block;
    flex: 1 1 100%;
    margin: 0;
    margin-inline-start: 0;
    width: 100%;
    max-width: none;
}

#cbi-${FORKOP_CBI_PREFIX}-diagnostic-_mount_node > div {
    width: 100%;
}

#cbi-${FORKOP_CBI_PREFIX}-diagnostic > h3 {
    display: none;
}

.fkp-diag {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 12px;
    width: 100%;
    box-sizing: border-box;
}

.fkp-diag-primary,
.fkp-diag-sidebar {
    display: grid;
    align-content: start;
    gap: 12px;
    min-width: 0;
}

.fkp-diag > .fkp-diag-details {
    grid-column: 1 / -1;
}

@media (min-width: 960px) {
    .fkp-diag {
        grid-template-columns: minmax(0, 1.7fr) minmax(280px, 0.85fr);
        align-items: start;
    }
}

.fkp-diag * {
    text-align: left;
}

/* The utility rail mirrors the diagnostic content without squeezing checks. */
.fkp-diag .fkp_diagnostic-page__right-bar__actions {
    display: grid;
    gap: 8px;
}

.fkp-diag .fkp_diagnostic-page__right-bar__actions > b,
.fkp-diag .fkp_diagnostic-page__right-bar__actions > p {
    margin: 0;
}

.fkp-diag .fkp_diagnostic-page__right-bar__actions > .fkp-partial-button {
    width: 100%;
    margin: 0;
}

.fkp-diag-card {
    border: 1px solid var(--border-color-medium, #777);
    border-radius: 6px;
    padding: 12px 14px;
    min-width: 0;
    overflow-wrap: break-word;
}

.fkp-diag-card__head {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 8px 16px;
}

.fkp-diag-card__title,
.fkp-diag-section-title {
    margin: 0 0 4px;
}

.fkp-diag-section-title {
    margin-top: 8px;
}

.fkp-diag-hint {
    display: block;
    margin: 4px 0;
    color: var(--text-color-medium, gray);
}

.fkp-diag-row {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
    gap: 12px;
    align-items: start;
}

.fkp-diag-actions {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 6px 10px;
    margin-top: 10px;
}

.fkp-diag-actions .btn {
    margin: 0;
}

.fkp-diag-form {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
}

.fkp-diag-field {
    display: grid;
    gap: 4px;
    min-width: 0;
}

.fkp-diag-field--wide {
    flex: 1 1 280px;
}

.fkp-diag-field input,
.fkp-diag-field select,
.fkp-diag-field textarea {
    width: 100%;
    max-width: 100%;
    box-sizing: border-box;
    margin: 0;
}

.fkp-diag-details > summary {
    cursor: pointer;
    font-weight: bold;
    font-size: 1.1em;
}

.fkp-diag-details[open] > summary {
    margin-bottom: 8px;
}

.fkp-diag-badge {
    display: inline-block;
    max-width: 100%;
    box-sizing: border-box;
    padding: 1px 8px;
    border-radius: 10px;
    border: 1px solid currentColor;
    font-size: 0.9em;
    white-space: nowrap;
}

.fkp-diag-badge--success, .fkp-diag-text--success { color: var(--success-color-medium, green); }
.fkp-diag-badge--warning, .fkp-diag-text--warning { color: var(--warn-color-medium, orange); }
.fkp-diag-badge--error, .fkp-diag-text--error { color: var(--error-color-medium, red); }
.fkp-diag-badge--loading, .fkp-diag-text--loading { color: var(--primary-color-high, dodgerblue); }
.fkp-diag-badge--neutral, .fkp-diag-text--neutral { color: var(--text-color-medium, gray); }

.fkp-diag-facts {
    display: grid;
    grid-template-columns: max-content minmax(0, 1fr);
    gap: 6px 16px;
    margin: 0;
}

.fkp-diag-facts dt { font-weight: bold; }
.fkp-diag-facts dd { margin: 0; min-width: 0; }
.fkp-diag-facts .fkp-diag-badge,
.fkp-diag-events .fkp-diag-badge { white-space: normal; overflow-wrap: break-word; }

.fkp-diag-events {
    border-collapse: collapse;
}

.fkp-diag-events td {
    padding: 3px 16px 3px 0;
    vertical-align: top;
}

/* Show every check as its own full-width card, matching the scan order of the
   router diagnostic rather than hiding successful checks in an accordion. */
.fkp-diag-checks {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 8px;
    margin-top: 10px;
}

.fkp-diag-summary {
    margin: 0;
    font-weight: 600;
}

.fkp-diag-run-reason:empty {
    display: none;
}

.fkp-diag-run-reason {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 6px 10px;
    margin-top: 8px;
    color: var(--text-color-medium, gray);
}

.fkp-diag-run-reason .btn {
    margin: 0;
}

.fkp-check__advice {
    display: grid;
    grid-template-columns: max-content minmax(0, 1fr);
    gap: 4px 12px;
    margin: 8px 0 0;
}

.fkp-check__advice dt {
    font-weight: 600;
    color: var(--text-color-medium, gray);
}

.fkp-check__advice dd {
    margin: 0;
}

.fkp-check__advice ul {
    margin: 0;
    padding-left: 1.2em;
}

.fkp-diag-help {
    display: grid;
    gap: 8px;
}

.fkp-diag-help a { display: block; }

.fkp-diag-subsection h4 {
    margin: 12px 0 4px;
}

.fkp-site__value {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: 4px 8px;
}

.fkp-site__conclusion {
    margin: 10px 0 0;
    font-weight: 600;
}

.fkp-check {
    border: 1px solid var(--border-color-low, lightgray);
    border-radius: 8px;
    padding: 12px 14px;
    min-width: 0;
}

.fkp-check--success { border: 2px solid var(--success-color-medium, green); }
.fkp-check--warning { border: 2px solid var(--warn-color-medium, orange); }
.fkp-check--error { border: 2px solid var(--error-color-medium, red); }
.fkp-check--loading { border-color: var(--primary-color-high, dodgerblue); }

.fkp-check__head {
    /* Flex-wrap: the badge moves below a long title instead of squeezing it. */
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 4px 8px;
}

.fkp-check__head .fkp-check__title { flex: 1 1 8em; }
.fkp-check__head .fkp-diag-badge { flex: 0 0 auto; }

.fkp-check__icon svg { width: 20px; height: 20px; }

.fkp-check__details { margin-top: 6px; }
.fkp-check__details > summary { cursor: pointer; }
.fkp-check__description { margin: 4px 0; }
.fkp-check__items { display: grid; gap: 6px; margin-top: 8px; }

.fkp-check__item {
    display: grid;
    /* Name and value on separate lines, so a long name never squeezes the
       value into one character per line. */
    grid-template-columns: 16px minmax(0, 1fr);
    column-gap: 6px;
    align-items: start;
    overflow-wrap: break-word;
}

.fkp-check__item > :nth-child(3) { grid-column: 2; }

.fkp-check, .fkp-check__head, .fkp-check__details { min-width: 0; }
.fkp-check__title { min-width: 0; overflow-wrap: break-word; }

.fkp-check__item-icon svg { width: 16px; height: 16px; }

.fkp-check__actions {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    margin-top: 6px;
}

.fkp_diagnostic-page__run_check_wrapper button { width: 100%; margin: 8px 0 0; }

/* Reachability table: header and rows share one grid, so the action column can
   size to the real (translated) button labels; stacked cards on narrow screens. */
.fkp-conn {
    display: grid;
    grid-template-columns: minmax(140px, 2fr) minmax(90px, 110px) minmax(80px, 100px) minmax(140px, 2fr) max-content;
    column-gap: 8px;
    align-items: center;
}

.fkp-conn__head,
.fkp-conn__row {
    display: contents;
}

.fkp-conn__head > span {
    font-weight: bold;
    padding: 4px 0;
    border-bottom: 1px solid var(--border-color-low, lightgray);
    text-align: left;
}

.fkp-conn__row > * {
    padding: 6px 0;
    border-bottom: 1px solid var(--border-color-low, lightgray);
    min-width: 0;
    text-align: left;
}

.fkp-conn__cell { display: block; margin: 0; }
.fkp-conn__cell input, .fkp-conn__cell select {
    width: 100%;
    max-width: 100%;
    min-width: 0;
    box-sizing: border-box;
    margin: 0;
}
.fkp-conn__cell-label { display: none; }
.fkp-conn__cell--muted { color: var(--text-color-medium, gray); }
.fkp-conn__result { overflow-wrap: break-word; }
.fkp-conn__actions { display: flex; gap: 4px; }
.fkp-conn__actions .btn { margin: 0; white-space: nowrap; }

@media (max-width: 860px) {
    .fkp-conn { display: block; }
    .fkp-conn__head { display: none; }
    .fkp-conn__row {
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
        gap: 6px 8px;
        border: 1px solid var(--border-color-low, lightgray);
        border-radius: 6px;
        padding: 8px;
        margin-top: 8px;
    }
    .fkp-conn__row > * { padding: 0; border-bottom: 0; }
    .fkp-conn__row > :first-child,
    .fkp-conn__row > :nth-child(4) { grid-column: 1 / -1; }
    .fkp-conn__cell-label {
        display: block;
        font-size: 0.85em;
        color: var(--text-color-medium, gray);
    }
    .fkp-conn__actions { grid-column: 1 / -1; flex-wrap: wrap; }
}

.fkp-route__form {
    display: flex;
    flex-wrap: wrap;
    align-items: end;
    gap: 10px;
}

.fkp-route__form .btn { margin: 0; }

.fkp-route__facts {
    display: grid;
    grid-template-columns: max-content minmax(0, 1fr);
    gap: 6px 16px;
    margin: 12px 0 0;
}

.fkp-route__facts dt { font-weight: bold; }
.fkp-route__facts dd { margin: 0; display: grid; gap: 2px; }
.fkp-route__facts small { color: var(--text-color-medium, gray); }

@media (max-width: 560px) {
    .fkp-diag-facts, .fkp-route__facts, .fkp-check__advice { grid-template-columns: minmax(0, 1fr); }
    .fkp-diag-checks { grid-template-columns: minmax(0, 1fr); }
}

.fkp_diagnostic-page__right-bar__actions {
    display: grid;
    grid-template-columns: auto;
    grid-row-gap: 10px;

}

.fkp_diagnostic-page__right-bar__actions > .fkp-partial-button {
    width: 100%;
    min-width: 0;
    margin-left: 0;
}

.fkp_diagnostic-page__right-bar__system-info {
    display: grid;
    grid-template-columns: auto;
    grid-row-gap: 10px;
}

.fkp_diagnostic-page__right-bar__system-info__title {

}

.fkp_diagnostic-page__right-bar__system-info__row {
    display: grid;
    grid-template-columns: auto 1fr;
    grid-column-gap: 5px;
}

.fkp_diagnostic-page__right-bar__system-info__row__tag {
    padding: 2px 4px;
    border: 1px transparent solid;
    border-radius: 4px;
    margin-left: 5px;
}

.fkp_diagnostic-page__right-bar__system-info__row__tag--neutral {
    border: 1px var(--background-color-high, gray) solid;
    color: var(--text-color-medium, gray);
}

.fkp_diagnostic-page__right-bar__system-info__row__tag--warning {
    border: 1px var(--warn-color-medium, orange) solid;
    color: var(--warn-color-medium, orange);
}

.fkp_diagnostic-page__right-bar__system-info__row__tag--success {
    border: 1px var(--success-color-medium, green) solid;
    color: var(--success-color-medium, green);
}

`;
