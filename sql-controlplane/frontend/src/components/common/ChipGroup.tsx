interface ChipGroupProps<T extends string> {
  options: { value: T; label: string }[]
  selected: T[]
  onToggle: (value: T) => void
}

/** Toggle chips (multi-select). For single-select, pass one selected value and replace it in onToggle. */
export function ChipGroup<T extends string>({ options, selected, onToggle }: ChipGroupProps<T>) {
  return (
    <div className="chips">
      {options.map(o => (
        <button key={o.value} type="button" className={`chip ${selected.includes(o.value) ? 'on' : ''}`}
          onClick={() => onToggle(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  )
}
