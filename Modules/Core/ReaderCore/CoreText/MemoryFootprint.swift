import Foundation
import Darwin

/// DEBUG-only process footprint helper for memory diagnostics.
///
/// Reads `task_vm_info.phys_footprint` — the number of bytes the system counts
/// against this process's memory budget (the same number jetsam uses). Used to
/// measure the memory effects of cache-budget changes: log before/after a
/// memory warning, or after a reading burst, and compare numbers.
///
/// All entry points are no-ops in release builds.
enum MemoryFootprint {
    /// Physical footprint of this process in bytes.
    /// Returns -1 when the kernel call fails (never throws, never crashes).
    static func current() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), p, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int64(info.phys_footprint)
    }

    /// Logs footprint in MB via the AppLogger render channel, e.g.
    /// `⟐ MEM warning-before footprint=312.4MB`. DEBUG builds only.
    static func log(_ context: String) {
        #if DEBUG
        let bytes = current()
        guard bytes >= 0 else { return }
        AppLogger.render(
            "⟐ MEM \(context) footprint=\(String(format: "%.1f", Double(bytes) / 1_000_000))MB"
        )
        #endif
    }
}
