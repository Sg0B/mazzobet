/**
 * Regole di gioco usate dall'interfaccia solo per anteprime e controlli immediati.
 * L'autorità è il server: i parametri (puntata minima, costi, quote, compenso…) arrivano dalla configurazione
 * e questi controlli non sostituiscono mai quelli del server.
 */

/** Vincita totale accreditata: floor(puntata × quota) su interi. */
export const payout = (stake: number, oddsCents: number) => Math.floor((stake * oddsCents) / 100)

/** "1,90" / "1.9" → centesimi, oppure null se fuori range o oltre 2 decimali. */
export function parseOdds(input: string, min: number, max: number): number | null {
  const v = parseFloat(input.replace(',', '.'))
  if (!isFinite(v)) return null
  const cents = Math.round(v * 100)
  if (Math.abs(v * 100 - cents) > 1e-6 || cents < min || cents > max) return null
  return cents
}

/** Controllo sul margine: 1/qSÌ + 1/qNO ≥ 1, in soli interi (blocca le quote «regalo» come 5,00 e 5,00). */
export const oddsMarginOk = (yesCents: number, noCents: number) => 100 * (yesCents + noCents) >= yesCents * noCents

/** Compenso di chi esita: percentuale del totale puntato, con un tetto. */
export const resolverFee = (total: number, pct: number, cap: number) => Math.min(Math.floor((total * pct) / 100), cap)
