import { useState } from 'react'
import { useGame, type Side } from './store/game'
import { BottomNav } from './components/BottomNav'
import { BetSheet } from './components/BetSheet'
import { CreateSheet } from './components/CreateSheet'
import { MustResolve } from './components/MustResolve'
import { Toast } from './components/Toast'
import { Bets } from './screens/Bets'
import { Home } from './screens/Home'
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
      </div>
      <BottomNav />
      {sheet?.type === 'bet' && <BetSheet marketId={sheet.id} side={sheet.side} onClose={close} />}
      {sheet?.type === 'create' && <CreateSheet onClose={close} />}
      <MustResolve />
      <Toast />
    </>
  )
}
