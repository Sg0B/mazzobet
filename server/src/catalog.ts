import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

/** Segnaposto ammessi (PRD §10.1). Il catalogo fornisce solo i testi: mai importi, probabilità o destinatari. */
const ALLOWED = new Set([
  'nomeSquadre', 'nomeSquadra', 'importo', 'numeroScommessa', 'nomeSponsor',
  'importoSponsor', 'numeroSquadre', 'importoPerSquadra', 'elencoCaduti',
])

type Entry = Record<string, unknown>

const EXPECTED: Record<string, { fields: string[]; text: string[] }> = {
  bonus: { fields: ['id', 'evento', 'titolo', 'testo'], text: ['titolo', 'testo'] },
  malus: { fields: ['id', 'evento', 'titolo', 'testo'], text: ['titolo', 'testo'] },
  sponsor: { fields: ['id', 'nome', 'titolo', 'testoCassa', 'testoPioggia'], text: ['titolo', 'testoCassa', 'testoPioggia'] },
  radiocorsa: { fields: ['id', 'evento', 'titolo', 'testo'], text: ['titolo', 'testo'] },
}

/** Ritorna l'elenco degli errori di validazione (vuoto = catalogo valido). */
export function validateCatalog(c: unknown): string[] {
  const errors: string[] = []
  if (typeof c !== 'object' || c === null) return ['catalogo non è un oggetto JSON']
  const ids = new Set<string>()
  for (const [section, spec] of Object.entries(EXPECTED)) {
    const list = (c as Record<string, unknown>)[section]
    if (!Array.isArray(list) || list.length === 0) {
      errors.push(`sezione "${section}" mancante o vuota`)
      continue
    }
    for (const raw of list as Entry[]) {
      for (const f of spec.fields) {
        if (typeof raw[f] !== 'string' || !(raw[f] as string).trim()) errors.push(`${section}: campo "${f}" mancante o vuoto (${String(raw.id)})`)
      }
      const id = String(raw.id)
      if (ids.has(id)) errors.push(`id duplicato: ${id}`)
      ids.add(id)
      for (const f of spec.text) {
        for (const m of String(raw[f] ?? '').matchAll(/\{([^}]*)\}/g)) {
          if (!ALLOWED.has(m[1])) errors.push(`${id}: segnaposto non ammesso {${m[1]}}`)
        }
      }
    }
  }
  return errors
}

export function readCatalog(path = process.env.CATALOG_PATH ?? 'data/catalogo_banco.json'): unknown {
  return JSON.parse(readFileSync(resolve(path), 'utf8'))
}
