import React, { useState } from 'react';

interface HistoryViewProps {
  transcript: string[];
  onClearHistory: () => void;
}

export default function HistoryView({ transcript, onClearHistory }: HistoryViewProps) {
  const [search, setSearch] = useState('');
  const [copiedIndex, setCopiedIndex] = useState<number | null>(null);

  const filtered = transcript.filter((item) =>
    item.toLowerCase().includes(search.toLowerCase())
  );

  const handleCopy = (text: string, index: number) => {
    navigator.clipboard.writeText(text);
    setCopiedIndex(index);
    setTimeout(() => setCopiedIndex(null), 2000);
  };

  const handleExportMarkdown = () => {
    const content = transcript
      .map((t, idx) => `### Transcript ${idx + 1}\n\n${t}\n`)
      .join('\n---\n\n');
    const blob = new Blob([content], { type: 'text/markdown' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `voiceflow-transcripts-${new Date().toISOString().slice(0, 10)}.md`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="history-view">
      <div className="history-toolbar">
        <input
          type="text"
          className="history-search-input"
          placeholder="Search transcripts..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        <div style={{ display: 'flex', gap: '8px' }}>
          {transcript.length > 0 && (
            <>
              <button
                type="button"
                className="action-btn-sm"
                onClick={handleExportMarkdown}
                title="Export all to Markdown"
              >
                Export .md
              </button>
              <button
                type="button"
                className="action-btn-sm"
                onClick={onClearHistory}
                title="Clear all transcripts"
              >
                Clear
              </button>
            </>
          )}
        </div>
      </div>

      <div className="settings-card">
        {filtered.length === 0 ? (
          <div className="history-empty">
            {transcript.length === 0
              ? 'No dictation history yet. Hold Option+Space, or double-tap Option for hands-free.'
              : 'No transcripts match your search.'}
          </div>
        ) : (
          filtered.map((item, index) => (
            <div key={index} className="history-item">
              <div className="history-item-header">
                <span>Take #{filtered.length - index} • {item.trim().split(/\s+/).length} words</span>
                <button
                  type="button"
                  className="action-btn-sm"
                  onClick={() => handleCopy(item, index)}
                >
                  {copiedIndex === index ? 'Copied!' : 'Copy'}
                </button>
              </div>
              <p className="history-text">{item}</p>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
