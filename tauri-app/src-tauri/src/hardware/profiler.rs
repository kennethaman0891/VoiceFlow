use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HardwareTier {
    Tier1Low,      // <= 8GB RAM, older CPU -> tiny.en, regex-only
    Tier2Mid,      // 8GB - 16GB RAM, Apple Silicon base -> base.en, qwen 0.8B
    Tier3High,     // 16GB - 32GB RAM, Apple Silicon Pro/Max, modern dGPU -> small.en, qwen 1.5B/2B
    Tier4Extreme,  // > 32GB RAM, Studio/Workstation -> large-v3-turbo, qwen 4B
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HardwareProfile {
    pub os: String,
    pub arch: String,
    pub cpu_brand: String,
    pub cpu_cores: usize,
    pub total_ram_mb: u64,
    pub is_apple_silicon: bool,
    pub apple_silicon_family: Option<String>,
    pub recommended_tier: HardwareTier,
    /// Settings id: tiny, base, small, medium, large-v3-turbo.
    pub recommended_model_id: String,
    /// Whisper file name, for the settings card.
    pub recommended_whisper_model: String,
    /// Always "off" until a real local LLM is wired. Paste does not wait on one.
    pub recommended_cleanup_model: String,
}

pub struct HardwareProfiler;

impl HardwareProfiler {
    pub fn detect() -> HardwareProfile {
        let os = std::env::consts::OS.to_string();
        let arch = std::env::consts::ARCH.to_string();

        let (total_ram_mb, cpu_brand, cpu_cores, is_apple_silicon, apple_silicon_family) =
            Self::detect_system_specs();

        let (recommended_tier, model_id, whisper_file) = tier_for_ram(total_ram_mb);

        HardwareProfile {
            os,
            arch,
            cpu_brand,
            cpu_cores,
            total_ram_mb,
            is_apple_silicon,
            apple_silicon_family,
            recommended_tier,
            recommended_model_id: model_id.to_string(),
            recommended_whisper_model: whisper_file.to_string(),
            recommended_cleanup_model: "off".to_string(),
        }
    }

    #[cfg(target_os = "macos")]
    fn detect_system_specs() -> (u64, String, usize, bool, Option<String>) {
        use std::ffi::CStr;

        let mut mem_size: u64 = 0;
        let mut len = std::mem::size_of::<u64>();
        let mut mib = [libc::CTL_HW, libc::HW_MEMSIZE];
        unsafe {
            let _ = libc::sysctl(
                mib.as_mut_ptr(),
                2,
                &mut mem_size as *mut _ as *mut libc::c_void,
                &mut len,
                std::ptr::null_mut(),
                0,
            );
        }
        let total_ram_mb = mem_size / (1024 * 1024);

        let mut cpu_buf = [0i8; 256];
        let mut cpu_len = cpu_buf.len();
        let cpu_brand = unsafe {
            let name = b"machdep.cpu.brand_string\0";
            if libc::sysctlbyname(
                name.as_ptr() as *const libc::c_char,
                cpu_buf.as_mut_ptr() as *mut libc::c_void,
                &mut cpu_len,
                std::ptr::null_mut(),
                0,
            ) == 0
            {
                CStr::from_ptr(cpu_buf.as_ptr())
                    .to_string_lossy()
                    .trim()
                    .to_string()
            } else {
                "Apple Silicon".to_string()
            }
        };

        let mut cores: i32 = 4;
        let mut cores_len = std::mem::size_of::<i32>();
        let mut mib = [libc::CTL_HW, libc::HW_NCPU];
        unsafe {
            let _ = libc::sysctl(
                mib.as_mut_ptr(),
                2,
                &mut cores as *mut _ as *mut libc::c_void,
                &mut cores_len,
                std::ptr::null_mut(),
                0,
            );
        }

        let is_apple_silicon = std::env::consts::ARCH == "aarch64";
        let mut family = None;

        if is_apple_silicon {
            if cpu_brand.contains("M5") {
                family = Some("M5".to_string());
            } else if cpu_brand.contains("M4") {
                family = Some("M4".to_string());
            } else if cpu_brand.contains("M3") {
                family = Some("M3".to_string());
            } else if cpu_brand.contains("M2") {
                family = Some("M2".to_string());
            } else if cpu_brand.contains("M1") {
                family = Some("M1".to_string());
            } else {
                family = Some("Apple M-Series".to_string());
            }
        }

        (
            total_ram_mb,
            cpu_brand,
            cores as usize,
            is_apple_silicon,
            family,
        )
    }

    #[cfg(target_os = "linux")]
    fn detect_system_specs() -> (u64, String, usize, bool, Option<String>) {
        let mut total_ram_mb = 8192;
        let mut cpu_brand = "Linux CPU".to_string();

        if let Ok(meminfo) = std::fs::read_to_string("/proc/meminfo") {
            for line in meminfo.lines() {
                if line.starts_with("MemTotal:") {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 2 {
                        if let Ok(kb) = parts[1].parse::<u64>() {
                            total_ram_mb = kb / 1024;
                        }
                    }
                    break;
                }
            }
        }

        if let Ok(cpuinfo) = std::fs::read_to_string("/proc/cpuinfo") {
            for line in cpuinfo.lines() {
                if line.starts_with("model name") {
                    if let Some(pos) = line.find(':') {
                        cpu_brand = line[pos + 1..].trim().to_string();
                        break;
                    }
                }
            }
        }

        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4);

        (total_ram_mb, cpu_brand, cores, false, None)
    }

    #[cfg(target_os = "windows")]
    fn detect_system_specs() -> (u64, String, usize, bool, Option<String>) {
        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4);
        let ram_mb = windows_ram_mb().unwrap_or(0);
        (ram_mb, "Windows PC".to_string(), cores, false, None)
    }
}

