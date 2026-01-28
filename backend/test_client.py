import socket
import json

def main():
    s = socket.socket()
    s.connect(('127.0.0.1', 8765))
    req = {'id': 1, 'cmd': 'ping'}
    s.send((json.dumps(req) + '\n').encode())
    data = b''
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
        if b'\n' in data:
            line, _ = data.split(b'\n', 1)
            print('RECV:', line.decode())
            break
    s.close()

if __name__ == '__main__':
    main()
