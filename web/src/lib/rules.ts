/**
 * Regole economiche del PRD v0.7. Funzioni pure, usate qui solo per validazione
 * e anteprime UI: l'autorità resta il server (PRD §13, invarianti 1–3).
 */

export const START_BALANCE = 1000
export const CREATE_FEE = 100
export const MIN_BET = 10
export const MIN_ODDS = 110
export const MAX_ODDS = 1000
export const BANKRUPT_BELOW = 10
export const READMIT_BALANCE = 500
export const BANKRUPT_LOCK_MIN = 5
export const RESOLVE_WINDOW_MIN = 15
export const APPEAL_WINDOW_MIN = 3
export const END_OF_NIGHT_HOUR = 3 // 03:00 Europe/Rome (default sessione)

/** Vincita totale accreditata: floor(puntata × quota) su interi. */
export const payout = (stake: number, oddsCents: number) => Math.floor((stake * oddsCents) / 100)

/** "1,90" / "1.9" → centesimi, oppure null se fuori range o oltre 2 decimali. */
export function parseOdds(input: string): number | null {
  const v = parseFloat(input.replace(',', '.'))
  if (!isFinite(v)) return null
  const cents = Math.round(v * 100)
  if (Math.abs(v * 100 - cents) > 1e-6 || cents < MIN_ODDS || cents > MAX_ODDS) return null
  return cents
}

/** Soglia ricorso: maggioranza assoluta dei distinti scommettitori. */
export const appealThreshold = (bettors: number) => Math.floor(bettors / 2) + 1

export const isBankrupt = (balance: number) => balance < BANKRUPT_BELOW
