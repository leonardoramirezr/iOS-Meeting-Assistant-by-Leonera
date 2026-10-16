#!/usr/bin/env python3
"""Genera los archivos de GitHub Pages para la instalación OTA (lo usa publish-pages.sh).

  pages_site.py build DIR   Escribe manifest.plist, build.json e index.html del build en DIR.
  pages_site.py site DIR    Poda builds antiguos y escribe la portada DIR/index.html.
  pages_site.py urls        Imprime page_url, manifest_url e install_url (formato $GITHUB_OUTPUT).

Los datos del build se leen de las variables de entorno descritas en publish-pages.sh.
"""

import datetime
import html
import json
import os
import plistlib
import shutil
import sys
import urllib.parse


def env(name, default=""):
    return os.environ.get(name, default).strip()


def urls(tag):
    base = env("BASE_URL")
    if not base.endswith("/"):
        base += "/"
    page = f"{base}{urllib.parse.quote(tag)}/"
    manifest = f"{page}manifest.plist"
    install = "itms-services://?action=download-manifest&url=" + urllib.parse.quote(manifest, safe="")
    return page, manifest, install


def version_key(version):
    parts = []
    for piece in version.split("."):
        parts.append(int(piece) if piece.isdigit() else 0)
    return tuple(parts)


STYLE = """
:root { color-scheme: light dark; --bg: #f5f5f7; --card: #ffffff; --text: #1d1d1f; --muted: #6e6e73;
        --accent: #6d28d9; --accent-text: #ffffff; --border: #e3e3e8; --badge: #ede9fe; --badge-text: #5b21b6; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #000000; --card: #1c1c1e; --text: #f5f5f7; --muted: #98989d; --accent: #a78bfa;
          --accent-text: #1c1033; --border: #2c2c2e; --badge: #2e1065; --badge-text: #ddd6fe; }
}
* { box-sizing: border-box; }
body { margin: 0; font: 16px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
       background: var(--bg); color: var(--text); }
main { max-width: 680px; margin: 0 auto; padding: 24px 16px 48px; }
header { display: flex; gap: 16px; align-items: center; margin-bottom: 20px; }
header img { width: 72px; height: 72px; border-radius: 16px; box-shadow: 0 2px 8px rgba(0,0,0,.15); }
h1 { font-size: 24px; margin: 0; line-height: 1.2; }
h2 { font-size: 18px; margin: 28px 0 10px; }
.muted { color: var(--muted); }
.small { font-size: 13px; }
.card { background: var(--card); border: 1px solid var(--border); border-radius: 14px; padding: 14px 16px; margin: 10px 0; }
.button { display: inline-block; background: var(--accent); color: var(--accent-text); text-decoration: none;
          font-weight: 600; padding: 10px 18px; border-radius: 12px; }
.button.big { display: block; text-align: center; font-size: 18px; padding: 14px 18px; margin: 16px 0 8px; }
.button.secondary { background: transparent; color: var(--accent); border: 1px solid var(--accent); }
.row { display: flex; justify-content: space-between; gap: 12px; align-items: center; flex-wrap: wrap; }
.actions { display: flex; gap: 8px; flex-wrap: wrap; }
.badge { display: inline-block; font-size: 12px; font-weight: 600; padding: 2px 8px; border-radius: 999px;
         background: var(--badge); color: var(--badge-text); margin-left: 6px; vertical-align: middle; }
dl { display: grid; grid-template-columns: max-content 1fr; gap: 6px 14px; margin: 0; }
dt { color: var(--muted); }
dd { margin: 0; word-break: break-word; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; }
a { color: var(--accent); }
"""


def page(title, body):
    return f"""<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>{STYLE}</style>
</head>
<body>
<main>
{body}
</main>
</body>
</html>
"""


def format_date(iso):
    try:
        value = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return value.strftime("%Y-%m-%d %H:%M UTC")
    except ValueError:
        return iso


