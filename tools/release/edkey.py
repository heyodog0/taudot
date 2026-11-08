"""Ed25519 keys in Sparkle's file format (base64 of the 32-byte seed), for tests that mustn't touch the Keychain.

    uv run --no-project --with cryptography==44.0.2 python tools/release/edkey.py new FILE      writes a private key
    uv run --no-project --with cryptography==44.0.2 python tools/release/edkey.py public FILE   prints its public key

Releases use the key Sparkle's generate_keys keeps in the Keychain (docs/release.md), never a file.
"""

import base64
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def main() -> int:
    cmd, path = sys.argv[1], Path(sys.argv[2])
    if cmd == "new":
        k = Ed25519PrivateKey.generate()
        seed = k.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        path.write_text(base64.b64encode(seed).decode() + "\n")
        path.chmod(0o600)
        return 0
    if cmd == "public":
        seed = base64.b64decode(path.read_text().strip())[:32]
        pub = Ed25519PrivateKey.from_private_bytes(seed).public_key()
        print(base64.b64encode(pub.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode())
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
