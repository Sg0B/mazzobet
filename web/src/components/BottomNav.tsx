import { actions, toResolve, useGame, type GameState } from '../store/game'

const TABS: { id: GameState['tab']; label: string; icon: string[] }[] = [
  { id: 'home', label: 'Home', icon: ['M3 11l9-8 9 8v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z'] },
  { id: 'race', label: 'Corsa', icon: ['M2.5 16.5a3.5 3.5 0 1 0 7 0a3.5 3.5 0 1 0-7 0', 'M14.5 16.5a3.5 3.5 0 1 0 7 0a3.5 3.5 0 1 0-7 0', 'M6 16.5L10 9h5.5l3 7.5', 'M10 9l2.2 7.5', 'M15.5 9L14 6h3', 'M8.5 7h3'] },
  { id: 'rank', label: 'Classifiche', icon: ['M5 21V11M12 21V4M19 21v-7'] },
  { id: 'bets', label: 'Scommesse', icon: ['M3 8a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v2a2 2 0 0 0 0 4v2a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-2a2 2 0 0 0 0-4z', 'M14 6v12'] },
  { id: 'radio', label: 'RadioCorsa', icon: ['M3 9h18v11H3z', 'M7 9l10-5', 'M15 13h3M15 16h3'] },
]

export function BottomNav() {
  const s = useGame()
  const badge = toResolve(s).length
  return (
    <nav id="nav" aria-label="Navigazione principale">
      <div>
        {TABS.map((t) => (
          <button key={t.id} className={s.tab === t.id ? 'on' : ''} onClick={() => actions.setTab(t.id)} aria-current={s.tab === t.id ? 'page' : undefined}>
            <svg viewBox="0 0 24 24" aria-hidden="true">
              {t.icon.map((d) => (
                <path key={d} d={d} />
              ))}
            </svg>
            {t.label}
            {t.id === 'bets' && badge > 0 && <span className="badge">{badge}</span>}
          </button>
        ))}
      </div>
    </nav>
  )
}
