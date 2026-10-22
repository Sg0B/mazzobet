import { useGame } from '../store/game'

export function Toast() {
  const { toast } = useGame()
  if (!toast) return null
  return (
    <div id="toast" role="status">
      {toast}
    </div>
  )
}
