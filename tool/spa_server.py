"""Petit serveur statique avec fallback SPA pour tester le build web en local.

Sert `build/web` et, pour toute route qui ne correspond pas à un fichier réel
(ex: `/catalogue/<shopId>`, `/shop/<id>/...`), renvoie `index.html` — exactement
comme la règle `rewrites` de Firebase Hosting. Sans ça, `python -m http.server`
renvoie 404 sur les deep links et on ne peut pas tester la page catalogue.

Usage : python tool/spa_server.py [port]
"""
import http.server
import os
import socketserver
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "web")
ROOT = os.path.abspath(ROOT)


class SpaHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def do_GET(self):
        # Si le chemin demandé ne pointe pas vers un fichier existant,
        # on retombe sur index.html (routing côté client géré par go_router).
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            self.path = "/index.html"
        return super().do_GET()


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", PORT), SpaHandler) as httpd:
    print(f"SPA server -> http://localhost:{PORT}  (root={ROOT})")
    httpd.serve_forever()
