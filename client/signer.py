"""Browz Forever : signature des versions du client (à lancer par Bellock, sur SON PC uniquement).

  py signer.py BrowzClient.exe        → écrit BrowzClient.exe.sig (à joindre à la release GitHub avec l'exe)

La clé privée est dans signature_privee.json (même dossier) : NE JAMAIS la publier ni l'envoyer à quelqu'un
(.gitignore l'exclut). Les clients ne s'installent une nouvelle version que si sa signature correspond à la clé
publique écrite dans browz_client.py : même si le compte GitHub était piraté, personne ne pourrait leur faire
installer un autre programme sans cette clé.
Signature RSA (PKCS#1 v1.5, SHA-256) en Python pur, sans bibliothèque à installer.
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KEY_PATH = os.path.join(HERE, "signature_privee.json")
DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")   # SHA-256 (PKCS#1)


def sign(data, n, d):
    k = (n.bit_length() + 7) // 8
    t = DIGEST_INFO + hashlib.sha256(data).digest()
    em = b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t
    return pow(int.from_bytes(em, "big"), d, n).to_bytes(k, "big")


def main():
    if len(sys.argv) < 2:
        print("Usage : py signer.py BrowzClient.exe")
        return 1
    if not os.path.exists(KEY_PATH):
        print("Clé privée introuvable :", KEY_PATH)
        return 1
    with open(KEY_PATH, encoding="utf-8") as f:
        key = json.load(f)
    n, d = int(key["n"], 16), int(key["d"], 16)
    path = sys.argv[1]
    with open(path, "rb") as f:
        sig = sign(f.read(), n, d)
    with open(path + ".sig", "w", encoding="ascii") as f:
        f.write(sig.hex())
    print("Signature écrite :", path + ".sig")
    return 0


if __name__ == "__main__":
    sys.exit(main())
