/** Etichetta colorata per tipo di notizia (come i tipi di PCS). «RACE UPDATE» e «START» non hanno etichetta: sono la cronaca normale. */
export const RACE_BADGE: Record<string, { label: string; cls: string }> = {
  ATTACK: { label: 'ATTACK', cls: 'atk' },
  INCIDENT: { label: 'INCIDENT', cls: 'inc' },
  'MEDICAL UPDATE': { label: 'MEDICAL', cls: 'inc' },
  WITHDRAWAL: { label: 'WITHDRAWAL', cls: 'out' },
  RESULT: { label: 'RESULT', cls: 'res' },
  'OFFICIAL RESULT': { label: 'OFFICIAL', cls: 'res' },
  'RACE DATA': { label: 'DATA', cls: 'dat' },
  'PCS STATS': { label: 'STATS', cls: 'dat' },
}
