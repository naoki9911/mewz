const mem = @import("../../mem.zig");
const heap = @import("../../heap.zig");
const log = @import("../../log.zig");
const pci = @import("../../pci.zig");
const param = @import("../../param.zig");
const interrupt = @import("../../interrupt.zig");
const mmio = @import("mmio.zig");
const common = @import("common.zig");

const VirtioVsockDeviceFeature = enum(u64) {
    VIRTIO_VSOCK_F_STREAM = 0,
    VIRTIO_VSOCK_F_SEQPACKET = 1,
    VIRTIO_VSOCK_F_NO_IMPLIED_STREAM = 1 << 1,
    VIRTIO_VSOCK_F_DGRAM = 1 << 3,

    VIRTIO_F_VERSION_1 = 1 << 32,
};

const VirtioVsockDeviceConfig = packed struct { guest_cid: u64 };

const PACKET_MAX_LEN: usize = 2048;

pub var virtio_vsock: ?VirtioVsock = null;

pub const Header = packed struct {
    src_cid: u64,
    dst_cid: u64,
    src_port: u32,
    dst_port: u32,
    len: u32,
    typ: u16,
    op: u16,
    flags: u32,
    buf_alloc: u32,
    fwd_cnt: u32,

    // acutual size is 44 bytes, but @sizeOf(Header) returns 48 bytes.
    // Use this field to get Header size.
    pub const Size = 44;
};

