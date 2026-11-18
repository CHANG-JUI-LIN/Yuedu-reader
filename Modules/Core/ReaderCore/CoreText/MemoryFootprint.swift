import Foundation
import Darwin

/// Process footprint helper for memory measurements.
///
/// Reads `task_vm_info.phys_footprint` — the number of bytes the system counts
/// against this process's memory budget (the same number jetsam uses). Used by
/// tests to measure the memory effects of cache-budget changes.
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
}
