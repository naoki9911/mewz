const std = @import("std");

const tcpip = @import("tcpip.zig");
const wasi = @import("wasi.zig");
const log = @import("log.zig");
const vsock = @import("vsock.zig");
const stream = @import("stream.zig");

const Allocator = std.mem.Allocator;

pub const TsiSocket = struct {
    csock: ?*vsock.VsockSocket,
    csock_port: u32 = 0,
    bind_port: u32 = 0,
    dsock: *vsock.VsockSocket,

    // 192.168.1.1
    // TODO: FIX THIS
    peer_addr: tcpip.IpAddr = tcpip.IpAddr{
        .addr = 0xc0a80101,
    },
    // TODO: FIX THIS
    local_addr: tcpip.IpAddr = tcpip.IpAddr{
        .addr = 0xc0a80101,
    },
    fd: i32 = -1,

    const Self = @This();
    const Error = tcpip.Socket.Error;

    pub fn new(af: wasi.AddressFamily, allocator: Allocator) Allocator.Error!Self {
        _ = af;
        _ = allocator;
        const csock = vsock.vsock_muxer.?.newSocket(vsock.SocketType.Datagram);
        const dsock = vsock.vsock_muxer.?.newSocket(vsock.SocketType.Stream);

        return Self{
            .csock = csock,
            .dsock = dsock,
        };
    }

    pub fn bind(self: *Self, port: i32) Error!void {
        self.bind_port = @as(u32, @intCast(port));
        self.csock_port = 0xFFFF0000 | self.bind_port;
        try self.csock.?.bind(self.csock_port);
        try self.dsock.bind(self.bind_port);
    }

    pub fn listen(self: *Self, backlog: u32) Error!void {
        log.debug.print("tsi.TsiSocket.listen start\n");
        var create_req = [6]u8{ 0, 0, 0, 0, 1, 0 };
        self.csock.?.setHeader(&create_req);
        _ = try self.csock.?.send(2, 1024, &create_req);

        var listen_req = [18]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 4, 0xd2, 123, 0, 0, 0, 10, 0, 0, 0 };
        listen_req[8] = @intCast((self.bind_port >> 8) & 0xFF);
        listen_req[9] = @intCast((self.bind_port & 0xFF));

        listen_req[10] = @intCast((self.bind_port) & 0xFF);
        listen_req[11] = @intCast((self.bind_port >> 8) & 0xFF);
        listen_req[12] = @intCast((self.bind_port >> 16) & 0xFF);
        listen_req[13] = @intCast((self.bind_port >> 24) & 0xFF);
        self.csock.?.setHeader(&listen_req);
        _ = try self.csock.?.send(2, 1029, &listen_req);

        var listen_resp = [4]u8{ 0, 0, 0, 0 };
        _ = try self.csock.?.read(&listen_resp);
        const result: u32 = listen_resp[0] | @as(u32, listen_resp[1]) << 8 | @as(u32, listen_resp[2]) << 16 | @as(u32, listen_resp[3]) << 24;
        log.debug.printf("tsi: listen request result={x}\n", .{result});

        try self.dsock.listen(backlog);
    }

    pub fn accept(self: *Self) Error!*Self {
        const new_con = try self.dsock.accept();
        const new_sock = Self{
            .csock = null,
            .dsock = new_con,
        };

        const new_fd = stream.fd_table.set(stream.Stream{ .tsock = new_sock }) catch @panic("tsock.accept: failed to alloc new fd");
        const sock = &(stream.fd_table.get(new_fd) orelse @panic("tsock.accept: invalid fd")).tsock;
        return sock;
    }

    pub fn read(self: *Self, buffer: []u8) Error!usize {
        const size = try self.dsock.read(buffer);
        if (size != 0) {
            log.info.printf("tsi.TsiSocket.read len={}\n", .{size});
        }
        return size;
    }

    pub fn write(self: *Self, buffer: []u8) Error!usize {
        log.info.print("tsi.TsiSocket.write start\n");
        defer log.info.print("tsi.TsiSocket.write done\n");

        return self.dsock.write(buffer);
    }

    pub fn close(self: *Self) void {
        self.dsock.close();
        if (self.csock) |cs| {
            cs.close();
        }
    }

    pub fn shutdown(self: *Self) void {
        self.dsock.shutdown();
    }

    pub fn setFd(self: *Self, fd: i32) void {
        self.fd = fd;
    }

    pub fn bytesCanRead(self: *Self) usize {
        return self.dsock.bytesCanRead();
    }

    pub fn bytesCanWrite(self: *Self) usize {
        return self.dsock.bytesCanWrite();
    }

    pub fn getRemoteAddr(self: *Self) *tcpip.IpAddr {
        return &self.peer_addr;
    }

    pub fn getRemotePort(self: *Self) u16 {
        _ = self;
        return 1234;
    }

    pub fn getLocalAddr(self: *Self) *tcpip.IpAddr {
        return &self.local_addr;
    }

    pub fn getLocalPort(self: *Self) u16 {
        _ = self;
        return 1234;
    }
};
