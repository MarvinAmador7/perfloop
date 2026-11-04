import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The kernel's per-thread and per-process counters the objective is made of, readable as a normal user.
public enum KernelCounters {
  /// The calling thread's CPU time (user + system) in ms.
  public static func threadCpuMs() -> Double {
    #if canImport(Darwin)
    return threadCpuMs(mach_thread_self())
    #else
    return 0
    #endif
  }

  #if canImport(Darwin)
  /// Another thread of this task (the sampler's), by its port.
  public static func threadCpuMs(_ port: mach_port_t) -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) } }
    guard r == KERN_SUCCESS else { return 0 }
    return Double(info.user_time.seconds + info.system_time.seconds) * 1000 + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
  }
  #endif

  /// Instructions retired by this process (all threads) so far; nil where the call fails, 0 where the counters aren't
  /// kept (a VM).
  public static func instructions() -> UInt64? {
    #if canImport(Darwin)
    var info = rusage_info_v4()
    // libproc declares the buffer as `rusage_info_t *` (void **) but writes the struct at the pointer passed: hand it
    // the struct's own address.
    let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
      p.withMemoryRebound(to: rusage_info_t?.self, capacity: MemoryLayout<rusage_info_v4>.size / MemoryLayout<rusage_info_t?>.size) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    return rc == 0 ? info.ri_instructions : nil
    #else
    return nil
    #endif
  }
}
