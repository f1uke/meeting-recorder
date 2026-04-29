// Menu bar popover — the home base of the app.
// 360px wide, attached under a menu bar icon.
// Three states surfaced in design: idle, recording, transcribing-mini.

function MenuBarPopover({ state = 'idle' }) {
  return (
    <div style={{ position: 'relative', width: 360 }}>
      {/* arrow tail */}
      <div style={{
        position: 'absolute', top: -7, left: 24,
        width: 14, height: 14,
        background: 'rgba(255,255,255,0.62)',
        backdropFilter: 'blur(36px) saturate(180%)',
        WebkitBackdropFilter: 'blur(36px) saturate(180%)',
        borderTop: '0.5px solid rgba(255,255,255,0.7)',
        borderLeft: '0.5px solid rgba(255,255,255,0.7)',
        transform: 'rotate(45deg)',
        zIndex: 0,
      }} />
      <Glass radius={18} tint="light" blur={40} style={{ overflow: 'hidden' }}>
        <div style={{ padding: 14 }}>
          {state === 'idle' && <PopoverIdle />}
          {state === 'recording' && <PopoverRecording />}
          {state === 'transcribing' && <PopoverTranscribing />}
        </div>
      </Glass>
    </div>
  );
}

function PopHeader({ title, sub }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
      <div>
        <div style={{ fontSize: 15, fontWeight: 700, color: '#0c0e14', letterSpacing: '-0.01em' }}>{title}</div>
        {sub && <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.55)', marginTop: 2 }}>{sub}</div>}
      </div>
      <div style={{ display: 'flex', gap: 6 }}>
        <SmallGlassIcon name="search" />
        <SmallGlassIcon name="gear" />
      </div>
    </div>
  );
}

function SmallGlassIcon({ name, onClick, active }) {
  return (
    <div onClick={onClick} style={{
      width: 26, height: 26, borderRadius: 8,
      background: active ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.5)',
      border: '0.5px solid rgba(255,255,255,0.6)',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      cursor: 'pointer',
      boxShadow: 'inset 0 0.5px 0 rgba(255,255,255,0.6)',
    }}>
      <Icon name={name} size={13} color="rgba(0,0,0,0.7)" />
    </div>
  );
}

// Card representing the chosen window
function WindowChip({ app, title, icon, onChange }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 10,
      padding: 10, borderRadius: 12,
      background: 'rgba(255,255,255,0.55)',
      border: '0.5px solid rgba(255,255,255,0.7)',
      boxShadow: 'inset 0 0.5px 0 rgba(255,255,255,0.6), 0 1px 4px rgba(0,0,0,0.04)',
    }}>
      {/* App icon placeholder */}
      <div style={{
        width: 32, height: 32, borderRadius: 8,
        background: 'linear-gradient(135deg, oklch(0.7 0.16 250), oklch(0.55 0.18 280))',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: '#fff', fontWeight: 700, fontSize: 13, letterSpacing: '-.02em',
        boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.4), 0 1px 4px rgba(0,0,0,0.15)',
      }}>{icon}</div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 12, fontWeight: 600, color: '#0c0e14', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{title}</div>
        <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.55)' }}>{app}</div>
      </div>
      <div onClick={onChange} style={{
        fontSize: 11, fontWeight: 600, color: 'oklch(0.55 0.18 252)',
        padding: '4px 8px', borderRadius: 6, cursor: 'pointer',
      }}>Change</div>
    </div>
  );
}

