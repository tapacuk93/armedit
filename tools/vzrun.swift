// vzrun - boot an armedit image under macOS's Virtualization framework.
//
// The target is bare metal on this Mac. This is the closest test bed available
// before that: a real Apple CPU at EL1, with the same timer, the same cache
// behaviour and the same errata as the machine the kernel will eventually boot
// on for real - which QEMU, however convenient, does not have.
//
// What it is not is a rehearsal of Apple hardware. The devices here are virtio,
// not Apple's; there is no AIC, no Apple UART, and the framebuffer is virtio-gpu
// rather than one iBoot set up. So this proves the CPU-facing half of the port -
// image format, boot protocol, device discovery, position independence - and
// says nothing about the driver half.
//
// Usage:  vzrun <kernel image> [kernel command line]
//
// It needs the com.apple.security.virtualization entitlement, so the built
// binary is ad-hoc signed with one; see the Makefile.

import Foundation
import Virtualization

func die(_ why: String) -> Never {
    FileHandle.standardError.write(("vzrun: " + why + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: vzrun <kernel image> [command line]") }
let kernel = URL(fileURLWithPath: args[1])
guard FileManager.default.fileExists(atPath: kernel.path) else {
    die("no such image: \(kernel.path)")
}

let boot = VZLinuxBootLoader(kernelURL: kernel)
// The framework insists on a command line and a Linux-shaped boot. armedit
// ignores it, but a loader that is told nothing may decline to boot at all.
boot.commandLine = args.count > 2 ? args[2] : "console=hvc0"

let config = VZVirtualMachineConfiguration()
config.bootLoader = boot
config.cpuCount = 1
config.memorySize = 512 * 1024 * 1024

// A console, wired to this process's own stdin and stdout, so the guest's
// output is this program's output. It is virtio, which the kernel does not yet
// speak - the point for now is that the machine boots far enough to want one.
let console = VZVirtioConsoleDeviceSerialPortConfiguration()

// A real file rather than this process's stdout, when asked.
//
// Worth being able to choose: the guest's console output goes to whatever
// handle is attached, and a pipe that something upstream has stopped reading
// behaves differently from a file. When a device is not consuming buffers at
// all, ruling out the shape of the far end is cheaper than reasoning about it.
// Something for the guest to read, when asked.
//
// The console's transmit direction has never completed a descriptor, and the
// entropy device on the same bus completes one immediately - the difference
// being that entropy writes into guest memory and a console transmit asks the
// device to read from it. Feeding input tests the other direction: if the
// receive queue completes, the device services queues and only the read path
// is wrong.
let feed: FileHandle? = ProcessInfo.processInfo.environment["VZRUN_IN"].flatMap {
    FileHandle(forReadingAtPath: $0)
}

if let path = ProcessInfo.processInfo.environment["VZRUN_OUT"] {
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let out = FileHandle(forWritingAtPath: path) else { die("cannot write \(path)") }
    let sink = feed ?? FileHandle(forReadingAtPath: "/dev/null")!
    console.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: sink, fileHandleForWriting: out)
} else {
    console.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: FileHandle.standardInput,
        fileHandleForWriting: FileHandle.standardOutput)
}
config.serialPorts = [console]

config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

do {
    try config.validate()
} catch {
    die("this configuration is not one the framework will accept: \(error)")
}

let queue = DispatchQueue(label: "vzrun")
let vm = VZVirtualMachine(configuration: config, queue: queue)

/// Watches for the machine stopping, since a guest that halts is the ordinary
/// end of a boot that did not get far enough to say anything.
final class Watcher: NSObject, VZVirtualMachineDelegate {
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        FileHandle.standardError.write(
            "vzrun: the machine stopped: \(error)\n".data(using: .utf8)!)
        exit(2)
    }
    func guestDidStop(_ vm: VZVirtualMachine) {
        FileHandle.standardError.write("vzrun: the guest halted\n".data(using: .utf8)!)
        exit(0)
    }
}
let watcher = Watcher()
queue.sync { vm.delegate = watcher }

queue.async {
    vm.start { result in
        switch result {
        case .success:
            FileHandle.standardError.write("vzrun: started\n".data(using: .utf8)!)
        case .failure(let error):
            die("could not start: \(error)")
        }
    }
}

// Long enough to see whether anything comes out, short enough not to leave a
// machine running because a test forgot about it.
let seconds = Double(ProcessInfo.processInfo.environment["VZRUN_SECONDS"] ?? "10") ?? 10
Thread.sleep(forTimeInterval: seconds)
FileHandle.standardError.write("vzrun: time is up\n".data(using: .utf8)!)
exit(0)
