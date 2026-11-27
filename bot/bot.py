"""Browz Forever — bot Discord « Browzer ».

- Reçoit les données des ponts (client PC) sur  POST /api/ingest  (clé de guilde obligatoire)
- Publie une carte par passage au coffre dans #banque-de-guilde
- Commandes : /browz bdg, /browz or, /browz po, /browz objet, /browz journal, /browz joueur
- Résumé mensuel le 1er du mois

Lancement : python bot.py   (config dans config_bot.json, données dans donnees.json)
"""
import asyncio
import calendar
import io
import sys
import datetime as dt
import json
import os
import secrets
import time

import discord
from aiohttp import web
from discord import app_commands
from discord.ext import tasks

from browz_core import CATS, Store, money
from browz_grid import ensure_icons, render_tab

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config_bot.json")
DATA_PATH = os.path.join(HERE, "donnees.json")

COLOR_IN, COLOR_OUT, COLOR_GOLD, COLOR_INFO = 0x2ECC71, 0xE74C3C, 0xF1C40F, 0xE67E22
FOOTER = "Browz Forever"


def load_config():
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, encoding="utf-8") as f:
            cfg = json.load(f)
    else:
        cfg = {}
    defaults = {"token": "", "cle_guilde": secrets.token_urlsafe(24), "port": 8787,
                "salon_bdg": "banque-de-guilde", "salon_officiers": "officier", "salon_metiers": "commandes-m",
                "salon_donnees": "browz-donnees", "api_http": True}
    changed = False
    for k, v in defaults.items():
        if k not in cfg:
            cfg[k] = v
            changed = True
    if changed:
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=1)
    return cfg


cfg = load_config()
store = Store(DATA_PATH)

intents = discord.Intents.default()
intents.members = True
intents.message_content = True   # pour lire les pièces jointes postées par les ponts (webhook)


class Browzer(discord.Client):
    def __init__(self):
        super().__init__(intents=intents)
        self.tree = app_commands.CommandTree(self)
        self.synced = False
        self.lock = asyncio.Lock()

    async def setup_hook(self):
        monthly.start()
        backup.start()
        if not cfg.get("api_http", True):
            return
        app = web.Application()
        app.router.add_post("/api/ingest", ingest)
        app.router.add_get("/", health)
        runner = web.AppRunner(app)
        await runner.setup()
        try:
            # sur un hébergeur à panneau Pterodactyl (Wispbyte…), le port ouvert est donné par SERVER_PORT
            port = int(os.environ.get("SERVER_PORT") or cfg.get("port", 8787))
            await web.TCPSite(runner, "0.0.0.0", port).start()
            print("API des ponts ouverte sur le port %d." % port, flush=True)
        except OSError as e:
            print("API HTTP indisponible (%s) : seuls les envois par webhook seront reçus." % e, flush=True)

    async def on_ready(self):
        print("Connecté en tant que %s sur %d serveur(s)." % (self.user, len(self.guilds)), flush=True)
        if not self.synced:
            for g in self.guilds:
                self.tree.copy_global_to(guild=g)
                await self.tree.sync(guild=g)
            self.synced = True
            print("Commandes /browz enregistrées.", flush=True)


client = Browzer()


@client.event
async def on_message(message):
    """Les ponts postent leurs données en pièce jointe JSON (webhook) dans le salon caché."""
    if not message.webhook_id or not message.attachments:
        return
    needle = cfg.get("salon_donnees", "")
    if not needle or needle.lower() not in getattr(message.channel, "name", "").lower():
        return
    ok_all = True
    for att in message.attachments:
        if not att.filename.endswith(".json"):
            continue
        try:
            body = json.loads((await att.read()).decode("utf-8"))
        except Exception as e:
            print("Pièce jointe illisible :", e, flush=True)
            ok_all = False
            continue
        if not await process(body):
            print("Envoi refusé (mauvaise clé) dans #%s" % message.channel.name, flush=True)
            ok_all = False
    if ok_all:
        try:
            await message.delete()   # salon tenu propre (droit « Gérer les messages » requis)
        except discord.DiscordException:
            pass


def find_channel(key):
    needle = cfg.get(key, "")
    for g in client.guilds:
        for ch in g.text_channels:
            if needle and needle.lower() in ch.name.lower():
                return ch
    return None


