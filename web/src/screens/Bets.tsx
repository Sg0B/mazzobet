import { useState, type ReactNode } from 'react'
import { cur, fmt, odds } from '../lib/format'
import { payout } from '../lib/rules'
import { actions, toResolve, useGame, type LedgerKind, type Market } from '../store/game'
import { Countdown } from '../components/Countdown'

const LEDGER_LABEL: Record<LedgerKind, string> = {
  start: 'INGRESSO',
  create: 'CREAZIONE',
  bet: 'PUNTATA',
  win: 'VINCITA',
  refund: 'RIMBORSO',
  bonus: 'BONUS',
  malus: 'MALUS',
  colletta: 'COLLETTA',
  sponsor: 'SPONSOR',
  adjust: 'RETTIFICA',
  fee: 'COMPENSO',
  reamm: 'RIAMMISSIONE',
  other: 'ALTRO',
}
const BANK_KINDS: LedgerKind[] = ['bonus', 'malus', 'colletta', 'sponsor', 'adjust', 'fee', 'reamm']

function betStatus(m: Market, now: number): { label: string; cls: string; note: ReactNode } {
  const my = m.my!
  if (m.status === 'void') return { label: 'ANNULLATA', cls: '', note: 'Rimborsata.' }
  if (m.status === 'done') {
    const canAppeal = m.appealUntil && m.appealUntil > now && !m.flipped
    const appeal = canAppeal && !my.appealed ? <> <button className="sm" style={{ textDecoration: 'underline' }} onClick={() => actions.appeal(m.id)}>Contesta</button></> : null
    const flipped = (m.flipped ? ' Verdetto ribaltato dalla giuria.' : '') + (m.byAdmin ? ' Esitata dalla Regia.' : '')
    return my.result === 'win'
      ? { label: 'VINTA', cls: 'ok', note: <>+{cur(my.payout ?? 0)}.{flipped}{appeal}</> }
      : { label: 'PERSA', cls: 'ko', note: <>−{cur(my.amount)}.{flipped}{appeal}</> }
  }
  if (m.status === 'closed') return { label: 'IN ATTESA DI ESITO', cls: '', note: 'Puntate chiuse.' }
  return { label: 'IN CORSO', cls: '', note: `Incasso potenziale ${cur(payout(my.amount, my.side === 'yes' ? m.yes : m.no))}.` }
}

/** Compenso di chi esita, dal punto di vista del creatore: potenziale mentre è aperta, ricevuto a esito chiuso. */
function feeNote(m: Market, teamId: number | null): string {
  if (m.status === 'open' || m.status === 'closed') return m.feeCreator > 0 ? `Compenso se esiti tu: ${cur(m.feeCreator)}.` : ''
  if (m.status !== 'done') return ''
  if (m.flipped) return 'Esito ribaltato: nessun compenso.'
  if (m.byAdmin) return `Esitata dalla Regia.${m.feeAmount > 0 ? ` Compenso ricevuto: ${cur(m.feeAmount)}.` : ''}`
  if (m.feeTeamId === undefined) return ''
  if (m.feeTeamId !== teamId) return 'Ha esitato un’altra squadra: nessun compenso per te.'
  return m.feePaid ? `Compenso ricevuto: ${cur(m.feeAmount)}.` : `Compenso in arrivo a fine contestazione: ${cur(m.feeAmount)}.`
}

/** ESITA ORA in un passo: tocchi, scegli SÌ o NO, e le puntate si chiudono con l'esito registrato. */
function EsitaOra({ id }: { id: number }) {
  const [choosing, setChoosing] = useState(false)
  if (!choosing) {
    return (
      <div className="btns">
        <button className="sm" onClick={() => setChoosing(true)}>ESITA ORA</button>
      </div>
    )
  }
  return (
    <>
      <p className="m">Chiudi subito la scommessa con quale esito?</p>
      <div className="btns">
        <button onClick={() => actions.resolve(id, 'yes')}>SÌ</button>
        <button onClick={() => actions.resolve(id, 'no')}>NO</button>
        <button className="sm" onClick={() => setChoosing(false)}>Annulla</button>
      </div>
    </>
  )
}

