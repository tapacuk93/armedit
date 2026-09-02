// vzefi - boot armedit under the Virtualization framework through EFI.
//
// The other host program, tools/vzrun.swift, uses the Linux boot loader: it
// hands the guest a raw arm64 image and a device tree and gets out of the way.
// That works, and on this machine the guest then has no way to say anything,
// because every device the framework offers is virtio and its console will not
// transmit for reasons several rounds of investigation did not find.
//
// EFI is the way round it. The firmware owns the hardware, brings up a console
// and a framebuffer itself, and hands an application services to use them - so
// a guest can print before it knows what it is running on. It also happens to
// be how a great many arm64 machines start something, which makes it worth
// having beyond this one problem.
//
// It needs a disk, because that is where EFI looks: a FAT volume with
// /EFI/BOOT/BOOTAA64.EFI on it. See the `efi` target in the Makefile.
//
//     vzefi <disk image> [seconds]

import Foundation
import Virtualization

func die(_ why: String) -> Never {
    FileHandle.standardError.write(("vzefi: " + why + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: vzefi <disk image> [seconds]") }
let disk = URL(fileURLWithPath: args[1])
guard FileManager.default.fileExists(atPath: disk.path) else {
    die("no such disk: \(disk.path)")
}

let boot = VZEFIBootLoader()

// Somewhere for the firmware to keep its own variables. It is created fresh
// each run: this is a test bed, and a boot order remembered from a previous
// experiment is a variable nobody meant to set.
let varsURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("armedit-efivars")
try? FileManager.default.removeItem(at: varsURL)
do {
    boot.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: varsURL)
} catch {
    die("could not create the EFI variable store: \(error)")
}

let config = VZVirtualMachineConfiguration()
config.bootLoader = boot
config.cpuCount = 1
config.memorySize = 512 * 1024 * 1024

do {
    let attachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
} catch {
    die("could not attach \(disk.lastPathComponent): \(error)")
}

// A console anyway, so that anything the firmware or the guest sends that way
// is not lost. The point of this path is that it does not depend on it.
let console = VZVirtioConsoleDeviceSerialPortConfiguration()
if let path = ProcessInfo.processInfo.environment["VZEFI_OUT"] {
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let out = FileHandle(forWritingAtPath: path) else { die("cannot write \(path)") }
    console.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: FileHandle(forReadingAtPath: "/dev/null")!,
        fileHandleForWriting: out)
} else {
    console.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: FileHandle.standardInput,
        fileHandleForWriting: FileHandle.standardOutput)
}
config.serialPorts = [console]

// A screen, because EFI's own console is a framebuffer one and there has to be
// something for it to draw on.
let display = VZMacGraphicsDisplayConfiguration(widthInPixels: 1280,
                                                heightInPixels: 800,
                                                pixelsPerInch: 80)
let graphics = VZVirtioGraphicsDeviceConfiguration()
graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280,
                                                          heightInPixels: 800)]
config.graphicsDevices = [graphics]
_ = display

do {
    try config.validate()
} catch {
    die("this configuration is not one the framework will accept: \(error)")
}

let queue = DispatchQueue(label: "vzefi")
let vm = VZVirtualMachine(configuration: config, queue: queue)

final class Watcher: NSObject, VZVirtualMachineDelegate {
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        FileHandle.standardError.write("vzefi: stopped: \(error)\n".data(using: .utf8)!)
        exit(2)
    }
    func guestDidStop(_ vm: VZVirtualMachine) {
        FileHandle.standardError.write("vzefi: the guest halted\n".data(using: .utf8)!)
        exit(0)
    }
}
let watcher = Watcher()
queue.sync { vm.delegate = watcher }

queue.async {
    vm.start { result in
        if case .failure(let error) = result { die("could not start: \(error)") }
        FileHandle.standardError.write("vzefi: started\n".data(using: .utf8)!)
    }
}

let seconds = Double(args.count > 2 ? args[2] : "20") ?? 20
Thread.sleep(forTimeInterval: seconds)
FileHandle.standardError.write("vzefi: time is up\n".data(using: .utf8)!)
exit(0)
