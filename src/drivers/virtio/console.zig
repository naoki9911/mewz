const common = @import("common.zig");
const heap = @import("../../heap.zig");
const interrupt = @import("../../interrupt.zig");
const log = @import("../../log.zig");
const lwip = @import("../../lwip.zig");
const mem = @import("../../mem.zig");
const pci = @import("../../pci.zig");
const param = @import("../../param.zig");
const uart = @import("../../uart.zig");
const virtio_mmio = @import("mmio.zig");

pub var virtio_con: ?*VirtioConsole = null;

extern fn rx_recv(data: *u8, len: u16) void;

const VirtioConsoleDeviceFeature = enum(u64) {
    VIRTIO_CONSOLE_F_SIZE = 1 << 0,
    VIRTIO_CONSOLE_F_MULTIPORT = 1 << 1,
    VIRTIO_CONSOLE_F_EMERG_WRITE = 1 << 2,
};

const VirtioConsoleControl = packed struct {
    id: u32,
    event: VirtioConsoleControlEvent,
    value: u16,
};

const VirtioConsoleControlEvent = enum(u16) {
    VIRTIO_CONSOLE_DEVICE_READY = 0,
    VIRTIO_CONSOLE_DEVICE_ADD = 1,
    VIRTIO_CONSOLE_DEVICE_REMOVE = 2,
    VIRTIO_CONSOLE_PORT_READY = 3,
    VIRTIO_CONSOLE_CONSOLE_PORT = 4,
    VIRTIO_CONSOLE_RESIZE = 5,
    VIRTIO_CONSOLE_PORT_OPEN = 6,
    VIRTIO_CONSOLE_PORT_NAME = 7,
};