INSTALL_HINT = (
    '<p class="muted small">Abre esta página en <strong>Safari</strong> desde el iPhone. '
    "Solo se puede instalar en iPhones cuyo UDID esté registrado en la cuenta de Apple Developer; "
    "si iOS lo pide, activa el Modo de desarrollador en Ajustes › Privacidad y seguridad.</p>"
)


def build_page(info):
    title = info["title"]
    channel = "Estable" if info["channel"] == "stable" else "Pre-release"
    rows = [
        ("Versión", f'{info["version"]} ({info["build_number"]})'),
        ("Canal", channel),
        ("Rama", info.get("branch") or "—"),
        ("Commit", info.get("commit_short") or "—"),
        ("Mensaje", info.get("commit_message") or "—"),
        ("Fecha", format_date(info["created_at"])),
        ("Dispositivos en el perfil", info.get("devices") or "—"),
        ("Bundle ID", info["bundle_id"]),
    ]
    details = "\n".join(
        f"<dt>{html.escape(str(label))}</dt><dd>{html.escape(str(value))}</dd>" for label, value in rows
    )
    run = ""
    if info.get("run_url"):
        run = ' · <a href="%s">Ejecución en GitHub Actions</a>' % html.escape(info["run_url"])
    tag = html.escape(info["tag"])
    install = html.escape(info["install_url"])
    version = html.escape(info["version"])
    ipa = html.escape(urllib.parse.quote(info["ipa"]))
    body = f"""
<header>
  <img src="icon-512.png" alt="">
  <div>
    <h1>{html.escape(title)}</h1>
    <div class="muted">{tag}<span class="badge">{channel}</span></div>
  </div>
</header>
<a class="button big" href="{install}">Instalar {version}</a>
{INSTALL_HINT}
<div class="card"><dl>
{details}
</dl></div>
<p class="small"><a href="../">Todos los builds</a> · <a href="{ipa}">Descargar IPA</a>{run}</p>
"""
    return page(title + " " + info["tag"], body)


