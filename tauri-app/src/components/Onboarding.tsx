interface OnboardingProps {
  models: Array<{ name: string; filename: string; downloaded: boolean; sizeMb: number; url: string }>;
  onDownload: (url: string, filename: string, sizeMb: number) => void;
  onComplete: () => void;
}

export default function Onboarding({ models, onDownload, onComplete }: OnboardingProps) {
  const missingModels = models.filter(m => m.url && !m.downloaded);
  const allDownloaded = missingModels.length === 0;

  const handleDownloadAll = async () => {
    for (const model of missingModels) {
      await onDownload(model.url, model.filename, model.sizeMb);
    }
  };

  return (
    <div className="onboarding">
      <div className="onboarding-content">
        <div className="logo-large">V</div>
        <h1>Welcome to VoiceFlow</h1>
        <p>Setup complete! Ready to dictate.</p>

        {!allDownloaded && (
          <div className="model-setup">
            <h3>Download Models</h3>
            <p>Download speech recognition models for offline use:</p>
            <ul>
              {missingModels.map(m => (
                <li key={m.filename}>
                  <span>{m.name}</span>
                  <span>{m.sizeMb} MB</span>
                </li>
              ))}
            </ul>
            <button
              className="btn-primary"
              onClick={handleDownloadAll}
            >
              Download All
            </button>
          </div>
        )}

        <button className="btn-primary btn-start" onClick={onComplete}>
          Start Dictating
        </button>

        <p className="note">
          VoiceFlow runs 100% locally — no internet required after setup.
        </p>
      </div>
    </div>
  );
}
