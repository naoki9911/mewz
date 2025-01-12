const std = @import("std");
const log = @import("log.zig");
const heap = @import("heap.zig");
const sync = @import("sync.zig");
const tcpip = @import("tcpip.zig");
const stream = @import("stream.zig");
const util = @import("util.zig");
const types = @import("wasi/types.zig");
const virtio_vsock = @import("drivers/virtio/vsock.zig");

pub var vsock_muxer: ?VsockMuxer = null;

const Header = virtio_vsock.Header;
const SpinLock = sync.SpinLock;
const Allocator = std.mem.Allocator;

const VirtioVsockOp = enum(u16) {
    VIRTIO_VSOCK_OP_INVALID = 0,
    VIRTIO_VSOCK_OP_REQUEST = 1,
    VIRTIO_VSOCK_OP_RESPONSE = 2,
    VIRTIO_VSOCK_OP_RST = 3,
    VIRTIO_VSOCK_OP_SHUTDOWN = 4,
    VIRTIO_VSOCK_OP_RW = 5,
    VIRTIO_VSOCK_OP_CREDIT_UPDATE = 6,
    VIRTIO_VSOCK_OP_CREDIT_REQUEST = 7,
};

const VIRTIO_VSOCK_SHUTDOWN_F_RECEIVE: u32 = 1;
const VIRTIO_VSOCK_SHUTDOWN_F_SEND: u32 = 2;

