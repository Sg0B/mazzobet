import { RACE_TRACK } from './raceTrack'

/**
 * Chilometri percorsi al secondo di gara indicato: interpolazione lineare tra i punti della traiettoria
 * (ricerca binaria). Mai indietro, mai oltre l'arrivo; dipende solo dal tempo di gara del server, non dalle notizie.
 */
export function kmAt(sec: number): number {
  const t = RACE_TRACK
  if (!t.length || sec <= t[0][0]) return 0
  const last = t[t.length - 1]
  if (sec >= last[0]) return last[1]
  let lo = 0
  let hi = t.length - 1
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1
    if (t[mid][0] <= sec) lo = mid
    else hi = mid
  }
  const [t0, k0] = t[lo]
  const [t1, k1] = t[hi]
  return k0 + ((k1 - k0) * (sec - t0)) / (t1 - t0)
}
