#!/usr/bin/env python3
"""Offline audit of public modem build identities and corresponding source."""
from verify_public_release import main

if __name__ == '__main__':
    main('public-build-verification.json')
