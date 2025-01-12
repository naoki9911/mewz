import socket

sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
sock.connect((3, 1234))

msg = "Hello from host"
sock.send(msg.encode())
res = sock.recv(1024).decode()
print("res = {}".format(res))

sock.close()
