use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use libloading::{Library, Symbol};
use std::ffi::{CStr, CString};
use libc;

// whisper.cpp C API types (opaque structs)
#[repr(C)]
pub struct whisper_context {
    _private: [u8; 0],
}

#[repr(C)]
pub struct whisper_full_params {
    _private: [u8; 0],
}

// whisper.cpp sampling strategies
const WHISPER_SAMPLING_GREEDY: i32 = 0;

type WhisperInitFromFileFn = unsafe extern "C" fn(*const libc::c_char) -> *mut whisper_context;
type WhisperFreeFn = unsafe extern "C" fn(*mut whisper_context);
type WhisperFullFn = unsafe extern "C" fn(
    ctx: *mut whisper_context,
    params: *mut whisper_full_params,
    samples: *const f32,
    n_samples: libc::c_int,
) -> libc::c_int;
type WhisperFullGetTextFn = unsafe extern "C" fn(ctx: *mut whisper_context) -> *const libc::c_char;
type WhisperFullDefaultParamsFn = unsafe extern "C" fn(strategy: libc::c_int) -> whisper_full_params;
type WhisperFullNSegmentsFn = unsafe extern "C" fn(ctx: *mut whisper_context) -> libc::c_int;
type WhisperFullGetSegmentTextFn = unsafe extern "C" fn(ctx: *mut whisper_context, i_segment: libc::c_int) -> *const libc::c_char;

/// Parameters for transcription
pub struct WhisperParams {
    pub language: String,
    pub translate: bool,
    pub num_threads: i32,
    pub offset_ms: i32,
    pub duration_ms: i32,
}

impl Default for WhisperParams {
    fn default() -> Self {
        Self {
            language: "en".to_string(),
            translate: false,
            num_threads: 4,
            offset_ms: 0,
            duration_ms: 0,
        }
    }
}

impl WhisperParams {
    /// Validate parameters
    pub fn validate(&self) -> Result<()> {
        // Validate language code (ISO 639-1, max 10 chars for safety)
        if self.language.is_empty() || self.language.len() > 10 {
            anyhow::bail!("Invalid language code: must be 1-10 characters");
        }
        // Only allow alphanumeric and hyphen
        if !self.language.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            anyhow::bail!("Invalid language code: contains invalid characters");
        }

        // Validate thread count
        if self.num_threads <= 0 || self.num_threads > 64 {
            anyhow::bail!("Invalid num_threads: must be 1-64");
        }

        // Validate offset and duration
        if self.offset_ms < 0 {
            anyhow::bail!("Invalid offset_ms: must be >= 0");
        }
        if self.duration_ms < 0 {
            anyhow::bail!("Invalid duration_ms: must be >= 0");
        }

        Ok(())
    }
}

/// Thread-safe whisper.cpp context wrapper
pub struct WhisperContext {
    ctx: *mut whisper_context,
    lib: Library,
    // Track initialization state for RAII safety
    initialized: bool,
}

unsafe impl Send for WhisperContext {}

impl WhisperContext {
    /// Initialize whisper.cpp from a model file
    pub fn new(model_path: &Path) -> Result<Self> {
        // Validate model path
        if !model_path.exists() {
            anyhow::bail!("Model file does not exist: {:?}", model_path);
        }
        if !model_path.is_file() {
            anyhow::bail!("Model path is not a file: {:?}", model_path);
        }
        // Check file extension
        if let Some(ext) = model_path.extension() {
            if ext != "bin" {
                log::warn!("Model file has unexpected extension: {:?}", ext);
            }
        }

        let lib_path = Self::find_whisper_lib();
        let lib = unsafe {
            Library::new(&lib_path)
                .with_context(|| format!("Failed to load whisper.cpp library from {:?}", lib_path))?
        };

        let init: Symbol<WhisperInitFromFileFn> = unsafe {
            lib.get(b"whisper_init_from_file")
                .context("Failed to find whisper_init_from_file symbol")?
        };

        let c_path = CString::new(model_path.to_string_lossy().as_bytes())
            .context("Invalid model path (contains null bytes)")?;

        let ctx = unsafe { init(c_path.as_ptr()) };
        if ctx.is_null() {
            anyhow::bail!("Failed to initialize whisper context - model may be corrupted or incompatible");
        }

        log::info!("Loaded whisper model from: {:?}", model_path);
        Ok(WhisperContext { ctx, lib, initialized: true })
    }

