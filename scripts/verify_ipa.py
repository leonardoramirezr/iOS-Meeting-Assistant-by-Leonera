#!/usr/bin/env python3
"""Verifica que cada bundle (.app/.appex) del IPA lleve un embedded.mobileprovision Ad Hoc.

Uso: verify_ipa.py ruta/al.ipa

Imprime el tipo de perfil y el número de dispositivos de cada bundle, escribe
`devices=<n>` en $GITHUB_OUTPUT y falla si algún perfil no es Ad Hoc.
"""

import os
import plistlib
import subprocess
import sys
import tempfile
import zipfile


def profile_kind(profile):
    if profile.get("ProvisionsAllDevices"):
        return "enterprise"
    devices = profile.get("ProvisionedDevices")
    if not devices:
        return "app-store"
    if profile.get("Entitlements", {}).get("get-task-allow"):
        return "development"
    return "ad-hoc"


def decode_profile(path):
    result = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace").strip())
    return plistlib.loads(result.stdout)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    ipa = sys.argv[1]
    problems = []
    device_counts = []
    with tempfile.TemporaryDirectory() as workdir:
        with zipfile.ZipFile(ipa) as archive:
            archive.extractall(workdir)
        bundles = []
        for root, dirs, _files in os.walk(os.path.join(workdir, "Payload")):
            for name in dirs:
                if name.endswith((".app", ".appex")):
                    bundles.append(os.path.join(root, name))
        if not bundles:
            print("::error title=IPA::El IPA no contiene ningún .app en Payload/.")
            sys.exit(1)

        for bundle in sorted(bundles):
            label = os.path.relpath(bundle, os.path.join(workdir, "Payload"))
            profile_path = os.path.join(bundle, "embedded.mobileprovision")
            if not os.path.exists(profile_path):
                problems.append(f"{label}: no tiene embedded.mobileprovision")
                continue
            try:
                profile = decode_profile(profile_path)
            except RuntimeError as error:
                problems.append(f"{label}: no se pudo leer el perfil ({error})")
                continue
            kind = profile_kind(profile)
            devices = len(profile.get("ProvisionedDevices") or [])
            expiration = profile.get("ExpirationDate")
            app_id = profile.get("Entitlements", {}).get("application-identifier", "?")
            print(f"{label}: perfil «{profile.get('Name', '?')}» ({kind}), {devices} dispositivo(s), "
                  f"App ID {app_id}, caduca {expiration}")
            if kind != "ad-hoc":
                problems.append(f"{label}: el perfil es {kind}, no Ad Hoc")
            device_counts.append(devices)

    if problems:
        for problem in problems:
            print(f"::error title=Perfil de aprovisionamiento::{problem}")
        sys.exit(1)

    count = min(device_counts) if device_counts else 0
    print(f"Todos los bundles llevan un perfil Ad Hoc. Dispositivos incluidos: {count}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"devices={count}\n")


if __name__ == "__main__":
    main()
