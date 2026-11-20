import ClaudeDeckCore
import Darwin
import Foundation

/// One cheap look at the system (a few sysctls and one pass over the process table: no simctl,
/// no `ps`). Runs off the main thread; the rules for what the numbers mean are in SystemLoad.swift.
enum SystemLoadSampler {
    /// Everything but `sessions` (the app fills that in on the main actor).
    nonisolated static func sample(at date: Date = Date()) -> LoadSample {
        var averages = [Double](repeating: 0, count: 3)
        let read = getloadavg(&averages, 3)
        let names = processNames()
        let counted = LoadProcesses.count(names)
        return LoadSample(at: date, load1: read >= 1 ? averages[0] : 0, load5: read >= 2 ? averages[1] : 0,
                          cores: ProcessInfo.processInfo.activeProcessorCount, pressure: MemoryPressure(kernelLevel: pressureLevel()),
                          memoryUsedPercent: memoryUsedPercent(), swapUsedBytes: swapUsed(), simulators: counted.simulators,
                          compilers: counted.compilers, processes: names.count)
    }

    /// Booted simulators right now (`claudedeck sim acquire` checks this, not a sample).
    nonisolated static func bootedSimulators() -> Int { LoadProcesses.count(processNames()).simulators }

    /// Every process's short name (`proc_name`, at most 16 characters).
    nonisolated static func processNames() -> [String] {
        // proc_listallpids answers in bytes with a nil buffer on some releases and in pids on others:
        // room for either, plus processes started between the two calls (zeros are skipped).
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var names: [String] = []
        names.reserveCapacity(Int(count))
        var buffer = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            names.append(String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return names
    }

    /// Every process with its parent, name, start time, CPU time and resident memory (libproc:
    /// one `proc_pidinfo(PROC_PIDTASKALLINFO)` each; another user's process falls back to its BSD
    /// info, without CPU and memory). Only for the load tab and `claudedeck load --detail`.
    nonisolated static func usageTable(at date: Date = Date()) -> ProcessUsageTable {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return ProcessUsageTable(at: date, records: []) }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return ProcessUsageTable(at: date, records: []) }
        let ticks = machTickNanos
        var records: [ProcessUsageRecord] = []
        records.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var all = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, size) == size {
                let cpu = Double(all.ptinfo.pti_total_user + all.ptinfo.pti_total_system) * ticks
                records.append(ProcessUsageRecord(pid: pid, ppid: Int32(all.pbsd.pbi_ppid), name: bsdName(all.pbsd),
                                                  started: Double(all.pbsd.pbi_start_tvsec) + Double(all.pbsd.pbi_start_tvusec) / 1e6,
                                                  cpuNanos: UInt64(cpu), residentBytes: all.ptinfo.pti_resident_size))
                continue
            }
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
            records.append(ProcessUsageRecord(pid: pid, ppid: Int32(bsd.pbi_ppid), name: bsdName(bsd),
                                              started: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6))
        }
        return ProcessUsageTable(at: date, records: records)
    }

    /// Nanoseconds per Mach tick: `pti_total_user`/`_system` are in Mach time units on Apple silicon
    /// (1 on Intel).
    nonisolated static let machTickNanos: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    private nonisolated static func bsdName(_ info: proc_bsdinfo) -> String {
        var copy = info
        let long = withUnsafeBytes(of: &copy.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !long.isEmpty { return long }
        return withUnsafeBytes(of: &copy.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    nonisolated static func pressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return Int(level)
    }

    /// Active, wired and compressed memory out of the physical memory.
    nonisolated static func memoryUsedPercent() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = Double(getpagesize())
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? min(100, used / total * 100) : 0
    }

    nonisolated static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }
}