const VirtioConsole = struct {
    virtio: common.Virtio(VirtioConsoleDeviceConfig),

    tx_ring_index: usize,
    tx_ring: []u8,
    rx_ring: []u8,

    // port0 states
    port0_added: bool = false,
    port0_console: bool = false,
    port0_opened: bool = false,

    ctrl_tx_ring_index: usize,
    ctrl_tx_ring: []u8,
    ctrl_rx_ring: []u8,

    const Self = @This();
    const BUF_LEN: usize = 1024;

    fn new(virtio: common.Virtio(VirtioConsoleDeviceConfig)) Self {
        var self = Self{
            .virtio = virtio,
            .tx_ring_index = 0,
            .tx_ring = undefined,
            .rx_ring = undefined,
            .ctrl_tx_ring_index = 0,
            .ctrl_tx_ring = undefined,
            .ctrl_rx_ring = undefined,
        };

        const tx_ring_len = @as(usize, @intCast(self.transmitq().num_descs));
        const rx_ring_len = @as(usize, @intCast(self.receiveq().num_descs));
        const ctrl_tx_ring_len = @as(usize, @intCast(self.ctrlTransmitq().num_descs));
        const ctrl_rx_ring_len = @as(usize, @intCast(self.ctrlReceiveq().num_descs));
        self.tx_ring = mem.boottime_allocator.?.alloc(u8, tx_ring_len * BUF_LEN) catch @panic("virtio console tx ring alloc failed");
        self.rx_ring = mem.boottime_allocator.?.alloc(u8, rx_ring_len * BUF_LEN) catch @panic("virtio console rx ring alloc failed");
        self.ctrl_tx_ring = mem.boottime_allocator.?.alloc(u8, ctrl_tx_ring_len * BUF_LEN) catch @panic("virtio console tx ring alloc failed");
        self.ctrl_rx_ring = mem.boottime_allocator.?.alloc(u8, ctrl_rx_ring_len * BUF_LEN) catch @panic("virtio console rx ring alloc failed");

        for (0..rx_ring_len) |i| {
            const desc_buf = common.VirtqDescBuffer{
                .addr = @intFromPtr(&self.rx_ring[i * BUF_LEN]),
                .len = BUF_LEN,
                .type = common.VirtqDescBufferType.WritableFromDevice,
            };
            var chain = [1]common.VirtqDescBuffer{desc_buf};
            self.receiveq().enqueue(chain[0..1]);
            switch (self.virtio) {
                inline else => |*v| v.transport.notifyQueue(self.receiveq()),
            }
        }
        for (0..ctrl_rx_ring_len) |i| {
            const desc_buf = common.VirtqDescBuffer{
                .addr = @intFromPtr(&self.ctrl_rx_ring[i * BUF_LEN]),
                .len = BUF_LEN,
                .type = common.VirtqDescBufferType.WritableFromDevice,
            };
            var chain = [1]common.VirtqDescBuffer{desc_buf};
            self.ctrlReceiveq().enqueue(chain[0..1]);
            switch (self.virtio) {
                inline else => |*v| v.transport.notifyQueue(self.ctrlReceiveq()),
            }
        }

        self.transmitq().avail.flags().* = common.VIRTQ_AVAIL_F_NO_INTERRUPT;
        self.ctrlTransmitq().avail.flags().* = common.VIRTQ_AVAIL_F_NO_INTERRUPT;

        self.ctrlTransmit(0, .VIRTIO_CONSOLE_DEVICE_READY, 1);
        self.ctrlReceiveHandle(handleCtrl);

        return self;
    }

    fn handleCtrl(self: *Self, ctrl: *VirtioConsoleControl) void {
        switch (ctrl.event) {
            .VIRTIO_CONSOLE_DEVICE_ADD => {
                // only accept port 0
                if (ctrl.id == 0) {
                    log.info.printf("virtio.console: ctrl port added (port={})\n", .{ctrl.id});
                    self.port0_added = true;
                    self.ctrlTransmit(ctrl.id, .VIRTIO_CONSOLE_PORT_READY, 1);
                } else {
                    log.warn.printf("virtio.console: ctrl port is not ready (port={})\n", .{ctrl.id});
                    self.ctrlTransmit(ctrl.id, .VIRTIO_CONSOLE_PORT_READY, 0);
                }
            },
            .VIRTIO_CONSOLE_CONSOLE_PORT => {
                if (ctrl.id != 0 or !self.port0_added) {
                    log.warn.printf("virtio.console: cannot use port{} as a console: not added\n", .{ctrl.id});
                } else {
                    self.port0_console = true;
                    log.info.print("virtio.console: port0 is specified as a console\n");
                    self.ctrlTransmit(0, .VIRTIO_CONSOLE_PORT_OPEN, 1);
                }
            },
            .VIRTIO_CONSOLE_PORT_OPEN => {
                if (ctrl.id != 0 or !self.port0_added) {
                    log.warn.printf("virtio.console: cannot open port{}: not added\n", .{ctrl.id});
                } else {
                    if (ctrl.value == 1) {
                        self.port0_opened = true;
                        log.info.print("virtio.console: port0 is opened\n");
                    } else if (ctrl.value == 0) {
                        self.port0_opened = false;
                        log.info.print("virtio.console: port0 is closed\n");
                    } else {
                        log.warn.printf("virtio.console: invalid value: {}\n", .{ctrl});
                    }
                }
            },
            .VIRTIO_CONSOLE_RESIZE => {
                log.warn.print("virtio.console: VIRTIO_CONSOLE_RESIZE is ignored\n");
            },
            else => log.warn.printf("virtio.console: ctrl event {} is not handled\n", .{ctrl.event}),
        }
    }

    fn receiveq(self: *Self) *common.Virtqueue {
        switch (self.virtio) {
            inline else => |v| return &v.virtqueues[0],
        }
    }

    fn transmitq(self: *Self) *common.Virtqueue {
        switch (self.virtio) {
            inline else => |v| return &v.virtqueues[1],
        }
    }

    pub fn transmit(
        self: *Self,
        data: []const u8,
    ) void {
        @setRuntimeSafety(false);

        var i: usize = 0;
        while (i < data.len) {
            const idx = self.tx_ring_index % self.transmitq().num_descs;
            const base = @intFromPtr(&self.tx_ring[idx * BUF_LEN]);
            defer self.tx_ring_index += 1;

            const len = @min(BUF_LEN, data.len - i);
            @memcpy(@as([*]u8, @ptrCast(&self.tx_ring[idx * BUF_LEN])), data[i .. i + len]);

            // TODO: handle large data as a descriptor chain.
            self.transmitq().enqueue(([_]common.VirtqDescBuffer{common.VirtqDescBuffer{
                .addr = base,
                .len = len,
                .type = common.VirtqDescBufferType.ReadonlyFromDevice,
            }})[0..1]);

            i += len;
        }

        switch (self.virtio) {
            inline else => |*v| v.transport.notifyQueue(self.transmitq()),
        }
    }

    pub fn receive(self: *Self) void {
        const isr = switch (self.virtio) {
            inline else => |*v| v.transport.getIsr(),
        };
        if (self.port0_opened and self.port0_added and self.port0_console) {
            return;
        }
        if (isr.isQueue()) {
            const rq = self.receiveq();
            while (rq.last_used_idx != rq.used.idx().*) {
                const used_elem = rq.popUsedOne() orelse continue;
                const buf = @as([*]u8, @ptrFromInt(rq.desc[used_elem.id].addr))[0..used_elem.len];
                _ = buf;

                rq.enqueue(([1]common.VirtqDescBuffer{common.VirtqDescBuffer{
                    .addr = rq.desc[used_elem.id].addr,
                    .len = BUF_LEN,
                    .type = common.VirtqDescBufferType.WritableFromDevice,
                }})[0..1]);
            }
            switch (self.virtio) {
                inline else => |*v| v.transport.notifyQueue(self.receiveq()),
            }

            self.ctrlReceiveHandle(handleCtrl);
        }
    }

    fn ctrlReceiveq(self: *Self) *common.Virtqueue {
        switch (self.virtio) {
            inline else => |v| return &v.virtqueues[2],
        }
    }

    fn ctrlTransmitq(self: *Self) *common.Virtqueue {
        switch (self.virtio) {
            inline else => |v| return &v.virtqueues[3],
        }
    }

    pub fn ctrlTransmit(
        self: *Self,
        id: u32,
        event: VirtioConsoleControlEvent,
        value: u16,
    ) void {
        @setRuntimeSafety(false);

        const idx = self.ctrl_tx_ring_index % self.ctrlTransmitq().num_descs;
        const base = @intFromPtr(&self.ctrl_tx_ring[idx * BUF_LEN]);
        defer self.ctrl_tx_ring_index += 1;

        const ctrl = @as(*VirtioConsoleControl, @ptrFromInt(base));
        ctrl.id = id;
        ctrl.event = event;
        ctrl.value = value;
        self.ctrlTransmitq().enqueue(([1]common.VirtqDescBuffer{common.VirtqDescBuffer{
            .addr = base,
            .len = @sizeOf(VirtioConsoleControl),
            .type = common.VirtqDescBufferType.ReadonlyFromDevice,
        }})[0..1]);

        switch (self.virtio) {
            inline else => |*v| v.transport.notifyQueue(self.ctrlTransmitq()),
        }
    }

    pub fn ctrlReceiveHandle(self: *Self, handler: fn (self: *Self, ctrl: *VirtioConsoleControl) void) void {
        const rq = self.ctrlReceiveq();
        while (rq.last_used_idx != rq.used.idx().*) {
            const used_elem = rq.popUsedOne() orelse continue;
            if (used_elem.len >= @sizeOf(VirtioConsoleControl)) {
                const ctrl = @as(*VirtioConsoleControl, @ptrFromInt(rq.desc[used_elem.id].addr));
                handler(self, ctrl);
            }
            rq.enqueue(([1]common.VirtqDescBuffer{common.VirtqDescBuffer{
                .addr = rq.desc[used_elem.id].addr,
                .len = BUF_LEN,
                .type = common.VirtqDescBufferType.WritableFromDevice,
            }})[0..1]);
        }

        switch (self.virtio) {
            inline else => |*v| v.transport.notifyQueue(self.ctrlReceiveq()),
        }
    }
};

