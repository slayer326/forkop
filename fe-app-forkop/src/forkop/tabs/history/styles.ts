// language=CSS
import { FORKOP_UCI_PACKAGE as FORKOP_CBI_PREFIX } from '../../../constants';

export const styles = `
#cbi-${FORKOP_CBI_PREFIX}-history-_mount_node {
    display: block;
    width: 100%;
    margin: 0;
    padding: 0;
}
#cbi-${FORKOP_CBI_PREFIX}-history-_mount_node > .cbi-value-title {
    display: none;
}
#cbi-${FORKOP_CBI_PREFIX}-history-_mount_node > .cbi-value-field {
    display: block;
    flex: 1 1 100%;
    margin: 0;
    margin-inline-start: 0;
    width: 100%;
    max-width: none;
}
#cbi-${FORKOP_CBI_PREFIX}-history-_mount_node > div {
    width: 100%;
}

.fkp-history {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: var(--fkp-space-3);
    width: 100%;
    min-width: 0;
}
.fkp-history__card {
    display: flex;
    flex-direction: column;
    gap: var(--fkp-space-2);
    min-width: 0;
    padding: var(--fkp-space-3) var(--fkp-space-4);
    border: 1px solid var(--fkp-border);
    border-radius: 6px;
}
.fkp-history__head {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: var(--fkp-space-2);
}
.fkp-history__title { margin: 0; font-size: 1.05em; }
.fkp-history__hint { margin: 0; color: var(--fkp-tone-neutral); overflow-wrap: anywhere; }
.fkp-history__facts {
    display: grid;
    grid-template-columns: minmax(0, 1fr) 190px;
    gap: var(--fkp-space-1) var(--fkp-space-4);
    margin: 0;
}
.fkp-history__facts dt { min-width: 0; font-weight: 600; overflow-wrap: normal; }
.fkp-history__facts dd { min-width: 0; margin: 0; }
.fkp-history__facts .fkp-status {
    display: block;
    width: 100%;
    border-radius: 6px;
    overflow-wrap: normal;
    word-break: normal;
}
.fkp-history__filter { display: flex; flex-wrap: wrap; gap: var(--fkp-space-1); }
.fkp-history__filter .btn[aria-pressed="true"] { font-weight: 600; border-color: var(--fkp-tone-loading); }
.fkp-history__list { margin: 0; padding: 0; list-style: none; }
.fkp-history__event,
.fkp-history__snapshot {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--fkp-space-1) var(--fkp-space-3);
    padding: var(--fkp-space-2) 0;
    border-top: 1px solid var(--fkp-border);
}
.fkp-history__event:first-child,
.fkp-history__snapshot:first-child { border-top: 0; }
.fkp-history__time { color: var(--fkp-tone-neutral); min-width: 0; }
.fkp-history__what { flex: 1 1 240px; min-width: 0; overflow-wrap: anywhere; }
.fkp-history__lkg {
    padding: 0 var(--fkp-space-2);
    border: 1px solid var(--fkp-tone-success);
    border-radius: 999px;
    color: var(--fkp-tone-success);
    font-size: 0.85em;
}
.fkp-history__diff-wrap { width: 0; min-width: 100%; overflow-x: auto; }
.fkp-history__diff { width: 100%; }
.fkp-history__diff td { overflow-wrap: anywhere; vertical-align: top; }

@media (min-width: 1100px) {
    .fkp-history {
        grid-template-columns: minmax(480px, 0.95fr) minmax(0, 1.5fr);
        align-items: start;
    }
    .fkp-history__card:nth-child(n + 3) {
        grid-column: 1 / -1;
    }
}

@media (max-width: 599px) {
    .fkp-history__facts { grid-template-columns: minmax(0, 1fr); }
    .fkp-history__facts .fkp-status { width: auto; }
    .fkp-history__facts dd { margin-bottom: var(--fkp-space-2); }
}
`;
