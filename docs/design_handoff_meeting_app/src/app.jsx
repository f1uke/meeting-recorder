// Canvas — composes all the frames into a tour of the full app.

const { useState, useEffect } = React;

function App() {
  return (
    <div className="stage">
      <div className="crumb fade"><span className="dot" /> Meeting · macOS · Apr 2026</div>
      <h1 className="title fade d1">Capture every word.<br />Find every moment.</h1>
      <p className="lede fade d2">A native macOS menu‑bar app that records the meeting window, the meeting app's audio, and your mic — separately — then transcribes locally and labels every speaker. The Library is the heart of it.</p>

      {/* ─── Section 1: menu bar entry point ─────────────────────────────── */}
      <div style={{ marginTop: 96 }} className="fade d3">
        <div className="section-label">01 — Menu bar</div>
        <div className="row">
          <div className="col-stack">
            <DesktopMenuBar state="idle" />
            <div className="caption"><b>Idle.</b> Click the menu bar icon and a glass popover slides down. Source picker, expected speaker count, recents, and the big record button — everything one tap away.</div>
          </div>
          <div className="col-stack">
            <DesktopMenuBar state="recording" />
            <div className="caption"><b>While recording.</b> The menu bar icon turns into a live timer + pulsing red dot. The popover shows two-channel waveforms (you + meeting), so you can confirm both streams are coming through without opening the main window. ⌘B marks moments inline.</div>
          </div>
          <div className="col-stack">
            <DesktopMenuBar state="transcribing" />
            <div className="caption"><b>After stop.</b> The popover shows local transcription progress — Mic → Output → Diarize → Merge. No data leaves the Mac.</div>
          </div>
        </div>
      </div>

      {/* ─── Section 2: Library ──────────────────────────────────────────── */}
      <div style={{ marginTop: 120 }} className="fade d4">
        <div className="section-label">02 — Library · the heart of the app</div>
        <div style={{ display: 'flex', justifyContent: 'center' }}>
          <LibraryWindow />
        </div>
        <div className="caption" style={{ margin: '20px auto 0', textAlign: 'center', maxWidth: 720 }}>
          Three-pane layout — sidebar groups by tag and speaker, a list grouped by recency, and a detail pane that surfaces the AI summary, action items, and speaker breakdown <i>before</i> the user has to open the full transcript.
        </div>
      </div>

      {/* ─── Section 3: recording window ─────────────────────────────────── */}
      <div style={{ marginTop: 120 }} className="fade d5">
        <div className="section-label">03 — Recording (expanded window)</div>
        <div style={{ display: 'flex', justifyContent: 'center' }}>
          <RecordingWindow />
        </div>
        <div className="caption" style={{ margin: '20px auto 0', textAlign: 'center', maxWidth: 720 }}>
          When the user wants more space, the menu bar popover expands into this dark glass window. Big monospace timer, both channels visualised separately so you can spot a dead mic before it's too late, and a Mark moment button for tagging anything important.
        </div>
      </div>

      {/* ─── Section 4: transcript viewer ────────────────────────────────── */}
      <div style={{ marginTop: 120 }} className="fade d5">
        <div className="section-label">04 — Transcript viewer</div>
        <div style={{ display: 'flex', justifyContent: 'center' }}>
          <TranscriptWindow />
        </div>
        <div className="caption" style={{ margin: '20px auto 0', textAlign: 'center', maxWidth: 720 }}>
          Click any timestamp to scrub the video. Edit speaker names — <span className="mono">speaker_0</span> becomes <i>Pim</i> everywhere. Inline edit transcript text. Search highlights matches with a live count. Action items are auto-extracted and surfaced inline next to where they were said.
        </div>
      </div>

      {/* ─── Section 5: permissions + toast ──────────────────────────────── */}
      <div style={{ marginTop: 120 }} className="fade d5">
        <div className="section-label">05 — Onboarding & ambient</div>
        <div className="row" style={{ alignItems: 'flex-start' }}>
          <div className="col-stack">
            <PermissionsWindow />
            <div className="caption"><b>First run.</b> macOS TCC is the worst part of building this. The view names the three privileges plainly and reassures the user nothing leaves the device. Each row shows live state.</div>
          </div>
          <div className="col-stack" style={{ paddingTop: 36 }}>
            <ToastDone />
            <div style={{ height: 16 }} />
            <ToastDone />
            <div className="caption"><b>Notification.</b> When transcription finishes (it can take a few minutes for an hour-long meeting), a glass toast slides in from the top right. One tap opens the transcript viewer.</div>
          </div>
        </div>
      </div>

      {/* ─── footer note ─────────────────────────────────────────────────── */}
      <div style={{ marginTop: 140, paddingTop: 32, borderTop: '0.5px solid rgba(255,255,255,0.08)' }}>
        <div style={{ display: 'flex', gap: 48, color: '#9aa0ac', fontSize: 12, lineHeight: 1.6 }}>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: '0.12em', color: '#5b6370', marginBottom: 8 }}>VISUAL SYSTEM</div>
            Liquid glass throughout — translucent surfaces with backdrop-blur and inset highlights. Inter for UI, JetBrains Mono for time/numbers, Instrument Serif for hero titles. One cobalt accent (oklch 0.65 0.18 250), one record red.
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: '0.12em', color: '#5b6370', marginBottom: 8 }}>WHAT I SKIPPED</div>
            Settings window, audio device pickers, model download progress UI, share sheet detail. Tell me what to design next.
          </div>
        </div>
      </div>
    </div>
  );
}

// Desktop chrome that hosts the menu bar + popover so the popover reads in context
function DesktopMenuBar({ state }) {
  const isRecording = state === 'recording';
  return (
    <div className="desktop" style={{ width: 540, height: 360 }}>
      {/* menu bar */}
      <div className="menubar">
        <span className="apple"><Icon name="apple" size={13} color="#fff" /></span>
        <span className="app-name">Zoom</span>
        <div className="menus">
          <span>File</span><span>Edit</span><span>View</span><span>Meeting</span>
        </div>
        <div className="right">
          {/* meeting app icon */}
          <span style={{ display:'flex', alignItems:'center', gap: 6, padding: '2px 7px', borderRadius: 5, background: isRecording ? 'rgba(255,93,87,0.22)' : 'transparent' }}>
            {isRecording && <span className="recording-dot" />}
            <Icon name="mic-line" size={13} color="#fff" />
            {isRecording && <span style={{ fontFamily: MONO, fontSize: 11, fontWeight: 600, color: '#ff8a85' }}>00:14:32</span>}
            {state === 'transcribing' && <span style={{ fontSize: 11, fontWeight: 600, color: 'rgba(255,255,255,0.85)' }}>62%</span>}
          </span>
          <span>100%</span>
          <span>Wed 10:42</span>
          <Icon name="search" size={13} color="rgba(255,255,255,0.85)" />
        </div>
      </div>
      {/* desktop body — placeholder app windows */}
      <div style={{ position: 'relative', height: 'calc(100% - 28px)' }}>
        {/* fake app window blurred behind */}
        <div style={{
          position: 'absolute', left: 28, top: 24, right: 28, bottom: 24,
          borderRadius: 10, opacity: 0.45,
          background: 'linear-gradient(160deg, oklch(0.45 0.06 240), oklch(0.3 0.05 280))',
          filter: 'blur(2px)',
        }} />
        {/* popover */}
        <div style={{ position: 'absolute', top: 8, right: 12 }}>
          <MenuBarPopover state={state} />
        </div>
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
