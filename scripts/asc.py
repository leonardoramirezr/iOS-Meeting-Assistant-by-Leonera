#!/usr/bin/env python3
"""Utilidades de la API de App Store Connect para el workflow de CI.

Solo usa la biblioteca estándar de Python y `openssl` (para firmar el JWT ES256).

Variables de entorno:
  ASC_KEY_ID      ID de la clave de API (Team Key).
  ASC_ISSUER_ID   Issuer ID de App Store Connect.
  ASC_KEY_P8      Contenido del archivo .p8 (o ASC_KEY_PATH con la ruta al archivo).

Comandos:
  write-key PATH                    Escribe la clave .p8 normalizada en PATH (para xcodebuild).
  check                             Comprueba que la clave funciona y que hay dispositivos iOS.
  keychain-serials                  Lista los seriales de los certificados "Apple Development"
                                    que hay en el llavero.
  revoke-new-dev-certs --before F   Revoca por la API los certificados "Apple Development" del
                                    llavero cuyo serial no aparece en el archivo F.
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API_BASE = "https://api.appstoreconnect.apple.com"
DEV_CERT_NAME = "Apple Development"


class ASCError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def fail(message):
    print(f"::error title=App Store Connect::{message}")
    sys.exit(1)


def github_output(name, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


# ---------------------------------------------------------------------------
# Clave privada y JWT


def load_key_text():
    raw = os.environ.get("ASC_KEY_P8", "")
    if not raw.strip():
        path = os.environ.get("ASC_KEY_PATH")
        if path and os.path.exists(path):
            with open(path, encoding="utf-8") as handle:
                raw = handle.read()
    if not raw.strip():
        fail("Falta ASC_KEY_P8 (contenido del archivo .p8).")
    text = raw.replace("\\n", "\n").replace("\r", "").strip()
    if "-----BEGIN" not in text:
        # Se pegó solo el base64: se reconstruye el PEM.
        body = re.sub(r"\s+", "", text)
        lines = [body[i:i + 64] for i in range(0, len(body), 64)]
        text = "-----BEGIN PRIVATE KEY-----\n" + "\n".join(lines) + "\n-----END PRIVATE KEY-----"
    return text + "\n"


def write_key(path):
    text = load_key_text()
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(path, 0o600)
    check = subprocess.run(["openssl", "pkey", "-in", path, "-noout"], capture_output=True, text=True)
    if check.returncode != 0:
        fail("ASC_KEY_P8 no contiene una clave privada válida (se esperaba el contenido completo del .p8).")
    return path


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_signature_to_raw(der):
    """Convierte una firma ECDSA DER (SEQUENCE{INTEGER r, INTEGER s}) a r||s de 64 bytes."""

    def read_length(buffer, index):
        length = buffer[index]
        index += 1
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(buffer[index:index + count], "big")
            index += count
        return length, index

    if not der or der[0] != 0x30:
        raise ValueError("Firma DER no válida")
    _, index = read_length(der, 1)
    raw = b""
    for _ in range(2):
        if der[index] != 0x02:
            raise ValueError("Firma DER no válida")
        length, index = read_length(der, index + 1)
        value = der[index:index + length].lstrip(b"\x00")
        index += length
        if len(value) > 32:
            raise ValueError("Componente de firma demasiado largo")
        raw += value.rjust(32, b"\x00")
    return raw


class Client:
    def __init__(self):
        self.key_id = os.environ.get("ASC_KEY_ID", "").strip()
        self.issuer_id = os.environ.get("ASC_ISSUER_ID", "").strip()
        if not self.key_id or not self.issuer_id:
            fail("Faltan ASC_KEY_ID o ASC_ISSUER_ID.")
        key_path = os.environ.get("ASC_KEY_PATH")
        if not key_path or not os.path.exists(key_path):
            handle, key_path = tempfile.mkstemp(suffix=".p8")
            os.close(handle)
            write_key(key_path)
        self.key_path = key_path
        self._token = None
        self._expires = 0

    def token(self):
        now = int(time.time())
        if self._token and now < self._expires - 60:
            return self._token
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        payload = {"iss": self.issuer_id, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
        signing_input = (
            b64url(json.dumps(header, separators=(",", ":")).encode())
            + "."
            + b64url(json.dumps(payload, separators=(",", ":")).encode())
        )
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", self.key_path],
            input=signing_input.encode("ascii"),
            capture_output=True,
        )
        if result.returncode != 0:
            fail("openssl no pudo firmar el JWT: " + result.stderr.decode(errors="replace").strip())
        signature = der_signature_to_raw(result.stdout)
        self._token = signing_input + "." + b64url(signature)
        self._expires = now + 1200
        return self._token

    def request(self, method, path, params=None):
        url = path if path.startswith("https://") else API_BASE + path
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        request = urllib.request.Request(
            url,
            method=method,
            headers={"Authorization": "Bearer " + self.token(), "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            body = error.read().decode(errors="replace")
            message = body
            try:
                errors = json.loads(body).get("errors", [])
                if errors:
                    message = "; ".join(
                        f"{item.get('title', '')}: {item.get('detail', '')}".strip(": ") for item in errors
                    )
            except ValueError:
                pass
            raise ASCError(error.code, message) from None
        except urllib.error.URLError as error:
            raise ASCError(0, f"No se pudo conectar con App Store Connect: {error.reason}") from None

    def paginate(self, path, params=None):
        page = self.request("GET", path, params)
        while page:
            for item in page.get("data", []):
                yield item
            next_url = (page.get("links") or {}).get("next")
            page = self.request("GET", next_url) if next_url else None


def explain(error):
    if error.status == 401:
        return ("La clave de API fue rechazada (401). Revisa que ASC_KEY_ID y ASC_ISSUER_ID correspondan "
                "a la clave de ASC_KEY_P8 y que la clave no esté revocada. Detalle: " + error.message)
    if error.status == 403:
        return ("La clave de API no tiene permisos suficientes (403). Usa una Team Key con rol Admin. "
                "Detalle: " + error.message)
    return f"Error {error.status} de App Store Connect: {error.message}"


# ---------------------------------------------------------------------------
# Comandos


def cmd_write_key(args):
    write_key(args.path)
    print(f"Clave escrita en {args.path}")


def cmd_check(_args):
    client = Client()
    try:
        devices = list(client.paginate(
            "/v1/devices",
            {"filter[platform]": "IOS", "filter[status]": "ENABLED", "limit": "200"},
        ))
    except ASCError as error:
        fail(explain(error))

    print(f"Clave de API válida. Dispositivos iOS habilitados: {len(devices)}")
    for device in devices:
        attributes = device.get("attributes", {})
        udid = attributes.get("udid", "")
        masked = udid[:8] + "…" + udid[-4:] if len(udid) > 12 else udid
        print(f"  - {attributes.get('name', '?')} ({attributes.get('model') or attributes.get('deviceClass', '?')}) {masked}")
    github_output("devices", str(len(devices)))
    if not devices:
        fail("No hay ningún dispositivo iOS registrado y habilitado en Apple Developer. "
             "Registra al menos un UDID en Certificates, Identifiers & Profiles › Devices.")


def normalize_serial(serial):
    cleaned = serial.strip().replace(":", "").upper().lstrip("0")
    return cleaned or "0"


def keychain_dev_serials():
    result = subprocess.run(
        ["security", "find-certificate", "-a", "-c", DEV_CERT_NAME, "-p"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return set()
    serials = set()
    pems = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", result.stdout, re.S)
    for pem in pems:
        info = subprocess.run(["openssl", "x509", "-noout", "-serial"], input=pem, capture_output=True, text=True)
        if info.returncode == 0 and "=" in info.stdout:
            serials.add(normalize_serial(info.stdout.strip().split("=", 1)[1]))
    return serials


def cmd_keychain_serials(_args):
    serials = sorted(keychain_dev_serials())
    for serial in serials:
        print(serial)
    print(f"{len(serials)} certificado(s) \"{DEV_CERT_NAME}\" en el llavero.", file=sys.stderr)


def cmd_revoke_new_dev_certs(args):
    if not os.path.exists(args.before):
        print(f"No existe {args.before}: el archive no llegó a ejecutarse, no hay nada que revocar.")
        return
    with open(args.before, encoding="utf-8") as handle:
        before = {normalize_serial(line) for line in handle if line.strip()}
    current = keychain_dev_serials()
    new = current - before
    if not new:
        print("xcodebuild no creó certificados de desarrollo nuevos.")
        return

    print(f"Certificados de desarrollo nuevos en el llavero: {', '.join(sorted(new))}")
    client = Client()
    try:
        certificates = list(client.paginate(
            "/v1/certificates",
            {"limit": "200", "fields[certificates]": "serialNumber,name,displayName,certificateType"},
        ))
    except ASCError as error:
        fail(explain(error))

    revoked = set()
    errors = []
    for certificate in certificates:
        attributes = certificate.get("attributes", {})
        serial = normalize_serial(attributes.get("serialNumber", ""))
        if serial not in new:
            continue
        name = attributes.get("displayName") or attributes.get("name") or certificate["id"]
        try:
            client.request("DELETE", f"/v1/certificates/{certificate['id']}")
            revoked.add(serial)
            print(f"Revocado: {name} ({attributes.get('certificateType')}, serial {serial})")
        except ASCError as error:
            errors.append(f"{name}: {explain(error)}")

    for serial in sorted(new - revoked):
        if not any(serial in message for message in errors):
            print(f"::notice::El certificado {serial} no aparece en App Store Connect (quizá ya estaba revocado).")
    if errors:
        fail("No se pudieron revocar algunos certificados: " + " | ".join(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    write_key_parser = commands.add_parser("write-key")
    write_key_parser.add_argument("path")
    write_key_parser.set_defaults(func=cmd_write_key)

    commands.add_parser("check").set_defaults(func=cmd_check)
    commands.add_parser("keychain-serials").set_defaults(func=cmd_keychain_serials)

    revoke_parser = commands.add_parser("revoke-new-dev-certs")
    revoke_parser.add_argument("--before", required=True)
    revoke_parser.set_defaults(func=cmd_revoke_new_dev_certs)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
