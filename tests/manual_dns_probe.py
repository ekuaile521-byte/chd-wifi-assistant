"""Read-only diagnostic for one DNS A-record query, bound to one local IPv4 address."""
import socket
import struct
import sys

local_ip, dns_ip, host = sys.argv[1:4]
name = b"".join(bytes([len(label)]) + label.encode("ascii") for label in host.split(".")) + b"\0"
packet = struct.pack("!HHHHHH", 0x2C42, 0x0100, 1, 0, 0, 0) + name + struct.pack("!HH", 1, 1)
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
    client.settimeout(3)
    client.bind((local_ip, 0))
    client.sendto(packet, (dns_ip, 53))
    response, _ = client.recvfrom(4096)
print("DNS response bytes:", response.hex())