# ------------------------------------------------------------------ cartes
def visit_card(who, items, money_delta, t, approx):
    ins = {k: v for k, v in items.items() if v > 0}
    outs = {k: -v for k, v in items.items() if v < 0}
    n_in, n_out = sum(ins.values()), sum(outs.values())
    if not items:
        color = COLOR_GOLD
    elif n_in >= n_out:
        color = COLOR_IN
    else:
        color = COLOR_OUT
    e = discord.Embed(title="🏦 %s — Banque de guilde" % who, color=color,
                      timestamp=dt.datetime.fromtimestamp(t, dt.timezone.utc))

    def lines(d, arrow):
        rows = ["• %d× %s" % (n, store.label(iid)) for iid, n in sorted(d.items(), key=lambda x: store.name(x[0]))]
        text = "\n".join(rows)
        return text if len(text) <= 1024 else text[:1000] + "\n…"

    if ins:
        e.add_field(name="📥 Dépôts", value=lines(ins, "→"), inline=False)
    if outs:
        e.add_field(name="📤 Retraits", value=lines(outs, "←"), inline=False)
    if money_delta:
        e.add_field(name="💰 Or", value=money(money_delta, sign=True), inline=False)
    bank = store.d.get("bank")
    if bank:
        e.add_field(name="Solde de la banque", value=money(bank.get("money", 0)), inline=False)
    e.set_footer(text="%s · %s" % (FOOTER, "rattrapé du journal (heure ≈)" if approx else "scan direct"))
    return e


async def post_visit(who, items, money_delta, t, approx):
    ch = find_channel("salon_bdg")
    if ch:
        await ch.send(embed=visit_card(who, items, money_delta, t, approx))


# ------------------------------------------------------------------ API des ponts
async def health(request):
    return web.Response(text="Browz Forever : bot en ligne")


async def process(body):
    """Traite un envoi d'un pont (via webhook Discord ou via HTTP). Renvoie False si la clé est fausse."""
    if not secrets.compare_digest(str(body.get("cle", "")), str(cfg["cle_guilde"])):
        return False
    kind, payload = body.get("kind"), body.get("payload")
    async with client.lock:
        to_post, to_link = [], []
        if kind == "events":
            for ev in payload or []:
                if store.add_event(ev):
                    to_post.append((ev["who"], ev.get("items", {}), ev.get("money", 0), ev["t"], False))
        elif kind == "bank":
            store.set_bank(payload)
        elif kind == "items":
            store.merge_items(payload)
        elif kind == "roster":
            if isinstance(payload, dict) and payload.get("members"):
                store.d["roster"] = payload["members"]
        elif kind == "chars":
            chars = store.d.setdefault("chars", {})
            for name, data in (payload or {}).items():
                if isinstance(data, dict) and (data.get("t") or 0) >= (chars.get(name, {}).get("t") or 0):
                    chars[name] = data
                    if data.get("discord"):
                        to_link.append(name)
        elif kind == "logs":
            new_items, new_money, first = store.merge_logs(payload)
            if not first:
                for who, g in store.uncovered(new_items, new_money).items():
                    if g["items"] or g["money"]:
                        to_post.append((who, g["items"], g["money"], g["t"], True))
        store.save()
    for args in to_post:
        try:
            await post_visit(*args)
        except discord.DiscordException as e:
            print("Envoi Discord impossible :", e, flush=True)
    for name in to_link:
        try:
            await ask_link(name)
        except Exception as e:
            print("Liaison impossible pour %s : %s" % (name, e), flush=True)
    return True


# ------------------------------------------------------------------ liaison personnage <-> compte Discord
def link_state(name):
    return store.d.setdefault("link_state", {}).get(name)


def find_member(pseudo):
    p = pseudo.strip().lstrip("@").lower()
    for g in client.guilds:
        for m in g.members:
            if p in (m.name.lower(), (m.global_name or "").lower(), m.display_name.lower()):
                return m
    return None


async def ask_link(name):
    """Le joueur a renseigné son pseudo Discord dans l'addon : on lui demande de confirmer en message privé."""
    card = (store.d.get("chars") or {}).get(name) or {}
    pseudo = card.get("discord")
    if not pseudo:
        return
    st = link_state(name)
    now = int(time.time())
    if st and st.get("discord", "").lower() == pseudo.lower():
        if st["state"] in ("ok", "pending", "refused"):
            return
        if now - st.get("t", 0) < 3600:          # introuvable / MP fermés : on réessaie au plus 1 fois par heure
            return
    states = store.d.setdefault("link_state", {})
    member = find_member(pseudo)
    if not member:
        states[name] = {"discord": pseudo, "state": "notfound", "t": now}
        store.save()
        return
    view = discord.ui.View(timeout=None)
    view.add_item(discord.ui.Button(label="Confirmer", style=discord.ButtonStyle.success, custom_id="browzlink:yes:" + name))
    view.add_item(discord.ui.Button(label="Refuser", style=discord.ButtonStyle.danger, custom_id="browzlink:no:" + name))
    e = discord.Embed(title="🔗 Lier un personnage à ton compte", color=COLOR_INFO,
                      description="Le personnage **%s** (guilde Browz Forever) indique ton pseudo Discord.\n"
                                  "C'est bien toi ?" % name)
    e.set_footer(text=FOOTER)
    try:
        await member.send(embed=e, view=view)
        states[name] = {"discord": pseudo, "state": "pending", "user": str(member.id), "t": now}
    except discord.Forbidden:
        states[name] = {"discord": pseudo, "state": "dm_closed", "user": str(member.id), "t": now}
    store.save()


