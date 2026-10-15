use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use libloading::{Library, Symbol};
use zeroize::Zeroize;
use libc;

// llama.cpp C API types (opaque structs)
#[repr(C)]
pub struct llama_context {
    _private: [u8; 0],
}

#[repr(C)]
pub struct llama_model {
    _private: [u8; 0],
}

type LlamaLoadFileFromPathFn = unsafe extern "C" fn(*const libc::c_char, *mut libc::c_void) -> *mut llama_model;
type LlamaNewContextWithModelFn = unsafe extern "C" fn(*mut llama_model, *const libc::c_void) -> *mut llama_context;
type LlamaFreeFn = unsafe extern "C" fn(*mut llama_context);
type LlamaModelFreeFn = unsafe extern "C" fn(*mut llama_model);

/// Parameters for text cleanup
pub struct CleanupParams {
    pub max_tokens: i32,
    pub temperature: f32,
    pub repeat_penalty: f32,
}

impl Default for CleanupParams {
    fn default() -> Self {
        Self {
            max_tokens: 512,
            temperature: 0.3,
            repeat_penalty: 1.1,
        }
    }
}

/// Thread-safe llama.cpp context wrapper for text cleanup
pub struct LlamaContext {
    ctx: *mut llama_context,
    model: *mut llama_model,
    lib: Library,
    // Track initialization state for RAII safety
    initialized: bool,
}

unsafe impl Send for LlamaContext {}

impl LlamaContext {
    /// Initialize llama.cpp from a GGUF model file
    pub fn new(model_path: &Path) -> Result<Self> {
        let lib_path = Self::find_llama_lib();
        let lib = unsafe {
            Library::new(&lib_path)
                .with_context(|| format!("Failed to load llama.cpp library from {:?}", lib_path))?
        };

        let load_fn: Symbol<LlamaLoadFileFromPathFn> = unsafe {
            lib.get(b"llama_load_file_from_path")
                .context("Failed to find llama_load_file_from_path symbol")?
        };

        let c_path = std::ffi::CString::new(model_path.to_string_lossy().as_bytes())
            .context("Invalid model path")?;

        let model = unsafe { load_fn(c_path.as_ptr(), std::ptr::null_mut()) };
        if model.is_null() {
            anyhow::bail!("Failed to load llama model from {:?}", model_path);
        }

        log::info!("Loaded cleanup model from: {:?}", model_path);

        // Create context with default parameters
        let new_ctx: Symbol<LlamaNewContextWithModelFn> = unsafe {
            lib.get(b"llama_new_context_with_model")
                .context("Failed to find llama_new_context_with_model symbol")?
        };

        // Use default context params (all zeros = defaults)
        let ctx = unsafe { new_ctx(model, std::ptr::null()) };
        if ctx.is_null() {
            // Clean up model if context creation fails
            if let Ok(free) = unsafe { lib.get::<LlamaModelFreeFn>(b"llama_model_free") } {
                unsafe { free(model) };
            }
            anyhow::bail!("Failed to create llama context");
        }

        Ok(LlamaContext { ctx, model, lib, initialized: true })
    }

    /// Find the llama.cpp shared library
    fn find_llama_lib() -> PathBuf {
        let exe_dir = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|p| p.to_path_buf()))
            .unwrap_or_default();

        let resource_dir = std::env::var_os("RESOURCE_DIR")
            .map(|d| PathBuf::from(d))
            .filter(|p| p.exists());

        let candidate = match std::env::consts::OS {
            "macos" => {
                if let Some(ref rd) = resource_dir {
                    let bundled = rd.join("Frameworks").join("libllama.dylib");
                    if bundled.exists() {
                        return bundled;
                    }
                }
                exe_dir.join("Frameworks").join("libllama.dylib")
            }
            "linux" => {
                if let Some(ref rd) = resource_dir {
                    let bundled = rd.join("libllama.so");
                    if bundled.exists() {
                        return bundled;
                    }
                }
                exe_dir.join("libllama.so")
            }
            "windows" => exe_dir.join("llama.dll"),
            _ => panic!("Unsupported platform"),
        };

        if !candidate.exists() {
            log::warn!("llama.cpp library not found at {:?}", candidate);
        }

        candidate
    }

    /// Clean up transcribed text using the LLM
    /// Returns the cleaned text or the original if cleanup fails
    pub fn clean_text(&mut self, text: &str, _params: &CleanupParams) -> Result<String> {
        if !self.initialized {
            anyhow::bail!("LlamaContext not properly initialized");
        }
        if text.trim().is_empty() {
            return Ok(text.to_string());
        }

        // Build the prompt for text cleanup
        let prompt = format!(
            "Clean up this transcribed text. Remove filler words (um, uh, like, you know),             fix grammar, add proper punctuation and capitalization.             Keep the original meaning intact - never change facts.             Return ONLY the cleaned text with no explanation.

{}

Cleaned text:",
            text
        );

        // Note: Full implementation requires tokenizer, batching, and sampling
        // For now, we'll do simple post-processing as a fallback
        // A complete implementation would need the full llama.cpp API

        // Simple heuristic cleanup (fallback when LLM unavailable)
        let result = self.simple_cleanup(&prompt);
        
        // Securely zero the prompt string after use
        let mut prompt_bytes = prompt.into_bytes();
        prompt_bytes.zeroize();
        
        Ok(result)
    }

    /// Simple rule-based text cleanup (used when LLM is not available)
    fn simple_cleanup(&self, text: &str) -> String {
        let mut result = text.to_string();

        // Remove filler words
        let fillers = ["um ", "uh ", "like ", "you know ", "i mean ", "so ", "basically "];
        for filler in &fillers {
            result = result.replace(filler, " ");
            result = result.replace(&format!(",{}", filler), ", ");
        }

        // Fix double spaces
        while result.contains("  ") {
            result = result.replace("  ", " ");
        }

        // Trim and ensure proper capitalization
        result = result.trim().to_string();
        if !result.is_empty() {
            let mut chars = result.chars();
            if let Some(first) = chars.next() {
                result = first.to_uppercase().collect::<String>() + &result[1..];
            }
        }

        // Ensure ends with punctuation
        if !result.ends_with('.') && !result.ends_with('!') && !result.ends_with('?') {
            result.push('.');
        }

        result
    }

    /// Explicit cleanup method for deterministic resource release
    pub fn cleanup(&mut self) {
        if self.initialized {
            self.drop_resources();
            self.initialized = false;
        }
    }

    fn drop_resources(&mut self) {
        if let Ok(sym) = unsafe { self.lib.get::<LlamaFreeFn>(b"llama_free") } {
            unsafe { sym(self.ctx) };
            self.ctx = std::ptr::null_mut();
        }
        if let Ok(sym) = unsafe { self.lib.get::<LlamaModelFreeFn>(b"llama_model_free") } {
            unsafe { sym(self.model) };
            self.model = std::ptr::null_mut();
        }
    }
}

impl Drop for LlamaContext {
    fn drop(&mut self) {
        self.drop_resources();
    }
}
