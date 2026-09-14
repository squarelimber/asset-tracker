#!/usr/bin/env python3
"""Fail if an APK's v3 signature block carries no proof-of-rotation.

Android 9+ accepts an APK signed with a new certificate only when the v3
signature block carries a signing certificate lineage proving that the new
key succeeds the old one. Without it the install is rejected with a signature
mismatch and users have to uninstall first.

apksigner has no command that answers "does this APK carry a rotation?", so
this parses the APK Signing Block directly. Standard library only, so it runs
on a bare CI runner.

Exit code 0 when every APK carries the proof-of-rotation attribute, 1 otherwise.
"""
import struct
import sys

V3_BLOCK_ID = 0xF05368C0
PROOF_OF_ROTATION_ATTR_ID = 0x3BA06F8C
SIG_BLOCK_MAGIC = b"APK Sig Block 42"
EOCD_MAGIC = b"PK\x05\x06"


def read_v3_block(data):
    """Return the v3 block payload, or None when there is no v3 signature."""
    eocd = data.rfind(EOCD_MAGIC)
    if eocd < 0:
        raise ValueError("not a zip archive (no end-of-central-directory record)")
    cd_offset = struct.unpack_from("<I", data, eocd + 16)[0]
    if cd_offset < 24 or data[cd_offset - 16:cd_offset] != SIG_BLOCK_MAGIC:
        raise ValueError("no APK Signing Block - the APK is not signed")
    block_size = struct.unpack_from("<Q", data, cd_offset - 24)[0]
    start = cd_offset - block_size - 8
    cursor = start + 8
    end = cd_offset - 24
    while cursor < end:
        pair_len = struct.unpack_from("<Q", data, cursor)[0]
        pair_id = struct.unpack_from("<I", data, cursor + 8)[0]
        if pair_id == V3_BLOCK_ID:
            return data[cursor + 12:cursor + 8 + pair_len]
        cursor += 8 + pair_len
    return None


def carries_proof_of_rotation(v3_block):
    """Walk the v3 signers and their additional attributes."""
    signers_len = struct.unpack_from("<I", v3_block, 0)[0]
    signers = v3_block[4:4 + signers_len]
    cursor = 0
    while cursor < len(signers):
        signer_len = struct.unpack_from("<I", signers, cursor)[0]
        signer = signers[cursor + 4:cursor + 4 + signer_len]
        cursor += 4 + signer_len

        signed_len = struct.unpack_from("<I", signer, 0)[0]
        signed = signer[4:4 + signed_len]

        at = 0
        at += 4 + struct.unpack_from("<I", signed, at)[0]   # digests
        at += 4 + struct.unpack_from("<I", signed, at)[0]   # certificates
        at += 4                                             # minSdkVersion
        at += 4                                             # maxSdkVersion
        attrs_len = struct.unpack_from("<I", signed, at)[0]
        attrs = signed[at + 4:at + 4 + attrs_len]

        a = 0
        while a + 8 <= len(attrs):
            entry_len = struct.unpack_from("<I", attrs, a)[0]
            entry_id = struct.unpack_from("<I", attrs, a + 4)[0]
            if entry_id == PROOF_OF_ROTATION_ATTR_ID:
                return True
            if entry_len < 4:
                break
            a += 4 + entry_len
    return False


def main(paths):
    all_ok = True
    for path in paths:
        try:
            with open(path, "rb") as f:
                data = f.read()
            v3 = read_v3_block(data)
        except (OSError, ValueError, struct.error) as exc:
            print("%s: FAIL - %s" % (path, exc))
            all_ok = False
            continue

        if v3 is None:
            print("%s: FAIL - signed without APK Signature Scheme v3" % path)
            all_ok = False
            continue

        if carries_proof_of_rotation(v3):
            print("%s: OK - proof-of-rotation present in the v3 block" % path)
        else:
            print("%s: FAIL - v3 block carries no proof-of-rotation; "
                  "installs on Android 9+ would be rejected as a signature "
                  "mismatch" % path)
            all_ok = False

    return 0 if all_ok else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: check_apk_rotation.py <apk> [apk ...]")
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1:]))
