#!/bin/bash
# Downloads Image-Line's public FL Studio online manual (HTML pages only, no images) into
# FL Studio's QuickAsk knowledge folder, where app control indexes it for search_manual.
# One page a second, backing off when the site asks; about 1,000 pages, roughly 20 minutes.
# Re-running resumes, skipping pages already saved; --refresh downloads everything again.
#
#   bash scripts/fetch-fl-manual.sh
set -euo pipefail
destination="${QUICKASK_KNOWLEDGE_ROOT:-$HOME/Library/Application Support/QuickAsk/Apps}/com.image-line.flstudio/manual/fl-studio"
mkdir -p "$destination"
/usr/bin/python3 -I - "$destination" "${1:-}" <<'PY'
import os, re, sys, time, urllib.error, urllib.parse, urllib.request
base = "https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/"
destination = sys.argv[1]
refresh = len(sys.argv) > 2 and sys.argv[2] == "--refresh"
agent = {"User-Agent": "QuickAsk manual fetch (personal, offline reference)"}

def get(url):
    for attempt in range(6):
        try:
            # Plugin pages have spaces in their names.
            with urllib.request.urlopen(urllib.request.Request(urllib.parse.quote(url, safe=":/%"), headers=agent), timeout=30) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 5:
                raise
            wait = int(error.headers.get("Retry-After") or 0) or 30 * (attempt + 1)
            print(f"rate limited; waiting {wait} s", file=sys.stderr, flush=True)
            time.sleep(wait)

def links(html, page):
    for href in re.findall(r'href="([^"#?]+)', html):
        url = urllib.parse.unquote(urllib.parse.urljoin(page, href))
        if url.startswith(base + "html/") and url.endswith((".htm", ".html")):
            yield url

queue = list(dict.fromkeys(links(get(base + "Index_Frame_Left.html").decode("utf-8", "replace"), base)))
seen, saved = set(queue), 0
while queue and saved < 3000:
    url = queue.pop(0)
    # Keep the site's folders (html/plugins/…), so links between pages still resolve.
    path = os.path.join(destination, urllib.parse.urlparse(url).path[len(urllib.parse.urlparse(base).path) + len("html/"):])
    fresh = not refresh and os.path.exists(path)
    if fresh:
        with open(path, "rb") as file:
            data = file.read()
    else:
        try:
            data = get(url)
        except Exception as error:
            print(f"skip {url}: {error}", file=sys.stderr)
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as file:
            file.write(data)
    saved += 1
    for link in links(data.decode("utf-8", "replace"), url):
        if link not in seen:
            seen.add(link); queue.append(link)
    if saved % 100 == 0:
        print(f"{saved} pages…", flush=True)
    if not fresh:
        time.sleep(1)
print(f"Saved {saved} pages to {destination}")
PY
