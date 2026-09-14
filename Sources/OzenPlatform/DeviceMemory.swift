// `mach_task_self_` is a C global; without @preconcurrency Swift 6 refuses
// to read it. It names this process and never changes while it runs.
@preconcurrency import Darwin
import os

/// How much memory the app is using, and how much more iOS lets it have.
///
/// A speech model is one of the biggest things in a phone's memory, and
/// iOS ends an app that goes over its limit without a word. When captions
/// "just closed", these two numbers are the first thing to look at.
public enum DeviceMemory {
    /// What iOS counts against the app when deciding whether to end it
    /// (its "footprint"), in bytes. Nil if it can't be read.
    public static func footprintBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }

    /// How much more the app may use before iOS ends it, in bytes. Nil
    /// where iOS doesn't say (the simulator, macOS).
    public static func availableBytes() -> Int64? {
        #if os(iOS)
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Int64(bytes) : nil
        #else
        return nil
        #endif
    }
}
