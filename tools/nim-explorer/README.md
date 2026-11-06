# Nim Explorer
Static page: analyses a GitHub Nim repo (or a local folder) for module imports, cycles and type relationships.
Run: `python3 -m http.server 8765` here, open http://localhost:8765/index.html, enter `owner/repo` (token optional) or "Open local folder".
Tests: `node test_nimparse.js`. Lexical analysis only: macro/template-generated imports are not seen.
