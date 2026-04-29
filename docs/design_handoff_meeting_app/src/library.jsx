// Library — the heart of the app.
// macOS window with sidebar, list, and detail preview.

function LibraryWindow() {
  const meetings = [
    { id: 1, title: 'Q2 Roadmap Sync', date: 'Today, 10:30 AM', dur: '47m', speakers: 4, app: 'Zoom', tag: 'Engineering', selected: true, color: 'oklch(0.7 0.16 250)' },
    { id: 2, title: 'Design crit — onboarding flow', date: 'Yesterday, 3:15 PM', dur: '32m', speakers: 3, app: 'Figma', tag: 'Design', color: 'oklch(0.7 0.16 320)' },
    { id: 3, title: 'Hiring panel — Pim Sutthichai', date: 'Apr 26, 2:00 PM', dur: '58m', speakers: 5, app: 'Google Meet', tag: 'People', color: 'oklch(0.7 0.16 30)' },
    { id: 4, title: 'Customer interview — Spaceship Labs', date: 'Apr 25, 11:00 AM', dur: '41m', speakers: 2, app: 'Zoom', tag: 'Research', color: 'oklch(0.7 0.16 145)' },
    { id: 5, title: 'Weekly 1:1 with Tar', date: 'Apr 24, 4:30 PM', dur: '28m', speakers: 2, app: 'FaceTime', tag: '1:1', color: 'oklch(0.7 0.16 250)' },
    { id: 6, title: 'Board prep — March numbers', date: 'Apr 22, 9:00 AM', dur: '1h 12m', speakers: 6, app: 'Zoom', tag: 'Exec', color: 'oklch(0.7 0.16 30)' },
    { id: 7, title: 'Eng all-hands', date: 'Apr 19, 10:00 AM', dur: '52m', speakers: 8, app: 'Zoom', tag: 'Engineering', color: 'oklch(0.7 0.16 250)' },
  ];

  return (
    <div style={{
      width: 1080, height: 700, borderRadius: 16, overflow: 'hidden',
      display: 'flex',
      boxShadow: '0 0 0 0.5px rgba(0,0,0,0.4), 0 32px 80px rgba(0,0,0,0.4)',
      position: 'relative',
      background: 'rgba(245,247,252,0.5)',
    }}>
      {/* Sidebar */}
      <LibrarySidebar />

      {/* Center — list */}
      <div style={{ width: 380, display: 'flex', flexDirection: 'column', position: 'relative' }}>
        <div style={{
          position: 'absolute', inset: 0,
          background: 'rgba(255,255,255,0.55)',
          backdropFilter: 'blur(40px) saturate(180%)',
          WebkitBackdropFilter: 'blur(40px) saturate(180%)',
          borderRight: '0.5px solid rgba(0,0,0,0.08)',
        }} />
        <div style={{ position: 'relative', zIndex: 1, display: 'flex', flexDirection: 'column', height: '100%' }}>
          <ListToolbar />
          <div style={{ flex: 1, overflow: 'auto', padding: '4px 8px 12px' }}>
            <ListGroup label="TODAY" />
            {meetings.slice(0,1).map(m => <MeetingRow key={m.id} m={m} />)}
            <ListGroup label="YESTERDAY" />
            {meetings.slice(1,2).map(m => <MeetingRow key={m.id} m={m} />)}
            <ListGroup label="THIS WEEK" />
            {meetings.slice(2,5).map(m => <MeetingRow key={m.id} m={m} />)}
            <ListGroup label="EARLIER" />
            {meetings.slice(5).map(m => <MeetingRow key={m.id} m={m} />)}
          </div>
        </div>
      </div>

      {/* Detail */}
      <div style={{ flex: 1, position: 'relative' }}>
        <div style={{
          position: 'absolute', inset: 0,
          background: 'rgba(255,255,255,0.42)',
          backdropFilter: 'blur(40px) saturate(180%)',
          WebkitBackdropFilter: 'blur(40px) saturate(180%)',
        }} />
        <div style={{ position: 'relative', zIndex: 1, height: '100%' }}>
          <MeetingDetail meeting={meetings[0]} />
        </div>
      </div>
    </div>
  );
}

