"""Check static pages for broken local links, fragments, and assets."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).parent / "dist"


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.ids, self.refs = set(), []
        self.feed(path.read_text())

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            assert attrs["id"] not in self.ids, f"Duplicate ID: {attrs['id']}"
            self.ids.add(attrs["id"])
        for key in ("href", "src"):
            if attrs.get(key):
                self.refs.append(attrs[key])


pages = {p.resolve(): Page(p) for p in ROOT.glob("*.html")}
count = 0
for path, page in pages.items():
    for ref in page.refs:
        url = urlsplit(ref)
        if url.scheme or url.netloc:
            continue
        target = (path.parent / unquote(url.path)).resolve() if url.path else path
        if target.is_dir():
            target /= "index.html"
        assert target.is_file(), f"{path.name}: missing {ref}"
        if url.fragment:
            assert target in pages and unquote(url.fragment) in pages[target].ids, f"{path.name}: missing fragment {ref}"
        count += 1
print(f"PASS: {len(pages)} pages, {count} local links and assets")
