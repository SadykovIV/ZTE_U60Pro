export interface TabDef<T extends string> {
  id: T
  label: string
}

/** Horizontally scrollable pill tab strip. */
export function Tabs<T extends string>({
  tabs,
  active,
  onChange,
}: {
  tabs: TabDef<T>[]
  active: T
  onChange: (id: T) => void
}) {
  return (
    <div className="no-scrollbar -mx-1 -my-1 flex gap-1 overflow-x-auto px-1 py-1" role="tablist">
      {tabs.map((t) => (
        <button
          key={t.id}
          role="tab"
          aria-selected={active === t.id}
          onClick={() => onChange(t.id)}
          className={`whitespace-nowrap rounded-full px-3.5 py-1.5 text-[13px] font-semibold transition-colors ${
            active === t.id
              ? 'bg-surface text-ink shadow-sm ring-1 ring-line/10'
              : 'text-ink2 hover:bg-surface2 hover:text-ink'
          }`}
        >
          {t.label}
        </button>
      ))}
    </div>
  )
}
