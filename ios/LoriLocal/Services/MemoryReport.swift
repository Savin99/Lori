import Foundation
import os

/// Сколько памяти занято и сколько ещё можно занять.
///
/// На телефоне это главное число при работе локальной модели: 225 МБ весов плюс
/// активации, а лимит у приложения жёсткий — система убивает без предупреждения и
/// без крэш-отчёта. Поэтому расход пишется в журнал перед каждым куском: если
/// приложение исчезло, в логе останется, на чём именно кончилась память.
enum MemoryReport {
    /// Занято этим процессом.
    static var footprintBytes: UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }

    /// Сколько ещё можно занять до вмешательства системы.
    /// В симуляторе лимита нет, и значение там бессмысленно велико.
    static var availableBytes: UInt64 {
        UInt64(os_proc_available_memory())
    }

    static var text: String {
        let occupied = Double(footprintBytes) / 1024 / 1024
        let available = Double(availableBytes) / 1024 / 1024
        guard available > 0 else { return String(format: "занято %.0f МБ", occupied) }
        return String(format: "занято %.0f МБ, до предела %.0f МБ", occupied, available)
    }
}
