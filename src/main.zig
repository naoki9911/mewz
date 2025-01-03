const std = @import("std");
const options = @import("options");

const ioapic = @import("ioapic.zig");
const lapic = @import("lapic.zig");
const log = @import("log.zig");
const fs = @import("fs.zig");
const heap = @import("heap.zig");
const mem = @import("mem.zig");
const mewz_panic = @import("panic.zig");
const uart = @import("uart.zig");
const param = @import("param.zig");
const pci = @import("pci.zig");
const picirq = @import("picirq.zig");
const tcpip = @import("tcpip.zig");
const timer = @import("timer.zig");
const util = @import("util.zig");
const multiboot = @import("multiboot.zig");
const virtio_net = @import("drivers/virtio/net.zig");
const virtio_console = @import("drivers/virtio/console.zig");
const interrupt = @import("interrupt.zig");
const x64 = @import("x64.zig");
const zeropage = @import("zeropage.zig");

const wasi = @import("wasi.zig");

extern fn wasker_main() void;

pub const panic = mewz_panic.panic;

export fn bspEarlyInit(boot_magic: u32, boot_params: u32) align(16) callconv(.C) void {
    x64.init();

    uart.init();
    lapic.init();
    ioapic.init();
    picirq.init();
    timer.init();
    interrupt.init();
    if (boot_magic == 0x2badb002) {
        log.info.print("booted with multiboot1\n");
        const bootinfo = @as(*multiboot.BootInfo, @ptrFromInt(boot_params));
        printBootinfo(boot_magic, bootinfo);
        mem.init(bootinfo);
        param.parseFromArgs(util.getString(bootinfo.cmdline));
    } else {
        log.info.print("booted with linux zero page\n");
        const info = zeropage.parseZeroPageInfo(0x7000);
        mem.initWithZeroPage(info);
        const cmd_params = @as([*]u8, @ptrFromInt(info.setup_header.cmd_line_ptr))[0..info.setup_header.cmdline_size];
        param.parseFromArgs(cmd_params);
        for (param.params.mmio_devices) |dev_param| {
            if (dev_param) |d| {
                log.info.printf("virtio_mmio device detected: addr=0x{x} size=0x{x} IRQ={}\n", .{ d.param.addr, d.param.size, d.param.irq });
            }
        }
    }

    if (options.enable_pci) {
        pci.init();
        log.debug.print("pci init finish\n");
    }
    virtio_console.init(options.enable_pci);
    if (param.params.isNetworkEnabled()) {
        virtio_net.init(options.enable_pci);
    }

    mem.init2();
    if (virtio_net.virtio_net != null and param.params.isNetworkEnabled()) {
        tcpip.init(param.params.addr.?, param.params.subnetmask.?, param.params.gateway.?, &virtio_net.virtio_net.?.mac_addr);
    }
    fs.init();

    uart.putc('\n');

    asm volatile ("sti");

    if (virtio_console.virtio_con) |vc| {
        // wait for virtio.console to be available.
        while (!vc.port0_opened) {}
    }

    if (options.is_test) {
        wasi.integrationTest();
    }

    if (options.has_wasm) {
        wasker_main();
    }

    _ = wasi.memory_grow;
    _ = heap.sbrk;

    x64.shutdown(0);
    // libkrun traps this to shutdown itself.
    x64.i8042_reset();
    unreachable;
}

// ssize_t write(int fd, const void* buf, size_t count)
export fn write(fd: i32, b: *const u8, count: usize) callconv(.C) isize {
    if (fd == 1 or fd == 2) {
        const buf = @as([*]u8, @constCast(@ptrCast(b)))[0..count];
        log.fatal.print(buf);
        return @as(isize, @intCast(count));
    }
    return -1;
}

fn printBootinfo(magic: u32, bootinfo: *multiboot.BootInfo) void {
    log.debug.print("=== bootinfo ===\n");
    log.debug.printf("magic: {x}\n", .{magic});
    log.debug.printf("bootinfo addr: {x}\n", .{@intFromPtr(bootinfo)});
    log.debug.printf("flags: {b:0>8}\n", .{bootinfo.flags});
    log.debug.printf("mmap_addr: {x}\n", .{bootinfo.mmap_addr});
    log.debug.printf("mmap_length: {x}\n", .{bootinfo.mmap_length});
    const boot_loader_name = @as([*]u8, @ptrFromInt(bootinfo.boot_loader_name))[0..20];
    log.debug.printf("boot_loader_name: {s}\n", .{boot_loader_name});
    log.debug.print("================\n");
}
