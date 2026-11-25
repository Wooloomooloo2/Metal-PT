#!/bin/bash
# Regenerates the website's golden fixtures from the committed run dirs in Tests/Fixtures/site/.
# Writes web/test/fixtures/<name>/{bundle.zip,run.json,samples.csv,summary.json,headers.json,expected.json}.
# expected.json = summary.json's values + { key, keyID, timestamp, signature } from the fixed test key
# (32 x 0x01) and timestamp 2026-11-25T12:00:00Z. Signatures are randomized ECDSA: the site verifies, never compares.
set -euo pipefail
cd "$(dirname "$0")/.."
KEY_HEX=$(printf '01%.0s' {1..32})
TS=2026-11-25T12:00:00Z
swift build --product mpt >/dev/null
for src in Tests/Fixtures/site/*/; do
  name=$(basename "$src")
  out="web/test/fixtures/$name"
  rm -rf "$out"
  .build/debug/mpt payload "$src" --out "$out" --test-key-hex "$KEY_HEX" --timestamp "$TS" >/dev/null
  python3 -I - "$out" <<'PY'
import base64, hashlib, json, sys
d = sys.argv[1]
summary = json.load(open(d + "/summary.json"))
h = json.load(open(d + "/headers.json"))
key = base64.urlsafe_b64decode(h["key"] + "=" * (-len(h["key"]) % 4))
exp = dict(summary)
exp.update({"key": h["key"], "keyID": hashlib.sha256(key).hexdigest()[:16],
            "timestamp": h["timestamp"], "signature": h["signature"]})
with open(d + "/expected.json", "w") as f:
    json.dump(exp, f, indent=2, sort_keys=True); f.write("\n")
PY
  echo "$name: $(python3 -I -c 'import json,sys; e=json.load(open(sys.argv[1])); print(e["medianFPS"], e["fpsPerWatt"], e["powerSource"], e["limiter"])' "$out/expected.json")"
done