function LibrarySidebar() {
  return (
    <div style={{ width: 220, position: 'relative', display: 'flex', flexDirection: 'column' }}>
      <div style={{
        position: 'absolute', inset: 0,
        background: 'rgba(225,232,245,0.5)',
        backdropFilter: 'blur(50px) saturate(180%)',
        WebkitBackdropFilter: 'blur(50px) saturate(180%)',
        borderRight: '0.5px solid rgba(0,0,0,0.06)',
      }} />
      <div style={{ position: 'relative', zIndex: 1, padding: '12px 0', flex: 1 }}>
        <div style={{ height: 32, display: 'flex', alignItems: 'center', padding: '0 14px', marginBottom: 12 }}>
          <TrafficLights size={12} />
        </div>

        <SidebarGroup label="LIBRARY">
          <SidebarItem icon="clock" label="All meetings" count="124" selected />
          <SidebarItem icon="star" label="Starred" count="9" />
          <SidebarItem icon="flag" label="Marked moments" count="38" />
          <SidebarItem icon="sparkles" label="Action items" count="17" pulse />
        </SidebarGroup>

        <SidebarGroup label="TAGS">
          <SidebarItem dot="oklch(0.7 0.16 250)" label="Engineering" count="42" />
          <SidebarItem dot="oklch(0.7 0.16 320)" label="Design" count="28" />
          <SidebarItem dot="oklch(0.7 0.16 30)" label="People" count="19" />
          <SidebarItem dot="oklch(0.7 0.16 145)" label="Research" count="14" />
          <SidebarItem dot="oklch(0.7 0.16 75)" label="1:1" count="21" />
        </SidebarGroup>

        <SidebarGroup label="SPEAKERS">
          <SidebarItem avatar="T" label="Tar" count="34" />
          <SidebarItem avatar="P" label="Pim" count="22" />
          <SidebarItem avatar="J" label="June" count="18" />
          <SidebarItem icon="user" label="Show all 47…" muted />
        </SidebarGroup>
      </div>

      {/* Footer storage */}
      <div style={{ position: 'relative', zIndex: 1, padding: 14, borderTop: '0.5px solid rgba(0,0,0,0.06)' }}>
        <div style={{ fontSize: 10, fontWeight: 700, color: 'rgba(0,0,0,0.5)', letterSpacing: '0.08em', marginBottom: 6 }}>STORAGE</div>
        <div style={{ height: 4, borderRadius: 2, background: 'rgba(0,0,0,0.08)', overflow: 'hidden', marginBottom: 6 }}>
          <div style={{ width: '38%', height: '100%', background: 'linear-gradient(90deg, oklch(0.7 0.14 250), oklch(0.65 0.16 200))' }} />
        </div>
        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 10, color: 'rgba(0,0,0,0.55)' }}>
          <span>14.2 GB used</span>
          <span>~37 GB free</span>
        </div>
      </div>
    </div>
  );
}

function SidebarGroup({ label, children }) {
  return (
    <div style={{ marginBottom: 14 }}>
      <div style={{ padding: '0 16px 4px', fontSize: 10, fontWeight: 700, color: 'rgba(0,0,0,0.45)', letterSpacing: '0.1em' }}>{label}</div>
      {children}
    </div>
  );
}

