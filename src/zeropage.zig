// Zero Page is a kind of Linux's booting protocol
// https://www.kernel.org/doc/html/next/x86/zero-page.html

const std = @import("std");
const log = @import("log.zig");

pub const OFFSET_E820_ENTRIES = 0x1E8;
pub const OFFSET_SETUP_HEADER = 0x1F1;
pub const OFFSET_E820_TABLE = 0x2D0;

pub const KERNEL_BOOT_FLAG_MAGIC = 0xaa55;
pub const KERNEL_HDR_MAGIC = 0x5372_6448;

pub const SetupHeader = packed struct {
    setup_sects: u8,
    root_flags: u16,
    syssize: u32,
    ram_size: u16,
    vid_mode: u16,
    root_dev: u16,
    boot_flag: u16,
    jump: u16,
    header: u32,
    version: u16,
    realmode_swtch: u32,
    start_sys_seg: u16,
    kernel_version: u16,
    type_of_loader: u8,
    loadflags: u8,
    setup_move_size: u16,
    code32_start: u32,
    ramdisk_image: u32,
    ramdisk_size: u32,
    bootsect_kludge: u32,
    heap_end_ptr: u16,
    ext_loader_ver: u8,
    ext_loader_type: u8,
    cmd_line_ptr: u32,
    initrd_addr_max: u32,
    kernel_alignment: u32,
    relocatable_kernel: u8,
    min_alignment: u8,
    xloadflags: u16,
    cmdline_size: u32,
    hardware_subarch: u32,
    hardware_subarch_data: u64,
    payload_offset: u32,
    payload_length: u32,
    setup_data: u64,
    pref_address: u64,
    init_size: u32,
    handover_offset: u32,
};

pub const E820Entry = extern struct {
    addr: u64 align(4),
    size: u64 align(4),
    type_: u32 align(4),
};

pub const ZeroPageInfo = struct {
    setup_header: *align(1) SetupHeader,
    e820_entry_num: u8,
    e820_entries: [*]E820Entry,
};

pub fn parseZeroPageInfo(base_addr: u64) ZeroPageInfo {
    const hdr = @as(*align(1) SetupHeader, @ptrFromInt(base_addr + OFFSET_SETUP_HEADER));

    if (hdr.boot_flag != KERNEL_BOOT_FLAG_MAGIC) {
        @panic("zeropage: invalid boot flag");
    }
    if (hdr.header != KERNEL_HDR_MAGIC) {
        @panic("zeropage: invalid header");
    }

    const e820_entry_num = @as(*u8, @ptrFromInt(base_addr + OFFSET_E820_ENTRIES)).*;
    log.info.printf("zeropage: e820_entries={}\n", .{e820_entry_num});
    const e820_entries = @as([*]E820Entry, @ptrFromInt(base_addr + OFFSET_E820_TABLE));

    return ZeroPageInfo{
        .setup_header = hdr,
        .e820_entry_num = e820_entry_num,
        .e820_entries = e820_entries,
    };
}
