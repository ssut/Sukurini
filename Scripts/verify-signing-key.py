#!/usr/bin/env python3
import argparse
import base64
import binascii
import hashlib
import os
import plistlib
import sys

P = 2**255 - 19
D = -121665 * pow(121666, P - 2, P) % P
SQRT_MINUS_ONE = pow(2, (P - 1) // 4, P)


def fail(message):
    print("signing-key status=fail reason=%s" % message, file=sys.stderr, flush=True)
    sys.exit(1)


def recover_x(y):
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P)
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P != 0:
        x = (x * SQRT_MINUS_ONE) % P
    if x % 2 != 0:
        x = P - x
    return x


def base_point():
    y = 4 * pow(5, P - 2, P) % P
    return (recover_x(y) % P, y)


def point_add(first, second):
    x1, y1 = first
    x2, y2 = second
    t = D * x1 * x2 * y1 * y2
    x3 = (x1 * y2 + x2 * y1) * pow(1 + t, P - 2, P)
    y3 = (y1 * y2 + x1 * x2) * pow(1 - t, P - 2, P)
    return (x3 % P, y3 % P)


def scalar_mult(point, scalar):
    result = (0, 1)
    while scalar > 0:
        if scalar & 1:
            result = point_add(result, point)
        point = point_add(point, point)
        scalar >>= 1
    return result


def encode_point(point):
    x, y = point
    bits = [(y >> i) & 1 for i in range(255)] + [x & 1]
    return bytes(sum(bits[i * 8 + j] << j for j in range(8)) for i in range(32))


def public_key_from_seed(seed):
    digest = hashlib.sha512(seed).digest()
    scalar = 2**254 + sum(2**i * ((digest[i // 8] >> (i % 8)) & 1) for i in range(3, 254))
    return encode_point(scalar_mult(base_point(), scalar))


def load_seed(private_key, private_key_file):
    raw = private_key
    if private_key_file:
        if not os.path.exists(private_key_file):
            fail("private_key_file_missing path=%s" % private_key_file)
        with open(private_key_file, encoding="utf-8") as handle:
            raw = handle.read()
    if not raw or not raw.strip():
        fail("private_key_empty source=SPARKLE_PRIVATE_KEY")
    try:
        seed = base64.b64decode(raw.strip(), validate=True)
    except (binascii.Error, ValueError):
        fail("private_key_not_base64")
    if len(seed) != 32:
        fail("private_key_bad_length bytes=%d expected=32" % len(seed))
    return seed


def load_expected(info_plist):
    if not os.path.exists(info_plist):
        fail("info_plist_missing path=%s" % info_plist)
    with open(info_plist, "rb") as handle:
        contents = plistlib.load(handle)
    expected = contents.get("SUPublicEDKey", "")
    if not expected:
        fail("public_key_empty path=%s key=SUPublicEDKey" % info_plist)
    return expected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--info-plist", default="Support/Info.plist")
    parser.add_argument("--private-key-file", default="")
    args = parser.parse_args()

    seed = load_seed(os.environ.get("SPARKLE_PRIVATE_KEY", ""), args.private_key_file)
    expected = load_expected(args.info_plist)
    derived = base64.b64encode(public_key_from_seed(seed)).decode()

    if derived != expected:
        print("signing-key derived=%s expected=%s" % (derived, expected), file=sys.stderr, flush=True)
        fail("keypair_mismatch detail=private_key_does_not_match_SUPublicEDKey")

    print("signing-key status=ok public_key=%s" % derived, flush=True)


if __name__ == "__main__":
    main()