@client.event
async def on_interaction(interaction):
    data = interaction.data or {}
    cid = data.get("custom_id", "") if isinstance(data, dict) else ""
    if not cid.startswith("browzlink:"):
        return
    _, answer, name = cid.split(":", 2)
    st = link_state(name)
    if not st or st.get("user") != str(interaction.user.id):
        await interaction.response.send_message("Cette demande n'est plus valable.", ephemeral=True)
        return
    if answer == "yes":
        st["state"] = "ok"
        links = store.d.setdefault("links", {})
        names = links.setdefault(str(interaction.user.id), [])
        if name not in names:
            names.append(name)
        text = "✅ **%s** est maintenant lié à ton compte." % name
    else:
        st["state"] = "refused"
        text = "❌ Liaison refusée pour **%s**." % name
    st["t"] = int(time.time())
    store.save()
    await interaction.response.edit_message(content=text, embed=None, view=None)


def discord_status(name):
    st = link_state(name)
    if not st:
        return None
    return {"ok": "<@%s> ✅" % st.get("user"),
            "pending": "%s — en attente de confirmation" % st.get("discord"),
            "refused": "%s — liaison refusée" % st.get("discord"),
            "notfound": "%s — pseudo introuvable sur le serveur" % st.get("discord"),
            "dm_closed": "%s — messages privés fermés, confirmation impossible" % st.get("discord")}.get(st["state"])


async def ingest(request):
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "erreur": "json"}, status=400)
    if not await process(body):
        return web.json_response({"ok": False, "erreur": "clé"}, status=403)
    return web.json_response({"ok": True})


# ------------------------------------------------------------------ commandes
browz = app_commands.Group(name="browz", description="Browz Forever : banque de guilde")


def bank_header():
    bank = store.d.get("bank")
    if not bank:
        return None
    return "💰 **%s** · scan de %s <t:%d:R>" % (money(bank.get("money", 0)), bank.get("scanner", "?"), bank.get("time", 0))


class Pages(discord.ui.View):
    def __init__(self, embeds):
        super().__init__(timeout=600)
        self.embeds, self.i = embeds, 0
        self.update()

    def update(self):
        self.prev.disabled = self.i == 0
        self.next.disabled = self.i >= len(self.embeds) - 1

    @discord.ui.button(label="◀", style=discord.ButtonStyle.secondary)
    async def prev(self, interaction, _):
        self.i -= 1
        self.update()
        await interaction.response.edit_message(embed=self.embeds[self.i], view=self)

    @discord.ui.button(label="▶", style=discord.ButtonStyle.secondary)
    async def next(self, interaction, _):
        self.i += 1
        self.update()
        await interaction.response.edit_message(embed=self.embeds[self.i], view=self)


def paged(title, header, blocks, color=COLOR_INFO):
    """blocks = [(titre de section, [lignes])] -> liste d'embeds de 3 800 caractères max."""
    pages, cur = [], header + "\n" if header else ""
    for sec, rows in blocks:
        chunk = "\n**%s**\n" % sec
        for r in rows:
            if len(cur) + len(chunk) + len(r) > 3800:
                pages.append(cur + chunk)
                cur, chunk = "", "**%s (suite)**\n" % sec
            chunk += r + "\n"
        cur += chunk
    if cur.strip() or not pages:
        pages.append(cur or "Rien à afficher.")
    embeds = []
    for i, text in enumerate(pages, 1):
        e = discord.Embed(title=title, description=text, color=color)
        e.set_footer(text="%s · page %d/%d" % (FOOTER, i, len(pages)))
        embeds.append(e)
    return embeds


async def send_pages(interaction, embeds, ephemeral=False):
    if len(embeds) == 1:
        await interaction.response.send_message(embed=embeds[0], ephemeral=ephemeral)
    else:
        await interaction.response.send_message(embed=embeds[0], view=Pages(embeds), ephemeral=ephemeral)


def list_embeds():
    tot, _ = store.bank_totals()
    groups = {}
    for iid, n in tot.items():
        groups.setdefault(store.category(iid), []).append((store.name(iid), iid, n))
    blocks = []
    for key, label in CATS:
        rows = sorted(groups.get(key, []))
        if rows:
            blocks.append(("%s (%d)" % (label, len(rows)), ["%s ×%d" % (store.label(iid), n) for _, iid, n in rows]))
    return paged("🏦 Banque de guilde — liste", bank_header(), blocks)


