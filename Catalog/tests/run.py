#!/usr/bin/env python3
"""Test catalog validation with ephemeral keys; never read a release private key."""
import base64
import pathlib
import re
import runpy
import shutil
import subprocess
import tempfile


def command(*args, check=True):
    return subprocess.run(args, check=check, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def constant(source, name):
    matches = re.findall(r'\b' + re.escape(name) + r' = "([^"]*)"', source)
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one {name} constant")
    return matches[0]


def replace_constant(source, name, value):
    result, count = re.subn(
        r'(\b' + re.escape(name) + r' = ")[^"]*(")',
        lambda match: match[1] + value + match[2], source)
    if count != 1:
        raise ValueError(f"Expected exactly one {name} constant")
    return result


def main():
    root = pathlib.Path(__file__).resolve().parents[2]
    catalog = root / "Catalog"
    tests = catalog / "tests"
    # Production-signed update fixtures and any signing keys must not be shipped.
    forbidden = list(tests.rglob("*.sig")) + list(tests.rglob("*.pem"))
    if forbidden:
        raise ValueError("Test fixtures must contain JSON only, without stored signatures or keys")
    crypto = runpy.run_path(str(catalog / "tools/catalog.py"))
    payload = (catalog / "verified-apps.json").read_bytes()
    signature = base64.b64decode((catalog / "verified-apps.sig").read_text().strip(), validate=True)
    public_key = catalog / "catalog-public-key.pem"
    public_der = command("openssl", "pkey", "-pubin", "-in", str(public_key), "-outform", "DER").stdout
    if len(public_der) != 91 or public_der[-65] != 4:
        raise ValueError("Expected an uncompressed P-256 verification key")
    key_base64 = base64.b64encode(public_der[-65:]).decode()
    source_specs = [
        ("MacIMEI/Sources/VerifiedCatalog.swift", "publicKeyBase64", "baselinePayload", "baselineSignature"),
        ("Windows_x64/src/VerifiedCatalog.cs", "PublicKeyBase64", "BaselinePayload", "BaselineSignature"),
    ]
    originals = {}
    for name, key_name, payload_name, signature_name in source_specs:
        source = (root / name).read_text()
        if constant(source, key_name) != key_base64:
            raise ValueError(f"Embedded production key differs: {name}")
        if base64.b64decode(constant(source, payload_name), validate=True) != payload:
            raise ValueError(f"Embedded production payload differs: {name}")
        if base64.b64decode(constant(source, signature_name), validate=True) != signature:
            raise ValueError(f"Embedded production signature differs: {name}")
        originals[name] = source

    with tempfile.TemporaryDirectory(prefix="zte-catalog-tests-") as temporary:
        work = pathlib.Path(temporary)
        signature_der = work / "production-signature.der"
        signature_der.write_bytes(crypto["der_signature"](signature))
        verify = ["openssl", "dgst", "-sha256", "-verify", str(public_key), "-signature", str(signature_der)]
        command(*verify, str(catalog / "verified-apps.json"))
        altered = work / "altered-production.json"
        altered.write_bytes(bytes([payload[0] ^ 1]) + payload[1:])
        if command(*verify, str(altered), check=False).returncode == 0:
            raise ValueError("Production signature unexpectedly accepted tampered data")
        print("PASS production baseline signature, pinned constants and tamper rejection", flush=True)

        # Key material exists only in the mode-0700 temporary directory, is never
        # copied into the public tree and is deleted when the test process exits.
        private_key = work / "ephemeral-test-key.pem"
        private_key.write_bytes(command("openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout").stdout)
        private_key.chmod(0o600)
        test_der = command("openssl", "pkey", "-in", str(private_key), "-pubout", "-outform", "DER").stdout
        test_key_base64 = base64.b64encode(test_der[-65:]).decode()
        if test_key_base64 == key_base64:
            raise ValueError("Test and production keys must be different")

        def sign(path):
            der = command("openssl", "dgst", "-sha256", "-sign", str(private_key), str(path)).stdout
            return base64.b64encode(crypto["raw_signature"](der)).decode()

        test_signature = sign(catalog / "verified-apps.json")
        isolated = work / "repository"
        isolated_tests = isolated / "Catalog/tests"
        (isolated_tests / "fixtures").mkdir(parents=True)
        for fixture in sorted((tests / "fixtures").glob("*.json")):
            destination = isolated_tests / "fixtures" / fixture.name
            shutil.copyfile(fixture, destination)
            destination.with_suffix(".sig").write_text(sign(destination) + "\n")
        for name in ["VerifiedCatalogTests.swift", "dotnet/Program.cs", "dotnet/CatalogTests.csproj"]:
            destination = isolated_tests / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(tests / name, destination)
        for name, key_name, _, signature_name in source_specs:
            source = replace_constant(originals[name], key_name, test_key_base64)
            source = replace_constant(source, signature_name, test_signature)
            destination = isolated / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(source)
        # Payload and validator logic are identical to production. Only trust
        # constants in the temporary copies use the ephemeral test key/signature.
        binary = work / "catalog-swift-tests"
        subprocess.run([
            "swiftc", "-parse-as-library", "-module-cache-path", str(work / "module-cache"),
            str(isolated / source_specs[0][0]), str(isolated_tests / "VerifiedCatalogTests.swift"),
            "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary), str(isolated / "Catalog")], check=True)
        subprocess.run([
            "dotnet", "run", "--project", str(isolated_tests / "dotnet/CatalogTests.csproj"),
            "--", str(isolated / "Catalog"),
        ], check=True)
    for name, source in originals.items():
        if (root / name).read_text() != source:
            raise ValueError(f"Production source changed during tests: {name}")
    print("PASS production sources unchanged; ephemeral keys and build output removed")


if __name__ == "__main__":
    main()
