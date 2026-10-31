import { useEffect, useState } from 'react'
import { actions, mustResolve, toResolve, useGame, type Side } from './store/game'
import { registerWorker, resyncPush } from './lib/push'
import { PinSetup } from './components/PinSetup'
import { BottomNav } from './components/BottomNav'
import { BetSheet } from './components/BetSheet'
import { CreateSheet } from './components/CreateSheet'
import { MustResolve } from './components/MustResolve'
import { Toast } from './components/Toast'
import { Bets } from './screens/Bets'
import { Home } from './screens/Home'
import { Race } from './screens/Race'
import { Radio } from './screens/Radio'
import { Rank } from './screens/Rank'
import { Regia } from './screens/Regia'
import { TeamSelect } from './screens/TeamSelect'
import { TvScreen } from './screens/Tv'

type SheetState = { type: 'bet'; id: number; side: Side } | { type: 'create' } | null

export default function App() {
  if (window.location.pathname.startsWith('/regia')) return <Regia />
  if (window.location.pathname.startsWith('/tv')) return <TvScreen />
  return <Game />
}

function Game() {
  const s = useGame()
  const [sheet, setSheet] = useState<SheetState>(null)
  const close = () => setSheet(null)
  const [pinAsk, setPinAsk] = useState(false)

  // Avvisi: service worker, tocco sulla notifica (app chiusa: ?m=… nell'indirizzo; app aperta: messaggio) e fallback senza permesso
  // (numero nel titolo della scheda, vibrazione quando ne arriva una nuova).
  const count = s.team ? mustResolve(s).length + toResolve(s).length : 0
  const [seen, setSeen] = useState(0)
  useEffect(() => {
    registerWorker()
    if (new URLSearchParams(window.location.search).has('m')) {
      actions.setTab('bets')
      window.history.replaceState(null, '', '/')
    }
    const onMsg = (e: MessageEvent) => { if (e.data?.type === 'mazzobet-open') actions.setTab('bets') }
    navigator.serviceWorker?.addEventListener('message', onMsg)
    return () => navigator.serviceWorker?.removeEventListener('message', onMsg)
  }, [])
  useEffect(() => { if (s.teamId) void resyncPush() }, [s.teamId])
  useEffect(() => {
    document.title = count > 0 ? `(${count}) MazzoBet` : 'MazzoBet'
    if (count > seen) { try { navigator.vibrate?.(200) } catch { /* ignora */ } }
    setSeen(count)
  }, [count])   // eslint-disable-line react-hooks/exhaustive-deps

  // Squadra entrata prima dei PIN: al primo caricamento chiede di impostarlo (una volta per apertura dell'app).
  useEffect(() => {
    if (!s.teamId) { setPinAsk(false); return }
    let live = true
    void actions.needsPin(s.teamId).then((n) => { if (live) setPinAsk(n) })
    return () => { live = false }
  }, [s.teamId])

  if (!s.ready) return <div id="app"><p className="empty">Carico…</p></div>

  if (!s.team) {
    return (
      <div id="app">
        <TeamSelect />
      </div>
    )
  }

  return (
    <>
      <div id="app">
        {s.tab === 'home' && <Home onBet={(id, side) => setSheet({ type: 'bet', id, side })} onCreate={() => setSheet({ type: 'create' })} />}
        {s.tab === 'rank' && <Rank />}
        {s.tab === 'bets' && <Bets />}
        {s.tab === 'radio' && <Radio />}
        {s.tab === 'race' && <Race />}
      </div>
      <BottomNav />
      {sheet?.type === 'bet' && <BetSheet marketId={sheet.id} side={sheet.side} onClose={close} />}
      {sheet?.type === 'create' && <CreateSheet onClose={close} />}
      {pinAsk && s.teamId !== null && <PinSetup teamId={s.teamId} team={s.team} onDone={() => setPinAsk(false)} />}
      <MustResolve />
      <Toast />
    </>
  )
}