def cmd_build(directory):
    tag = env("TAG")
    page_url, manifest_url, install_url = urls(tag)
    ipa = env("IPA_NAME")
    sha = env("COMMIT_SHA")
    message = env("COMMIT_MESSAGE").splitlines()
    info = {
        "tag": tag,
        "title": env("APP_TITLE"),
        "bundle_id": env("BUNDLE_ID"),
        "version": env("VERSION"),
        "build_number": env("BUILD_NUMBER"),
        "channel": "stable" if env("CHANNEL") == "stable" else "prerelease",
        "branch": env("BRANCH"),
        "commit": sha,
        "commit_short": sha[:7],
        "commit_message": message[0] if message else "",
        "run_number": int(env("RUN_NUMBER", "0") or 0),
        "run_url": env("RUN_URL"),
        "devices": env("DEVICE_COUNT"),
        "created_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ipa": ipa,
        "page_url": page_url,
        "manifest_url": manifest_url,
        "install_url": install_url,
    }

    manifest = {
        "items": [
            {
                "assets": [
                    {"kind": "software-package", "url": page_url + urllib.parse.quote(ipa)},
                    {"kind": "display-image", "url": page_url + "icon-57.png"},
                    {"kind": "full-size-image", "url": page_url + "icon-512.png"},
                ],
                "metadata": {
                    "bundle-identifier": info["bundle_id"],
                    "bundle-version": info["version"],
                    "kind": "software",
                    "title": info["title"],
                },
            }
        ]
    }
    with open(os.path.join(directory, "manifest.plist"), "wb") as handle:
        plistlib.dump(manifest, handle)
    with open(os.path.join(directory, "build.json"), "w", encoding="utf-8") as handle:
        json.dump(info, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    with open(os.path.join(directory, "index.html"), "w", encoding="utf-8") as handle:
        handle.write(build_page(info))


def build_card(info):
    channel = "Estable" if info.get("channel") == "stable" else "Pre-release"
    meta = [f'{info.get("version", "?")} ({info.get("build_number", "?")})']
    if info.get("branch"):
        meta.append(info["branch"])
    if info.get("commit_short"):
        meta.append(info["commit_short"])
    meta.append(format_date(info.get("created_at", "")))
    message = info.get("commit_message") or ""
    message_html = '<div class="small">%s</div>' % html.escape(message) if message else ""
    folder = html.escape(urllib.parse.quote(info["tag"]) + "/")
    tag = html.escape(info["tag"])
    meta_html = html.escape(" · ".join(meta))
    install = html.escape(info.get("install_url", ""))
    return f"""<div class="card">
  <div class="row">
    <div>
      <strong>{tag}</strong><span class="badge">{channel}</span>
      <div class="muted small">{meta_html}</div>
      {message_html}
    </div>
    <div class="actions">
      <a class="button" href="{install}">Instalar</a>
      <a class="button secondary" href="{folder}">Detalles</a>
    </div>
  </div>
</div>"""


def cmd_site(directory):
    keep = int(env("KEEP_BRANCH_BUILDS", "20") or 20)
    builds = []
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name, "build.json")
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                info = json.load(handle)
        except (OSError, ValueError):
            continue
        info["tag"] = name
        builds.append(info)

    stable = sorted(
        (b for b in builds if b.get("channel") == "stable"),
        key=lambda b: version_key(b.get("version", "0")),
        reverse=True,
    )
    prerelease = sorted(
        (b for b in builds if b.get("channel") != "stable"),
        key=lambda b: (b.get("created_at", ""), b.get("run_number", 0)),
        reverse=True,
    )
    for old in prerelease[keep:]:
        shutil.rmtree(os.path.join(directory, old["tag"]), ignore_errors=True)
        print(f"Eliminado build antiguo: {old['tag']}")
    prerelease = prerelease[:keep]

    title = env("APP_TITLE") or (builds[0].get("title") if builds else "App")
    newest = (stable + prerelease)[0] if (stable or prerelease) else None
    latest_any = max(stable + prerelease, key=lambda b: b.get("created_at", ""), default=newest)
    icon_html = ""
    if latest_any:
        icon_html = '<img src="%s/icon-512.png" alt="">' % html.escape(urllib.parse.quote(latest_any["tag"]))

    if stable:
        latest = stable[0]
        hero = '<a class="button big" href="%s">Instalar la última versión estable (%s)</a>' % (
            html.escape(latest["install_url"]), html.escape(latest["version"]))
    else:
        hero = ('<div class="card muted">Todavía no hay una versión estable: se publica una con cada push a '
                '<code>main</code>. Mientras tanto puedes instalar un build de rama.</div>')

    sections = [
        f"""<header>
  {icon_html}
  <div>
    <h1>{html.escape(title)}</h1>
    <div class="muted">Instalación Ad Hoc</div>
  </div>
</header>
{hero}
{INSTALL_HINT}"""
    ]
    sections.append("<h2>Versiones estables (main)</h2>")
    sections.append("\n".join(build_card(b) for b in stable) or '<p class="muted">Ninguna todavía.</p>')
    sections.append(f"<h2>Builds de ramas (últimos {keep})</h2>")
    sections.append("\n".join(build_card(b) for b in prerelease) or '<p class="muted">Ninguno.</p>')

    with open(os.path.join(directory, "index.html"), "w", encoding="utf-8") as handle:
        handle.write(page(title, "\n".join(sections)))
    print(f"Portada generada: {len(stable)} estable(s), {len(prerelease)} de ramas.")


def cmd_urls():
    page_url, manifest_url, install_url = urls(env("TAG"))
    print(f"page_url={page_url}")
    print(f"manifest_url={manifest_url}")
    print(f"install_url={install_url}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    command = sys.argv[1]
    if command == "build" and len(sys.argv) == 3:
        cmd_build(sys.argv[2])
    elif command == "site" and len(sys.argv) == 3:
        cmd_site(sys.argv[2])
    elif command == "urls":
        cmd_urls()
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
