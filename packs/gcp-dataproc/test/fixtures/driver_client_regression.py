"""Execute actual embedded client functions with real hostile child pipes."""
import json
import os
from pathlib import Path
import time

source = Path('/packs/gcp-dataproc/scripts/driver_log.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
source = source.rsplit('\ntry:\n    main()', 1)[0]
namespace = {'__name__': 'driver_client_regression'}
exec(compile(source, 'signed-driver-log', 'exec'), namespace)
Failure = namespace['Failure']
header = b'HTTP/1.1 206 Partial Content\r\nContent-Type: text/plain\r\n\r\n'
read = os.read
captured = []
def observed(fd, size):
    data = read(fd, size)
    captured.append(data)
    return data
os.read = observed
try:
    namespace['child'](['python3', '-I', '-c', 'import os,time;os.write(1,' + repr(header + b'x' * 40000) + ');time.sleep(60)'], cap=16389, seconds=3, http_cap=5)
    raise AssertionError('oversized body unexpectedly succeeded')
except Failure as exc:
    assert 'body byte limit' in str(exc), str(exc)
finally:
    os.read = read
assert sum(map(len, captured)) == len(header) + 6, sum(map(len, captured))
start = time.monotonic()
try:
    namespace['child'](['python3', '-I', '-c', 'import time;time.sleep(60)'], seconds=0.15)
    raise AssertionError('sleeping client unexpectedly succeeded')
except Failure as exc:
    assert 'deadline' in str(exc)
assert time.monotonic() - start < 2
# The same HTTP parser accepts a repeatable Vary header but rejects duplicate
# Content-Range framing. The transport is replaced only for parser unit cases.
namespace['child'] = lambda *args, **kwargs: (0, b'HTTP/1.1 206 Partial Content\r\nVary: Origin\r\nVary: Accept-Encoding\r\nContent-Range: bytes 0-0/1\r\n\r\nx')
assert namespace['http']('https://storage.googleapis.com/example', 'fixture-token', 1)[2] == b'x'
namespace['child'] = lambda *args, **kwargs: (0, b'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/1\r\nContent-Range: bytes 1-1/2\r\n\r\nx')
try:
    namespace['http']('https://storage.googleapis.com/example', 'fixture-token', 1)
    raise AssertionError('duplicate range unexpectedly succeeded')
except Failure as exc:
    assert 'duplicate framing' in str(exc)
print(json.dumps({'independent_body_limit_plus_one': True, 'actual_child_deadline_and_reap': True,
                  'repeatable_headers_accepted': True, 'duplicate_range_rejected': True}))