async def grid_message(tab_index):
    """Embed + image PNG de l'onglet demandé."""
    bank = store.d["bank"]
    tab = bank["tabs"][tab_index]
    ids = sorted({str(sl["id"]) for sl in (tab.get("slots") or {}).values()})
    paths = await ensure_icons(ids) if ids else {}
    title = "%s   ·   %s" % (tab.get("name") or "Onglet %d" % (tab_index + 1), money(bank.get("money", 0)))
    buf = await asyncio.get_running_loop().run_in_executor(
        None, lambda: render_tab(tab, lambda i: store.item(i).get("q"), paths, title))
    e = discord.Embed(title="🏦 Banque de guilde", description=bank_header(), color=COLOR_INFO)
    if not tab.get("viewable", True):
        e.description += "\n*Onglet non visible pour le membre qui a fait le scan.*"
    e.set_image(url="attachment://bdg.png")
    e.set_footer(text="%s · vue coffre · « Vue liste » pour les noms" % FOOTER)
    return e, discord.File(buf, filename="bdg.png")


class GridView(discord.ui.View):
    """Image de l'onglet + menus déroulants pour voir le nom des objets (Discord ne permet pas
    de survoler une image) + boutons d'onglets + bouton liste."""
    def __init__(self, current):
        super().__init__(timeout=900)
        tabs = (store.d.get("bank") or {}).get("tabs", [])
        # menus : objets de l'onglet affiché, par ordre alphabétique (25 par menu, 2 menus)
        tab = tabs[current] if current < len(tabs) else {}
        tot = {}
        for sl in (tab.get("slots") or {}).values():
            tot[str(sl["id"])] = tot.get(str(sl["id"]), 0) + sl["n"]
        items = sorted(tot.items(), key=lambda x: store.name(x[0]))
        chunks = [items[i:i + 25] for i in range(0, min(len(items), 50), 25)]
        for k, chunk in enumerate(chunks):
            sel = discord.ui.Select(
                placeholder=("🔎 Voir un objet de l'onglet" + (" — partie %d/%d" % (k + 1, len(chunks)) if len(chunks) > 1 else ""))[:150],
                options=[discord.SelectOption(label=("%s ×%d" % (store.name(i), n))[:100], value=i,
                                              emoji=store.quality_emoji(i)) for i, n in chunk],
                row=k)
            sel.callback = self._pick(sel)
            self.add_item(sel)
        for i, t in enumerate(tabs[:10]):
            b = discord.ui.Button(label=(t.get("name") or "Onglet %d" % (i + 1))[:80], row=2 + i // 5,
                                  style=discord.ButtonStyle.primary if i == current else discord.ButtonStyle.secondary)
            b.callback = self._tab(i)
            self.add_item(b)
        lst = discord.ui.Button(label="📋 Vue liste", style=discord.ButtonStyle.success, row=4)
        lst.callback = self._list
        self.add_item(lst)
        find = discord.ui.Button(label="🔎 Rechercher", style=discord.ButtonStyle.secondary, row=4)
        find.callback = self._search
        self.add_item(find)

    async def _search(self, interaction):
        await interaction.response.send_modal(SearchModal())

    def _pick(self, sel):
        async def cb(interaction):
            iid = sel.values[0]
            tot, where = store.bank_totals()
            e = discord.Embed(title=store.label(iid), color=COLOR_INFO, description="**×%d** en banque" % tot.get(iid, 0))
            if where.get(iid):
                e.add_field(name="Onglets", value="\n".join("%s : %d" % (t, n) for t, n in where[iid].items()), inline=False)
            e.set_footer(text=FOOTER)
            await interaction.response.send_message(embed=e, ephemeral=True)
        return cb

    def _tab(self, i):
        async def cb(interaction):
            await interaction.response.defer()
            e, f = await grid_message(i)
            await interaction.edit_original_response(embed=e, attachments=[f], view=GridView(i))
        return cb

    async def _list(self, interaction):
        embeds = list_embeds()
        await interaction.response.edit_message(embed=embeds[0], attachments=[], view=ListView(embeds))


