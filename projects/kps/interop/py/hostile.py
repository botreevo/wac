# Hostile datagrams at a KPS listener: random bytes, truncated and forged QUIC long headers (including
# full-size Initials whose protection is garbage), forged short headers, STUN-shaped junk and a binding
# request that does not know the certhash. Usage: python3 hostile.py <ip> <port> [count]
import os, random, socket, struct, sys

ip, port = sys.argv[1], int(sys.argv[2])
count = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
rng = random.Random(7)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

def initial(size):
    dcid = os.urandom(rng.choice([0, 1, 8, 20, 21]))
    scid = os.urandom(rng.choice([0, 8, 20]))
    h = bytes([0xC3]) + struct.pack(">I", rng.choice([1, 1, 1, 0xff00001d, 0])) + bytes([len(dcid)]) + dcid
    h += bytes([len(scid)]) + scid + bytes([rng.choice([0, 0x40, 0xff])]) + struct.pack(">H", 0x4000 | rng.randrange(0, 0x3fff))
    return (h + os.urandom(max(0, size - len(h))))[:size]

def stun():
    body = os.urandom(rng.randrange(0, 60))
    return struct.pack(">HHI", rng.choice([1, 0x101, 0x111]), len(body), 0x2112A442) + os.urandom(12) + body

def binding_wrong_password():
    user = b"abcd:abcd"
    attr = struct.pack(">HH", 6, len(user)) + user + b"\0" * ((4 - len(user) % 4) % 4)
    attr += struct.pack(">HH", 8, 20) + os.urandom(20)
    return struct.pack(">HHI", 1, len(attr), 0x2112A442) + os.urandom(12) + attr

for i in range(count):
    k = int(os.environ["ONLY"]) if "ONLY" in os.environ else i % 7
    if k == 0: d = os.urandom(rng.randrange(1, 1500))
    elif k == 1: d = initial(1200 + rng.randrange(0, 200))
    elif k == 2: d = initial(rng.randrange(1, 60))
    elif k == 3: d = bytes([0x40 | rng.randrange(0, 64)]) + os.urandom(rng.randrange(0, 1300))
    elif k == 4: d = stun()
    elif k == 5: d = binding_wrong_password()
    else: d = bytes([rng.randrange(20, 64)]) + os.urandom(rng.randrange(0, 1300))   # DTLS-shaped
    s.sendto(d, (ip, port))
print("sent", count)