function PopoverIdle() {
  return (
    <div>
      <PopHeader title="Meeting" sub="Ready to record" />

      <div style={{ fontSize: 10, fontWeight: 700, color: 'rgba(0,0,0,0.45)', letterSpacing: '0.08em', textTransform: 'uppercase', marginBottom: 8 }}>SOURCE</div>
      <WindowChip app="Zoom" title="Q2 Roadmap Sync — 8 participants" icon="Z" />

      <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
        <PopRow icon="users" label="Expected speakers" value="4" />
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 14 }}>
        <GlassPill accent style={{ flex: 1 }}>
          <div style={{ height: 38, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, fontWeight: 600, fontSize: 13 }}>
            <Icon name="record" size={14} color="#fff" />
            <span>Start Recording</span>
          </div>
        </GlassPill>
        <div style={{
          width: 38, height: 38, borderRadius: 999,
          background: 'rgba(255,255,255,0.55)',
          border: '0.5px solid rgba(255,255,255,0.7)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          boxShadow: 'inset 0 0.5px 0 rgba(255,255,255,0.6)',
        }}>
          <Icon name="expand" size={14} color="#0c0e14" />
        </div>
      </div>

      {/* Recent */}
      <div style={{ marginTop: 16, paddingTop: 12, borderTop: '0.5px solid rgba(0,0,0,0.08)' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: 'rgba(0,0,0,0.45)', letterSpacing: '0.08em', textTransform: 'uppercase' }}>RECENT</div>
          <div style={{ fontSize: 11, fontWeight: 600, color: 'oklch(0.55 0.18 252)', cursor: 'pointer' }}>Open Library →</div>
        </div>
        {[
          { title: 'Q2 Roadmap Sync', when: '2h ago', dur: '47m' },
          { title: 'Design crit — onboarding', when: 'Yesterday', dur: '32m' },
          { title: 'Hiring panel: Pim', when: 'Apr 26', dur: '58m' },
        ].map((r,i)=>(
          <div key={i} style={{
            display: 'flex', alignItems: 'center', gap: 10,
            padding: '7px 8px', borderRadius: 8, cursor: 'pointer',
          }}
          onMouseEnter={e=>e.currentTarget.style.background='rgba(0,0,0,0.04)'}
          onMouseLeave={e=>e.currentTarget.style.background='transparent'}
          >
            <div style={{ width: 6, height: 6, borderRadius: '50%', background: 'oklch(0.7 0.14 250)' }} />
            <div style={{ flex: 1, fontSize: 12, color: '#0c0e14', fontWeight: 500 }}>{r.title}</div>
            <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.5)' }}>{r.dur}</div>
            <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.4)', width: 64, textAlign: 'right' }}>{r.when}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

function PopRow({ icon, label, value }) {
  return (
    <div style={{
      flex: 1, display: 'flex', alignItems: 'center', gap: 8,
      padding: '8px 10px', borderRadius: 10,
      background: 'rgba(255,255,255,0.4)',
      border: '0.5px solid rgba(255,255,255,0.6)',
    }}>
      <Icon name={icon} size={13} color="rgba(0,0,0,0.55)" />
      <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.6)', flex: 1 }}>{label}</div>
      <div style={{ fontSize: 11, color: '#0c0e14', fontWeight: 600 }}>{value}</div>
      <Icon name="caret-down" size={12} color="rgba(0,0,0,0.4)" />
    </div>
  );
}

