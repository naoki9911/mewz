const std = @import("std");
const log = @import("../../log.zig");
const ioapic = @import("../../ioapic.zig");
const x64 = @import("../../x64.zig");
const common = @import("common.zig");

pub fn VirtioMMIO(comptime DeviceConfigType: type) type {
    return struct {
        transport: MMIOTransport(DeviceConfigType),
        virtqueues: []common.Virtqueue,

        const Self = @This();

        pub fn new(dev: MMIODevice, features: u64, queue_num: u32, allocator: std.mem.Allocator) !Self {
            var transport = MMIOTransport(DeviceConfigType).new(dev);

            // TODO: volatile
            transport.common_config.status = common.DeviceStatus.RESET.toInt();
            x64.mfence();

            transport.common_config.status |= common.DeviceStatus.ACKNOWLEDGE.toInt();
            x64.mfence();

            transport.common_config.status |= common.DeviceStatus.DRIVER.toInt();
            x64.mfence();

            const device_features = transport.common_config.read_device_feature();
            log.debug.printf("virtio.mmio: device_features=0x{}\n", .{device_features});
            if ((device_features & features) != features) {
                @panic("virtio net does not support required features");
            }
            transport.common_config.write_driver_feature(features);
            x64.mfence();

            transport.common_config.status |= common.DeviceStatus.FEATURES_OK.toInt();
            x64.mfence();

            // this reads only 1 byte and cause warning
            var status = transport.common_config.status;
            x64.mfence();
            if ((status & common.DeviceStatus.FEATURES_OK.toInt()) == 0) {
                @panic("virtio net failed to set FEATURES_OK");
            }
            x64.mfence();

            const virtqueues = try allocator.alloc(common.Virtqueue, queue_num);
            for (0..queue_num) |i| {
                const queue_index = @as(u16, @intCast(i));

                transport.common_config.queue_sel = queue_index;
                x64.mfence();

                if (transport.common_config.queue_ready != 0) {
                    log.fatal.printf("virtio.mmio: virtqueue[{}] is not ready", .{i});
                    @panic("virio.mmio is not available");
                }

                const queue_size: u16 = @intCast(transport.common_config.queue_size_max & 0xFFFF);
                log.debug.printf("virtio.mmio: virtqueue[{}] queue size is {}\n", .{ i, queue_size });
                if (queue_size == 0) {
                    log.fatal.printf("virtio.mmio: virtqueue[{}] is not avaiable", .{i});
                    @panic("virio.mmio is not available");
                }

                const virtqueue = try common.Virtqueue.new(queue_index, queue_size, allocator);
                transport.common_config.queue_size = queue_size;
                const desc = @as(u64, @intFromPtr(virtqueue.desc));
                const driver = @as(u64, @intCast(virtqueue.avail.addr()));
                const device = @as(u64, @intCast(virtqueue.used.addr()));
                transport.common_config.queue_desc_low = @intCast(desc & 0xFFFFFFFF);
                transport.common_config.queue_desc_high = @intCast(desc >> 32);
                transport.common_config.queue_driver_low = @intCast(driver & 0xFFFFFFFF);
                transport.common_config.queue_driver_high = @intCast(driver >> 32);
                transport.common_config.queue_device_low = @intCast(device & 0xFFFFFFFF);
                transport.common_config.queue_device_high = @intCast(device >> 32);
                x64.mfence();
                transport.common_config.queue_ready = 1;
                virtqueues[i] = virtqueue;
                x64.mfence();
            }

            ioapic.ioapicenable(dev.param.irq, 0);

            x64.mfence();
            status = transport.common_config.status;
            x64.mfence();
            status |= common.DeviceStatus.DRIVER_OK.toInt();
            transport.common_config.status = status;
            x64.mfence();

            return Self{
                .transport = transport,
                .virtqueues = virtqueues,
            };
        }
    };
}

