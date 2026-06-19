import {
  findNext, findPrevious, replaceNext, replaceAll,
  getSearchQuery, setSearchQuery, SearchQuery,
} from '@codemirror/search'

// Custom search panel

/*
  Builds the search/replace UI passed to search({ createPanel }). The panel owns
  only its DOM and event wiring; all search behavior is delegated to the exported
  @codemirror/search commands (findNext, replaceAll, …), and the query is driven
  through setSearchQuery. CM6's automatic match highlighting is a function of the
  search state, not the panel, so it keeps working with no extra effort here.

  Layout is two rows:
    Row 1: Find field, Next, Prev, Options (a dropdown of toggles).
    Row 2: Replace field, Replace, Replace all.
*/
export function createSearchPanel(view) {
  const dom = document.createElement('div')
  dom.className = 'ft-search'

  // Small helpers for the repeated control types.
  function field(placeholder) {
    const el = document.createElement('input')
    el.className = 'ft-search-field'
    el.placeholder = placeholder
    el.setAttribute('aria-label', placeholder)
    return el
  }
  function button(label, onClick) {
    const b = document.createElement('button')
    b.className = 'ft-search-btn'
    b.type = 'button'
    b.textContent = label
    b.addEventListener('click', e => { e.preventDefault(); onClick() })
    return b
  }

  const findField = field('Find…')
  // CM6 focuses the element marked main-field when the panel opens.
  findField.setAttribute('main-field', 'true')
  const replaceField = field('Replace…')

  const caseToggle = document.createElement('input')
  caseToggle.type = 'checkbox'
  const wordToggle = document.createElement('input')
  wordToggle.type = 'checkbox'

  // Seed every control from any pre-existing query (e.g. reopening the panel).
  const initial = getSearchQuery(view.state)
  findField.value    = initial.search
  replaceField.value = initial.replace
  caseToggle.checked = initial.caseSensitive
  wordToggle.checked = initial.wholeWord

  // Rebuilds the query from current control values and dispatches it, so the
  // highlighted matches and the next find/replace always match what's on screen.
  function commit() {
    view.dispatch({
      effects: setSearchQuery.of(new SearchQuery({
        search:        findField.value,
        replace:       replaceField.value,
        caseSensitive: caseToggle.checked,
        wholeWord:     wordToggle.checked,
      })),
    })
  }
  findField.addEventListener('input', commit)
  replaceField.addEventListener('input', commit)
  caseToggle.addEventListener('change', commit)
  wordToggle.addEventListener('change', commit)

  // Enter / Shift+Enter step through matches; Enter in replace does one replace.
  findField.addEventListener('keydown', e => {
    if (e.key !== 'Enter') return
    e.preventDefault()
    if (e.shiftKey) findPrevious(view)
    else findNext(view)
  })
  replaceField.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); replaceNext(view) }
  })

  // Options dropdown. The popover stays open while toggling and closes on an
  // outside click or a second press of the Options button.
  const optionsWrap = document.createElement('div')
  optionsWrap.className = 'ft-search-options'
  const popover = document.createElement('div')
  popover.className = 'ft-search-popover'
  function optionRow(text, checkbox) {
    const row = document.createElement('label')
    row.className = 'ft-search-option'
    row.appendChild(checkbox)
    row.appendChild(document.createTextNode(text))
    return row
  }
  popover.appendChild(optionRow('Case-sensitive', caseToggle))
  popover.appendChild(optionRow('By word', wordToggle))

  let optionsOpen = false
  function onOutside(e) {
    if (!optionsWrap.contains(e.target)) setOptions(false)
  }
  function setOptions(open) {
    optionsOpen = open
    popover.classList.toggle('open', open)
    if (open) document.addEventListener('mousedown', onOutside)
    else document.removeEventListener('mousedown', onOutside)
  }
  const optionsBtn = button('Options', () => setOptions(!optionsOpen))
  optionsWrap.appendChild(optionsBtn)
  optionsWrap.appendChild(popover)

  const nextBtn = button('Next', () => findNext(view))
  const prevBtn = button('Prev', () => findPrevious(view))
  const row1 = document.createElement('div')
  row1.className = 'ft-search-row'
  row1.appendChild(findField)
  row1.appendChild(nextBtn)
  row1.appendChild(prevBtn)
  row1.appendChild(optionsWrap)

  const replaceBtn    = button('Replace', () => replaceNext(view))
  const replaceAllBtn = button('Replace all', () => replaceAll(view))
  const row2 = document.createElement('div')
  row2.className = 'ft-search-row'
  row2.appendChild(replaceField)
  row2.appendChild(replaceBtn)
  row2.appendChild(replaceAllBtn)

  dom.appendChild(row1)
  dom.appendChild(row2)

  /*
    Two passes. Top row: equalize the three buttons to the widest, find field
    flexes to fill. Bottom row: pin the replace field to the find field's settled
    width so the two fields align, then equalize the two bottom buttons (leaving
    empty space at bottom-right). Buttons are border-box, so style.width == offsetWidth.
  */
  function balanceRows() {
    const top = [nextBtn, prevBtn, optionsBtn]
    const bottom = [replaceBtn, replaceAllBtn]
    for (const b of [...top, ...bottom]) b.style.width = ''
    replaceField.style.flex = ''
    replaceField.style.width = ''

    // Top row: equalize the three buttons; the find field flexes to fill.
    const a = Math.max(...top.map(b => b.offsetWidth))
    for (const b of top) b.style.width = `${a}px`

    // Bottom row: match the replace field to the now-settled find field width
    // (reading offsetWidth forces the reflow that accounts for the line above).
    replaceField.style.flex = '0 0 auto'
    replaceField.style.width = `${findField.offsetWidth}px`

    // Equalize the two bottom buttons; leftover row space stays empty at right.
    const b = Math.max(...bottom.map(btn => btn.offsetWidth))
    for (const btn of bottom) btn.style.width = `${b}px`
  }

  return {
    dom,
    top: true,
    mount() {
      findField.focus()
      findField.select()
      balanceRows()
    },
    // Keep controls in sync when the query is changed from outside the panel.
    // Skip focused text fields so we never clobber what the user is typing.
    update(u) {
      const q = getSearchQuery(u.state)
      if (document.activeElement !== findField    && q.search  !== findField.value)    findField.value = q.search
      if (document.activeElement !== replaceField && q.replace !== replaceField.value) replaceField.value = q.replace
      caseToggle.checked = q.caseSensitive
      wordToggle.checked = q.wholeWord
    },
    // Ensure the outside-click listener never outlives the panel.
    destroy() { setOptions(false) },
  }
}