class SearchModal(discord.ui.Modal, title="Rechercher dans la banque"):
    texte = discord.ui.TextInput(label="Nom (ou morceau du nom) de l'objet", placeholder="ex. : lin, plans, potion",
                                 min_length=2, max_length=60)

    async def on_submit(self, interaction):
        q = self.texte.value.strip().lower()
        tot, where = store.bank_totals()
        found = sorted((store.name(i), i) for i in tot if q in store.name(i).lower())
        if not found:
            await interaction.response.send_message("Aucun objet contenant « %s » dans la banque." % self.texte.value, ephemeral=True)
            return
        def tabs_of(i):
            w = where[i]
            if len(w) == 1:   # un seul onglet : la quantité est déjà donnée par ×N
                return next(iter(w))
            return ", ".join("%s (%d)" % (t, n) for t, n in w.items())
        rows = ["%s ×%d  ·  %s" % (store.label(i), tot[i], tabs_of(i)) for _, i in found]
        embeds = paged("🔎 « %s » — %d objet(s)" % (self.texte.value, len(found)), None, [("Résultats", rows)])
        await send_pages(interaction, embeds, ephemeral=True)


class ListView(Pages):
    def __init__(self, embeds):
        super().__init__(embeds)

    @discord.ui.button(label="🗃️ Vue coffre", style=discord.ButtonStyle.success)
    async def grid(self, interaction, _):
        await interaction.response.defer()
        e, f = await grid_message(0)
        await interaction.edit_original_response(embed=e, attachments=[f], view=GridView(0))


@browz.command(name="bdg", description="La banque de guilde, comme dans le jeu (onglets) ou en liste")
async def cmd_bdg(interaction: discord.Interaction):
    bank = store.d.get("bank")
    if not bank or not bank.get("tabs"):
        await interaction.response.send_message("Aucune photo de la banque pour l'instant.", ephemeral=True)
        return
    await interaction.response.defer()
    try:
        e, f = await grid_message(0)
        await interaction.followup.send(embed=e, file=f, view=GridView(0))
    except Exception as err:  # image impossible : on montre la liste
        print("Image de la banque impossible :", err, flush=True)
        embeds = list_embeds()
        await interaction.followup.send(embed=embeds[0], view=ListView(embeds))


async def gold(interaction):
    bank = store.d.get("bank")
    if not bank:
        await interaction.response.send_message("Aucune photo de la banque pour l'instant.", ephemeral=True)
        return
    now = int(time.time())
    e = discord.Embed(title="💰 Richesses de la banque", color=COLOR_GOLD, description="# %s" % money(bank.get("money", 0)))
    for label, delta in (("Sur 24 h", 86400), ("Sur 7 jours", 7 * 86400), ("Sur 30 jours", 30 * 86400)):
        before = store.money_at(now - delta)
        e.add_field(name=label, value=money(bank["money"] - before, sign=True) if before is not None else "—", inline=True)
    e.add_field(name="Dernier scan", value="%s <t:%d:R>" % (bank.get("scanner", "?"), bank.get("time", 0)), inline=False)
    e.set_footer(text=FOOTER)
    await interaction.response.send_message(embed=e)


@browz.command(name="or", description="Or de la banque de guilde")
async def cmd_or(interaction: discord.Interaction):
    await gold(interaction)


@browz.command(name="po", description="Or de la banque de guilde")
async def cmd_po(interaction: discord.Interaction):
    await gold(interaction)


async def item_autocomplete(interaction: discord.Interaction, current: str):
    tot, _ = store.bank_totals()
    cur = current.lower()
    found = sorted((store.name(i), i) for i in tot if cur in store.name(i).lower())
    return [app_commands.Choice(name=("%s ×%d" % (n, tot[i]))[:100], value=i) for n, i in found[:25]]


@browz.command(name="objet", description="Quantité d'un objet dans la banque de guilde")
@app_commands.describe(nom="Commence à taper le nom de l'objet")
@app_commands.autocomplete(nom=item_autocomplete)
async def cmd_objet(interaction: discord.Interaction, nom: str):
    tot, where = store.bank_totals()
    iid = nom if nom in tot else next((i for i in tot if store.name(i).lower() == nom.lower()), None)
    if not iid:
        await interaction.response.send_message("« %s » n'est pas dans la banque (d'après le dernier scan)." % nom, ephemeral=True)
        return
    e = discord.Embed(title=store.label(iid), color=COLOR_INFO, description="# ×%d en banque" % tot[iid])
    e.add_field(name="Onglets", value="\n".join("%s : %d" % (t, n) for t, n in where[iid].items()), inline=False)
    moves = [m for m in store.movements(kind="objets") if m.get("id") == iid][:5]
    if moves:
        e.add_field(name="Derniers mouvements", value="\n".join(store.movement_line(m) for m in moves), inline=False)
    hdr = bank_header()
    if hdr:
        e.add_field(name="​", value=hdr, inline=False)
    e.set_footer(text=FOOTER)
    await interaction.response.send_message(embed=e)


async def player_autocomplete(interaction: discord.Interaction, current: str):
    cur = current.lower()
    return [app_commands.Choice(name=p, value=p) for p in store.players() if cur in p.lower()][:25]


