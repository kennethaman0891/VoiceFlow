import Foundation
import Metal

// MARK: - HardwareTier

public enum HardwareTier: String, Codable, Sendable {
    case tier1Low = "Tier 1: Low-End (<8GB RAM)"
    case tier2Mid = "Tier 2: Balanced (8-15GB RAM)"
    case tier3High = "Tier 3: High Performance (16-31GB RAM)"
    case tier4Extreme = "Tier 4: Extreme Performance (≥32GB RAM)"
}

// MARK: - HardwareProfile

public struct HardwareProfile: Codable, Sendable {
    public let chipName: String
    public let cpuCores: Int
    public let totalRamMB: Int
    public let isAppleSilicon: Bool
    public let metalDeviceName: String?
    public let recommendedTier: HardwareTier
    public let recommendedWhisperModel: String
    public let recommendedCleanupModel: String

    public var totalRamGB: Double {
        Double(totalRamMB) / 1024.0
    }
}

// MARK: - HardwareProfiler

public enum HardwareProfiler {

    /// Profiles the local Mac system hardware and determines optimal local Whisper & LLM models.
    public static func profile() -> HardwareProfile {
        let chipName = getCpuBrand()
        let cpuCores = ProcessInfo.processInfo.activeProcessorCount
        let ramBytes = getPhysicalMemory()
        let totalRamMB = Int(ramBytes / (1024 * 1024))

        let metalDevice = MTLCopyAllDevices().first?.name
        let isAppleSilicon = chipName.lowercased().contains("apple") || isAppleSiliconArchitecture()

        let tier: HardwareTier
        let whisperModel: String
        let cleanupModel: String

        if totalRamMB < 7 * 1024 {
            tier = .tier1Low
            whisperModel = "tiny.en"
            cleanupModel = "none"
        } else if totalRamMB < 15 * 1024 {
            tier = .tier2Mid
            whisperModel = "base.en"
            cleanupModel = isAppleSilicon ? "qwen0.8b" : "none"
        } else if totalRamMB < 30 * 1024 {
            tier = .tier3High
            whisperModel = "medium.en"
            cleanupModel = "qwen0.8b"
        } else {
            tier = .tier4Extreme
            whisperModel = "large-v3-turbo"
            cleanupModel = "qwen0.8b"
        }

        return HardwareProfile(
            chipName: chipName,
            cpuCores: cpuCores,
            totalRamMB: totalRamMB,
            isAppleSilicon: isAppleSilicon,
            metalDeviceName: metalDevice,
            recommendedTier: tier,
            recommendedWhisperModel: whisperModel,
            recommendedCleanupModel: cleanupModel
        )
    }

    private static func getPhysicalMemory() -> UInt64 {
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &memSize, &size, nil, 0)
        if result == 0 && memSize > 0 {
            return memSize
        }
        return ProcessInfo.processInfo.physicalMemory
    }

    private static func getCpuBrand() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else {
            return isAppleSiliconArchitecture() ? "Apple Silicon" : "Mac Processor"
        }

        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let name = String(cString: brand).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (isAppleSiliconArchitecture() ? "Apple Silicon" : "Mac Processor") : name
    }

    private static func isAppleSiliconArchitecture() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
