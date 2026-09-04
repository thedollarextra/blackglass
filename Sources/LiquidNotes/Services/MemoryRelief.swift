import Foundation
import AppKit

/// Trimming for the background state: window closed, app alive only for the
/// menu extra and the web server.
///
/// The search index stays resident because `/api/search` needs it, but
/// everything the UI accumulated — WebKit's caches, rendered images, the
/// allocator's free pages — can go back.
public enum LiquidNotesMemory {
    /// Called when the last window closes, and from Settings' Release Memory.
    public static func releaseIdle() {
        URLCache.shared.removeAllCachedResponses()
        // Hand free pages back to the OS rather than holding them in the
        // allocator's per-thread caches after a burst of indexing or rendering.
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Resident footprint in bytes, for the Settings readout.
    public static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
