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


FONT_DIR = os.path.join(HERE, "polices")


def _font(size, bold=True):
    """Police livrée avec le bot (accents garantis, même sur l'hébergeur), sinon celles du système."""
    local = os.path.join(FONT_DIR, "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf")
    for name in ((local, "arialbd.ttf", "DejaVuSans-Bold.ttf") if bold else (local, "arial.ttf", "DejaVuSans.ttf")):
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


# ------------------------------------------------------------------ fenêtre de personnage (équipement)
LEFT_SLOTS = [1, 2, 3, 15, 5, 9]           # tête, cou, épaules, dos, torse, poignets
RIGHT_SLOTS = [10, 6, 7, 8, 11, 12, 13, 14] # mains, taille, jambes, pieds, doigts, bijoux
BOTTOM_SLOTS = [16, 17, 18]                 # main droite, main gauche, à distance
CLASS_RGB = {"WARRIOR": (198, 155, 109), "PALADIN": (244, 140, 186), "HUNTER": (170, 211, 114), "ROGUE": (255, 244, 104),
             "PRIEST": (255, 255, 255), "SHAMAN": (0, 112, 221), "MAGE": (63, 199, 235), "WARLOCK": (135, 136, 238),
             "DRUID": (255, 124, 10)}
PD_ICON, PD_ROW, PD_W, PD_H = 40, 50, 820, 520


def _fit(d, text, font, width):
    """Coupe un texte trop long avec « … »."""
    if d.textlength(text, font=font) <= width:
        return text
    while text and d.textlength(text + "…", font=font) > width:
        text = text[:-1]
    return text + "…"


def render_paperdoll(card, item_of, icon_paths, class_label, spec_label):
    """card = fiche (gear : [{slot, id}]) ; item_of(id) -> {"n", "q"} ; icon_paths : {id: fichier}."""
    img = Image.new("RGB", (PD_W, PD_H), (20, 18, 16))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, PD_W - 1, PD_H - 1], outline=(70, 60, 45), width=2)
    gear = {g["slot"]: g["id"] for g in card.get("gear") or []}
    name_font, small = _font(13), _font(11, bold=False)
    cache = {}

    def icon(x, y, slot):
        d.rectangle([x, y, x + PD_ICON - 1, y + PD_ICON - 1], fill=(12, 11, 10), outline=(60, 56, 50))
        iid = gear.get(slot)
        if not iid:
            return None
        path = icon_paths.get(str(iid))
        if path:
            if path not in cache:
                try:
                    cache[path] = Image.open(path).convert("RGB").resize((PD_ICON - 4, PD_ICON - 4))
                except OSError:
                    cache[path] = None
            if cache[path]:
                img.paste(cache[path], (x + 2, y + 2))
        if not path or not cache.get(path):
            d.text((x + PD_ICON // 2 - 6, y + 8), "?", font=_font(22), fill=(255, 209, 0))
        it = item_of(iid) or {}
        q = it.get("q")
        if q is not None and q >= 2:
            d.rectangle([x, y, x + PD_ICON - 1, y + PD_ICON - 1], outline=QUALITY_RGB.get(q, (200, 200, 200)), width=2)
        return it

    def label(x, y, it, slot, align_right=False, width=250, center=False):
        from_slot = {1: "Tête", 2: "Cou", 3: "Épaules", 15: "Dos", 5: "Torse", 9: "Poignets", 10: "Mains", 6: "Taille",
                     7: "Jambes", 8: "Pieds", 11: "Doigt", 12: "Doigt", 13: "Bijou", 14: "Bijou", 16: "Main droite",
                     17: "Main gauche", 18: "À distance"}[slot]
        if it is None:
            lines = [("— " + from_slot, small, (110, 105, 95))]
        else:
            color = QUALITY_RGB.get(it.get("q"), (230, 230, 230)) if it.get("q") is not None else (230, 230, 230)
            lines = [(_fit(d, it.get("n") or "Objet #%s" % gear.get(slot), name_font, width), name_font, color),
                     (from_slot, small, (150, 145, 135))]
        for k, (text, font, color) in enumerate(lines):
            tw = d.textlength(text, font=font)
            tx = x - tw if align_right else (x - tw / 2 if center else x)
            d.text((tx, y + 4 + k * 17), text, font=font, fill=color)

    top = 20
    for k, slot in enumerate(LEFT_SLOTS):
        y = top + k * PD_ROW
        it = icon(16, y, slot)
        label(16 + PD_ICON + 8, y, it, slot)
    for k, slot in enumerate(RIGHT_SLOTS):
        y = top + k * PD_ROW
        it = icon(PD_W - 16 - PD_ICON, y, slot)
        label(PD_W - 16 - PD_ICON - 8, y, it, slot, align_right=True)
    # armes en bas, au centre
    by = PD_H - 16 - PD_ICON - 34
    step = 250
    bx0 = PD_W // 2 - step - PD_ICON // 2
    for k, slot in enumerate(BOTTOM_SLOTS):
        x = bx0 + k * step
        it = icon(x, by, slot)
        label(x + PD_ICON // 2, by + PD_ICON + 2, it, slot, width=230, center=True)
    # centre : identité du personnage
    cx = PD_W // 2
    big = _font(22)
    name = card.get("name") or "?"
    rgb = CLASS_RGB.get(card.get("class"), (255, 209, 0))
    d.text((cx - d.textlength(name, font=big) / 2, 150), name, font=big, fill=rgb)
    sub = "%s niveau %s" % (class_label or "?", card.get("level") or "?")
    f2 = _font(15, bold=False)
    d.text((cx - d.textlength(sub, font=f2) / 2, 184), sub, font=f2, fill=(220, 215, 205))
    if spec_label:
        d.text((cx - d.textlength(spec_label, font=f2) / 2, 208), spec_label, font=f2, fill=(220, 215, 205))
    if card.get("ilvl"):
        il = "Niveau d'objet %s" % card["ilvl"]
        f3 = _font(18)
        d.text((cx - d.textlength(il, font=f3) / 2, 250), il, font=f3, fill=(255, 209, 0))
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    buf.seek(0)
    return buf