pub const VsockSocket = struct {
    muxer: *VsockMuxer,
    sock_type: SocketType,
    my_port: u32,
    peer_cid: u64 = 0,
    peer_port: u32 = 0,

    buffer: Buffer,
    buf_len: u32,
    fwd_cnt: u32 = 0,
    tx_cnt: u32 = 0,

    peer_buf_len: u32 = 0,
    peer_fwd_cnt: u32 = 0,

    fd: i32 = -1,
    flags: u16 = 0,
    state: State = .INIT,
    binded: bool = false,
    accepted_socks: AcceptedSocksFifo = AcceptedSocksFifo.init(),

    const AcceptedSocksFifo = std.fifo.LinearFifo(*VsockSocket, std.fifo.LinearFifoBufferType{ .Static = 10 });
    const Buffer = sync.SpinLock(util.RingBuffer);
    const Error = tcpip.Socket.Error;
    const Self = @This();

    const BUFFER_SIZE: usize = 16384;

    const State = enum(u8) {
        INIT = 0,
        LISTEN = 1,
        CONNECTING = 2,
        CONNECTED = 3,
        CLOSED = 4,
    };

    fn new(muxer: *VsockMuxer, initial_port: u32, sock_type: SocketType, allocator: Allocator) Allocator.Error!Self {
        const buffer = try heap.runtime_allocator.create(util.RingBuffer);
        buffer.* = try util.RingBuffer.new(BUFFER_SIZE, allocator);

        return Self{ .muxer = muxer, .sock_type = sock_type, .my_port = initial_port, .buffer = Buffer.new(buffer), .buf_len = @intCast(buffer.buffer.len) };
    }

    fn newConnected(muxer: *VsockMuxer, my_port: u32, peer_cid: u64, peer_port: u32, allocator: Allocator) Allocator.Error!Self {
        const buffer = try heap.runtime_allocator.create(util.RingBuffer);
        buffer.* = try util.RingBuffer.new(BUFFER_SIZE, allocator);

        return Self{
            .muxer = muxer,
            .sock_type = SocketType.Stream,
            .my_port = my_port,
            .peer_cid = peer_cid,
            .peer_port = peer_port,
            .buffer = Buffer.new(buffer),
            .buf_len = @intCast(buffer.buffer.len),
            .state = .CONNECTED,
        };
    }

    pub fn connect(self: *Self, cid: u64, port: u32) Error!void {
        if (self.state != .INIT) {
            return Error.Failed;
        }

        self.peer_cid = cid;
        self.peer_port = port;
        self.state = .CONNECTING;

        self.muxer.connect(self);

        // TODO: is non-blocking connect required?
        while (self.state == .CONNECTING) {
            continue;
        }

        // if not connected and nothing to read, then terminate the connection
        if (self.state != .CONNECTED and !(self.bytesCanRead() > 0)) {
            return Error.Failed;
        }
    }

    pub fn setHeader(self: *Self, buffer: []u8) void {
        buffer[3] = @intCast((self.my_port >> 24) & 0xFF);
        buffer[2] = @intCast((self.my_port >> 16) & 0xFF);
        buffer[1] = @intCast((self.my_port >> 8) & 0xFF);
        buffer[0] = @intCast((self.my_port >> 0) & 0xFF);
    }

    pub fn bind(self: *Self, port: u32) Error!void {
        if (self.state != .INIT) {
            return Error.Failed;
        }

        self.my_port = port;
        try self.muxer.bind(self);

        self.binded = true;
        return;
    }

    pub fn listen(self: *Self, backlog: usize) Error!void {
        // TODO: handle backlog
        _ = backlog;

        self.state = .LISTEN;
    }

    pub fn accept(self: *Self) Error!*Self {
        while (self.accepted_socks.readableLength() == 0) {
            if (self.isNonBlocking()) {
                return Error.Again;
            }
            continue;
        }

        if (self.accepted_socks.readItem()) |new_sock| {
            return new_sock;
        } else {
            return Error.Again;
        }
    }

    pub fn setFd(self: *Self, fd: i32) void {
        self.fd = fd;
    }

    pub fn read(self: *Self, buffer: []u8) Error!usize {
        while (true) {
            const buf = self.buffer.acquire();
            defer self.buffer.release();

            if (buf.availableToRead() > 0) {
                break;
            }

            // here socket does not have readable data.

            if (self.state != .CONNECTED) {
                // TODO: notify state as error code.
                return Error.Failed;
            }

            if (self.isNonBlocking()) {
                return Error.Again;
            }
        }

        const buf = self.buffer.acquire();
        defer self.buffer.release();

        const read_size = buf.read(buffer);
        self.fwd_cnt += @as(u32, @intCast(read_size));

        return read_size;
    }

    pub fn write(self: *Self, buffer: []const u8) Error!usize {
        log.debug.print("vsock.VsockSocket.write start\n");
        defer log.debug.print("vsock.VsockSocket.write done\n");
        if (self.state != .CONNECTED) {
            // TODO: notify state as error code.
            return Error.Failed;
        }

        var write_size = buffer.len;
        if (self.sock_type == .Stream) {
            log.debug.printf("peer_buf_len={} tx_cnt={} peer_fwd_cnt={}\n", .{ self.peer_buf_len, self.tx_cnt, self.peer_fwd_cnt });
            const left_credit: usize = @intCast(self.peer_buf_len + self.peer_fwd_cnt - self.tx_cnt);
            write_size = @min(buffer.len, left_credit);
        }

        var hdr = self.muxer.create_base_pkt(self.sock_type, self.peer_cid, self.my_port, self.peer_port, .VIRTIO_VSOCK_OP_RW, 0);
        hdr.len = @intCast(write_size);
        hdr.buf_alloc = self.buf_len;
        hdr.fwd_cnt = self.fwd_cnt;

        // is this OK?
        virtio_vsock.virtio_vsock.?.transmit(&hdr, buffer[0..write_size]);

        return write_size;
    }

    pub fn send(self: *Self, dst_cid: u64, dst_port: u32, buffer: []const u8) Error!usize {
        // FIXME: handle this
        self.state = .CONNECTED;
        self.peer_cid = dst_cid;
        self.peer_port = dst_port;
        return self.write(buffer);
    }

    pub fn shutdown(self: *Self) void {
        switch (self.state) {
            .CONNECTED => {
                self.muxer.send_op_base(self.sock_type, self.peer_cid, self.my_port, self.peer_port, .VIRTIO_VSOCK_OP_SHUTDOWN, VIRTIO_VSOCK_SHUTDOWN_F_RECEIVE | VIRTIO_VSOCK_SHUTDOWN_F_SEND);
            },
            .CONNECTING => {
                // abort connection initiation
                self.muxer.send_op_base(self.sock_type, self.peer_cid, self.my_port, self.peer_port, .VIRTIO_VSOCK_OP_RST, 0);
                self.state = .CLOSED;
            },
            .INIT, .LISTEN => {
                self.state = .CLOSED;
            },
            .CLOSED => {},
        }

        while (self.state != .CLOSED) {}
    }

    pub fn close(self: *Self) void {
        switch (self.state) {
            .CONNECTED => {
                self.muxer.send_op_base(self.sock_type, self.peer_cid, self.my_port, self.peer_port, .VIRTIO_VSOCK_OP_SHUTDOWN, VIRTIO_VSOCK_SHUTDOWN_F_RECEIVE | VIRTIO_VSOCK_SHUTDOWN_F_SEND);
            },
            .CONNECTING => {
                // abort connection initiation
                self.muxer.send_op_base(self.sock_type, self.peer_cid, self.my_port, self.peer_port, .VIRTIO_VSOCK_OP_RST, 0);
                self.state = .CLOSED;
            },
            .INIT, .LISTEN => {
                self.state = .CLOSED;
            },
            .CLOSED => {},
        }

        while (self.state != .CLOSED) {}
        self.muxer.removeSocket(self);
    }

    pub fn bytesCanRead(self: *Self) usize {
        const buf = self.buffer.acquire();
        defer self.buffer.release();

        return buf.availableToRead();
    }

    pub fn bytesCanWrite(self: *Self) usize {
        const buf = self.buffer.acquire();
        defer self.buffer.release();

        return buf.availableToWrite();
    }

    pub fn setFlags(self: *Self, flags: u16) void {
        self.flags = flags;
    }

    fn isNonBlocking(self: *Self) bool {
        return self.flags & types.FdFlag.NonBlock.toInt() != 0;
    }
};