@browz.command(name="journal", description="Journal des échanges et des richesses de la banque")
@app_commands.describe(type="Objets, or, ou tout", nombre="Nombre de lignes (1 à 50)", joueur="Filtrer sur un personnage")
@app_commands.choices(type=[app_commands.Choice(name="Tout", value="tout"),
                            app_commands.Choice(name="Objets", value="objets"),
                            app_commands.Choice(name="Or", value="or")])
@app_commands.autocomplete(joueur=player_autocomplete)
async def cmd_journal(interaction: discord.Interaction, type: app_commands.Choice[str] = None,
                      nombre: app_commands.Range[int, 1, 50] = 15, joueur: str = None):
    kind = type.value if type else "tout"
    moves = store.movements(who=joueur, kind=kind)[:nombre]
    rows = [store.movement_line(m) for m in moves] or ["Aucun mouvement connu."]
    title = "📒 Journal de la banque" + (" — %s" % joueur if joueur else "")
    await send_pages(interaction, paged(title, "≈ = heure reconstituée depuis le journal du jeu (à l'heure près)", [("Mouvements", rows)]))


CLASSES = {"WARRIOR": "Guerrier", "PALADIN": "Paladin", "HUNTER": "Chasseur", "ROGUE": "Voleur", "PRIEST": "Prêtre",
           "SHAMAN": "Chaman", "MAGE": "Mage", "WARLOCK": "Démoniste", "DRUID": "Druide"}
ROLES = {"TANK": "🛡️ Tank", "HEALER": "💚 Soigneur", "DAMAGER": "⚔️ DPS"}
SLOTS = {1: "Tête", 2: "Cou", 3: "Épaules", 15: "Dos", 5: "Torse", 9: "Poignets", 10: "Mains", 6: "Taille",
         7: "Jambes", 8: "Pieds", 11: "Doigt 1", 12: "Doigt 2", 13: "Bijou 1", 14: "Bijou 2", 16: "Main droite",
         17: "Main gauche", 18: "À distance"}
INSPECT_PAGES = [("fiche", "📋 Fiche"), ("metiers", "🔨 Métiers"), ("equipement", "🛡️ Équipement"), ("banque", "🏦 Banque")]
NO_ADDON = ("⚠️ **%s n'a pas l'addon Browz Forever** (ou ne s'est pas encore connecté avec) : "
            "seules les informations de la liste de guilde sont disponibles.")
NOT_ANALYZED = "*Non analysé : ce joueur n'a pas l'addon Browz Forever, ces informations ne sont pas connues.*"


def _find(table, name):
    table = table or {}
    return table.get(name) or next((v for k, v in table.items() if k.lower() == name.lower()), None)


def char_data(name):
    """Fiche envoyée par l'addon du joueur (None s'il n'a pas l'addon)."""
    return _find(store.d.get("chars"), name)


def roster_data(name):
    """Ligne de la liste de guilde (connue même sans l'addon, envoyée par n'importe quel membre équipé)."""
    return _find(store.d.get("roster"), name)