const VirtioConsoleDeviceConfig = packed struct {};

pub fn init(enable_pci: bool) void {
    if (enable_pci) {
        for (pci.devices) |d| {
            var dev = d orelse continue;
            if (dev.config.vendor_id == 0x1af4 and dev.config.device_id == 0x1003) {
                log.info.print("virito.console: device found\n");
                initPCI(&dev);
                log.info.print("virito.console: initialized pci device\n");
                return;
            }
        }
    }
    for (param.params.mmio_devices) |d| {
        const dev = d orelse continue;
        if (dev.dev_reg.device_id == 3) {
            log.info.print("virtio.console: found mmio device\n");
            initMMIO(dev);
            log.info.print("virtio.console: initialized mmio device\n");
            return;
        }
    }
    log.warn.print("virtio console is not found\n");
}

fn initPCI(dev: *pci.Device) void {
    // TODO: VIRTIO_F_VERSION_1
    const virtio = common.VirtioPCI(VirtioConsoleDeviceConfig)
        .new(dev, (1 << 32) | @intFromEnum(VirtioConsoleDeviceFeature.VIRTIO_CONSOLE_F_MULTIPORT), 4, mem.boottime_allocator.?) catch @panic("virtio console init failed");

    const virtio_con_slice = mem.boottime_allocator.?.alloc(VirtioConsole, 1) catch @panic("virtio console alloc failed");
    virtio_con = @as(*VirtioConsole, @ptrCast(virtio_con_slice.ptr));
    virtio_con.?.* = VirtioConsole.new(.{ .pci = virtio });
    interrupt.registerIrq(virtio.transport.pci_dev.config.interrupt_line, handleIrq);
}

