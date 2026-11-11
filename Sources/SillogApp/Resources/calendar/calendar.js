// 캘린더 화면: 일정은 앱(맥 캘린더, EventKit)에서 받아 FullCalendar 로 그린다.
// 앱과는 window.webkit.messageHandlers.sillog 로 주고받는다 (보낸 것마다 앱의 답이 약속으로 온다)
(async () => {
  const post = (message) => window.webkit.messageHandlers.sillog.postMessage(message)
  const setup = await post({ type: 'init' })
  const detail = document.getElementById('detail')

  const calendar = new FullCalendar.Calendar(document.getElementById('calendar'), {
    locale: window.SILLOG_LANG || 'ko',
    initialView: setup.view,
    firstDay: setup.firstDay,
    height: '100%',
    nowIndicator: true,
    scrollTime: '08:00:00',
    dayMaxEvents: true,
    eventDisplay: 'block',
    nextDayThreshold: '06:00:00',                     // 새벽 6시 전에 끝나는 일정은 다음 날까지 걸쳐 그리지 않는다
    headerToolbar: { left: 'today prev,next title', center: '', right: 'timeGridDay,timeGridWeek,dayGridMonth' },
    buttonText: { today: '오늘', day: '일', week: '주', month: '월' },
    eventTimeFormat: { hour: '2-digit', minute: '2-digit', hour12: false },
    slotLabelFormat: { hour: '2-digit', minute: '2-digit', hour12: false },
    // 보이는 기간이 바뀔 때마다 앱에 묻는다 (보이는 캘린더의 일정 + 아직 등록 안 한 제안)
    events: (info) => post({ type: 'events', start: info.startStr, end: info.endStr }),
    eventClassNames: (arg) => (arg.event.extendedProps.kind === 'event' ? ['sillog-event'] : []),
    eventDidMount: (arg) => {
      if (arg.event.extendedProps.color) arg.el.style.setProperty('--ev', arg.event.extendedProps.color)
    },
    eventClick: (arg) => {
      arg.jsEvent.preventDefault()
      show(arg.event, arg.el)
    },
    datesSet: (arg) => {
      hide()
      post({ type: 'view', name: arg.view.type })
    },
  })
  calendar.render()
  window.sillog = { refetch: () => calendar.refetchEvents() }

  // 일정을 누르면 뜨는 상자. 제목·메모는 사용자 데이터라 textContent 로만 넣는다
  function node(tag, className, text) {
    const element = document.createElement(tag)
    if (className) element.className = className
    if (text) element.textContent = text
    return element
  }

  function button(label, primary, action) {
    const element = node('button', primary ? 'primary' : '', label)
    element.addEventListener('click', () => { hide(); action() })
    return element
  }

  const dayFormat = new Intl.DateTimeFormat('ko-KR', { month: 'long', day: 'numeric', weekday: 'short' })
  const timeFormat = new Intl.DateTimeFormat('ko-KR', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })

  // "11월 5일 (목) 15:00–16:00", 종일이면 "11월 5일 (목) 종일" (여러 날이면 끝 날까지)
  function when(event) {
    if (event.allDay) {
      const last = event.end ? new Date(event.end.getTime() - 86400000) : event.start
      const span = last.toDateString() === event.start.toDateString() ? dayFormat.format(event.start) : `${dayFormat.format(event.start)} – ${dayFormat.format(last)}`
      return `${span} 종일`
    }
    return `${dayFormat.format(event.start)} ${timeFormat.format(event.start)}${event.end ? `–${timeFormat.format(event.end)}` : ''}`
  }

  function show(event, anchor) {
    const props = event.extendedProps
    detail.replaceChildren(node('h3', '', event.title), node('div', 'when', when(event)))
    const actions = node('div', 'actions')
    if (props.kind === 'suggestion') {
      detail.append(node('div', 'meta', '기록에서 찾은 일정 · 아직 캘린더에 없어요'))
      if (props.evidence) detail.append(node('div', 'quote', props.evidence))
      actions.append(button('무시', false, () => post({ type: 'dismiss', id: props.suggestionId })),
                     button('등록', true, () => post({ type: 'register', id: props.suggestionId })))
    } else {
      if (props.calendar) {
        const meta = node('div', 'meta')
        const dot = node('span', 'dot')
        dot.style.background = props.color
        meta.append(dot, document.createTextNode(props.calendar))
        detail.append(meta)
      }
      if (props.location) detail.append(node('div', 'meta', props.location))
      if (props.notes) detail.append(node('div', 'quote', props.notes))
      actions.append(button('캘린더 앱에서 열기', false, () => post({ type: 'openCalendarApp' })))
    }
    detail.append(actions)
    detail.hidden = false
    place(anchor)
  }

  // 누른 일정 옆(오른쪽, 자리가 없으면 왼쪽)에, 창 밖으로 나가지 않게
  function place(anchor) {
    const box = anchor.getBoundingClientRect()
    const width = detail.offsetWidth, height = detail.offsetHeight
    let left = box.right + 8
    if (left + width > window.innerWidth - 8) left = Math.max(8, box.left - width - 8)
    const top = Math.max(8, Math.min(box.top, window.innerHeight - height - 8))
    detail.style.left = `${left}px`
    detail.style.top = `${top}px`
  }

  function hide() { detail.hidden = true }

  document.addEventListener('mousedown', (event) => {
    if (!detail.hidden && !detail.contains(event.target) && !event.target.closest('.fc-event')) hide()
  })
  document.addEventListener('keydown', (event) => { if (event.key === 'Escape') hide() })
})()
