#!/usr/bin/env python3
"""
Simple backend CLI stub for demoing stdin/stdout IPC with a frontend.

Supported commands (one per line):
- ping -> responds 'pong'
- time -> responds with ISO timestamp
- quit|exit -> respond 'bye' and exit
- anything else -> echo back with prefix
"""
import sys
from datetime import datetime


def main():
    print('backend: ready', flush=True)
    for raw in sys.stdin:
        line = raw.rstrip('\n')
        if not line:
            continue
        if line.lower() in ('quit', 'exit'):
            print('bye', flush=True)
            break
        if line.lower() == 'ping':
            print('pong', flush=True)
            continue
        if line.lower() == 'time':
            print(datetime.utcnow().isoformat() + 'Z', flush=True)
            continue
        print(f'echo: {line}', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'error: {exc}', file=sys.stderr, flush=True)
        sys.exit(1)