fn initMMIO(dev: virtio_mmio.MMIODevice) void {
    // TODO: VIRTIO_F_VERSION_1
    const virtio = virtio_mmio.VirtioMMIO(VirtioConsoleDeviceConfig).new(dev, (1 << 32) | @intFromEnum(VirtioConsoleDeviceFeature.VIRTIO_CONSOLE_F_MULTIPORT), 4, mem.boottime_allocator.?) catch @panic("virtio console init failed");
    const virtio_con_slice = mem.boottime_allocator.?.alloc(VirtioConsole, 1) catch @panic("virtio console alloc failed");
    virtio_con = @as(*VirtioConsole, @ptrCast(virtio_con_slice.ptr));
    virtio_con.?.* = VirtioConsole.new(.{ .mmio = virtio });
    interrupt.registerIrq(virtio.transport.param.irq, handleIrq);
}

fn handleIrq(frame: *interrupt.InterruptFrame) void {
    _ = frame;

    // Must use uart in virtio.console's logging
    // to avoid loop dependency on console output process.
    // TODO: switch console device depending on a device.

    //uart.puts("interrupt\n");
    //defer uart.puts("interrupt done\n");
    if (virtio_con) |vn| {
        vn.receive();
        // acknowledge irq
        switch (vn.virtio) {
            .mmio => |*m| m.transport.common_config.interuupt_ack = 1,
            else => {},
        }
    } else {
        @panic("virtio/console: handled interrupt, but the device is not registered");
    }
}

pub fn flush() void {
    if (virtio_con) |vn| {
        switch (vn.virtio) {
            inline else => |*v| v.transport.notifyQueue(vn.transmitq()),
        }
    } else {
        log.debug.printf("virtio/console: try to flush(), but the device is not registered\n", .{});
    }
}
