"""Linux integration test: python3 tests/native_bridge_drain.py /path/to/bridge.

Uses synthetic Ogg pages to test transport boundaries, not audio decoding.
"""
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import time


def page(serial, sequence, flags, body, granule=0):
    assert len(body) < 255
    return (b'OggS' + bytes([0, flags]) + struct.pack('<QII', granule, serial, sequence)
            + b'\0' * 4 + bytes([1, len(body)]) + body)


def headers(serial):
    ident = b'\x01vorbis' + b'\0' * 5 + struct.pack('<I', 44100)
    return (page(serial, 0, 2, ident) + page(serial, 1, 0, b'\x03vorbis')
            + page(serial, 2, 0, b'\x05vorbis'))


def wait_for(predicate):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError('bridge did not reach expected state')


def main(binary):
    with tempfile.TemporaryDirectory() as directory:
        marker = pathlib.Path(directory) / 'stream.ready'
        loading = pathlib.Path(directory) / 'loading'
        with socket.socket() as reserved:
            reserved.bind(('127.0.0.1', 0))
            port = reserved.getsockname()[1]
        process = subprocess.Popen(
            [binary, str(port), '--stream-marker', str(marker),
             '--loading-marker', str(loading)], stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            # EOF at the producer is deliberately absent: its FIFO stays open.
            process.stdin.write(headers(22))
            process.stdin.flush()
            wait_for(marker.exists)
            with socket.create_connection(('127.0.0.1', port), timeout=5) as client:
                client.sendall(b'GET /spotify.ogg HTTP/1.0\r\n\r\n')
                final = page(22, 3, 4, b'final-audio-page', 44100)
                process.stdin.write(final)
                process.stdin.flush()
                received = b''
                while True:
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    received += chunk
                assert received.split(b'\r\n\r\n', 1)[1] == headers(22) + final
                assert pathlib.Path(str(marker) + '.eos').read_text().strip() == '1:22'
                assert process.poll() is None  # Bridge survives a natural EOF.

            # The next stream must clear old EOF and remain independently usable.
            loading.write_text('next:2')
            process.stdin.write(headers(33))
            process.stdin.flush()
            wait_for(lambda: marker.read_text().strip() == '2:33')
            assert not pathlib.Path(str(marker) + '.eos').exists()
            with socket.create_connection(('127.0.0.1', port), timeout=5) as client:
                client.sendall(b'GET /spotify.ogg HTTP/1.0\r\n\r\n')
                final = page(33, 3, 4, b'next-audio-page', 44100)
                process.stdin.write(final)
                process.stdin.flush()
                received = b''
                while True:
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    received += chunk
                assert received.split(b'\r\n\r\n', 1)[1] == headers(33) + final
            # A manual loading marker must interrupt pacing, not wait for the
            # old track's future page or a natural output acknowledgement.
            process.stdin.write(headers(44))
            process.stdin.flush()
            wait_for(lambda: marker.read_text().strip() == '3:44')
            with socket.create_connection(('127.0.0.1', port), timeout=5) as client:
                client.sendall(b'GET /spotify.ogg HTTP/1.0\r\n\r\n')
                first = page(44, 3, 0, b'playing', 44100)
                process.stdin.write(first + page(44, 4, 0, b'future-audio', 4410000))
                process.stdin.flush()
                received = b''
                while not received.endswith(first):
                    received += client.recv(65536)
                began = time.monotonic()
                loading.write_text('manual-next:4')
                assert client.recv(65536) == b''
                assert time.monotonic() - began < 1.5
            process.stdin.write(headers(55))
            process.stdin.flush()
            wait_for(lambda: marker.read_text().strip() == '4:55')
            print('PASS: complete EOS/HTTP EOF, next stream, and manual skip interrupts pacing')
        finally:
            process.terminate()
            process.wait(timeout=5)


if __name__ == '__main__':
    main(sys.argv[1])
