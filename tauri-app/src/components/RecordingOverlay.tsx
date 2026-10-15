interface RecordingOverlayProps {
  status: string;
}

export default function RecordingOverlay({ status }: RecordingOverlayProps) {
  const isRecording = status === 'recording';

  return (
    <div className={`recording-overlay ${isRecording ? 'visible' : ''}`}>
      <div className="wave-container">
        {[...Array(12)].map((_, i) => (
          <div
            key={i}
            className="wave-bar"
            style={{
              animationDelay: `${i * 0.08}s`,
              height: isRecording ? undefined : '4px',
            }}
          />
        ))}
      </div>
      {isRecording && <span className="recording-label">Recording...</span>}
    </div>
  );
}