const VirtioVsock = struct {
    virtio: common.Virtio(VirtioVsockDeviceConfig),

    cid: u64,
    tx_ring_index: usize,
    rx_ring: []u8,
    tx_ring: []u8,
    event_ring: []u8,

    const Self = @This();

    fn new(virtio: common.Virtio(VirtioVsockDeviceConfig)) Self {
        const gcid = switch (virtio) {
            inline else => |*v| v.transport.device_config.guest_cid,
        };
        var self = Self{
            .virtio = virtio,
            .cid = gcid,
            .tx_ring_index = 0,
            .tx_ring = undefined,
            .rx_ring = undefined,
            .event_ring = undefined,
        };

        const rx_ring_len = @as(usize, @intCast(self.receiveq().num_descs));
        const tx_ring_len = @as(usize, @intCast(self.transmitq().num_descs));
        const event_ring_len = @as(usize, @intCast(self.eventq().num_descs));
        self.rx_ring = mem.boottime_allocator.?.alloc(u8, rx_ring_len * PACKET_MAX_LEN) catch @panic("virtio.vsock: rx ring alloc failed");
        self.tx_ring = mem.boottime_allocator.?.alloc(u8, tx_ring_len * PACKET_MAX_LEN) catch @panic("virtio.vsock: tx ring alloc failed");
        self.event_ring = mem.boottime_allocator.?.alloc(u8, event_ring_len * PACKET_MAX_LEN) catch @panic("virtio.vsock: event ring alloc failed");

        for (0..event_ring_len) |i| {
            const desc_buf = common.VirtqDescBuffer{
                .addr = @intFromPtr(&self.event_ring[i * PACKET_MAX_LEN]),
                .len = PACKET_MAX_LEN,
                .type = common.VirtqDescBufferType.WritableFromDevice,
            };
            var chain = [1]common.VirtqDescBuffer{desc_buf};
            self.eventq().enqueue(chain[0..1]);
            switch (self.virtio) {
                inline else => |*v| v.transport.notifyQueue(self.eventq()),
            }
        }

        for (0..rx_ring_len) |i| {
            const desc_buf = common.VirtqDescBuffer{
                .addr = @intFromPtr(&self.rx_ring[i * PACKET_MAX_LEN]),
                .len = PACKET_MAX_LEN,
                .type = common.VirtqDescBufferType.WritableFromDevice,
            };
            var chain = [1]common.VirtqDescBuffer{desc_buf};
            self.receiveq().enqueue(chain[0..1]);
            switch (self.virtio) {
                inline else => |*v| v.transport.notifyQueue(self.receiveq()),
            }
        }

        self.transmitq().avail.flags().* = common.VIRTQ_AVAIL_F_NO_INTERRUPT;

        return self;
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

    fn eventq(self: *Self) *common.Virtqueue {
        switch (self.virtio) {
            inline else => |v| return &v.virtqueues[2],
        }
    }

    pub fn transmit(
        self: *Self,
        hdr: *const Header,
        data: ?[]const u8,
    ) void {
        log.debug.print("virtio.vsock.VirtioVsock: transmit start\n");
        defer log.debug.print("virtio.vsock.VirtioVsock: transmit done\n");
        @setRuntimeSafety(false);

        const idx = self.tx_ring_index % self.transmitq().num_descs;
        const base = @intFromPtr(&self.tx_ring[idx * PACKET_MAX_LEN]);
        defer self.tx_ring_index +%= 1;

        const hdr_buf = @as([*]u8, @ptrFromInt(base));
        @memcpy(hdr_buf, @as([*]const u8, @ptrCast(hdr))[0..Header.Size]);

        //log.debug.printf("virtio.vsock.transmit: src_cid={} dst_cid={} src_port={} dst_port={}\n", .{ hdr.src_cid, hdr.dst_cid, hdr.src_port, hdr.dst_port });
        //log.debug.printf("virtio.vsock.transmit: len={} type={} op={} flags={}\n", .{ hdr.len, hdr.typ, hdr.op, hdr.flags });

        var desc = [2]common.VirtqDescBuffer{ common.VirtqDescBuffer{
            .addr = base,
            .len = @intCast(Header.Size),
            .type = common.VirtqDescBufferType.ReadonlyFromDevice,
        }, common.VirtqDescBuffer{
            .addr = base + @as(u64, @intCast(Header.Size)),
            .len = 0,
            .type = common.VirtqDescBufferType.ReadonlyFromDevice,
        } };

        if (data != null) {
            // TODO: handle this
            if (data.?.len > PACKET_MAX_LEN) {
                @panic("virtio.vscok.transmit: too large data");
            }

            const data_buf = @as([*]u8, @ptrFromInt(desc[1].addr));
            @memcpy(data_buf, data.?);

            desc[1].len = @intCast(data.?.len);
            self.transmitq().enqueue(desc[0..2]);
        } else {
            self.transmitq().enqueue(desc[0..1]);
        }

        switch (self.virtio) {
            inline else => |*v| v.transport.notifyQueue(self.transmitq()),
        }
    }

    pub fn receive(self: *Self) void {
        const isr = switch (self.virtio) {
            inline else => |*v| v.transport.getIsr(),
        };
        if (isr.isQueue()) {
            const rq = self.receiveq();
            while (rq.last_used_idx != rq.used.idx().*) {
                const chain = rq.popUsed(heap.runtime_allocator) catch @panic("failed to pop used descriptors") orelse continue;
                defer heap.runtime_allocator.free(chain.desc_list.?);
                const buf = rq.retrieveFromUsedDesc(chain, heap.runtime_allocator) catch @panic("virtio net receive failed");
                defer heap.runtime_allocator.free(buf);

                // Header has 44 bytes struct but @sizeOf returns 48 bytes (due to alignment?)
                if (buf.len < Header.Size) {
                    log.warn.printf("invalid packet len={} expected_len={}\n", .{ buf.len, Header.Size });
                    continue;
                }
                const hdr = @as(*Header, @alignCast(@ptrCast(buf.ptr)));
                log.debug.printf("virtio.vsock.receive: src_cid={} dst_cid={} src_port={} dst_port={}\n", .{ hdr.src_cid, hdr.dst_cid, hdr.src_port, hdr.dst_port });
                log.debug.printf("virtio.vsock.receive: len={} type={} op={} flags={}\n", .{ hdr.len, hdr.typ, hdr.op, hdr.flags });

                // TODO: performance may degraded due to unaligned access
                const data = buf[Header.Size..chain.total_len];
                _ = data;

                // call VsockMuxer
                //if (vsock_muxer.vsock_muxer) |*vmx| {
                //    vmx.process_rx(hdr, &data);
                //}

                rq.enqueue(chain.desc_list.?);
            }
        }
        switch (self.virtio) {
            inline else => |*v| v.transport.notifyQueue(self.receiveq()),
        }
    }
};

pub fn init(enable_pci: bool) void {
    log.debug.print("virtio.vsock: init is called\n");
    if (enable_pci) {
        for (pci.devices) |d| {
            var dev = d orelse continue;
            if (dev.config.vendor_id == 0x1af4 and dev.config.device_id == 0x1053) {
                initPCI(&dev);
                return;
            }
        }
    }
    for (param.params.mmio_devices) |d| {
        const dev = d orelse continue;
        if (dev.dev_reg.device_id == 19) {
            log.info.print("virtio.vsock: found mmio device\n");
            initMMIO(dev);
            log.info.print("virtio.vsock: initialized mmio device\n");
            return;
        }
    }
    log.debug.print("virtio.vsock: found device\n");
    @panic("virtio.vsock: not found");
}

fn initPCI(dev: *pci.Device) void {
    const virtio = common.VirtioPCI(VirtioVsockDeviceConfig)
        .new(dev, @intFromEnum(VirtioVsockDeviceFeature.VIRTIO_F_VERSION_1), 3, mem.boottime_allocator.?) catch @panic("virtio.vsock: init failed");
    log.debug.printf("virtio.vsock: guest CID is {}\n", .{virtio.transport.device_config.guest_cid});
    log.debug.print("virtio.vsock: virtio ring init done\n");

    virtio_vsock = VirtioVsock.new(.{ .pci = virtio });
    interrupt.registerIrq(virtio.transport.pci_dev.config.interrupt_line, handleIrq);
}

fn initMMIO(dev: mmio.MMIODevice) void {
    const virtio = mmio.VirtioMMIO(VirtioVsockDeviceConfig)
        .new(dev, @intFromEnum(VirtioVsockDeviceFeature.VIRTIO_F_VERSION_1), 3, mem.boottime_allocator.?) catch @panic("virtio.vsock: init failed");
    log.debug.printf("virtio.vsock: guest CID is {}\n", .{virtio.transport.device_config.guest_cid});
    log.debug.print("virtio.vsock: virtio ring init done\n");

    virtio_vsock = VirtioVsock.new(.{ .mmio = virtio });
    interrupt.registerIrq(virtio.transport.param.irq, handleIrq);
}

fn handleIrq(frame: *interrupt.InterruptFrame) void {
    _ = frame;
    log.debug.print("virtio.vsock: interrupt\n");
    defer log.debug.print("virtio.vsock: intruupt done\n");

    if (virtio_vsock) |*vs| {
        vs.receive();

        // acknowledge irq
        switch (vs.virtio) {
            .mmio => |*m| m.transport.common_config.interuupt_ack = 1,
            else => {},
        }
    } else {
        log.warn.print("virtio.vsock: not initialized yet\n");
    }
}