function SidebarItem({ icon, label, count, selected, dot, avatar, pulse, muted }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 8,
      padding: '5px 10px 5px 12px', margin: '0 8px',
      borderRadius: 7, position: 'relative',
      background: selected ? 'rgba(0,0,0,0.08)' : 'transparent',
      cursor: 'pointer',
    }}>
      {icon && <Icon name={icon} size={14} color={muted ? 'rgba(0,0,0,0.4)' : 'rgba(0,0,0,0.7)'} />}
      {dot && <div style={{ width: 9, height: 9, borderRadius: '50%', background: dot }} />}
      {avatar && <div style={{
        width: 16, height: 16, borderRadius: '50%',
        background: 'linear-gradient(135deg, oklch(0.7 0.16 250), oklch(0.6 0.18 280))',
        color: '#fff', fontSize: 9, fontWeight: 700,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>{avatar}</div>}
      <div style={{ flex: 1, fontSize: 12, fontWeight: selected ? 600 : 500, color: muted ? 'rgba(0,0,0,0.4)' : '#0c0e14' }}>{label}</div>
      {count && <div style={{ fontSize: 10, color: 'rgba(0,0,0,0.45)', fontVariantNumeric: 'tabular-nums' }}>{count}</div>}
      {pulse && <div style={{ width: 6, height: 6, borderRadius: '50%', background: 'oklch(0.78 0.16 25)', boxShadow: '0 0 6px oklch(0.78 0.16 25)' }} />}
    </div>
  );
}

function ListToolbar() {
  return (
    <div style={{
      height: 52, display: 'flex', alignItems: 'center',
      padding: '0 12px 0 14px', gap: 8,
      borderBottom: '0.5px solid rgba(0,0,0,0.06)',
    }}>
      <div style={{ fontSize: 15, fontWeight: 700, color: '#0c0e14', letterSpacing: '-0.01em' }}>All meetings</div>
      <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.5)' }}>124</div>
      <div style={{ flex: 1 }} />
      <div style={{
        width: 180, height: 28, borderRadius: 7,
        background: 'rgba(255,255,255,0.7)',
        border: '0.5px solid rgba(0,0,0,0.08)',
        display: 'flex', alignItems: 'center', gap: 6, padding: '0 10px',
        boxShadow: 'inset 0 1px 2px rgba(0,0,0,0.03)',
      }}>
        <Icon name="search" size={12} color="rgba(0,0,0,0.45)" />
        <span style={{ fontSize: 12, color: 'rgba(0,0,0,0.4)' }}>Search…</span>
        <div style={{ marginLeft: 'auto', fontSize: 10, color: 'rgba(0,0,0,0.35)', fontFamily: MONO }}>⌘F</div>
      </div>
      <div style={{
        width: 28, height: 28, borderRadius: 7,
        background: 'rgba(255,255,255,0.7)',
        border: '0.5px solid rgba(0,0,0,0.08)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <Icon name="record" size={13} color="oklch(0.55 0.2 25)" />
      </div>
    </div>
  );
}

function ListGroup({ label }) {
  return (
    <div style={{
      padding: '12px 10px 4px',
      fontSize: 10, fontWeight: 700, color: 'rgba(0,0,0,0.4)',
      letterSpacing: '0.1em',
    }}>{label}</div>
  );
}

function MeetingRow({ m }) {
  return (
    <div style={{
      display: 'flex', gap: 10, padding: '10px 10px',
      borderRadius: 9, marginBottom: 2,
      background: m.selected ? 'linear-gradient(180deg, oklch(0.7 0.16 250 / 0.85), oklch(0.6 0.18 252 / 0.85))' : 'transparent',
      boxShadow: m.selected ? '0 4px 12px oklch(0.55 0.18 252 / 0.3)' : 'none',
      color: m.selected ? '#fff' : '#0c0e14',
      cursor: 'pointer',
    }}>
      <div style={{
        width: 38, height: 38, borderRadius: 9, flexShrink: 0,
        background: m.selected ? 'rgba(255,255,255,0.18)' : `linear-gradient(135deg, ${m.color}, ${m.color.replace('250','280').replace('320','340').replace('30','50').replace('145','165').replace('75','95')})`,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: '#fff', fontWeight: 700, fontSize: 11,
        border: m.selected ? '0.5px solid rgba(255,255,255,0.3)' : 'none',
        boxShadow: m.selected ? 'inset 0 1px 0 rgba(255,255,255,0.4)' : 'inset 0 1px 0 rgba(255,255,255,0.4), 0 1px 4px rgba(0,0,0,0.15)',
      }}>{m.title.split(' ').slice(0,2).map(w=>w[0]).join('')}</div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 12.5, fontWeight: 600, marginBottom: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{m.title}</div>
        <div style={{ fontSize: 11, color: m.selected ? 'rgba(255,255,255,0.85)' : 'rgba(0,0,0,0.55)', marginBottom: 4 }}>{m.date}</div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 10.5, color: m.selected ? 'rgba(255,255,255,0.8)' : 'rgba(0,0,0,0.5)' }}>
          <span style={{ display: 'flex', alignItems: 'center', gap: 3 }}>
            <Icon name="clock" size={10} color="currentColor" /> {m.dur}
          </span>
          <span style={{ display: 'flex', alignItems: 'center', gap: 3 }}>
            <Icon name="users" size={10} color="currentColor" /> {m.speakers}
          </span>
          <span style={{
            padding: '1px 6px', borderRadius: 4, fontSize: 9.5, fontWeight: 600,
            background: m.selected ? 'rgba(255,255,255,0.18)' : 'rgba(0,0,0,0.06)',
          }}>{m.tag}</span>
        </div>
      </div>
    </div>
  );
}

