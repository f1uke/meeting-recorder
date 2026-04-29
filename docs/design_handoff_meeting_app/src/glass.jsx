// Liquid Glass primitives — frosted, layered, with inset highlight
// All translucent surfaces in this design pass through one of these.

const FONT = 'Inter, -apple-system, BlinkMacSystemFont, "SF Pro", sans-serif';
const MONO = '"JetBrains Mono", ui-monospace, "SF Mono", monospace';

// Generic glass panel — layered translucent surface
function Glass({
  children, radius = 16, tint = 'light', blur = 36,
  border = true, shadow = true, inset = true,
  style = {}, className = '', onClick,
}) {
  // tint variants: 'light' (whitened), 'dark' (smoked), 'tinted-blue', 'clear'
  const bg = {
    light: 'rgba(255,255,255,0.62)',
    'light-soft': 'rgba(255,255,255,0.42)',
    dark: 'rgba(20,22,30,0.55)',
    'dark-soft': 'rgba(20,22,30,0.4)',
    'tinted-blue': 'rgba(190,210,240,0.45)',
    clear: 'rgba(255,255,255,0.18)',
  }[tint] || tint;
  const isDark = tint.startsWith('dark') || tint === 'clear';
  const borderColor = isDark
    ? 'rgba(255,255,255,0.14)'
    : 'rgba(255,255,255,0.7)';
  const innerHi = isDark
    ? 'rgba(255,255,255,0.08)'
    : 'rgba(255,255,255,0.55)';
  return (
    <div
      onClick={onClick}
      className={className}
      style={{
        position: 'relative',
        borderRadius: radius,
        ...style,
      }}
    >
      <div style={{
        position: 'absolute', inset: 0, borderRadius: radius,
        background: bg,
        backdropFilter: `blur(${blur}px) saturate(180%)`,
        WebkitBackdropFilter: `blur(${blur}px) saturate(180%)`,
        border: border ? `0.5px solid ${borderColor}` : 'none',
        boxShadow: [
          shadow ? (isDark ? '0 12px 36px rgba(0,0,0,0.35)' : '0 12px 36px rgba(0,0,0,0.18)') : '',
          inset ? `inset 0 1px 0 ${innerHi}` : '',
        ].filter(Boolean).join(', '),
        pointerEvents: 'none',
      }} />
      <div style={{ position: 'relative', zIndex: 1 }}>{children}</div>
    </div>
  );
}

// Glass pill button — small, capsule
function GlassPill({ children, tint = 'light', style = {}, onClick, accent = false, dark = false }) {
  const t = accent ? 'accent' : (dark ? 'dark' : tint);
  const isAccent = t === 'accent';
  const isDark = t === 'dark';
  return (
    <div
      onClick={onClick}
      style={{
        position: 'relative', borderRadius: 999,
        cursor: onClick ? 'pointer' : 'default',
        ...style,
      }}
    >
      <div style={{
        position: 'absolute', inset: 0, borderRadius: 999,
        background: isAccent
          ? 'linear-gradient(180deg, oklch(0.74 0.16 250) 0%, oklch(0.62 0.18 252) 100%)'
          : isDark
            ? 'rgba(255,255,255,0.12)'
            : 'rgba(255,255,255,0.55)',
        backdropFilter: 'blur(24px) saturate(180%)',
        WebkitBackdropFilter: 'blur(24px) saturate(180%)',
        border: isAccent
          ? '0.5px solid oklch(0.82 0.16 250)'
          : isDark
            ? '0.5px solid rgba(255,255,255,0.18)'
            : '0.5px solid rgba(255,255,255,0.7)',
        boxShadow: isAccent
          ? '0 6px 18px oklch(0.55 0.18 252 / 0.45), inset 0 1px 0 rgba(255,255,255,0.35)'
          : 'inset 0 1px 0 rgba(255,255,255,0.5), 0 1px 6px rgba(0,0,0,0.08)',
        pointerEvents: 'none',
      }} />
      <div style={{ position: 'relative', zIndex: 1, color: isAccent || isDark ? '#fff' : '#0c0e14' }}>
        {children}
      </div>
    </div>
  );
}

// Traffic lights — for the in-app expanded windows
function TrafficLights({ size = 12 }) {
  const dot = (bg) => (
    <div style={{
      width: size, height: size, borderRadius: '50%', background: bg,
      border: '0.5px solid rgba(0,0,0,0.12)',
      boxShadow: 'inset 0 0.5px 0 rgba(255,255,255,0.5)',
    }} />
  );
  return (
    <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
      {dot('#ff5f57')}{dot('#febc2e')}{dot('#28c940')}
    </div>
  );
}

Object.assign(window, { Glass, GlassPill, TrafficLights, FONT, MONO });