def inspect_embed(name, page):
    c = char_data(name)
    e = discord.Embed(title="👤 %s" % name, color=COLOR_INFO)
    if page == "fiche":
        if not c:
            r = roster_data(name)
            e.description = NO_ADDON % name
            if r:
                e.add_field(name="Classe", value="%s niveau %s" % (CLASSES.get(r.get("class"), r.get("class") or "?"), r.get("level", "?")))
                e.add_field(name="Grade", value=r.get("rank") or "?")
                if r.get("online"):
                    e.add_field(name="Statut", value="🟢 En ligne")
                elif r.get("seen"):
                    e.add_field(name="Dernière connexion", value=r["seen"])
                if r.get("note"):
                    e.add_field(name="Note de guilde", value=r["note"][:1024], inline=False)
            else:
                e.add_field(name="Liste de guilde", value="Personnage absent de la dernière liste reçue.", inline=False)
            e.add_field(name="Rôle, talents, rerolls, Discord", value=NOT_ANALYZED, inline=False)
        else:
            e.add_field(name="Classe", value="%s niveau %s" % (CLASSES.get(c.get("class"), c.get("class") or "?"), c.get("level", "?")))
            e.add_field(name="Grade", value=c.get("rank") or "?")
            e.add_field(name="Rôle", value=ROLES.get(c.get("role"), "—"))
            if c.get("spec"):
                e.add_field(name="Spécialisation active", value=c["spec"])
            dstat = discord_status(name)
            if dstat:
                e.add_field(name="Discord", value=dstat)
            alts = [a for a in c.get("alts") or [] if a != name]
            if alts:
                e.add_field(name="Rerolls", value=", ".join(alts)[:1024], inline=False)
            if c.get("t"):
                e.add_field(name="Dernière connexion", value="<t:%d:R>" % c["t"], inline=False)
    elif page == "metiers":
        profs = (c or {}).get("profs") or []
        if not c:
            e.description = NOT_ANALYZED
        elif not profs:
            e.description = "Aucun métier."
        else:
            def line(p):
                return "**%s** — %s/%s%s" % (p.get("n"), p.get("lvl", "?"), p.get("max", "?"),
                                              ("  ·  *%s*" % p["spe"]) if p.get("spe") else "")
            main = [line(p) for p in profs if p.get("main")]
            other = [line(p) for p in profs if not p.get("main")]
            if main:
                e.add_field(name="Métiers principaux", value="\n".join(main), inline=False)
            if other:
                e.add_field(name="Métiers secondaires", value="\n".join(other), inline=False)
    elif page == "equipement":
        gear = None
        if c and c.get("gear"):
            gear = c["gear"] if isinstance(c["gear"], dict) else {"ilvl": c.get("ilvl"), "items": c["gear"]}
        if not gear:
            e.description = NOT_ANALYZED if not c else "Équipement pas encore envoyé."
        else:
            e.description = "Niveau d'objet moyen : **%s**" % gear.get("ilvl", "?")
            rows = ["%s : %s" % (SLOTS.get(it.get("slot"), it.get("slot")), store.label(it.get("id"))) for it in gear.get("items", [])]
            if rows:
                e.add_field(name="Pièces", value="\n".join(rows)[:1024], inline=False)
    else:  # banque
        moves = store.movements(who=name)
        if not moves:
            e.description = "Aucun mouvement connu avec la banque."
        else:
            dep = sum(m["d"] for m in moves if "d" in m and m["d"] > 0)
            ret = -sum(m["d"] for m in moves if "d" in m and m["d"] < 0)
            gin = sum(m["money"] for m in moves if "money" in m and m["money"] > 0)
            gout = -sum(m["money"] for m in moves if "money" in m and m["money"] < 0)
            e.add_field(name="📥 Objets déposés", value=str(dep))
            e.add_field(name="📤 Objets retirés", value=str(ret))
            e.add_field(name="\u200b", value="\u200b")
            e.add_field(name="💰 Or déposé", value=money(gin))
            e.add_field(name="💸 Or retiré", value=money(gout))
            e.add_field(name="\u200b", value="\u200b")
            e.add_field(name="Derniers mouvements", value="\n".join(store.movement_line(m) for m in moves[:10])[:1024], inline=False)
    label = dict(INSPECT_PAGES)[page]
    e.set_footer(text="%s · %s" % (FOOTER, label))
    return e


class InspectView(discord.ui.View):
    def __init__(self, name, page):
        super().__init__(timeout=900)
        for key, label in INSPECT_PAGES:
            b = discord.ui.Button(label=label, style=discord.ButtonStyle.primary if key == page else discord.ButtonStyle.secondary)
            b.callback = self._go(name, key)
            self.add_item(b)

    def _go(self, name, key):
        async def cb(interaction):
            await interaction.response.edit_message(embed=inspect_embed(name, key), view=InspectView(name, key))
        return cb


async def inspect_autocomplete(interaction: discord.Interaction, current: str):
    names = set(store.players()) | set((store.d.get("chars") or {}).keys()) | set((store.d.get("roster") or {}).keys())
    cur = current.lower()
    return [app_commands.Choice(name=n, value=n) for n in sorted(names) if cur in n.lower()][:25]


@browz.command(name="inspect", description="Fiche d'un personnage : métiers, équipement, historique avec la banque")
@app_commands.describe(nom="Nom du personnage")
@app_commands.autocomplete(nom=inspect_autocomplete)
async def cmd_inspect(interaction: discord.Interaction, nom: str):
    await interaction.response.send_message(embed=inspect_embed(nom, "fiche"), view=InspectView(nom, "fiche"))


async def metier_autocomplete(interaction: discord.Interaction, current: str):
    names = set()
    for c in (store.d.get("chars") or {}).values():
        for p in c.get("profs") or []:
            if p.get("n"):
                names.add(p["n"])
    cur = current.lower()
    return [app_commands.Choice(name=n, value=n) for n in sorted(names) if cur in n.lower()][:25]


