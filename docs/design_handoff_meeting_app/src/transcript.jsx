// Transcript Viewer — split: video preview + transcript with speakers, search, edit.

function TranscriptWindow() {
  return (
    <div style={{
      width: 1180, height: 760, borderRadius: 16, overflow: 'hidden',
      display: 'flex',
      boxShadow: '0 0 0 0.5px rgba(0,0,0,0.4), 0 32px 80px rgba(0,0,0,0.4)',
      background: 'rgba(245,247,252,0.4)',
      position: 'relative',
    }}>
      {/* sidebar (collapsed-ish navigation) */}
      <TranscriptNav />

      {/* main area */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', position: 'relative', minWidth: 0 }}>
        {/* glass background */}
        <div style={{
          position: 'absolute', inset: 0,
          background: 'rgba(255,255,255,0.5)',
          backdropFilter: 'blur(40px) saturate(180%)',
          WebkitBackdropFilter: 'blur(40px) saturate(180%)',
        }} />

        {/* toolbar */}
        <div style={{
          position: 'relative', zIndex: 1,
          height: 52, display: 'flex', alignItems: 'center',
          padding: '0 16px', gap: 8,
          borderBottom: '0.5px solid rgba(0,0,0,0.06)',
        }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: 'rgba(0,0,0,0.6)' }}>
            <span style={{ cursor: 'pointer' }}>Library</span>
            <Icon name="caret-right" size={11} color="rgba(0,0,0,0.4)" />
            <span style={{ color: '#0c0e14', fontWeight: 600 }}>Q2 Roadmap Sync</span>
          </div>
          <div style={{ flex: 1 }} />
          <div style={{
            width: 240, height: 28, borderRadius: 7,
            background: 'rgba(255,255,255,0.7)',
            border: '0.5px solid rgba(0,0,0,0.08)',
            display: 'flex', alignItems: 'center', gap: 6, padding: '0 10px',
            boxShadow: 'inset 0 1px 2px rgba(0,0,0,0.03)',
          }}>
            <Icon name="search" size={12} color="rgba(0,0,0,0.45)" />
            <span style={{ fontSize: 12, color: '#0c0e14' }}>onboarding</span>
            <span style={{ marginLeft: 'auto', fontSize: 10.5, color: 'rgba(0,0,0,0.5)', fontFamily: MONO }}>4 hits</span>
          </div>
          <ToolbarBtn icon="sparkles" label="Summary" />
          <ToolbarBtn icon="download" label="Export" />
          <div style={{
            width: 28, height: 28, borderRadius: 7,
            background: 'rgba(255,255,255,0.7)',
            border: '0.5px solid rgba(0,0,0,0.08)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <Icon name="share" size={12} color="rgba(0,0,0,0.7)" />
          </div>
        </div>

        {/* split body */}
        <div style={{ position: 'relative', zIndex: 1, flex: 1, display: 'flex', minHeight: 0 }}>
          {/* video + speakers */}
          <div style={{ width: 380, flexShrink: 0, padding: '16px 12px 16px 16px', display: 'flex', flexDirection: 'column', gap: 12 }}>
            <VideoPreview />
            <SpeakerLegend />
            <MomentsList />
          </div>

          {/* transcript */}
          <div style={{ flex: 1, overflow: 'auto', padding: '12px 24px 32px 12px', minWidth: 0 }}>
            <TranscriptBody />
          </div>
        </div>
      </div>
    </div>
  );
}

function TranscriptNav() {
  return (
    <div style={{ width: 56, position: 'relative', flexShrink: 0 }}>
      <div style={{
        position: 'absolute', inset: 0,
        background: 'rgba(225,232,245,0.55)',
        backdropFilter: 'blur(50px) saturate(180%)',
        WebkitBackdropFilter: 'blur(50px) saturate(180%)',
        borderRight: '0.5px solid rgba(0,0,0,0.06)',
      }} />
      <div style={{ position: 'relative', zIndex: 1, padding: '8px 0', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, height: '100%' }}>
        <div style={{ height: 28, display: 'flex', alignItems: 'center', justifyContent: 'center', width: '100%' }}>
          <TrafficLights size={11} />
        </div>
        <div style={{ height: 8 }} />
        <NavIcon icon="list" />
        <NavIcon icon="search" />
        <NavIcon icon="sparkles" active />
        <NavIcon icon="flag" />
        <NavIcon icon="users" />
        <div style={{ flex: 1 }} />
        <NavIcon icon="record" />
        <NavIcon icon="gear" />
      </div>
    </div>
  );
}

function NavIcon({ icon, active }) {
  return (
    <div style={{
      width: 36, height: 36, borderRadius: 9,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      background: active ? 'rgba(0,0,0,0.08)' : 'transparent',
      cursor: 'pointer',
    }}>
      <Icon name={icon} size={15} color={active ? '#0c0e14' : 'rgba(0,0,0,0.55)'} />
    </div>
  );
}

function VideoPreview() {
  return (
    <div style={{
      borderRadius: 12, overflow: 'hidden',
      aspectRatio: '16 / 10',
      background: 'linear-gradient(160deg, #1d2238 0%, #2b1430 100%)',
      position: 'relative',
      border: '0.5px solid rgba(0,0,0,0.1)',
    }}>
      {/* fake meeting tiles */}
      <div style={{ position: 'absolute', inset: 8, display: 'grid', gridTemplateColumns: '1fr 1fr', gridTemplateRows: '1fr 1fr', gap: 4 }}>
        {['T','J','P','Y'].map((n,i)=>(
          <div key={i} style={{
            borderRadius: 6,
            background: `linear-gradient(135deg, oklch(0.4 0.12 ${250 + i*30}), oklch(0.3 0.1 ${260 + i*30}))`,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            position: 'relative',
          }}>
            <div style={{
              width: 36, height: 36, borderRadius: '50%',
              background: 'rgba(255,255,255,0.12)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              color: '#fff', fontWeight: 700, fontSize: 13,
              border: i === 0 ? '1.5px solid oklch(0.7 0.16 250)' : 'none',
            }}>{n}</div>
            {i===0 && <div style={{ position: 'absolute', bottom: 4, left: 4, fontSize: 9, color: 'rgba(255,255,255,0.7)', fontWeight: 500 }}>Tar</div>}
          </div>
        ))}
      </div>
      {/* scrubber */}
      <div style={{
        position: 'absolute', left: 0, right: 0, bottom: 0,
        padding: '8px 10px',
        background: 'linear-gradient(180deg, transparent, rgba(0,0,0,0.55))',
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
          <Icon name="play" size={12} color="#fff" />
          <div style={{ fontFamily: MONO, fontSize: 10, color: 'rgba(255,255,255,0.85)' }}>14:32 / 47:18</div>
          <div style={{ flex: 1 }} />
          <Icon name="speaker" size={12} color="rgba(255,255,255,0.85)" />
          <Icon name="expand" size={12} color="rgba(255,255,255,0.85)" />
        </div>
        <div style={{ position: 'relative', height: 3, borderRadius: 2, background: 'rgba(255,255,255,0.2)' }}>
          <div style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: '31%', background: '#fff', borderRadius: 2 }} />
          <div style={{ position: 'absolute', left: '31%', top: -2, width: 7, height: 7, borderRadius: '50%', background: '#fff', transform: 'translateX(-50%)' }} />
          {/* moment markers */}
          {[0.18, 0.42, 0.68].map((p,i)=>(
            <div key={i} style={{
              position: 'absolute', left: `${p*100}%`, top: -2, width: 2, height: 7,
              background: 'oklch(0.78 0.16 25)', transform: 'translateX(-50%)',
            }} />
          ))}
        </div>
      </div>
    </div>
  );
}

function SpeakerLegend() {
  const speakers = [
    { name: 'You', t: '18:42', color: 'oklch(0.65 0.16 250)' },
    { name: 'Tar', t: '14:08', color: 'oklch(0.65 0.16 320)' },
    { name: 'June', t: '8:51', color: 'oklch(0.65 0.16 30)' },
    { name: 'Pim', t: '5:19', color: 'oklch(0.65 0.16 145)' },
  ];
  return (
    <div style={{
      padding: 12, borderRadius: 12,
      background: 'rgba(255,255,255,0.55)',
      border: '0.5px solid rgba(255,255,255,0.7)',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
        <div style={{ fontSize: 10.5, fontWeight: 700, color: 'rgba(0,0,0,0.55)', letterSpacing: '0.08em' }}>SPEAKERS · 4</div>
        <div style={{ fontSize: 10, color: 'oklch(0.5 0.18 252)', fontWeight: 600, cursor: 'pointer' }}>Edit</div>
      </div>
      {speakers.map(s => (
        <div key={s.name} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '4px 0' }}>
          <div style={{
            width: 22, height: 22, borderRadius: '50%',
            background: `linear-gradient(135deg, ${s.color}, ${s.color.replace('0.65','0.5')})`,
            color: '#fff', fontSize: 10, fontWeight: 700,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>{s.name[0]}</div>
          <div style={{ flex: 1, fontSize: 12, fontWeight: 500, color: '#0c0e14' }}>{s.name}</div>
          <div style={{ fontFamily: MONO, fontSize: 10.5, color: 'rgba(0,0,0,0.55)' }}>{s.t}</div>
        </div>
      ))}
    </div>
  );
}

function MomentsList() {
  return (
    <div style={{
      padding: 12, borderRadius: 12,
      background: 'rgba(255,255,255,0.55)',
      border: '0.5px solid rgba(255,255,255,0.7)',
      flex: 1, minHeight: 0, overflow: 'hidden',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 10 }}>
        <Icon name="flag" size={11} color="oklch(0.6 0.18 25)" />
        <div style={{ fontSize: 10.5, fontWeight: 700, color: 'rgba(0,0,0,0.55)', letterSpacing: '0.08em' }}>MOMENTS · 3</div>
      </div>
      {[
        { t: '08:26', note: 'Hiring decision' },
        { t: '19:58', note: 'Roadmap pivot — agent SDK' },
        { t: '32:14', note: 'Customer feedback quote' },
      ].map(m=>(
        <div key={m.t} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '4px 0', cursor: 'pointer' }}>
          <div style={{ fontFamily: MONO, fontSize: 11, color: 'oklch(0.5 0.18 252)', fontWeight: 600, width: 38 }}>{m.t}</div>
          <div style={{ fontSize: 11.5, color: '#0c0e14', flex: 1 }}>{m.note}</div>
        </div>
      ))}
    </div>
  );
}

function TranscriptBody() {
  const segs = [
    { speaker: 'Tar', color: 'oklch(0.65 0.16 320)', t: '00:00', text: 'Alright, let\'s kick off. I want to walk through the revised roadmap. Three pillars this quarter: reliability, onboarding rework, and the agent SDK launch in June.' },
    { speaker: 'You', color: 'oklch(0.65 0.16 250)', t: '00:42', text: 'Quick question before we dive in — is the June date hard or soft? Marketing\'s been planning a launch event around it.', isMe: true },
    { speaker: 'Tar', color: 'oklch(0.65 0.16 320)', t: '01:08', text: 'Hard for the agent SDK. Soft for the rest. We need that launch to land in Q2 because of the keynote.' },
    { speaker: 'June', color: 'oklch(0.65 0.16 30)', t: '01:34', highlight: true, text: 'I\'m worried about staffing on the agent track. Right now it\'s just me and Aof, and Aof is split with platform. The onboarding rework is going to need full attention from at least one senior engineer or it\'ll slip.' },
    { speaker: 'Pim', color: 'oklch(0.65 0.16 145)', t: '02:18', editing: true, text: 'Fair point. I can move Aof full-time to agent next sprint. Platform can absorb that — they\'re wrapping up the migration this week.' },
    { speaker: 'June', color: 'oklch(0.65 0.16 30)', t: '02:45', text: 'That works. As long as it\'s decided by Monday so I can scope realistic.' },
    { speaker: 'Tar', color: 'oklch(0.65 0.16 320)', t: '02:58', search: true, text: 'Good. Let me also flag that the onboarding rework needs a design partner. I think we\'re going to need a dedicated designer for at least four weeks.' },
    { speaker: 'You', color: 'oklch(0.65 0.16 250)', t: '03:22', text: 'I\'ll set up a design sync this week to scope it. Probably needs Mai or Boy — both are coming off the dashboard project.', isMe: true },
  ];
  return (
    <div style={{ paddingTop: 8 }}>
      <div style={{ marginBottom: 18, paddingBottom: 14, borderBottom: '0.5px solid rgba(0,0,0,0.06)' }}>
        <div style={{
          fontFamily: '"Instrument Serif", serif',
          fontSize: 36, lineHeight: 1.05, color: '#0c0e14',
          letterSpacing: '-0.01em', marginBottom: 6,
        }}>Q2 Roadmap Sync</div>
        <div style={{ fontSize: 12, color: 'rgba(0,0,0,0.55)' }}>Today, 10:30 AM · 47 min · 4 speakers · Recorded from Zoom</div>
      </div>

      {segs.map((s,i)=>(
        <TranscriptSegment key={i} {...s} />
      ))}
    </div>
  );
}

function TranscriptSegment({ speaker, color, t, text, isMe, highlight, editing, search }) {
  // wrap "onboarding" with highlight if search
  const renderText = () => {
    if (search) {
      const parts = text.split(/(onboarding)/i);
      return parts.map((p, i) => p.toLowerCase() === 'onboarding'
        ? <mark key={i} style={{ background: 'oklch(0.9 0.15 90 / 0.6)', color: '#5a3500', padding: '0 2px', borderRadius: 2 }}>{p}</mark>
        : <span key={i}>{p}</span>);
    }
    return text;
  };

  return (
    <div style={{
      display: 'flex', gap: 14, padding: '10px 0',
      position: 'relative',
      ...(highlight && {
        background: 'linear-gradient(90deg, oklch(0.95 0.05 30 / 0.45), transparent 80%)',
        margin: '0 -16px', padding: '12px 16px',
        borderRadius: 10,
        borderLeft: '2px solid oklch(0.7 0.16 30)',
      }),
    }}>
      {/* speaker col */}
      <div style={{ width: 96, flexShrink: 0, paddingTop: 2 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 2 }}>
          <div style={{
            width: 20, height: 20, borderRadius: '50%',
            background: `linear-gradient(135deg, ${color}, ${color.replace('0.65','0.5')})`,
            color: '#fff', fontSize: 10, fontWeight: 700,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            flexShrink: 0,
          }}>{speaker[0]}</div>
          <div style={{ fontSize: 12, fontWeight: 600, color: '#0c0e14' }}>{speaker}</div>
        </div>
        <div style={{
          fontFamily: MONO, fontSize: 11, color: 'rgba(0,0,0,0.5)',
          paddingLeft: 26, cursor: 'pointer',
        }}>{t}</div>
      </div>

      {/* text */}
      <div style={{ flex: 1, minWidth: 0 }}>
        {editing ? (
          <div style={{
            padding: '6px 10px', borderRadius: 8,
            background: 'rgba(255,255,255,0.85)',
            border: '1px solid oklch(0.65 0.16 250)',
            fontSize: 14, lineHeight: 1.55, color: '#0c0e14',
            boxShadow: '0 0 0 3px oklch(0.65 0.16 250 / 0.15)',
          }}>
            {text}<span style={{ display: 'inline-block', width: 1.5, height: 16, background: 'oklch(0.55 0.18 252)', verticalAlign: 'middle', marginLeft: 1, animation: 'blink 1s steps(1) infinite' }} />
          </div>
        ) : (
          <div style={{
            fontSize: 14, lineHeight: 1.6, color: '#0c0e14',
          }}>{renderText()}</div>
        )}
        {highlight && (
          <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 6 }}>
            <div style={{
              fontSize: 10, fontWeight: 700, color: 'oklch(0.5 0.18 30)',
              padding: '2px 8px', borderRadius: 4,
              background: 'oklch(0.85 0.1 30 / 0.5)',
            }}>ACTION ITEM</div>
            <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.6)' }}>Auto-detected by Claude</div>
          </div>
        )}
      </div>
    </div>
  );
}

Object.assign(window, { TranscriptWindow });