export function Bets() {
  const s = useGame()
  const mine = s.markets.filter((m) => m.my).sort((a, b) => b.num - a.num)
  const made = s.markets.filter((m) => m.by === s.team).sort((a, b) => b.num - a.num)
  const todo = toResolve(s)
  const frozen = s.sessionStatus === 'closed'

  return (
    <>
      <div className="top"><div className="logo">SCOMMESSE</div></div>

      <h2 className="sec">Da esitare</h2>
      {todo.length ? todo.map((m) => (
        <div className="item" key={m.id}>
          <div className="h">
            <span className="pill">ESITA</span>
            <span className="cd num" style={{ fontSize: 16 }}>restano <Countdown until={m.resolveBy ?? 0} /></span>
          </div>
          <p className="q">{m.text}</p>
          <p className="m">
            Scommessa n. {m.num} · di {m.by}. Chi ha puntato non può esitare. La prima risposta vale.
            {m.feeOther > 0 && <> <b>Esita per {cur(m.feeOther)}.</b></>}
          </p>
          <div className="btns">
            <button disabled={frozen} onClick={() => actions.resolve(m.id, 'yes')}>SÌ</button>
            <button disabled={frozen} onClick={() => actions.resolve(m.id, 'no')}>NO</button>
          </div>
        </div>
      )) : <p className="empty">Nessuna scommessa da esitare.</p>}

      <h2 className="sec">Le mie puntate</h2>
      {mine.length ? mine.map((m) => {
        const st = betStatus(m, s.now)
        return (
          <div className="item" key={m.id}>
            <div className="h">
              <span className={`pill ${st.cls}`}>{st.label}</span>
              <span className="cd num" style={{ fontSize: 16 }}>{m.my!.side === 'yes' ? 'SÌ' : 'NO'} · {cur(m.my!.amount)}</span>
            </div>
            <p className="q">{m.text}</p>
            <p className="m">Scommessa n. {m.num} · quota {odds(m.my!.side === 'yes' ? m.yes : m.no)}. {st.note}</p>
          </div>
        )
      }) : <p className="empty">Non hai ancora puntato.</p>}

      <h2 className="sec">Create da me</h2>
      {made.length ? made.map((m) => {
        const label = m.status === 'open' ? 'APERTA' : m.status === 'closed' ? 'DA ESITARE' : m.status === 'void' ? 'ANNULLATA' : m.status === 'empty' ? 'SENZA PUNTATE' : `ESITATA ${m.outcome === 'yes' ? 'SÌ' : 'NO'}`
        const fee = feeNote(m, s.teamId)
        return (
          <div className="item" key={m.id}>
            <div className="h">
              <span className="pill">{label}</span>
              <span className="cd num" style={{ fontSize: 16 }}>{m.status === 'open' && <Countdown until={m.expiresAt} />}</span>
            </div>
            <p className="q">{m.text}</p>
            <p className="m">Scommessa n. {m.num} · SÌ {odds(m.yes)} / NO {odds(m.no)}{fee && <><br />{fee}</>}</p>
            {m.status === 'open' && !frozen && <EsitaOra id={m.id} />}
          </div>
        )
      }) : <p className="empty">Non hai creato scommesse.</p>}

      <h2 className="sec">Movimenti (Carletti)</h2>
      <div className="tbl" style={{ marginTop: 0 }}>
        {s.ledger.map((l) => (
          <div className="led" key={l.id}>
            <span className={`pill ${BANK_KINDS.includes(l.kind) ? 'bank' : ''}`}>{LEDGER_LABEL[l.kind]}</span>
            <span className="t">{l.label}</span>
            <span className={`a ${l.amount >= 0 ? 'pos-a' : 'neg-a'}`}>{l.amount >= 0 ? '+' : ''}{fmt(l.amount)}</span>
          </div>
        ))}
      </div>

      <button className="ghost leave" onClick={() => window.confirm('Cambiare squadra? Esci da questa e torni alla scelta.') && actions.leaveTeam()}>
        Cambia squadra
      </button>
    </>
  )
}