function MeetingDetail({ meeting }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      {/* Toolbar */}
      <div style={{
        height: 52, display: 'flex', alignItems: 'center',
        padding: '0 16px', gap: 8,
        borderBottom: '0.5px solid rgba(0,0,0,0.06)',
      }}>
        <div style={{ flex: 1 }} />
        <ToolbarBtn icon="play" label="Play" />
        <ToolbarBtn icon="sparkles" label="Summary" />
        <ToolbarBtn icon="share" label="Share" />
        <ToolbarBtn icon="download" label="Export" />
      </div>

      <div style={{ flex: 1, overflow: 'auto', padding: '20px 24px 24px' }}>
        {/* Hero */}
        <div style={{ marginBottom: 18 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6, fontSize: 11, color: 'rgba(0,0,0,0.55)' }}>
            <span style={{ padding: '2px 7px', borderRadius: 4, fontSize: 10, fontWeight: 600, background: 'oklch(0.7 0.16 250 / 0.15)', color: 'oklch(0.45 0.18 252)' }}>Engineering</span>
            <span>·</span>
            <span>Today, 10:30 AM</span>
            <span>·</span>
            <span>47m</span>
            <span>·</span>
            <span>Recorded from Zoom</span>
          </div>
          <div style={{
            fontFamily: '"Instrument Serif", serif',
            fontSize: 32, lineHeight: 1.05, color: '#0c0e14',
            letterSpacing: '-0.01em', marginBottom: 8,
          }}>Q2 Roadmap Sync</div>
        </div>

        {/* AI summary card */}
        <div style={{
          padding: 16, borderRadius: 14, marginBottom: 18,
          background: 'linear-gradient(135deg, oklch(0.95 0.04 250 / 0.7), oklch(0.93 0.05 280 / 0.6))',
          border: '0.5px solid rgba(255,255,255,0.7)',
          boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.6), 0 4px 12px rgba(0,0,0,0.04)',
        }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 10 }}>
            <Icon name="sparkles" size={13} color="oklch(0.55 0.18 252)" />
            <span style={{ fontSize: 11, fontWeight: 700, color: 'oklch(0.45 0.18 252)', letterSpacing: '0.06em', textTransform: 'uppercase' }}>Summary</span>
          </div>
          <p style={{ margin: 0, fontSize: 13.5, lineHeight: 1.55, color: 'rgba(0,0,0,0.78)' }}>
            Tar walked through the revised Q2 roadmap focusing on three pillars: <b>core reliability</b>, <b>onboarding rework</b>, and <b>the agent SDK launch in June</b>. June flagged staffing risk on the agent track; Pim agreed to redistribute one engineer from the platform pod next sprint.
          </p>
        </div>

        {/* Action items */}
        <div style={{ marginBottom: 18 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 10 }}>
            <Icon name="check" size={13} color="rgba(0,0,0,0.6)" />
            <span style={{ fontSize: 11, fontWeight: 700, color: 'rgba(0,0,0,0.55)', letterSpacing: '0.06em', textTransform: 'uppercase' }}>Action items · 4</span>
          </div>
          {[
            { who: 'Pim', what: 'Move Aof from platform → agent track by Mon', t: '14:22' },
            { who: 'Tar', what: 'Draft June reliability OKR for review Friday', t: '23:08' },
            { who: 'June', what: 'Spec rate-limiting on transcript API', t: '31:45' },
            { who: 'You', what: 'Schedule design sync for onboarding rework', t: '38:12' },
          ].map((a,i)=>(
            <div key={i} style={{
              display: 'flex', alignItems: 'center', gap: 10,
              padding: '8px 10px', borderRadius: 9,
              background: 'rgba(255,255,255,0.5)',
              border: '0.5px solid rgba(255,255,255,0.6)',
              marginBottom: 4,
            }}>
              <div style={{
                width: 14, height: 14, borderRadius: 4,
                border: '1.2px solid rgba(0,0,0,0.3)',
              }} />
              <div style={{
                fontSize: 10, fontWeight: 700, color: 'oklch(0.5 0.18 252)',
                background: 'oklch(0.7 0.16 250 / 0.18)', padding: '1px 6px', borderRadius: 4,
              }}>{a.who}</div>
              <div style={{ flex: 1, fontSize: 12.5, color: '#0c0e14' }}>{a.what}</div>
              <div style={{ fontFamily: MONO, fontSize: 10, color: 'rgba(0,0,0,0.45)' }}>{a.t}</div>
            </div>
          ))}
        </div>

        {/* Speakers */}
        <div>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'rgba(0,0,0,0.55)', letterSpacing: '0.06em', textTransform: 'uppercase', marginBottom: 8 }}>Speakers · 4</div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {[
              { name: 'You', t: '18:42', pct: 40, color: 'oklch(0.7 0.16 250)' },
              { name: 'Tar', t: '14:08', pct: 30, color: 'oklch(0.7 0.16 320)' },
              { name: 'June', t: '8:51', pct: 19, color: 'oklch(0.7 0.16 30)' },
              { name: 'Pim', t: '5:19', pct: 11, color: 'oklch(0.7 0.16 145)' },
            ].map(s => (
              <div key={s.name} style={{
                flex: 1, minWidth: 100,
                padding: 10, borderRadius: 10,
                background: 'rgba(255,255,255,0.5)',
                border: '0.5px solid rgba(255,255,255,0.6)',
              }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 6 }}>
                  <div style={{
                    width: 18, height: 18, borderRadius: '50%',
                    background: `linear-gradient(135deg, ${s.color}, ${s.color.replace('0.7','0.55')})`,
                    color: '#fff', fontSize: 9, fontWeight: 700,
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                  }}>{s.name[0]}</div>
                  <div style={{ fontSize: 11.5, fontWeight: 600 }}>{s.name}</div>
                </div>
                <div style={{ fontFamily: MONO, fontSize: 11, color: '#0c0e14' }}>{s.t}</div>
                <div style={{ height: 3, borderRadius: 2, background: 'rgba(0,0,0,0.06)', marginTop: 6, overflow: 'hidden' }}>
                  <div style={{ width: `${s.pct}%`, height: '100%', background: s.color }} />
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function ToolbarBtn({ icon, label, primary }) {
  return (
    <div style={{
      height: 28, padding: '0 11px', borderRadius: 7,
      display: 'flex', alignItems: 'center', gap: 6,
      background: primary ? 'oklch(0.6 0.18 252)' : 'rgba(255,255,255,0.7)',
      border: '0.5px solid rgba(0,0,0,0.08)',
      color: primary ? '#fff' : '#0c0e14',
      fontSize: 12, fontWeight: 500,
      cursor: 'pointer',
      boxShadow: primary ? '0 2px 6px oklch(0.5 0.18 252 / 0.4)' : 'inset 0 1px 0 rgba(255,255,255,0.6)',
    }}>
      <Icon name={icon} size={12} color={primary ? '#fff' : 'rgba(0,0,0,0.7)'} />
      {label}
    </div>
  );
}

Object.assign(window, { LibraryWindow });
