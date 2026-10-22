import { useGame } from '../store/game'
import { mmss } from '../lib/format'

export function Countdown({ until }: { until: number }) {
  const { now } = useGame()
  return <span className="num">{mmss(until - now)}</span>
}
