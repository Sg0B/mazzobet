/** Logo «PCS»: tre quadrati (P e C rossi, S scura) e, sotto, la striscia col nome. `mini` = solo i tre quadrati. */
export function PcsLogo({ mini = false }: { mini?: boolean }) {
  return (
    <span className={`pcs-logo${mini ? ' mini' : ''}`} role="img" aria-label="Pro Carletto Stats">
      <span className="sq">
        <i>P</i>
        <i>C</i>
        <i className="dk">S</i>
      </span>
      {!mini && <span className="pbar">PRO CARLETTO STATS</span>}
    </span>
  )
}
