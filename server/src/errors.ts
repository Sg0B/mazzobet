/** Codici lanciati dalle funzioni SQL (message dell'eccezione) → risposta HTTP. */
const ERRORS: Record<string, { status: number; message: string }> = {
  unauthorized: { status: 401, message: 'Sessione non valida: scegli di nuovo la squadra.' },
  no_session: { status: 409, message: 'Nessuna serata attiva.' },
  session_closed: { status: 409, message: 'La serata è chiusa: la classifica è congelata.' },
  session_closing: { status: 409, message: 'La serata sta chiudendo: nuove puntate e scommesse sospese.' },
  unknown_team: { status: 400, message: 'Squadra sconosciuta.' },
  market_not_found: { status: 404, message: 'Scommessa non trovata.' },
  market_closed: { status: 409, message: 'La scommessa è già chiusa.' },
  own_market: { status: 403, message: 'Non puoi puntare sulla tua scommessa.' },
  already_bet: { status: 409, message: 'Hai già puntato su questa scommessa.' },
  bankrupt: { status: 403, message: 'Sei in bancarotta: puntate e creazioni sospese.' },
  insufficient_funds: { status: 409, message: 'Saldo insufficiente.' },
  invalid_amount: { status: 400, message: 'Puntata minima 10 Carletti.' },
  creator_priority: { status: 409, message: 'Per il momento può esitare solo chi ha creato la scommessa.' },
  odds_margin: { status: 400, message: 'Quote troppo generose: con queste il Banco regalerebbe Carletti. Abbassa una delle due.' },
  invalid_side: { status: 400, message: 'Lato non valido.' },
  invalid_question: { status: 400, message: 'Scrivi una domanda chiara, da 8 a 120 caratteri.' },
  invalid_odds: { status: 400, message: 'Le quote devono essere tra 1,10 e 10,00.' },
  expiry_too_soon: { status: 400, message: 'Scegli un orario più avanti.' },
  expiry_too_late: { status: 400, message: 'Oltre la fine della serata non si può.' },
  not_creator: { status: 403, message: 'Solo chi ha creato la scommessa può farlo.' },
  not_resolvable: { status: 409, message: 'La scommessa non è ancora da esitare.' },
  already_resolved: { status: 409, message: 'Esito già registrato.' },
  window_expired: { status: 409, message: 'Tempo scaduto per esitare.' },
  not_eligible: { status: 403, message: 'Chi ha puntato non può esitare.' },
  not_bankrupt: { status: 409, message: 'Non sei in bancarotta.' },
  not_appealable: { status: 409, message: 'Questa scommessa non è contestabile.' },
  already_flipped: { status: 409, message: 'Il verdetto è già stato ribaltato: niente secondo ricorso.' },
  appeal_window_closed: { status: 409, message: 'Il tempo per contestare è scaduto.' },
  confirm_required: { status: 400, message: 'Per confermare scrivi RESET.' },
  bad_param: { status: 400, message: 'Valore non valido per questo parametro.' },
  not_voidable: { status: 409, message: 'Questa scommessa non si può più annullare.' },
  reason_required: { status: 400, message: 'Scrivi il motivo (almeno 3 caratteri).' },
  reset_failed: { status: 500, message: 'Reset non riuscito: controlla lo stato della serata.' },
  lock_active: { status: 409, message: 'Il blocco di 5 minuti non è ancora finito.' },
}

export interface ApiError {
  status: number
  code: string
  message: string
}

export function toApiError(err: unknown): ApiError {
  const code = typeof err === 'object' && err && 'message' in err ? String((err as { message: unknown }).message) : ''
  const known = ERRORS[code]
  if (known) return { status: known.status, code, message: known.message }
  return { status: 500, code: 'internal', message: 'Errore del server. Riprova.' }
}