/// Pick a Whisper file that leaves the OS several gigabytes free.
/// 8 GB → tiny, 16 GB → base, 24 GB → small, 32 GB → medium, 48 GB+ → turbo.
pub fn tier_for_ram(ram_mb: u64) -> (HardwareTier, &'static str, &'static str) {
    if ram_mb == 0 || ram_mb < 12_000 {
        (HardwareTier::Tier1Low, "tiny", "ggml-tiny.en.bin")
    } else if ram_mb < 20_000 {
        (HardwareTier::Tier2Mid, "base", "ggml-base.en.bin")
    } else if ram_mb < 28_000 {
        (
            HardwareTier::Tier3High,
            "small",
            "ggml-small.en.bin",
        )
    } else if ram_mb < 40_000 {
        (
            HardwareTier::Tier3High,
            "medium",
            "ggml-medium.en.bin",
        )
    } else {
        (
            HardwareTier::Tier4Extreme,
            "large-v3-turbo",
            "ggml-large-v3-turbo.bin",
        )
    }
}

#[cfg(target_os = "windows")]
fn windows_ram_mb() -> Option<u64> {
    #[link(name = "kernel32")]
    extern "system" {
        fn GetPhysicallyInstalledSystemMemory(total_memory_in_kilobytes: *mut u64) -> i32;
    }
    let mut kb = 0u64;
    if unsafe { GetPhysicallyInstalledSystemMemory(&mut kb) } != 0 && kb > 0 {
        Some(kb / 1024)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ram_tiers_match_the_dictation_matrix() {
        assert_eq!(tier_for_ram(8 * 1024).1, "tiny");
        assert_eq!(tier_for_ram(16 * 1024).1, "base");
        assert_eq!(tier_for_ram(24 * 1024).1, "small");
        assert_eq!(tier_for_ram(32 * 1024).1, "medium");
        assert_eq!(tier_for_ram(48 * 1024).1, "large-v3-turbo");
        assert_eq!(tier_for_ram(0).1, "tiny");
    }
}
