"""Browz Forever — image de la banque de guilde façon coffre (grille 14×7 par onglet).

Icônes : cherchées une fois sur Wowhead (Forever, puis Classic, puis Retail) et gardées dans
le dossier « icones ». Objet introuvable = point d'interrogation des macros.
"""
import asyncio
import io
import json
import os

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ICON_DIR = os.path.join(HERE, "icones")
INDEX_PATH = os.path.join(ICON_DIR, "index.json")   # id d'objet -> nom d'icône (ou "" si introuvable)
QUESTION = "inv_misc_questionmark"

SLOT, GAP, GROUP_GAP, MARGIN, HEADER = 44, 4, 10, 14, 34
QUALITY_RGB = {0: (157, 157, 157), 1: (230, 230, 230), 2: (30, 255, 0), 3: (0, 112, 221),
               4: (163, 53, 238), 5: (255, 128, 0), 6: (230, 204, 128), 7: (0, 204, 255)}

TOOLTIP_URLS = [
    "https://nether.wowhead.com/forever/tooltip/item/{id}",
    "https://nether.wowhead.com/classic/tooltip/item/{id}",
    "https://nether.wowhead.com/tooltip/item/{id}",
]
ICON_URL = "https://wow.zamimg.com/images/wow/icons/large/{name}.jpg"


def _font(size, bold=True):
    for name in (("arialbd.ttf", "DejaVuSans-Bold.ttf") if bold else ("arial.ttf", "DejaVuSans.ttf")):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def _load_index():
    try:
        with open(INDEX_PATH, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save_index(idx):
    os.makedirs(ICON_DIR, exist_ok=True)
    with open(INDEX_PATH, "w", encoding="utf-8") as f:
        json.dump(idx, f)


async def _get_json(session, url):
    async with session.get(url, timeout=10) as r:
        if r.status != 200:
            return None
        return json.loads(await r.text())


async def _download(session, name):
    path = os.path.join(ICON_DIR, name + ".jpg")
    if os.path.exists(path):
        return path
    async with session.get(ICON_URL.format(name=name), timeout=10) as r:
        if r.status != 200:
            return None
        data = await r.read()
    os.makedirs(ICON_DIR, exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    return path


async def ensure_icons(item_ids):
    """Télécharge les icônes manquantes. Renvoie {id: chemin du fichier ou None}."""
    import aiohttp
    idx = _load_index()
    todo = [i for i in item_ids if str(i) not in idx]
    out = {}
    async with aiohttp.ClientSession(headers={"User-Agent": "BrowzForeverBot/1.0"}) as session:
        sem = asyncio.Semaphore(6)

        async def resolve(iid):
            async with sem:
                for url in TOOLTIP_URLS:
                    try:
                        data = await _get_json(session, url.format(id=iid))
                    except Exception:
                        data = None
                    if data and data.get("icon"):
                        idx[str(iid)] = data["icon"].lower()
                        return
                idx[str(iid)] = ""   # introuvable : on ne recherchera plus

        await asyncio.gather(*(resolve(i) for i in todo))
        names = {idx.get(str(i)) or QUESTION for i in item_ids}
        paths = {}
        for n in names:
            try:
                paths[n] = await _download(session, n)
            except Exception:
                paths[n] = None
    if todo:
        _save_index(idx)
    for i in item_ids:
        out[str(i)] = paths.get(idx.get(str(i)) or QUESTION)
    return out


def slot_xy(s):
    col = (s - 1) // 14
    j = (s - 1) % 14
    sub, row = j // 7, j % 7
    x = MARGIN + (col * 2 + sub) * (SLOT + GAP) + col * GROUP_GAP
    y = HEADER + MARGIN + row * (SLOT + GAP)
    return x, y


def render_tab(tab, quality_of, icon_paths, title):
    """tab = {"name", "slots": {"1": {"id", "n"}}} -> PNG en mémoire."""
    width = MARGIN * 2 + 14 * (SLOT + GAP) - GAP + 6 * GROUP_GAP
    height = HEADER + MARGIN * 2 + 7 * (SLOT + GAP) - GAP
    img = Image.new("RGB", (width, height), (24, 22, 20))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, width - 1, HEADER], fill=(40, 30, 18))
    d.text((MARGIN, 8), title, font=_font(17), fill=(255, 209, 0))
    count_font = _font(14)
    cache = {}
    for s in range(1, 99):
        x, y = slot_xy(s)
        d.rectangle([x, y, x + SLOT - 1, y + SLOT - 1], fill=(14, 13, 12), outline=(60, 56, 50))
        it = (tab.get("slots") or {}).get(str(s))
        if not it:
            continue
        path = icon_paths.get(str(it["id"]))
        if path:
            if path not in cache:
                try:
                    cache[path] = Image.open(path).convert("RGB").resize((SLOT - 4, SLOT - 4))
                except OSError:
                    cache[path] = None
            if cache[path]:
                img.paste(cache[path], (x + 2, y + 2))
        if not path or not cache.get(path):
            d.text((x + SLOT // 2 - 6, y + 8), "?", font=_font(24), fill=(255, 209, 0))
        q = quality_of(it["id"])
        if q is not None and q >= 2:
            d.rectangle([x, y, x + SLOT - 1, y + SLOT - 1], outline=QUALITY_RGB.get(q, (200, 200, 200)), width=2)
        if it["n"] > 1:
            txt = str(it["n"])
            tw = d.textlength(txt, font=count_font)
            tx, ty = x + SLOT - 4 - tw, y + SLOT - 18
            for ox, oy in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)):
                d.text((tx + ox, ty + oy), txt, font=count_font, fill=(0, 0, 0))
            d.text((tx, ty), txt, font=count_font, fill=(255, 255, 255))
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    buf.seek(0)
    return buf