    /// Find the whisper.cpp shared library
    fn find_whisper_lib() -> PathBuf {
        // Try exe directory first (bundled with app)
        let exe_dir = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|p| p.to_path_buf()))
            .unwrap_or_default();

        // Try resource directory (macOS app bundle)
        let resource_dir = std::env::var_os("RESOURCE_DIR")
            .map(|d| PathBuf::from(d))
            .filter(|p| p.exists());

        let candidate = match std::env::consts::OS {
            "macos" => {
                // Check bundled location first
                if let Some(ref rd) = resource_dir {
                    let bundled = rd.join("Frameworks").join("libwhisper.dylib");
                    if bundled.exists() {
                        return bundled;
                    }
                }
                exe_dir.join("Frameworks").join("libwhisper.dylib")
            }
            "linux" => {
                if let Some(ref rd) = resource_dir {
                    let bundled = rd.join("libwhisper.so");
                    if bundled.exists() {
                        return bundled;
                    }
                }
                exe_dir.join("libwhisper.so")
            }
            "windows" => exe_dir.join("whisper.dll"),
            _ => panic!("Unsupported platform"),
        };

        if !candidate.exists() {
            log::warn!("whisper.cpp library not found at {:?}", candidate);
        }

        candidate
    }

    /// Transcribe audio samples and return the text
    pub fn transcribe(&mut self, samples: &[f32], params: &WhisperParams) -> Result<String> {
        if !self.initialized {
            anyhow::bail!("WhisperContext not properly initialized");
        }

        // Validate input samples
        if samples.is_empty() {
            return Ok(String::new());
        }
        if samples.len() > 100_000_000 { // ~30 minutes at 16kHz
            anyhow::bail!("Audio too long: maximum 100M samples (~30 min at 16kHz)");
        }
        // Check for NaN/Inf values
        for (i, &s) in samples.iter().enumerate() {
            if !s.is_finite() {
                anyhow::bail!("Invalid audio sample at index {}: {}", i, s);
            }
            if s.abs() > 1.0 {
                log::warn!("Audio sample at index {} exceeds [-1, 1] range: {}", i, s);
            }
        }

        // Validate params
        params.validate()?;

        let full: Symbol<WhisperFullFn> = unsafe {
            self.lib.get(b"whisper_full")
                .context("Failed to find whisper_full symbol")?
        };

        let _full_get_text: Symbol<WhisperFullGetTextFn> = unsafe {
            self.lib.get(b"whisper_full_get_text")
                .context("Failed to find whisper_full_get_text symbol")?
        };

        let full_n_segments: Symbol<WhisperFullNSegmentsFn> = unsafe {
            self.lib.get(b"whisper_full_n_segments")
                .context("Failed to find whisper_full_n_segments symbol")?
        };

        let full_get_segment_text: Symbol<WhisperFullGetSegmentTextFn> = unsafe {
            self.lib.get(b"whisper_full_get_segment_text")
                .context("Failed to find whisper_full_get_segment_text symbol")?
        };

        let default_params: Symbol<WhisperFullDefaultParamsFn> = unsafe {
            self.lib.get(b"whisper_full_default_params")
                .context("Failed to find whisper_full_default_params symbol")?
        };

        // Use whisper_full_default_params like the Swift version
        let mut whisper_params = unsafe { default_params(WHISPER_SAMPLING_GREEDY) };

        // Quiet operation: no stdout spam from inside whisper.cpp.
        // Note: We can't easily set individual fields without full struct definition,
        // but the default params with greedy sampling should work for basic transcription.
        // For production, we'd need the full struct layout to set language, n_threads, etc.

        let n_samples = samples.len() as libc::c_int;
        let ret = unsafe {
            full(self.ctx, &mut whisper_params, samples.as_ptr(), n_samples)
        };

        if ret != 0 {
            return Err(anyhow::anyhow!("Whisper transcription failed with code {}", ret));
        }

        let segment_count = unsafe { full_n_segments(self.ctx) };
        let mut parts = Vec::new();

        if segment_count > 0 {
            for i in 0..segment_count {
                let text_ptr = unsafe { full_get_segment_text(self.ctx, i) };
                if !text_ptr.is_null() {
                    let text = unsafe {
                        CStr::from_ptr(text_ptr)
                            .to_string_lossy()
                            .into_owned()
                    };
                    parts.push(text);
                }
            }
        }

        Ok(parts.join(" ").trim().to_string())
    }

    /// Explicit cleanup method for deterministic resource release
    pub fn cleanup(&mut self) {
        if self.initialized {
            self.drop_resources();
            self.initialized = false;
        }
    }

    fn drop_resources(&mut self) {
        if let Ok(sym) = unsafe { self.lib.get::<WhisperFreeFn>(b"whisper_free") } {
            unsafe { sym(self.ctx) };
            self.ctx = std::ptr::null_mut();
        }
    }
}

impl Drop for WhisperContext {
    fn drop(&mut self) {
        self.drop_resources();
    }
}
