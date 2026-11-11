import React, { ReactNode } from 'react';

interface SettingRowProps {
  label: string;
  tooltip?: string;
  children: ReactNode;
  onReset?: () => void;
  showReset?: boolean;
}

export default function SettingRow({
  label,
  tooltip,
  children,
  onReset,
  showReset = true,
}: SettingRowProps) {
  return (
    <div className="setting-row">
      <div className="setting-label-col">
        <span className="setting-title">{label}</span>
        {tooltip && (
          <div className="tooltip-trigger" tabIndex={0} aria-label={tooltip}>
            <svg
              viewBox="0 0 16 16"
              width="14"
              height="14"
              fill="currentColor"
              aria-hidden="true"
            >
              <path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14zm0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16z" />
              <path d="m8.93 6.588-2.29.287-.082.38.45.083c.294.07.352.176.288.469l-.738 3.468c-.194.897.105 1.319.808 1.319.545 0 1.178-.252 1.465-.598l.088-.416c-.2.176-.492.246-.686.246-.275 0-.375-.193-.304-.533L8.93 6.588zM9 4.5a1 1 0 1 1-2 0 1 1 0 0 1 2 0z" />
            </svg>
            <div className="tooltip-popover">{tooltip}</div>
          </div>
        )}
      </div>

      <div className="setting-control-col">
        {children}
        {onReset && showReset && (
          <button
            type="button"
            className="reset-btn"
            onClick={onReset}
            title="Reset to default"
            aria-label={`Reset ${label} to default`}
          >
            <svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor">
              <path
                fillRule="evenodd"
                d="M8 3a5 5 0 1 0 4.546 2.914.5.5 0 0 1 .908-.417A6 6 0 1 1 8 2v1z"
              />
              <path d="M8 4.466V.534a.25.25 0 0 1 .41-.192l2.36 1.966c.12.1.12.284 0 .384L8.41 4.658A.25.25 0 0 1 8 4.466z" />
            </svg>
          </button>
        )}
      </div>
    </div>
  );
}
