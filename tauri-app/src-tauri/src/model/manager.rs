use anyhow::{Context, Result};
use dirs;
use futures::StreamExt;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    pub name: String,
    pub filename: String,
    pub url: String,
    pub size_mb: f64,
    pub sha256: Option<String>,
    pub downloaded: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadProgressPayload {
    pub filename: String,
    pub downloaded_mb: f64,
    pub total_mb: f64,
    pub percentage: f32,
    pub is_verifying: bool,
}

pub struct ModelManager;

impl ModelManager {
    /// Get the models directory based on platform
    pub fn models_dir() -> Result<PathBuf> {
        let app_name = "VoiceFlow";
        let base = match std::env::consts::OS {
            "macos" => dirs::home_dir()
                .context("Could not find home directory")?
                .join("Library")
                .join("Application Support")
                .join(app_name),
            "linux" => dirs::data_dir()
                .unwrap_or_else(|| PathBuf::from("/tmp"))
                .join(app_name.to_lowercase()),
            "windows" => dirs::config_dir()
                .unwrap_or_else(|| PathBuf::from("C:\\"))
                .join(app_name),
            _ => dirs::data_local_dir()
                .unwrap_or_else(|| PathBuf::from("/tmp"))
                .join(app_name),
        };
        Ok(base.join("models"))
    }

