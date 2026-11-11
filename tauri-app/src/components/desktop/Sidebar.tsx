import React from 'react';

export type DesktopTab = 'general' | 'models' | 'advanced' | 'history' | 'about';

interface SidebarProps {
  activeTab: DesktopTab;
  onSelectTab: (tab: DesktopTab) => void;
}

export default function Sidebar({ activeTab, onSelectTab }: SidebarProps) {
  return (
    <aside className="desktop-sidebar">
      <div className="sidebar-brand">
        <span className="bubble-logo" onClick={() => onSelectTab('general')}>
          voiceflow
        </span>
      </div>

      <nav className="sidebar-nav" aria-label="Sidebar Navigation">
        <button
          type="button"
          className={`nav-item ${activeTab === 'general' ? 'active' : ''}`}
          onClick={() => onSelectTab('general')}
        >
          {/* Hand / Palm icon matching Handy */}
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M18 11V6a2 2 0 0 0-2-2v0a2 2 0 0 0-2 2v0"/>
            <path d="M14 10V4a2 2 0 0 0-2-2v0a2 2 0 0 0-2 2v2"/>
            <path d="M10 10.5V6a2 2 0 0 0-2-2v0a2 2 0 0 0-2 2v8"/>
            <path d="M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15"/>
          </svg>
          <span>General</span>
        </button>

        <button
          type="button"
          className={`nav-item ${activeTab === 'models' ? 'active' : ''}`}
          onClick={() => onSelectTab('models')}
        >
          {/* CPU / Chip icon */}
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <rect x="4" y="4" width="16" height="16" rx="2"/>
            <rect x="9" y="9" width="6" height="6"/>
            <path d="M15 2v2"/>
            <path d="M15 20v2"/>
            <path d="M2 15h2"/>
            <path d="M2 9h2"/>
            <path d="M20 15h2"/>
            <path d="M20 9h2"/>
            <path d="M9 2v2"/>
            <path d="M9 20v2"/>
          </svg>
          <span>Models</span>
        </button>

        <button
          type="button"
          className={`nav-item ${activeTab === 'advanced' ? 'active' : ''}`}
          onClick={() => onSelectTab('advanced')}
        >
          {/* Gear / Cog icon */}
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/>
            <circle cx="12" cy="12" r="3"/>
          </svg>
          <span>Advanced</span>
        </button>

        <button
          type="button"
          className={`nav-item ${activeTab === 'history' ? 'active' : ''}`}
          onClick={() => onSelectTab('history')}
        >
          {/* Clock / History icon */}
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/>
            <path d="M3 3v5h5"/>
            <path d="M12 7v5l4 2"/>
          </svg>
          <span>History</span>
        </button>

        <button
          type="button"
          className={`nav-item ${activeTab === 'about' ? 'active' : ''}`}
          onClick={() => onSelectTab('about')}
        >
          {/* Info Circle icon */}
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="12" cy="12" r="10"/>
            <line x1="12" y1="16" x2="12" y2="12"/>
            <line x1="12" y1="8" x2="12.01" y2="8"/>
          </svg>
          <span>About</span>
        </button>
      </nav>
    </aside>
  );
}