function PopoverRecording() {
  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <div style={{
            width: 8, height: 8, borderRadius: '50%', background: '#ff5d57',
            boxShadow: '0 0 10px #ff5d57', animation: 'pulse 1.6s ease-in-out infinite',
          }} />
          <div style={{ fontSize: 12, fontWeight: 700, color: '#0c0e14', letterSpacing: '0.04em', textTransform: 'uppercase' }}>Recording</div>
        </div>
        <div style={{ fontFamily: MONO, fontSize: 13, fontWeight: 600, color: '#0c0e14' }}>00:14:32</div>
      </div>

      <div style={{ fontSize: 12, color: 'rgba(0,0,0,0.7)', marginBottom: 10 }}>Q2 Roadmap Sync — Zoom</div>

      {/* Live waveforms — two channels */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginBottom: 12 }}>
        <ChannelMeter label="You (mic)" color="oklch(0.7 0.15 250)" peak={0.55} pattern={[0.3,0.5,0.4,0.7,0.55,0.8,0.6,0.45,0.7,0.5,0.65,0.55,0.4,0.5,0.6,0.7,0.5,0.4,0.6,0.55,0.45,0.5,0.65,0.55]} />
        <ChannelMeter label="Meeting" color="oklch(0.78 0.16 25)" peak={0.7} pattern={[0.5,0.6,0.7,0.55,0.4,0.5,0.65,0.7,0.55,0.4,0.45,0.6,0.75,0.65,0.5,0.45,0.55,0.7,0.6,0.5,0.45,0.55,0.65,0.5]} />
      </div>

      {/* Bookmarks added during meeting */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 8,
        padding: '8px 10px', borderRadius: 10, marginBottom: 12,
        background: 'rgba(255,255,255,0.4)',
        border: '0.5px solid rgba(255,255,255,0.6)',
      }}>
        <Icon name="flag" size={13} color="oklch(0.6 0.18 25)" />
        <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.7)', flex: 1 }}>3 moments marked</div>
        <div style={{ fontSize: 11, fontWeight: 600, color: 'oklch(0.55 0.18 252)', cursor: 'pointer' }}>+ Mark</div>
      </div>

      {/* Controls */}
      <div style={{ display: 'flex', gap: 8 }}>
        <div style={{
          flex: 1, height: 38, borderRadius: 999,
          background: 'rgba(255,255,255,0.55)',
          border: '0.5px solid rgba(255,255,255,0.7)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
          fontSize: 12, fontWeight: 600, color: '#0c0e14',
          boxShadow: 'inset 0 0.5px 0 rgba(255,255,255,0.6)',
          cursor: 'pointer',
        }}>
          <Icon name="pause" size={12} color="#0c0e14" />
          Pause
        </div>
        <div style={{
          flex: 1, height: 38, borderRadius: 999,
          background: 'linear-gradient(180deg, #ff7a73, #e94942)',
          border: '0.5px solid #ff8a83',
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
          fontSize: 12, fontWeight: 600, color: '#fff',
          boxShadow: '0 6px 16px rgba(233,73,66,0.4), inset 0 1px 0 rgba(255,255,255,0.3)',
          cursor: 'pointer',
        }}>
          <Icon name="stop" size={12} color="#fff" />
          Stop & Transcribe
        </div>
      </div>
    </div>
  );
}

function ChannelMeter({ label, color, peak, pattern }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <div style={{ width: 56, fontSize: 10, fontWeight: 600, color: 'rgba(0,0,0,0.6)' }}>{label}</div>
      <div style={{
        flex: 1, height: 28, display: 'flex', alignItems: 'center', gap: 2,
        padding: '0 6px', borderRadius: 8,
        background: 'rgba(0,0,0,0.04)',
      }}>
        {pattern.map((h, i) => (
          <div key={i} style={{
            flex: 1, height: `${Math.max(2, h * 24)}px`,
            background: color, borderRadius: 1, opacity: 0.85,
          }} />
        ))}
      </div>
      <div style={{ fontFamily: MONO, fontSize: 9, color: 'rgba(0,0,0,0.5)', width: 28, textAlign: 'right' }}>
        −{Math.round((1-peak)*30)}dB
      </div>
    </div>
  );
}

function PopoverTranscribing() {
  return (
    <div>
      <PopHeader title="Transcribing" sub="Q2 Roadmap Sync — 47m" />
      <div style={{
        padding: 14, borderRadius: 12,
        background: 'rgba(255,255,255,0.4)',
        border: '0.5px solid rgba(255,255,255,0.6)',
      }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 8 }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: '#0c0e14' }}>Diarization</div>
          <div style={{ fontFamily: MONO, fontSize: 12, color: 'rgba(0,0,0,0.6)' }}>62%</div>
        </div>
        <div style={{ height: 6, borderRadius: 3, background: 'rgba(0,0,0,0.06)', overflow: 'hidden' }}>
          <div style={{ width: '62%', height: '100%', background: 'linear-gradient(90deg, oklch(0.65 0.18 250), oklch(0.75 0.16 200))', borderRadius: 3 }} />
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
          {['Mic', 'Output', 'Diarize', 'Merge'].map((s, i) => (
            <div key={s} style={{
              flex: 1, height: 4, borderRadius: 2,
              background: i < 2 ? 'oklch(0.7 0.14 250)' : i === 2 ? 'oklch(0.7 0.14 250 / 0.5)' : 'rgba(0,0,0,0.08)',
            }} />
          ))}
        </div>
        <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.55)', marginTop: 10 }}>
          Running locally on your Mac. No data leaves the device.
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { MenuBarPopover, PopoverIdle, PopoverRecording, PopoverTranscribing });
