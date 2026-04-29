// Recording — full window state. Live waveforms, timer, source preview, mark moments.

function RecordingWindow() {
  return (
    <div style={{
      width: 720, height: 480, borderRadius: 16, overflow: 'hidden',
      position: 'relative',
      boxShadow: '0 0 0 0.5px rgba(0,0,0,0.4), 0 32px 80px rgba(0,0,0,0.45)',
      background: 'linear-gradient(160deg, #1a1d2a 0%, #2a1830 50%, #1d2240 100%)',
    }}>
      {/* glass overlay */}
      <div style={{
        position: 'absolute', inset: 0,
        background: 'rgba(20,22,30,0.4)',
        backdropFilter: 'blur(40px) saturate(180%)',
        WebkitBackdropFilter: 'blur(40px) saturate(180%)',
      }} />

      {/* Titlebar */}
      <div style={{
        position: 'relative', zIndex: 2,
        height: 38, display: 'flex', alignItems: 'center', padding: '0 14px',
      }}>
        <TrafficLights size={12} />
        <div style={{ flex: 1, textAlign: 'center', fontSize: 12, fontWeight: 600, color: 'rgba(255,255,255,0.85)', letterSpacing: '-0.01em' }}>
          Meeting · Recording
        </div>
        <div style={{ width: 60 }} />
      </div>

      {/* Content */}
      <div style={{ position: 'relative', zIndex: 2, padding: '20px 28px 24px', height: 'calc(100% - 38px)', display: 'flex', flexDirection: 'column' }}>
        {/* Top: status pill + source */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 16 }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8,
            padding: '6px 12px', borderRadius: 999,
            background: 'rgba(255,93,87,0.18)',
            border: '0.5px solid rgba(255,93,87,0.4)',
          }}>
            <div style={{ width: 8, height: 8, borderRadius: '50%', background: '#ff5d57', boxShadow: '0 0 10px #ff5d57', animation: 'pulse 1.6s ease-in-out infinite' }} />
            <div style={{ fontSize: 11, fontWeight: 700, color: '#ff8a85', letterSpacing: '0.06em', textTransform: 'uppercase' }}>Recording</div>
          </div>
          <div style={{ fontSize: 12, color: 'rgba(255,255,255,0.6)' }}>
            from <b style={{ color: 'rgba(255,255,255,0.9)', fontWeight: 600 }}>Zoom</b> — Q2 Roadmap Sync
          </div>
        </div>

        {/* Timer */}
        <div style={{ display: 'flex', alignItems: 'flex-end', gap: 14, marginBottom: 22 }}>
          <div style={{
            fontFamily: MONO,
            fontSize: 72, fontWeight: 300, color: '#fff',
            letterSpacing: '-0.04em', lineHeight: 1,
            fontVariantNumeric: 'tabular-nums',
          }}>00:14:32</div>
          <div style={{ paddingBottom: 8 }}>
            <div style={{ fontSize: 11, color: 'rgba(255,255,255,0.5)', textTransform: 'uppercase', letterSpacing: '0.08em', fontWeight: 600 }}>Saving to</div>
            <div style={{ fontFamily: MONO, fontSize: 11, color: 'rgba(255,255,255,0.7)' }}>~/Documents/Meetings/2026-04-29_10-30-12</div>
          </div>
        </div>

        {/* Two-channel waveform */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10, marginBottom: 22 }}>
          <BigWaveform label="You · mic" sub="Built-in Microphone" color="oklch(0.78 0.16 250)" peak={-12} />
          <BigWaveform label="Meeting · output" sub="Zoom (4 audio processes)" color="oklch(0.78 0.16 25)" peak={-8} />
        </div>

        {/* Bottom: bookmarks + controls */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 'auto' }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8,
            padding: '8px 12px', borderRadius: 10,
            background: 'rgba(255,255,255,0.08)',
            border: '0.5px solid rgba(255,255,255,0.14)',
            flex: 1,
          }}>
            <Icon name="flag" size={13} color="oklch(0.78 0.16 25)" />
            <div style={{ fontSize: 12, color: 'rgba(255,255,255,0.85)', flex: 1 }}>
              <b style={{ fontWeight: 600 }}>3 moments</b> marked · last at <span style={{ fontFamily: MONO }}>12:08</span>
            </div>
            <div style={{
              fontSize: 11, fontWeight: 600,
              padding: '4px 10px', borderRadius: 6,
              background: 'rgba(255,255,255,0.12)',
              color: '#fff',
            }}>+ Mark moment <span style={{ fontFamily: MONO, opacity: 0.6, marginLeft: 4 }}>⌘B</span></div>
          </div>

          <div style={{
            width: 44, height: 44, borderRadius: 999,
            background: 'rgba(255,255,255,0.12)',
            border: '0.5px solid rgba(255,255,255,0.18)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            cursor: 'pointer',
          }}>
            <Icon name="pause" size={16} color="#fff" />
          </div>

          <div style={{
            height: 44, padding: '0 18px', borderRadius: 999,
            background: 'linear-gradient(180deg, #ff7a73, #e94942)',
            border: '0.5px solid #ff8a83',
            display: 'flex', alignItems: 'center', gap: 8,
            color: '#fff', fontSize: 13, fontWeight: 600,
            boxShadow: '0 8px 22px rgba(233,73,66,0.45), inset 0 1px 0 rgba(255,255,255,0.3)',
            cursor: 'pointer',
          }}>
            <Icon name="stop" size={13} color="#fff" />
            Stop & Transcribe
            <span style={{ fontFamily: MONO, fontSize: 10, opacity: 0.7, marginLeft: 4 }}>⌘.</span>
          </div>
        </div>
      </div>
    </div>
  );
}

function BigWaveform({ label, sub, color, peak }) {
  // generate a more detailed waveform — 96 bars
  const bars = Array.from({ length: 96 }, (_, i) => {
    const x = i / 95;
    const env = Math.sin(x * Math.PI * 3 + 1) * 0.5 + 0.5;
    const noise = Math.sin(i * 1.7) * 0.3 + Math.sin(i * 0.3) * 0.5;
    return Math.max(0.08, Math.min(1, env * 0.7 + noise * 0.4));
  });

  return (
    <div style={{
      padding: '10px 14px', borderRadius: 12,
      background: 'rgba(255,255,255,0.06)',
      border: '0.5px solid rgba(255,255,255,0.1)',
      display: 'flex', alignItems: 'center', gap: 14,
    }}>
      <div style={{ width: 130, flexShrink: 0 }}>
        <div style={{ fontSize: 12, fontWeight: 600, color: '#fff' }}>{label}</div>
        <div style={{ fontSize: 10.5, color: 'rgba(255,255,255,0.5)' }}>{sub}</div>
      </div>
      <div style={{ flex: 1, height: 36, display: 'flex', alignItems: 'center', gap: 1.5 }}>
        {bars.map((h, i) => (
          <div key={i} style={{
            flex: 1, height: `${Math.max(2, h * 32)}px`,
            background: `linear-gradient(180deg, ${color}, ${color.replace('0.78', '0.55')})`,
            borderRadius: 1,
            opacity: 0.4 + h * 0.6,
          }} />
        ))}
      </div>
      <div style={{ fontFamily: MONO, fontSize: 11, color: 'rgba(255,255,255,0.7)', width: 44, textAlign: 'right' }}>{peak}dB</div>
    </div>
  );
}

Object.assign(window, { RecordingWindow });