pub const SocketType = enum(u16) {
    Stream = 1,
    Datagram = 3,
};

pub const VsockMuxer = struct {
    // key is concat(peer_port,my_port)
    sock_map: SpinLock(SockMap),

    // key is binded port
    bind_port_map: SpinLock(BindPortMap),

    allocator: Allocator,
    initial_port: u32 = 0xF0000000,

    const SockMap = std.AutoHashMap(u64, *VsockSocket);
    const BindPortMap = std.AutoHashMap(u32, void);
    const Error = tcpip.Socket.Error;

    const Self = @This();

    pub fn new(allocator: Allocator) Self {
        // TODO: not to allocate from heap
        const sock_map_slice = allocator.alloc(SockMap, 1) catch @panic("vsock.muxer: failed to alloc sock_map");
        const sock_map = @as(*SockMap, @ptrCast(sock_map_slice.ptr));
        sock_map.* = SockMap.init(allocator);

        // TODO: not to allocate from heap
        const bind_port_slice = allocator.alloc(BindPortMap, 1) catch @panic("vsock.muxer: failed to alloc bind_port_map");
        const bind_port_map = @as(*BindPortMap, @ptrCast(bind_port_slice.ptr));
        bind_port_map.* = BindPortMap.init(allocator);

        bind_port_map.put(124, void{}) catch @panic("vsock.muxer: failed to put port");

        return Self{
            .sock_map = SpinLock(SockMap).new(sock_map),
            .bind_port_map = SpinLock(BindPortMap).new(bind_port_map),
            .allocator = allocator,
        };
    }

    pub fn newSocket(self: *Self, sock_type: SocketType) *VsockSocket {
        // TODO: atomic get and increment
        const initial_port = self.initial_port;
        self.initial_port += 1;

        const new_sock = VsockSocket.new(self, initial_port, sock_type, self.allocator) catch @panic("TODO: vsock.muxer.newSocket: failed to create newSocket");
        const new_fd = stream.fd_table.set(stream.Stream{ .vsock = new_sock }) catch @panic("vsock.muxer.newSocket: failed to alloc new fd");
        const sock = stream.fd_table.get(new_fd) orelse @panic("vsock.muxer.newSocket: invalid fd");

        return &sock.vsock;
    }

    // assign fd and register accepted socket
    fn newSocketConnected(self: *Self, sock_map: *SockMap, my_port: u32, peer_cid: u64, peer_port: u32) *VsockSocket {
        const new_sock = VsockSocket.newConnected(self, my_port, peer_cid, peer_port, self.allocator) catch @panic("TODO: vsock.muxer.newSocket: failed to create newSocket");
        const new_fd = stream.fd_table.set(stream.Stream{ .vsock = new_sock }) catch @panic("vsock.muxer.newSocketConnected: failed to alloc new fd");
        const sock = &(stream.fd_table.get(new_fd) orelse @panic("vsock.muxer.newSocketConnected: invalid fd")).vsock;

        const key: u64 = @as(u64, sock.peer_port) << 32 | sock.my_port;
        if (sock_map.get(key)) |_| {
            // something is going wrong
            log.warn.printf("vsock.muxer: port {} is not allocated, but socket exists\n", .{sock.my_port});
            @panic("vsock.muxer: unexpected behavior");
        }
        sock_map.put(key, sock) catch @panic("vsock.muxer.bind: failed to put socket to socket map");

        return sock;
    }

    fn removeSocket(self: *Self, sock: *VsockSocket) void {
        const bind_port_map = self.bind_port_map.acquire();
        defer self.bind_port_map.release();

        const sock_map = self.sock_map.acquire();
        defer self.sock_map.release();

        if (sock.binded) {
            if (!bind_port_map.remove(sock.my_port)) {
                @panic("vsock.muxer: binded socket not found in bind_port_map");
            }
        }

        const key: u64 = @as(u64, sock.peer_port) << 32 | sock.my_port;
        _ = sock_map.remove(key);

        log.debug.printf("vsock.muxer: socket close (my_port={} peer_cid={} peer_port={})\n", .{ sock.my_port, sock.peer_cid, sock.peer_port });

        // fd_table owns VsockSocket, so we must remove this at the end of close() function.
        stream.fd_table.remove(sock.fd);
    }

    fn bind(self: *Self, sock: *VsockSocket) Error!void {
        const bind_port_map = self.bind_port_map.acquire();
        defer self.bind_port_map.release();

        const sock_map = self.sock_map.acquire();
        defer self.sock_map.release();

        if (bind_port_map.get(sock.my_port)) |_| {
            // if the port is already allocated, return error
            // TODO: Linux or POSIX like error
            return Error.Failed;
        }

        const key: u64 = @as(u64, sock.peer_port) << 32 | sock.my_port;
        if (sock_map.get(key)) |_| {
            // something is going wrong
            log.warn.printf("vsock.muxer: port {} is not allocated, but socket exists\n", .{sock.my_port});
            @panic("vsock.muxer: unexpected behavior");
        }

        bind_port_map.put(sock.my_port, void{}) catch @panic("vsock.muxer.bind: failed to put port to bind_port_map");
        sock_map.put(key, sock) catch @panic("vsock.muxer.bind: failed to put socket to socket map");
    }

    fn connect(self: *Self, sock: *VsockSocket) void {
        // if the socket is not binded, register the socket to sock_map
        if (!sock.binded) {
            const sock_map = self.sock_map.acquire();
            defer self.sock_map.release();

            const key: u64 = @as(u64, sock.peer_port) << 32 | sock.my_port;
            if (sock_map.get(key)) |_| {
                // something is going wrong
                log.fatal.printf("vsock.muxer: port {} is not allocated, but socket exists\n", .{sock.my_port});
                @panic("unexpected behavior");
            }
            sock_map.put(key, sock) catch @panic("vsock.muxer.connect: failed to put socket to socket map");
        }

        var hdr = self.create_base_pkt(sock.sock_type, sock.peer_cid, sock.my_port, sock.peer_port, .VIRTIO_VSOCK_OP_REQUEST, 0);
        hdr.buf_alloc = sock.buf_len;
        self.send_pkt(&hdr);
    }

    pub fn process_rx(self: *Self, hdr: *const Header, data: *const []u8) void {
        log.debug.printf("src_cid={} dst_cid={} src_port={} dst_port={}\n", .{ hdr.src_cid, hdr.dst_cid, hdr.src_port, hdr.dst_port });
        log.debug.printf("len={} type={} op={} flags={}\n", .{ hdr.len, hdr.typ, hdr.op, hdr.flags });
        log.debug.printf("data.len={}\n", .{data.len});
        if (hdr.op > @intFromEnum(VirtioVsockOp.VIRTIO_VSOCK_OP_CREDIT_REQUEST)) {
            log.warn.printf("vsock.muxer: invalid op code={}", .{hdr.op});
            return;
        }

        const op: VirtioVsockOp = @enumFromInt(hdr.op);
        switch (op) {
            .VIRTIO_VSOCK_OP_INVALID => self.handle_op_invalid(hdr),
            .VIRTIO_VSOCK_OP_REQUEST => self.handle_op_request(hdr),
            .VIRTIO_VSOCK_OP_RESPONSE => self.handle_op_response(hdr),
            .VIRTIO_VSOCK_OP_RST => self.handle_op_rst(hdr),
            .VIRTIO_VSOCK_OP_SHUTDOWN => self.handle_op_shutdown(hdr),
            .VIRTIO_VSOCK_OP_RW => self.handle_op_rw(hdr, data),
            .VIRTIO_VSOCK_OP_CREDIT_UPDATE => self.handle_op_credit_update(hdr),
            .VIRTIO_VSOCK_OP_CREDIT_REQUEST => self.handle_op_credit_request(hdr),
        }
    }

    fn handle_op_invalid(self: *Self, hdr: *const Header) void {
        _ = self; // autofix
        _ = hdr; // autofix
    }

    fn handle_op_request(self: *Self, hdr: *const Header) void {
        log.debug.print("vsock.muxer: received VSOCK_OP_REQUEST\n");
        const sock_map = self.sock_map.acquire();
        defer self.sock_map.release();

        if (sock_map.get(hdr.dst_port)) |vss| {
            log.debug.print("vsock.muxer: found socket\n");
            self.handleNewConnection(sock_map, hdr, vss);
        } else {
            // reject request
            log.debug.printf("vsock.muxer: not found socket (dst_port={})\n", .{hdr.dst_port});
            self.send_op_base(SocketType.Stream, hdr.src_cid, hdr.dst_port, hdr.src_port, .VIRTIO_VSOCK_OP_RST, 0);
        }
    }

    fn handle_op_response(self: *Self, hdr: *const Header) void {
        log.debug.print("vsock.muxer: received VSOCK_OP_RESPONSE\n");
        const sock_map = self.sock_map.acquire();
        defer self.sock_map.release();

        const key: u64 = @as(u64, hdr.src_port) << 32 | hdr.dst_port;
        if (sock_map.get(key)) |vss| {
            log.debug.print("vsock.muxer: found socket\n");
            if (vss.state != .CONNECTING) {
                log.warn.printf("vsock.muxer: socket(my_port={} peer_port={}) is not connecting\n", .{ vss.my_port, vss.peer_port });
                return;
            }

            vss.peer_buf_len = hdr.buf_alloc;
            vss.peer_fwd_cnt = hdr.fwd_cnt;
            vss.state = .CONNECTED;
            log.debug.printf("vsock.muxer: socket(my_port={} peer_port={}) is connected\n", .{ vss.my_port, vss.peer_port });
        } else {
            // reject request
            log.debug.print("vsock.muxer: not found socket\n");
            self.send_op_base(SocketType.Stream, hdr.src_cid, hdr.dst_port, hdr.src_port, .VIRTIO_VSOCK_OP_RST, 0);
        }
    }

    fn handle_op_rst(self: *Self, hdr: *const Header) void {
        log.debug.print("vsock.muxer: received VSOCK_OP_RST\n");
        const sock_map = self.sock_map.acquire();
        defer self.sock_map.release();

        const key: u64 = @as(u64, hdr.src_port) << 32 | hdr.dst_port;
        if (sock_map.get(key)) |vss| {
            log.debug.print("vsock.muxer: found socket\n");
            vss.state = .CLOSED;
        } else {
            log.debug.print("vsock.muxer: not found socket\n");
        }
    }

    fn handle_op_shutdown(self: *Self, hdr: *const Header) void {
        log.debug.print("vsock.muxer: received VSOCK_OP_SHUTDOWN\n");
        const sock_map = self.sock_map.acquire();
        defer self.sock_map.release();

        const key: u64 = @as(u64, hdr.src_port) << 32 | hdr.dst_port;
        if (sock_map.get(key)) |vss| {
            log.debug.print("vsock.muxer: found socket\n");
            vss.state = .CLOSED;
            log.debug.printf("vsock.muxer: socket(my_port={} peer_port={}) is closed\n", .{ vss.my_port, vss.peer_port });
            self.send_op_base(SocketType.Stream, vss.peer_cid, vss.my_port, vss.peer_port, .VIRTIO_VSOCK_OP_RST, 0);
        } else {
            log.debug.print("vsock.muxer: not found socket\n");
        }
    }

    fn handle_op_rw(self: *Self, hdr: *const Header, data: *const []u8) void {
        log.debug.print("vsock.muxer: received VSOCK_OP_RW\n");
        const sock_map = self.sock_map.acquire();
        defer self.sock_map.release();

        var key: u64 = @as(u64, hdr.src_port) << 32 | hdr.dst_port;

        if (hdr.typ == @intFromEnum(SocketType.Datagram)) {
            key = hdr.dst_port;
        }
        if (sock_map.get(key)) |vss| {
            log.debug.print("vsock.muxer: found socket\n");

            // update flow control values
            vss.peer_buf_len = hdr.buf_alloc;
            vss.peer_fwd_cnt = hdr.fwd_cnt;

            const buf = vss.buffer.acquire();
            defer vss.buffer.release();

            // this must be success because VirtioVsock has flow control.
            // TODO: handle buffer empty?
            buf.write(data.*) catch @panic("failed to write data");

            if (hdr.typ == @intFromEnum(SocketType.Stream)) {
                // we need to sent this CREDIT every rw?
                var resp_hdr = self.create_base_pkt(SocketType.Stream, vss.peer_cid, vss.my_port, vss.peer_port, .VIRTIO_VSOCK_OP_CREDIT_UPDATE, 0);
                resp_hdr.buf_alloc = vss.buf_len;
                resp_hdr.fwd_cnt = vss.fwd_cnt;
                self.send_pkt(&resp_hdr);
            }
        } else if (hdr.typ == @intFromEnum(SocketType.Stream)) {
            // reject request
            log.debug.print("vsock.muxer: not found socket\n");
            self.send_op_base(SocketType.Stream, hdr.src_cid, hdr.dst_port, hdr.src_port, .VIRTIO_VSOCK_OP_RST, 0);
        }
    }

    fn handle_op_credit_update(self: *Self, hdr: *const Header) void {
        log.debug.print("vsock.muxer: received VSOCK_OP_CREDIT_UPDATE\n");
        _ = self; // autofix
        _ = hdr; // autofix
    }

    fn handle_op_credit_request(self: *Self, hdr: *const Header) void {
        log.debug.print("vsock.muxer: received VSOCK_OP_CREDIT_REQUEST\n");
        _ = self; // autofix
        _ = hdr; // autofix
    }

    fn send_op_base(self: *Self, sock_type: SocketType, dst_cid: u64, src_port: u32, dst_port: u32, op: VirtioVsockOp, flags: u32) void {
        const hdr = self.create_base_pkt(sock_type, dst_cid, src_port, dst_port, op, flags);
        self.send_pkt(&hdr);
    }

    fn create_base_pkt(self: *Self, sock_type: SocketType, dst_cid: u64, src_port: u32, dst_port: u32, op: VirtioVsockOp, flags: u32) Header {
        _ = self; // autofix
        const hdr = Header{
            .src_cid = virtio_vsock.virtio_vsock.?.cid,
            .dst_cid = dst_cid,
            .src_port = src_port,
            .dst_port = dst_port,
            .len = 0,
            .typ = @intFromEnum(sock_type),
            .op = @intFromEnum(op),
            .flags = flags,
            .buf_alloc = @intCast(virtio_vsock.virtio_vsock.?.rx_ring.len),
            .fwd_cnt = 0,
        };

        return hdr;
    }

    fn send_pkt(self: *Self, hdr: *const Header) void {
        _ = self; // autofix
        virtio_vsock.virtio_vsock.?.transmit(hdr, null);
    }

    fn handleNewConnection(self: *Self, sock_map: *SockMap, hdr: *const Header, vss: *VsockSocket) void {
        // if socket is not ready or backlog is full, then reject the new connection.
        if (vss.state != .LISTEN or vss.accepted_socks.writableLength() == 0) {
            self.send_op_base(SocketType.Stream, hdr.src_cid, hdr.dst_port, hdr.src_port, .VIRTIO_VSOCK_OP_RST, 0);
            return;
        }

        const sock = self.newSocketConnected(sock_map, vss.my_port, hdr.src_cid, hdr.src_port);

        // update flow control values
        sock.peer_buf_len = hdr.buf_alloc;
        sock.peer_fwd_cnt = hdr.fwd_cnt;

        var resp_hdr = self.create_base_pkt(SocketType.Stream, sock.peer_cid, sock.my_port, sock.peer_port, .VIRTIO_VSOCK_OP_RESPONSE, 0);
        resp_hdr.buf_alloc = vss.buf_len;

        vss.accepted_socks.writeItem(sock) catch @panic("vsock.muxer: failed to write accepted socket");
        self.send_pkt(&resp_hdr);
    }
};

pub fn init() void {
    // ensure virtio.vsock is initialized
    if (virtio_vsock.virtio_vsock == null) {
        @panic("vsock.muxer: virtio.vsock is not initialized");
    }

    vsock_muxer = VsockMuxer.new(heap.runtime_allocator);
}
