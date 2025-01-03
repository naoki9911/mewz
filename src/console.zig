const uart = @import("uart.zig");
const virtio_console = @import("drivers/virtio/console.zig");

pub fn write(data: []const u8, enable_prefix: bool) usize {
    if (virtio_console.virtio_con) |vc| {
        if (vc.port0_opened and vc.port0_console) {
            if (enable_prefix) {
                vc.transmit("VC: ");
            }
            vc.transmit(data);
            return data.len;
        }
    }

    if (enable_prefix) {
        uart.puts("UART: ");
    }
    uart.puts(data);
    return data.len;
}
