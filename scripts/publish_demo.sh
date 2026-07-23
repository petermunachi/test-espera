#!/bin/sh
# Dogfood: npm publish triggers mint_scoped_credential when block_package_publish is false.
npm publish --dry-run 2>/dev/null || true