@browz.command(name="metier", description="Les membres de la guilde qui ont un métier, du plus haut niveau au plus bas")
@app_commands.describe(nom="Le métier (Forge, Ingénierie, Couture…)")
@app_commands.autocomplete(nom=metier_autocomplete)
async def cmd_metier(interaction: discord.Interaction, nom: str):
    rows = []
    for c in (store.d.get("chars") or {}).values():
        for p in c.get("profs") or []:
            if (p.get("n") or "").lower() == nom.lower():
                rows.append((p.get("lvl") or 0, c.get("name"), p))
    if not rows:
        await interaction.response.send_message("Personne n'a « %s » parmi les membres qui ont l'addon." % nom, ephemeral=True)
        return
    rows.sort(key=lambda r: (-r[0], r[1]))
    lines = ["**%s** — %s/%s%s" % (n, p.get("lvl", "?"), p.get("max", "?"), ("  ·  *%s*" % p["spe"]) if p.get("spe") else "")
             for _, n, p in rows]
    embeds = paged("🔨 %s — %d membre(s)" % (nom, len(rows)), "*Seuls les membres qui ont l'addon Browz Forever apparaissent.*",
                   [("Artisans", lines)])
    await send_pages(interaction, embeds)


client.tree.add_command(browz)


# ------------------------------------------------------------------ résumé mensuel
MONTHS = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre",
          "novembre", "décembre"]


@tasks.loop(minutes=30)
async def monthly():
    now = dt.datetime.now()
    key = now.strftime("%Y-%m")
    if now.day != 1 or now.hour < 10 or store.d.get("last_monthly") == key:
        return
    ch = find_channel("salon_bdg")
    if not ch:
        return
    year, month = (now.year, now.month - 1) if now.month > 1 else (now.year - 1, 12)
    start = int(dt.datetime(year, month, 1).timestamp())
    end = int(dt.datetime(year, month, calendar.monthrange(year, month)[1], 23, 59, 59).timestamp())
    s = store.month_summary(start, end)
    e = discord.Embed(title="📊 Bilan de %s %d" % (MONTHS[month - 1], year), color=COLOR_GOLD)
    if s["money_start"] is not None and s["money_end"] is not None:
        e.add_field(name="Or", value="%s → %s (%s)" % (money(s["money_start"]), money(s["money_end"]),
                                                       money(s["money_end"] - s["money_start"], sign=True)), inline=False)
    top = sorted(s["contrib"].items(), key=lambda x: -x[1])[:5]
    if top:
        e.add_field(name="🏅 Plus gros dons en or", value="\n".join("%s : %s" % (w, money(v)) for w, v in top), inline=False)
    topi = sorted(s["items_in"].items(), key=lambda x: -x[1])[:5]
    if topi:
        e.add_field(name="📥 Plus gros déposants d'objets", value="\n".join("%s : %d objets" % (w, v) for w, v in topi), inline=False)
    topw = sorted(s["withdrawn"].items(), key=lambda x: -x[1])[:5]
    if topw:
        e.add_field(name="📤 Objets les plus retirés", value="\n".join("%d× %s" % (v, store.name(i)) for i, v in topw), inline=False)
    e.set_footer(text="%s · %d mouvements ce mois-ci" % (FOOTER, s["count"]))
    await ch.send(embed=e)
    store.d["last_monthly"] = key
    store.save()


@monthly.before_loop
async def before_monthly():
    await client.wait_until_ready()


# ------------------------------------------------------------------ sauvegarde hebdomadaire
@tasks.loop(minutes=30)
async def backup():
    """Chaque dimanche à partir de 12 h : le fichier de données part en message privé au propriétaire du bot."""
    now = dt.datetime.now()
    week = now.strftime("%G-S%V")
    if now.weekday() != 6 or now.hour < 12 or store.d.get("last_backup") == week:
        return
    await send_backup("Sauvegarde hebdomadaire")
    store.d["last_backup"] = week
    store.save()


async def send_backup(reason):
    try:
        info = await client.application_info()
        owner = info.owner
        store.save()
        with open(DATA_PATH, "rb") as f:
            data = f.read()
        name = "browz_sauvegarde_%s.json" % dt.datetime.now().strftime("%Y-%m-%d")
        await owner.send("💾 %s de Browz Forever. Pour restaurer : remplacer `donnees.json` par ce fichier "
                         "(en le renommant) puis redémarrer le bot." % reason,
                         file=discord.File(io.BytesIO(data), filename=name))
        print("Sauvegarde envoyée à %s." % owner, flush=True)
    except Exception as e:
        print("Sauvegarde impossible :", e, flush=True)


@backup.before_loop
async def before_backup():
    await client.wait_until_ready()


if __name__ == "__main__":
    if "--test-icones" in sys.argv:
        ids = [a for a in sys.argv[1:] if a.isdigit()] or ["11185", "248696"]
        res = asyncio.run(ensure_icons(ids))
        for i in ids:
            print(i, "->", res.get(i) or "point d'interrogation")
        sys.exit(0)
    if not cfg.get("token"):
        print("Colle le jeton du bot dans config_bot.json (champ \"token\"), puis relance.")
        input("Entrée pour fermer…")
    else:
        client.run(cfg["token"])
