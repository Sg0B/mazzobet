export const MIN = 60_000

const pad = (n: number) => String(n).padStart(2, '0')

export const fmt = (n: number) =>
  (n < 0 ? '−' : '') + String(Math.abs(Math.round(n))).replace(/\B(?=(\d{3})+(?!\d))/g, '.')

export const cur = (n: number) => '₡ ' + fmt(n)

/** Quota in centesimi → "1,80". */
export const odds = (cents: number) => (cents / 100).toFixed(2).replace('.', ',')

export const mmss = (ms: number) => {
  const s = Math.max(0, Math.ceil(ms / 1000))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  return h ? `${h}:${pad(m)}:${pad(sec)}` : `${pad(m)}:${pad(sec)}`
}

export const hhmm = (t: number) => {
  const d = new Date(t)
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`
}

export const ago = (t: number, now: number) => {
  const m = Math.max(0, Math.floor((now - t) / MIN))
  return m < 1 ? 'adesso' : `${m} min fa`
}
