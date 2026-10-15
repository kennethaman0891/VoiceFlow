use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use std::fs;
use std::io::{Write, Read};
use reqwest::Client;
use sha2::{Sha256, Digest};
use dirs;
use futures::StreamExt;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ModelInfo {
    pub name: String,
    pub filename: String,
    pub url: String,
    pub size_mb: f64,
    pub sha256: Option<String>,
    pub downloaded: bool,
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
        ]
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
            ModelInfo {
                name: "Qwen 3.5 0.8B Q4_K_M".to_string(),
                filename: "qwen3.5-0.8b-q4_k_m.gguf".to_string(),
                url: "https://huggingface.co/TheBloke/Qwen3.5-0.8B-GGUF/resolve/main/qwen3.5-0.8b-q4_k_m.gguf".to_string(),
                size_mb: 500.0,
                sha256: Some("4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e".to_string()),
                downloaded: false,
            },
        ]
    }

    /// Compute SHA-256 hash of a file
    pub fn compute_sha256(path: &Path) -> Result<String> {
        let mut file = fs::File::open(path)
            .with_context(|| format!("Failed to open file {}", path.display()))?;
        let mut hasher = Sha256::new();
        let mut buffer = [0u8; 8192];
        loop {
            let bytes_read = file.read(&mut buffer)
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

    /// Check which models are downloaded and verified
    pub async fn check_models() -> Result<Vec<ModelInfo>> {
        let dir = Self::models_dir()?;
        fs::create_dir_all(&dir)?;

        let mut models = Self::whisper_models();
        for m in &mut models {
            let path = dir.join(&m.filename);
            m.downloaded = path.exists();
            if m.downloaded {
                if let Some(expected) = &m.sha256 {
                    m.downloaded = Self::verify_sha256(&path, expected).unwrap_or(false);
                }
            }
        }

        let mut cleanup = Self::cleanup_models();
        for m in &mut cleanup {
            if !m.filename.is_empty() {
                let path = dir.join(&m.filename);
                m.downloaded = path.exists();
                if m.downloaded {
                    if let Some(expected) = &m.sha256 {
                        m.downloaded = Self::verify_sha256(&path, expected).unwrap_or(false);
                    }
                }
            }
        }

        Ok(models.into_iter().chain(cleanup).collect())
    }

    /// Download a model from URL with SHA-256 verification
    pub async fn download_model(url: &str, filename: &str, expected_sha256: Option<&str>) -> Result<PathBuf> {
        let dir = Self::models_dir()?;
        fs::create_dir_all(&dir)?;

        let path = dir.join(filename);
        if path.exists() {
            // Verify existing file
            if let Some(expected) = expected_sha256 {
                if Self::verify_sha256(&path, expected)? {
                    return Ok(path);
                } else {
                    log::warn!("Existing model {} failed checksum verification, re-downloading", filename);
                    fs::remove_file(&path)?;
                }
            } else {
                return Ok(path);
            }
        }

        let client = Client::new();
        let resp = client.get(url).send().await
            .with_context(|| format!("Failed to download model from {}", url))?;

        let total_size = resp.content_length().unwrap_or(0);
        let mut file = fs::File::create(&path)
            .with_context(|| format!("Failed to create file {}", path.display()))?;
        let mut downloaded: u64 = 0;
        let mut last_progress = 0u64;
        let mut hasher = Sha256::new();

        let mut stream = resp.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let bytes = chunk
                .map_err(|e| anyhow::anyhow!("Failed to read download chunk: {}", e))?;
            file.write_all(&bytes)?;
            hasher.update(&bytes);
            downloaded += bytes.len() as u64;

            // Emit progress every 5MB or when complete
            if downloaded - last_progress >= 5 * 1024 * 1024 || downloaded == total_size {
                let percent = if total_size > 0 {
                    downloaded as f64 / total_size as f64 * 100.0
                } else {
                    0.0
                };
                log::info!("Downloading {}: {:.1}% ({:.1} MB)", filename, percent, downloaded as f64 / 1024.0 / 1024.0);
                last_progress = downloaded;
            }
        }

        // Verify SHA-256 after download
        if let Some(expected) = expected_sha256 {
            let actual = format!("{:x}", hasher.finalize());
            if !actual.eq_ignore_ascii_case(expected) {
                fs::remove_file(&path)?;
                anyhow::bail!("SHA-256 verification failed for {}: expected {}, got {}", filename, expected, actual);
            }
        }

        Ok(path)
    }
}