pub fn MMIOTransport(comptime DeviceConfigType: type) type {
    return struct {
        common_config: *volatile DeviceRegister,
        device_config: *volatile DeviceConfigType,
        param: MMIODeviceParam,

        const Self = @This();
        pub fn new(dev: MMIODevice) Self {
            return Self{
                .common_config = dev.dev_reg,
                .device_config = @ptrFromInt(dev.param.addr + 0x100),
                .param = dev.param,
            };
        }

        pub fn notifyQueue(self: *Self, virtq: *common.Virtqueue) void {
            self.common_config.queue_sel = virtq.index;
            x64.mfence();
            self.common_config.queue_notify = virtq.index;
            virtq.not_notified_num_descs = 0;
        }

        pub fn getIsr(self: *Self) common.IsrStatus {
            const isr = self.common_config.interrupt_status;
            //log.debug.printf("ISR={}\n", .{isr});
            return @as(common.IsrStatus, @enumFromInt(isr));
        }
    };
}

pub const MMIODeviceParam = struct {
    addr: usize,
    size: usize,
    irq: u8,
};

pub const MMIODevice = struct {
    param: MMIODeviceParam,
    dev_reg: *volatile DeviceRegister,

    const Self = @This();
    pub fn from_param(param: MMIODeviceParam) Self {
        return MMIODevice{
            .param = param,
            .dev_reg = (@ptrFromInt(param.addr)),
        };
    }
};

// https://docs.oasis-open.org/virtio/virtio/v1.3/csd01/virtio-v1.3-csd01.html
// 4.2.2 MMIO Device Register Layout
pub const DeviceRegister = packed struct {
    magic: u32, // 0x000
    version: u32, // 0x004
    device_id: u32, // 0x008
    vendor_id: u32, // 0x00C
    device_features: u32, // 0x010
    device_features_sel: u32, // 0x014
    _pad1: u64, // 0x018
    driver_features: u32, // 0x020
    driver_features_sel: u32, // 0x024
    _pad2: u64, // 0x28
    queue_sel: u32, // 0x30
    queue_size_max: u32, // 0x34
    queue_size: u32, // 0x38
    _pad3: u64, // 0x3C
    queue_ready: u32, // 0x44
    _pad4: u64, // 0x48
    queue_notify: u32, // 0x50
    _pad5: u32, // 0x54
    _pad6: u64, // 0x58
    interrupt_status: u32, // 0x60
    interuupt_ack: u32, // 0x64
    _pad7: u64, // 0x68,
    status: u32, // 0x70
    _pad8: u32, // 0x74
    _pad9: u64, // 0x78
    queue_desc_low: u32, // 0x80
    queue_desc_high: u32, // 0x84
    _pad10: u64, // 0x88
    queue_driver_low: u32, // 0x90
    queue_driver_high: u32, // 0x94
    _pad11: u64, // 0x98
    queue_device_low: u32, // 0xa0
    queue_device_high: u32, // 0xa4
    _pad12: u32, // 0xa8
    shm_sel: u32, // 0xac
    shm_len_low: u32, // 0xb0
    shm_len_high: u32, // 0xb4
    shm_base_low: u32, // 0xb8
    shm_base_high: u32, // 0xbc
    queue_reset: u32, // 0xc0

    const Self = @This();

    pub fn read_device_feature(self: *volatile Self) u64 {
        // TODO: mfence is actually needed?

        var value: u64 = 0;
        self.device_features_sel = 0;
        x64.mfence();
        value |= @as(u64, self.device_features);
        x64.mfence();
        self.device_features_sel = 1;
        x64.mfence();
        value |= @as(u64, self.device_features) << 32;
        x64.mfence();
        return value;
    }
    pub fn write_driver_feature(self: *volatile Self, value: u64) void {
        // TODO: mfence is actually needed?

        self.driver_features_sel = 0;
        x64.mfence();
        self.driver_features = @as(u32, @intCast(value & 0xffffffff));
        x64.mfence();
        self.driver_features_sel = 1;
        x64.mfence();
        self.driver_features = @as(u32, @intCast(value >> 32));
        x64.mfence();
    }
};
