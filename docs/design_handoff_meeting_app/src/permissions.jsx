// Permissions + Done states — small frames

function PermissionsWindow() {
  const items = [
    { name: 'Screen Recording', detail: 'Capture the meeting window', granted: true, icon: 'window' },
    { name: 'Microphone', detail: 'Record your voice', granted: true, icon: 'mic' },
    { name: 'Audio Capture', detail: 'Capture the meeting app\'s output, not your full desktop', granted: false, icon: 'sound' },
  ];
  return (
    <div style={{
      width: 480, borderRadius: 16, overflow: 'hidden',
      position: 'relative',
      background: 'rgba(245,247,252,0.6)',
      boxShadow: '0 0 0 0.5px rgba(0,0,0,0.4), 0 24px 64px rgba(0,0,0,0.4)',
    }}>
      <div style={{
        position: 'absolute', inset: 0,
        background: 'rgba(255,255,255,0.55)',
        backdropFilter: 'blur(40px) saturate(180%)',
        WebkitBackdropFilter: 'blur(40px) saturate(180%)',
      }} />
      <div style={{ position: 'relative', zIndex: 1 }}>
        <div style={{ height: 38, display: 'flex', alignItems: 'center', padding: '0 14px' }}>
          <TrafficLights size={12} />
        </div>
        <div style={{ padding: '8px 32px 28px', textAlign: 'center' }}>
          <div style={{
            width: 56, height: 56, borderRadius: 16, margin: '0 auto 16px',
            background: 'linear-gradient(135deg, oklch(0.7 0.16 250), oklch(0.55 0.18 280))',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            boxShadow: '0 8px 22px oklch(0.5 0.18 252 / 0.4), inset 0 1px 0 rgba(255,255,255,0.4)',
          }}>
            <Icon name="lock" size={26} color="#fff" />
          </div>
          <div style={{
            fontFamily: '"Instrument Serif", serif',
            fontSize: 30, lineHeight: 1.1, color: '#0c0e14', marginBottom: 6,
          }}>Permissions</div>
          <div style={{ fontSize: 13, color: 'rgba(0,0,0,0.6)', marginBottom: 20, lineHeight: 1.5 }}>
            Meeting needs three macOS privileges to record cleanly.<br />Everything runs locally.
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, textAlign: 'left' }}>
            {items.map(it=>(
              <div key={it.name} style={{
                display: 'flex', alignItems: 'center', gap: 12, padding: '12px 14px',
                borderRadius: 12,
                background: 'rgba(255,255,255,0.55)',
                border: '0.5px solid rgba(255,255,255,0.7)',
              }}>
                <div style={{
                  width: 32, height: 32, borderRadius: 8,
                  background: it.granted ? 'oklch(0.85 0.15 145 / 0.3)' : 'rgba(0,0,0,0.05)',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                }}>
                  <Icon name={it.icon} size={15} color={it.granted ? 'oklch(0.45 0.18 145)' : 'rgba(0,0,0,0.5)'} />
                </div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 12.5, fontWeight: 600, color: '#0c0e14' }}>{it.name}</div>
                  <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.55)' }}>{it.detail}</div>
                </div>
                {it.granted ? (
                  <div style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 11, fontWeight: 600, color: 'oklch(0.45 0.18 145)' }}>
                    <Icon name="check" size={12} color="oklch(0.5 0.18 145)" /> Granted
                  </div>
                ) : (
                  <GlassPill accent>
                    <div style={{ height: 26, padding: '0 12px', display: 'flex', alignItems: 'center', fontSize: 11, fontWeight: 600 }}>Allow</div>
                  </GlassPill>
                )}
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function ToastDone() {
  return (
    <div style={{ width: 360 }}>
      <Glass radius={14} tint="light" blur={40}>
        <div style={{ padding: 14, display: 'flex', alignItems: 'center', gap: 12 }}>
          <div style={{
            width: 38, height: 38, borderRadius: 10,
            background: 'linear-gradient(135deg, oklch(0.75 0.16 145), oklch(0.6 0.18 165))',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            boxShadow: '0 4px 12px oklch(0.55 0.18 155 / 0.4), inset 0 1px 0 rgba(255,255,255,0.4)',
          }}>
            <Icon name="check" size={18} color="#fff" />
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: '#0c0e14' }}>Transcript ready</div>
            <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.6)' }}>Q2 Roadmap Sync · 47m · 4 speakers</div>
          </div>
          <div style={{
            fontSize: 11, fontWeight: 600, color: '#fff',
            padding: '6px 11px', borderRadius: 7,
            background: 'oklch(0.6 0.18 252)',
            boxShadow: '0 2px 6px oklch(0.5 0.18 252 / 0.4)',
            cursor: 'pointer',
          }}>Open</div>
        </div>
      </Glass>
    </div>
  );
}

Object.assign(window, { PermissionsWindow, ToastDone });
