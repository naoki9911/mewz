const std = @import("std");
const log = @import("log.zig");
const Ip4Address = std.os.linux.sockaddr;
const virtio_mmio = @import("drivers/virtio/mmio.zig");

const Params = struct {
    addr: ?u32 = null,
    subnetmask: ?u32 = null,
    gateway: ?u32 = null,
    mmio_devices: [10]?virtio_mmio.MMIODevice = [_]?virtio_mmio.MMIODevice{null} ** 10,
    mmio_device_num: usize = 0,

    pub fn isNetworkEnabled(self: Params) bool {
        return self.addr != null and self.subnetmask != null and self.gateway != null;
    }
};

pub var params = Params{};

// TODO: Add tests
pub fn parseFromArgs(args: []const u8) void {
    log.debug.printf("params = '{s}'\n", .{args});
    var params_itr = std.mem.splitScalar(u8, args, ' ');
    while (params_itr.next()) |part_raw| {
        var part = part_raw;
        // parse including eivonrment variables(e.g. "ip=192.168.10.1/24")
        if (part.len > 0 and part[0] == '"' and part[part.len - 1] == '"') {
            part = part[1 .. part.len - 1];
        }
        var kv = std.mem.splitScalar(u8, part, '=');

        const k = kv.next() orelse continue;
        const v = kv.next() orelse continue;

        if (std.mem.eql(u8, k, "ip")) {
            parseIp(v);
        } else if (std.mem.eql(u8, k, "gateway")) {
            params.gateway = parseIp4Address(v) orelse {
                @panic("invalid ip format");
            };
        } else if (std.mem.eql(u8, k, "virtio_mmio.device")) {
            if (params.mmio_device_num >= params.mmio_devices.len) {
                log.warn.printf("too many virtio_mmio devices. '{s}' is ignored\n", .{v});
                continue;
            }
            // TODO: error handle
            // 4K@0xd0004000:9 SIZE@ADDR:IRQ
            var iter = std.mem.splitScalar(u8, v, '@');
            const size_str = iter.next() orelse continue;
            // TODO: support non 4KiB device
            if (!std.mem.eql(u8, size_str, "4K")) {
                log.warn.printf("vrtio_mmio: size {s} is not supported\n", .{size_str});
                continue;
            }

            // addr_with_irq = 0xd0004000:9
            const addr_with_irq = iter.next() orelse continue;
            // addr_str = 0xd0004000
            iter = std.mem.splitScalar(u8, addr_with_irq, ':');
            const addr_str = iter.next() orelse continue;
            const irq_str = iter.next() orelse continue;
            // addr_str contains prefix '0x', so base=0 is specified.
            const addr = std.fmt.parseInt(usize, addr_str, 0) catch |err| {
                log.warn.printf("failed to parse {s}: {}\n", .{ addr_str, err });
                continue;
            };
            const irq_line = std.fmt.parseInt(u8, irq_str, 10) catch |err| {
                log.warn.printf("failed to parse {s}: {}\n", .{ irq_str, err });
                continue;
            };

            params.mmio_devices[params.mmio_device_num] = virtio_mmio.MMIODevice.from_param(.{
                .addr = addr,
                .size = 4096,
                .irq = irq_line,
            });
            params.mmio_device_num += 1;
        } else {
            continue;
        }
    }
}

fn parseIp(ip_str: []const u8) void {
    var parts = std.mem.splitScalar(u8, ip_str, '/');
    const ip = parts.next() orelse @panic("invalid ip format");
    const subnet = parts.next() orelse @panic("invalid ip format");
    if (parts.next()) |_| {
        @panic("invalid ip format");
    }

    params.addr = parseIp4Address(ip) orelse {
        @panic("invalid ip format");
    };

    var subnetmask: u32 = 0;
    const subnet_num = std.fmt.parseInt(u32, subnet, 10) catch {
        @panic("invalid subnet format");
    };
    if (subnet_num > 32) {
        @panic("invalid subnet format");
    }
    for (0..subnet_num) |i| {
        subnetmask |= @as(u32, 1) << @as(u5, @intCast(31 - i));
    }
    params.subnetmask = subnetmask;
}

// This function is a copy of std.net.Ip4Address.parse
fn parseIp4Address(buf: []const u8) ?u32 {
    var result: u32 = 0;
    const out_ptr = std.mem.asBytes(&result);

    var x: u8 = 0;
    var index: u8 = 0;
    var saw_any_digits = false;
    var has_zero_prefix = false;
    for (buf) |c| {
        if (c == '.') {
            if (!saw_any_digits) {
                return null; // invalid character
            }
            if (index == 3) {
                return null; // invalid end
            }
            out_ptr[index] = x;
            index += 1;
            x = 0;
            saw_any_digits = false;
            has_zero_prefix = false;
        } else if (c >= '0' and c <= '9') {
            if (c == '0' and !saw_any_digits) {
                has_zero_prefix = true;
            } else if (has_zero_prefix) {
                return null; // non canonical
            }
            saw_any_digits = true;
            x = std.math.mul(u8, x, 10) catch {
                return null; // overflow
            };
            x = std.math.add(u8, x, c - '0') catch {
                return null; // overflow
            };
        } else {
            return null; // invalid character
        }
    }
    if (index == 3 and saw_any_digits) {
        out_ptr[index] = x;
        return result;
    }

    return null; // incomplete
}