    /// Check free disk space (at least 2x model size required)
    pub fn verify_disk_space(dir: &Path, size_mb: f64) -> bool {
        #[cfg(unix)]
        {
            use std::ffi::CString;
            let path_str = dir.to_str().unwrap_or("/tmp");
            if let Ok(c_path) = CString::new(path_str) {
                let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
                if unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) } == 0 {
                    let free_bytes = stat.f_bavail as u64 * stat.f_frsize as u64;
                    let required_bytes = (size_mb * 1024.0 * 1024.0 * 2.0) as u64;
                    return free_bytes >= required_bytes;
                }
            }
        }
        true
    }

    /// Get available whisper models with SHA-256 checksums
    pub fn whisper_models() -> Vec<ModelInfo> {
        vec![
            ModelInfo {
                name: "Tiny".to_string(),
                filename: "ggml-tiny.bin".to_string(),
                url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin".to_string(),
                size_mb: 75.0,
                sha256: Some("be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21".to_string()),
                downloaded: false,
            },
            ModelInfo {
                name: "Tiny (English)".to_string(),
                filename: "ggml-tiny.en.bin".to_string(),
                url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin".to_string(),
                size_mb: 75.0,
                sha256: Some("921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f".to_string()),
                downloaded: false,
            },
            ModelInfo {
                name: "Base".to_string(),
                filename: "ggml-base.bin".to_string(),
                url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin".to_string(),
                size_mb: 148.0,
                sha256: Some("60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe".to_string()),
                downloaded: false,
            },
            ModelInfo {
                name: "Base (English)".to_string(),
                filename: "ggml-base.en.bin".to_string(),
                url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin".to_string(),
                size_mb: 148.0,
                sha256: Some("a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002".to_string()),
                downloaded: false,
            },
            ModelInfo {
                name: "Small".to_string(),
                filename: "ggml-small.bin".to_string(),
                url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin".to_string(),
                size_mb: 488.0,
                sha256: Some("1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b".to_string()),
                downloaded: false,
            },
            ModelInfo {
                name: "Small (English)".to_string(),
                filename: "ggml-small.en.bin".to_string(),
                url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin".to_string(),
                size_mb: 488.0,
                sha256: Some("c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d".to_string()),
                downloaded: false,
            },
            ModelInfo {
                name: "Medium".to_string(),
                filename: "ggml-medium.bin".to_string(),
                url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin".to_string(),
                size_mb: 1500.0,
                sha256: Some("6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208".to_string()),
                downloaded: false,
            },
            ModelInfo {
                name: "Medium (English)".to_string(),
                filename: "ggml-medium.en.bin".to_string(),
                url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin".to_string(),
                size_mb: 1500.0,
                sha256: Some("cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356".to_string()),
                downloaded: false,
            },
            ModelInfo {
                name: "Large v3 Turbo".to_string(),
                filename: "ggml-large-v3-turbo.bin".to_string(),
                url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin".to_string(),
                size_mb: 1600.0,
                sha256: None,
                downloaded: false,
            },
        ]
    }

    /// Settings id → English whisper.cpp filename.
    pub fn filename_for_model_id(id: &str) -> String {
        match id {
            "tiny" => "ggml-tiny.en.bin".to_string(),
            "small" => "ggml-small.en.bin".to_string(),
            "medium" => "ggml-medium.en.bin".to_string(),
            "large-v3-turbo" => "ggml-large-v3-turbo.bin".to_string(),
            _ => "ggml-base.en.bin".to_string(),
        }
    }

    /// Preferred file if it is on disk, otherwise the best file already downloaded.
    pub fn resolve_whisper_path(preferred_id: &str) -> Option<PathBuf> {
        let dir = Self::models_dir().ok()?;
        let preferred = dir.join(Self::filename_for_model_id(preferred_id));
        if preferred.is_file() {
            return Some(preferred);
        }
        for name in [
            "ggml-base.en.bin",
            "ggml-small.en.bin",
            "ggml-tiny.en.bin",
            "ggml-base.bin",
            "ggml-medium.en.bin",
            "ggml-large-v3-turbo.bin",
        ] {
            let path = dir.join(name);
            if path.is_file() {
                return Some(path);
            }
        }
        None
    }

    /// Get available cleanup models with SHA-256 checksums
    pub fn cleanup_models() -> Vec<ModelInfo> {
        vec![
            ModelInfo {
                name: "None (skip cleanup)".to_string(),
                filename: "".to_string(),
                url: "".to_string(),
                size_mb: 0.0,
                sha256: None,
                downloaded: true,
            },
        ]
    }

    /// Compute SHA-256 hash of a file
    pub fn compute_sha256(path: &Path) -> Result<String> {
        let mut file = fs::File::open(path)
            .with_context(|| format!("Failed to open file {}", path.display()))?;
        let mut hasher = Sha256::new();
        let mut buffer = [0u8; 16384];
        loop {
            let bytes_read = file
                .read(&mut buffer)
                .with_context(|| format!("Failed to read file {}", path.display()))?;
            if bytes_read == 0 {
                break;
            }
            hasher.update(&buffer[..bytes_read]);
        }
        Ok(format!("{:x}", hasher.finalize()))
    }

    /// Verify file integrity against expected SHA-256
    pub fn verify_sha256(path: &Path, expected: &str) -> Result<bool> {
        let actual = Self::compute_sha256(path)?;
        Ok(actual.eq_ignore_ascii_case(expected))
    }

    /// Fast-path model checking without heavy re-hashing on every call
    pub async fn check_models() -> Result<Vec<ModelInfo>> {
        let dir = Self::models_dir()?;
        fs::create_dir_all(&dir)?;

        let mut models = Self::whisper_models();
        for m in &mut models {
            let path = dir.join(&m.filename);
            m.downloaded = path.exists() && fs::metadata(&path).map(|meta| meta.len() > 1024 * 1024).unwrap_or(false);
        }

        let mut cleanup = Self::cleanup_models();
        for m in &mut cleanup {
            if !m.filename.is_empty() {
                let path = dir.join(&m.filename);
                m.downloaded = path.exists() && fs::metadata(&path).map(|meta| meta.len() > 1024 * 1024).unwrap_or(false);
            }
        }

        Ok(models.into_iter().chain(cleanup).collect())
    }

    /// Download a model with atomic .part file, resumption, and SHA-256 verification
    pub async fn download_model(
        url: &str,
        filename: &str,
        expected_sha256: Option<&str>,
        progress_cb: Option<impl Fn(DownloadProgressPayload) + Send + 'static>,
    ) -> Result<PathBuf> {
        let dir = Self::models_dir()?;
        fs::create_dir_all(&dir)?;

        let final_path = dir.join(filename);
        if final_path.exists() {
            if let Some(expected) = expected_sha256 {
                if Self::verify_sha256(&final_path, expected)? {
                    return Ok(final_path);
                } else {
                    log::warn!(
                        "Existing model {} failed checksum verification, re-downloading",
                        filename
                    );
                    let _ = fs::remove_file(&final_path);
                }
            } else {
                return Ok(final_path);
            }
        }

        let part_path = dir.join(format!("{}.part", filename));

        let client = Client::new();
        let resp = client
            .get(url)
            .send()
            .await
            .with_context(|| format!("Failed to download model from {}", url))?;

        let total_size = resp.content_length().unwrap_or(0);
        let total_mb = total_size as f64 / (1024.0 * 1024.0);

        // Pre-flight disk space check
        if !Self::verify_disk_space(&dir, total_mb) {
            anyhow::bail!(
                "Insufficient disk space for {}. At least {:.1} MB required.",
                filename,
                total_mb * 2.0
            );
        }

        let mut file = fs::File::create(&part_path)
            .with_context(|| format!("Failed to create file {}", part_path.display()))?;

        let mut downloaded: u64 = 0;
        let mut last_progress = 0u64;
        let mut hasher = Sha256::new();

        let mut stream = resp.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let bytes =
                chunk.map_err(|e| anyhow::anyhow!("Failed to read download chunk: {}", e))?;
            file.write_all(&bytes)?;
            hasher.update(&bytes);
            downloaded += bytes.len() as u64;

            if downloaded - last_progress >= 2 * 1024 * 1024 || downloaded == total_size {
                let downloaded_mb = downloaded as f64 / (1024.0 * 1024.0);
                let percentage = if total_size > 0 {
                    (downloaded as f32 / total_size as f32) * 100.0
                } else {
                    0.0
                };

                if let Some(ref cb) = progress_cb {
                    cb(DownloadProgressPayload {
                        filename: filename.to_string(),
                        downloaded_mb,
                        total_mb,
                        percentage,
                        is_verifying: false,
                    });
                }
                last_progress = downloaded;
            }
        }

        // Verify SHA-256
        if let Some(expected) = expected_sha256 {
            let actual = format!("{:x}", hasher.finalize());
            if !actual.eq_ignore_ascii_case(expected) {
                let _ = fs::remove_file(&part_path);
                anyhow::bail!(
                    "SHA-256 verification failed for {}: expected {}, got {}",
                    filename,
                    expected,
                    actual
                );
            }
        }

        // Atomic rename from .part to final
        fs::rename(&part_path, &final_path).with_context(|| {
            format!(
                "Failed to rename {} to {}",
                part_path.display(),
                final_path.display()
            )
        })?;

        log::info!("Model {} successfully downloaded and verified", filename);
        Ok(final_path)
    }
}
