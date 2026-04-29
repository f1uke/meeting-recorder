// Tiny inline SVG icon set — outline, stroke 1.5, designed to sit at 16-20px

function Icon({ name, size = 16, color = 'currentColor', strokeWidth = 1.5, style = {} }) {
  const props = {
    width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
    stroke: color, strokeWidth, strokeLinecap: 'round', strokeLinejoin: 'round',
    style,
  };
  switch (name) {
    case 'mic':
      return (<svg {...props}><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>);
    case 'window':
      return (<svg {...props}><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 8h18"/></svg>);
    case 'record':
      return (<svg {...props}><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4" fill={color}/></svg>);
    case 'stop':
      return (<svg {...props}><rect x="6" y="6" width="12" height="12" rx="1.5" fill={color}/></svg>);
    case 'pause':
      return (<svg {...props}><rect x="7" y="5" width="3.5" height="14" rx="1" fill={color}/><rect x="13.5" y="5" width="3.5" height="14" rx="1" fill={color}/></svg>);
    case 'play':
      return (<svg {...props}><path d="M7 5l12 7-12 7z" fill={color}/></svg>);
    case 'search':
      return (<svg {...props}><circle cx="11" cy="11" r="6"/><path d="M16 16l4 4"/></svg>);
    case 'plus':
      return (<svg {...props}><path d="M12 5v14M5 12h14"/></svg>);
    case 'gear':
      return (<svg {...props}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a7.97 7.97 0 0 0 0-6l2.1-1.6-2-3.4-2.5.9a8 8 0 0 0-5.2-3L11.4 0h-4l-.4 1.9a8 8 0 0 0-5.2 3l-2.5-.9-2 3.4L-.6 9a7.97 7.97 0 0 0 0 6"/></svg>);
    case 'folder':
      return (<svg {...props}><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z"/></svg>);
    case 'user':
      return (<svg {...props}><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg>);
    case 'users':
      return (<svg {...props}><circle cx="9" cy="8" r="3.5"/><path d="M3 20a6 6 0 0 1 12 0"/><circle cx="17" cy="9" r="3"/><path d="M15 20a5 5 0 0 1 7-4.5"/></svg>);
    case 'sparkles':
      return (<svg {...props}><path d="M12 3l1.5 4.5L18 9l-4.5 1.5L12 15l-1.5-4.5L6 9l4.5-1.5z"/><path d="M19 16l.7 2.3L22 19l-2.3.7L19 22l-.7-2.3L16 19l2.3-.7z"/></svg>);
    case 'caret-down':
      return (<svg {...props}><path d="M6 9l6 6 6-6"/></svg>);
    case 'caret-right':
      return (<svg {...props}><path d="M9 6l6 6-6 6"/></svg>);
    case 'check':
      return (<svg {...props}><path d="M5 12l5 5L20 7"/></svg>);
    case 'x':
      return (<svg {...props}><path d="M6 6l12 12M18 6L6 18"/></svg>);
    case 'download':
      return (<svg {...props}><path d="M12 4v12m-5-5l5 5 5-5M5 20h14"/></svg>);
    case 'share':
      return (<svg {...props}><path d="M12 3v13m-4-9l4-4 4 4M5 14v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5"/></svg>);
    case 'pin':
      return (<svg {...props}><path d="M12 2v8l4 4-2 2H10l-2-2 4-4V2z"/><path d="M12 16v6"/></svg>);
    case 'edit':
      return (<svg {...props}><path d="M16 3l5 5-12 12H4v-5z"/></svg>);
    case 'star':
      return (<svg {...props}><path d="M12 3l2.6 6.3L21 10l-5 4.5L17.5 21 12 17.7 6.5 21 8 14.5 3 10l6.4-.7z"/></svg>);
    case 'clock':
      return (<svg {...props}><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>);
    case 'calendar':
      return (<svg {...props}><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/></svg>);
    case 'bookmark':
      return (<svg {...props}><path d="M6 4h12v17l-6-4-6 4z"/></svg>);
    case 'wave':
      return (<svg {...props}><path d="M3 12h2l2-6 3 12 3-9 3 6 2-3h3"/></svg>);
    case 'speaker':
      return (<svg {...props}><path d="M11 5l-5 4H3v6h3l5 4zM16 9a4 4 0 0 1 0 6"/></svg>);
    case 'speaker-x':
      return (<svg {...props}><path d="M11 5l-5 4H3v6h3l5 4zM16 9l5 5M21 9l-5 5"/></svg>);
    case 'eye':
      return (<svg {...props}><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>);
    case 'lock':
      return (<svg {...props}><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>);
    case 'sound':
      return (<svg {...props}><path d="M3 10v4M7 7v10M11 4v16M15 8v8M19 11v2"/></svg>);
    case 'arrow-right':
      return (<svg {...props}><path d="M5 12h14M13 6l6 6-6 6"/></svg>);
    case 'arrow-up-right':
      return (<svg {...props}><path d="M7 17L17 7M9 7h8v8"/></svg>);
    case 'menu':
      return (<svg {...props}><path d="M4 6h16M4 12h16M4 18h16"/></svg>);
    case 'list':
      return (<svg {...props}><path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/></svg>);
    case 'grid':
      return (<svg {...props}><rect x="4" y="4" width="7" height="7" rx="1"/><rect x="13" y="4" width="7" height="7" rx="1"/><rect x="4" y="13" width="7" height="7" rx="1"/><rect x="13" y="13" width="7" height="7" rx="1"/></svg>);
    case 'doc':
      return (<svg {...props}><path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6M8 13h8M8 17h6"/></svg>);
    case 'tag':
      return (<svg {...props}><path d="M20 12l-8 8-9-9V3h8z"/><circle cx="7.5" cy="7.5" r="1"/></svg>);
    case 'flag':
      return (<svg {...props}><path d="M5 21V4h12l-2 4 2 4H5"/></svg>);
    case 'sidebar':
      return (<svg {...props}><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/></svg>);
    case 'expand':
      return (<svg {...props}><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/></svg>);
    case 'mic-line':
      return (<svg {...props}><path d="M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3zM5 12a7 7 0 0 0 14 0M12 19v3"/></svg>);
    case 'apple':
      return (<svg {...props} viewBox="0 0 16 16"><path d="M11.6 8.4c0-1.7 1.4-2.5 1.5-2.6-.8-1.2-2-1.3-2.5-1.4-1-.1-2 .6-2.5.6-.5 0-1.4-.6-2.3-.6-1.2 0-2.3.7-2.9 1.8-1.2 2.1-.3 5.3.9 7 .6.8 1.3 1.8 2.2 1.7.9 0 1.2-.6 2.3-.6 1.1 0 1.4.6 2.3.5.9 0 1.6-.8 2.1-1.7.7-1 .9-2 .9-2-.9-.4-1.6-1.4-1.6-2.7zM10 3.3c.4-.5.8-1.3.7-2-.7 0-1.5.5-2 1-.4.4-.8 1.2-.7 1.9.8.1 1.5-.4 2-.9z" fill={color}/></svg>);
    default:
      return (<svg {...props}><circle cx="12" cy="12" r="9"/></svg>);
  }
}

Object.assign(window, { Icon });
