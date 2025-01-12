use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use wasmedge_wasi_socket::socket::{Socket, SocketType, AddressFamily};

fn main() {
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), 1234);
    let sock = Socket::new(AddressFamily::Vsock, SocketType::Stream).unwrap();
    sock.bind(&addr).unwrap();
    sock.listen(10).unwrap();
    let mut buf: [u8; 100] = [0; 100];
    loop {
        let new_sock = sock.accept(false).unwrap();
        let recv_cnt = new_sock.recv(&mut buf).unwrap();
        let recv_utf8 = std::string::String::from_utf8((&buf[0..recv_cnt]).to_vec()).unwrap();
        println!("recv_cnt={} content={:?}", recv_cnt, recv_utf8);
        let sent_cnt = new_sock.send(&buf[0..recv_cnt]).unwrap();
        println!("sent_cnt={}", sent_cnt);
    }
}
