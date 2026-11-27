"""Browz Forever — client pont (PC -> bot Discord).

Lit deux sorties de l'addon BrowzForever :
  1. Logs\\WoWChatLog.txt : lignes « BRWZ1 » (passages au coffre, quasi en direct)
  2. WTF\\Account\\<compte>\\SavedVariables\\BrowzForever.lua : photo de la banque, journaux,
     boîte d'envoi (écrit au /reload, à la déconnexion ou en quittant le jeu)
et envoie le tout au bot. Python standard uniquement, rien à installer.

Lancement :  python browz_client.py            (normal)
             python browz_client.py --test     (affiche ce qui serait envoyé, sans rien envoyer)
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")
STATE_PATH = os.path.join(HERE, "etat.json")
DEFAULT_WOW = r"C:\Program Files (x86)\World of Warcraft\_forever_"
POLL_SECONDS = 3


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


# ---------------------------------------------------------------- configuration / état
def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def load_config():
    cfg = load_json(CONFIG_PATH, None)
    if cfg is None:
        cfg = {"wow_path": DEFAULT_WOW, "bot_url": "", "cle_guilde": ""}
        save_json(CONFIG_PATH, cfg)
        log("config.json créé : renseigne bot_url et cle_guilde (mode test possible sans).")
    return cfg


# ---------------------------------------------------------------- lecture des SavedVariables
class LuaParser:
    """Lit le format des SavedVariables de WoW (tables, chaînes, nombres, booléens, nil)."""
    TOKEN = re.compile(r'\s*(?:(--[^\n]*)|("(?:[^"\\]|\\.)*")|(\[|\]|\{|\}|=|,|;)|'
                       r'(-?(?:0x[0-9a-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+))|([A-Za-z_][A-Za-z0-9_]*))', re.S)

    def __init__(self, text):
        self.tokens = []
        pos = 0
        while pos < len(text):
            m = self.TOKEN.match(text, pos)
            if not m or m.end() == pos:
                if text[pos:].strip() == "":
                    break
                raise ValueError("Lua illisible vers la position %d" % pos)
            pos = m.end()
            comment, string, sym, num, name = m.groups()
            if comment:
                continue
            if string is not None:
                self.tokens.append(("str", self._unescape(string[1:-1])))
            elif sym:
                self.tokens.append(("sym", sym))
            elif num:
                self.tokens.append(("num", float(int(num, 16)) if num.lower().startswith(("0x", "-0x")) else float(num)))
            elif name:
                self.tokens.append(("name", name))
        self.i = 0

    @staticmethod
    def _unescape(s):
        out, i = [], 0
        while i < len(s):
            c = s[i]
            if c == "\\" and i + 1 < len(s):
                n = s[i + 1]
                if n.isdigit():
                    j = i + 1
                    while j < len(s) and j < i + 4 and s[j].isdigit():
                        j += 1
                    out.append(chr(int(s[i + 1:j])))
                    i = j
                    continue
                out.append({"n": "\n", "t": "\t", "r": "\r"}.get(n, n))
                i += 2
                continue
            out.append(c)
            i += 1
        # les octets UTF-8 échappés en \ddd sont recollés ici
        try:
            return "".join(out).encode("latin-1").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            return "".join(out)

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else (None, None)

    def take(self):
        t = self.peek()
        self.i += 1
        return t

    def value(self):
        kind, v = self.take()
        if kind in ("str",):
            return v
        if kind == "num":
            return int(v) if v.is_integer() else v
        if kind == "name":
            return {"true": True, "false": False, "nil": None}.get(v, v)
        if kind == "sym" and v == "{":
            return self.table()
        raise ValueError("valeur inattendue : %r" % (v,))

    def table(self):
        arr, obj, n = [], {}, 0
        while True:
            kind, v = self.peek()
            if kind == "sym" and v == "}":
                self.take()
                break
            if kind == "sym" and v == "[":
                self.take()
                key = self.value()
                self.take()  # ]
                self.take()  # =
                obj[key] = self.value()
            else:
                n += 1
                obj[n] = self.value()
            kind, v = self.peek()
            if kind == "sym" and v in (",", ";"):
                self.take()
        # tableau Lua (clés 1..n) -> liste Python
        if obj and all(isinstance(k, int) for k in obj) and sorted(obj) == list(range(1, len(obj) + 1)):
            return [obj[k] for k in range(1, len(obj) + 1)]
        return obj

    def assignments(self):
        out = {}
        while self.i < len(self.tokens):
            kind, name = self.take()
            if kind != "name":
                continue
            self.take()  # =
            out[name] = self.value()
        return out


def find_savedvars(wow):
    base = os.path.join(wow, "WTF", "Account")
    best = None
    for acc in os.listdir(base) if os.path.isdir(base) else []:
        p = os.path.join(base, acc, "SavedVariables", "BrowzForever.lua")
        if os.path.isfile(p) and (best is None or os.path.getmtime(p) > os.path.getmtime(best)):
            best = p
    return best


def read_savedvars(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    return LuaParser(text).assignments().get("BrowzForeverDB") or {}


# ---------------------------------------------------------------- formats de l'addon
def parse_event(s):
    parts = s.split("^")
    if len(parts) < 7 or parts[0] != "1":
        return None
    items = {}
    for pair in parts[5].split(";"):
        m = re.match(r"^(\d+),(-?\d+)$", pair)
        if m:
            items[int(m.group(1))] = int(m.group(2))
    names = {}
    if len(parts) > 7:
        for entry in parts[7].split(";"):
            f = entry.split("=")
            if len(f) >= 2 and f[0].isdigit():
                names[f[0]] = {"n": f[1], "q": int(f[2]) if len(f) > 2 and f[2].isdigit() else None,
                               "c": int(f[3]) if len(f) > 3 and f[3].isdigit() else None}
    return {"id": parts[1], "who": parts[2], "t": int(parts[3]), "money": int(parts[4] or 0),
            "items": {str(k): v for k, v in items.items()}, "src": parts[6], "names": names}


def parse_card(s):
    """Fiche de personnage de l'addon : 1^nom^classe^niveau^grade^rôle^spé^discord^t^métiers^ilvl^équipement^rerolls"""
    f = s.split("^")
    if len(f) < 13 or f[0] != "1":
        return None
    profs = []
    for entry in filter(None, f[9].split(";")):
        p = entry.split("=")
        if len(p) >= 4:
            profs.append({"n": p[0], "lvl": int(p[1] or 0), "max": int(p[2] or 0), "main": p[3] == "1",
                          "spe": (p[4].strip() or None) if len(p) > 4 else None,
                          "sl": int(p[5]) if len(p) > 5 and p[5].isdigit() else None})
    gear = []
    for entry in filter(None, f[11].split(";")):
        m = re.match(r"^(\d+),(\d+)$", entry)
        if m:
            gear.append({"slot": int(m.group(1)), "id": int(m.group(2))})
    sets = []
    if len(f) > 13:
        for chunk in filter(None, f[13].split("!")):
            parts = chunk.split("@")
            items = []
            for pair in filter(None, (parts[2] if len(parts) > 2 else "").split(":")):
                m = re.match(r"^(\d+),(\d+)$", pair)
                if m:
                    items.append({"slot": int(m.group(1)), "id": int(m.group(2))})
            sets.append({"name": parts[0].strip(), "spec": (parts[1].strip() or None) if len(parts) > 1 else None,
                         "items": items})
    talents = None
    if len(f) > 14 and f[14].strip():
        t = f[14].split("@")
        chosen = []
        for entry in filter(None, (t[2] if len(t) > 2 else "").split(":")):
            m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", entry)
            if m:
                chosen.append([int(m.group(1)), int(m.group(2)), int(m.group(3))])
        talents = {"key": t[0], "loadout": (" ".join(t[1].split()) or None) if len(t) > 1 else None, "chosen": chosen,
                   "import": (t[3].strip() or None) if len(t) > 3 else None}
    return {"name": f[1], "class": f[2] or None, "level": int(f[3] or 0), "rank": f[4] or None,
            "role": f[5] or None, "spec": f[6].strip() or None, "discord": f[7].strip() or None,
            "t": int(f[8] or 0), "profs": profs, "ilvl": int(f[10] or 0) or None,
            "gear": gear, "alts": [a for a in f[12].split("&") if a], "sets": sets, "talents": talents}


def parse_layout(s):
    """Forme d'un arbre de talents : 1^clé^spé^nœud;nœud… (nœud = id,x,y,max,type,liens/…,sort[p]/…)"""
    f = s.split("^")
    if len(f) < 4 or f[0] != "1":
        return None
    nodes = []
    for entry in filter(None, f[3].split(";")):
        p = entry.split(",")
        if len(p) < 7:
            continue
        try:
            spells = []
            for sp in filter(None, p[6].split("/")):
                spells.append([int(sp.rstrip("p")), sp.endswith("p")])
            nodes.append({"id": int(p[0]), "x": int(p[1]), "y": int(p[2]), "max": int(p[3] or 1), "type": int(p[4] or 0),
                          "edges": [int(e) for e in p[5].split("/") if e], "spells": spells})
        except ValueError:
            continue
    if not nodes:
        return None
    return {"key": f[1], "spec": int(f[2] or 0), "nodes": nodes}


def bank_to_json(bank):
    """Photo de banque de l'addon -> JSON simple pour le bot."""
    if not isinstance(bank, dict):
        return None
    tabs0 = bank.get("tabs") or []
    first = (tabs0[0] if isinstance(tabs0, list) and tabs0 else None)
    if isinstance(first, dict) and "slots" not in first:
        return None  # ancien format (addon v0.1) : ignoré
    tabs = []
    raw_tabs = bank.get("tabs") or []
    if isinstance(raw_tabs, dict):
        raw_tabs = [raw_tabs[k] for k in sorted(raw_tabs)]
    for tab in raw_tabs:
        slots = tab.get("slots") or {}
        if isinstance(slots, list):
            slots = {i + 1: v for i, v in enumerate(slots) if v}
        tabs.append({
            "name": tab.get("name"),
            "viewable": bool(tab.get("viewable")),
            "slots": {str(k): {"id": v.get("id"), "n": v.get("n")} for k, v in slots.items() if isinstance(v, dict)},
        })
    return {"time": bank.get("time"), "scanner": bank.get("scanner"), "money": bank.get("money", 0), "tabs": tabs}


# ---------------------------------------------------------------- suivi du journal de chat
# Seules les lignes ENVOYÉES par ce client comptent (« À X : » / « To X: ») : un chuchotement
# reçu d'un autre joueur ne peut donc pas fabriquer un faux passage au coffre.
LINE_RE = re.compile(r"^(\d+/\d+ [\d:.]+)\s+(?:À|To) .+?[\s\u00a0]*:\s*(BRWZ1 .*)$")


class ChatTail:
    def __init__(self, path, state):
        self.path = path
        self.state = state
        # morceaux en attente, gardés dans etat.json : un redémarrage du client au milieu d'un
        # envoi ne perd plus le message (les lignes déjà lues ne sont pas relues)
        self.parts = {tuple(k.split("|", 1)): {"n": v["n"], "got": {int(i): d for i, d in v["got"].items()}}
                      for k, v in state.get("morceaux", {}).items()}
        self.seen = set(state.get("vus", []))

    def poll(self):
        """Renvoie la liste des passages complets trouvés depuis le dernier appel."""
        out = []
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return out
        offset = self.state.get("chatlog_offset", None)
        if offset is None:
            offset = 0 if self.state.get("lire_journal_depuis_debut") else size
        if size < offset:  # nouveau fichier (le jeu l'a recréé)
            offset = 0
        if size == offset:
            self.state["chatlog_offset"] = offset
            return out
        with open(self.path, "rb") as f:
            f.seek(offset)
            data = f.read(size - offset)
        # on ne traite que les lignes complètes
        cut = data.rfind(b"\n")
        if cut < 0:
            return out
        self.state["chatlog_offset"] = offset + cut + 1
        self.state.pop("lire_journal_depuis_debut", None)
        for raw in data[:cut].split(b"\n"):
            if b"BRWZ1" not in raw:
                continue
            line = raw.decode("utf-8", errors="replace").rstrip("\r")
            m = LINE_RE.match(line)
            if not m:
                continue
            fields = m.group(2).split(" ", 5)
            if len(fields) < 6:
                continue
            _, kind, seq, i, n, payload = fields
            k = "%s|%s|%s|%s" % (kind, seq, i, payload[:40])
            if k in self.seen:
                continue
            self.seen.add(k)
            p = self.parts.setdefault((kind, seq), {"n": int(n), "got": {}})
            p["got"][int(i)] = payload
            if len(p["got"]) >= p["n"]:
                del self.parts[(kind, seq)]
                full = "".join(p["got"][j] for j in range(1, p["n"] + 1))
                if kind == "E":
                    ev = parse_event(full)
                    if ev:
                        out.append(("E", ev))
                elif kind == "C":
                    card = parse_card(full)
                    if card:
                        out.append(("C", card))
                elif kind == "T":
                    lay = parse_layout(full)
                    if lay:
                        out.append(("T", lay))
        self.state["vus"] = list(self.seen)[-500:]
        self.state["morceaux"] = {"%s|%s" % k: {"n": v["n"], "got": {str(i): d for i, d in v["got"].items()}}
                                  for k, v in list(self.parts.items())[-50:]}
        return out


# ---------------------------------------------------------------- envoi au bot
class Sender:
    def __init__(self, cfg, state, test):
        self.cfg, self.state, self.test = cfg, state, test
        self.pending = state.setdefault("en_attente", [])

    def push(self, kind, payload):
        self.pending.append({"kind": kind, "payload": payload})

    def flush(self):
        if not self.pending:
            return
        if self.test or not (self.cfg.get("bot_url") or self.cfg.get("webhook_url")):
            for p in self.pending:
                pl = p["payload"]
                if p["kind"] == "events":
                    for e in pl:
                        log("[TEST] passage : %s, or %+d, objets %s (%s)" % (e["who"], e["money"], e["items"], e["src"]))
                elif p["kind"] == "bank":
                    nb = sum(len(t["slots"]) for t in pl["tabs"])
                    log("[TEST] photo de banque : %d onglet(s), %d cases, or %d, scan de %s"
                        % (len(pl["tabs"]), nb, pl["money"], pl["scanner"]))
                elif p["kind"] == "chars":
                    for c in pl.values():
                        log("[TEST] fiche : %s (%s %s), métiers : %s, Discord : %s" % (
                            c["name"], c.get("class"), c.get("level"),
                            ", ".join("%s %s%s" % (x["n"], x["lvl"], " (" + x["spe"] + ")" if x.get("spe") else "") for x in c["profs"]),
                            c.get("discord")))
                elif p["kind"] == "layouts":
                    for lay in pl.values():
                        log("[TEST] arbre de talents %s : %d talents" % (lay["key"], len(lay["nodes"])))
                elif p["kind"] == "roster":
                    log("[TEST] liste de guilde : %d membres" % len(pl["members"]))
                elif p["kind"] == "items":
                    log("[TEST] catalogue : %d objets connus" % len(pl))
                elif p["kind"] == "logs":
                    nb = sum(len(t) for t in pl.get("tabs", []))
                    log("[TEST] journaux : %d lignes objets, %d lignes or" % (nb, len(pl.get("money", []))))
            self.pending.clear()
            return
        if self.cfg.get("webhook_url"):
            return self._flush_webhook()
        url = self.cfg["bot_url"].rstrip("/") + "/api/ingest"
        while self.pending:
            body = json.dumps({"cle": self.cfg.get("cle_guilde", ""), **self.pending[0]}).encode("utf-8")
            req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=15) as r:
                    r.read()
                self.pending.pop(0)
            except (urllib.error.URLError, OSError) as e:
                log("Bot injoignable (%s) : nouvel essai plus tard, %d envoi(s) en attente." % (e, len(self.pending)))
                return


    def _flush_webhook(self):
        """Poste chaque envoi en pièce jointe JSON dans le salon caché ; le bot la lit puis l'efface."""
        url = self.cfg["webhook_url"].split("?")[0] + "?wait=true"
        if self.cfg.get("fil_id"):   # envoi dans un fil privé (pas de salon en plus)
            url += "&thread_id=%s" % str(self.cfg["fil_id"]).strip()
        while self.pending:
            item = self.pending[0]
            data = json.dumps({"cle": self.cfg.get("cle_guilde", ""), **item}, ensure_ascii=False).encode("utf-8")
            boundary = "----browz%d" % int(time.time() * 1000)
            meta = json.dumps({"content": "📦 %s" % item["kind"], "username": "Browz pont",
                               "attachments": [{"id": 0, "filename": "donnees.json"}]})
            body = b"".join([
                ("--%s\r\nContent-Disposition: form-data; name=\"payload_json\"\r\n"
                 "Content-Type: application/json\r\n\r\n" % boundary).encode(), meta.encode("utf-8"), b"\r\n",
                ("--%s\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"donnees.json\"\r\n"
                 "Content-Type: application/json\r\n\r\n" % boundary).encode(), data, b"\r\n",
                ("--%s--\r\n" % boundary).encode(),
            ])
            req = urllib.request.Request(url, data=body, headers={
                "Content-Type": "multipart/form-data; boundary=%s" % boundary, "User-Agent": "BrowzClient (1.0)"})
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    r.read()
                self.pending.pop(0)
                time.sleep(0.5)
            except urllib.error.HTTPError as e:
                if e.code == 429:   # trop d'envois : Discord indique combien attendre
                    try:
                        wait = float(json.loads(e.read().decode()).get("retry_after", 2))
                    except (ValueError, OSError):
                        wait = 2
                    time.sleep(min(wait, 30))
                    continue
                log("Discord refuse l'envoi (erreur %s) : vérifie webhook_url. %d envoi(s) en attente." % (e.code, len(self.pending)))
                return
            except (urllib.error.URLError, OSError) as e:
                log("Discord injoignable (%s) : nouvel essai plus tard, %d envoi(s) en attente." % (e, len(self.pending)))
                return


# ---------------------------------------------------------------- boucle principale
def normalize_logs(logs):
    if not isinstance(logs, dict):
        return None
    tabs = logs.get("tabs") or []
    if isinstance(tabs, dict):
        tabs = [tabs[k] for k in sorted(tabs)]
    return {"time": logs.get("time"), "reader": logs.get("reader"),
            "tabs": [t if isinstance(t, list) else [] for t in tabs], "money": logs.get("money") or []}


def outbox_events(db):
    evs = []
    for _, it in (db.get("outbox") or {}).items():
        ev = parse_event(it.get("data", "")) if isinstance(it, dict) else None
        if ev:
            evs.append(ev)
    return evs


def main():
    test = "--test" in sys.argv
    cfg = load_config()
    state = load_json(STATE_PATH, {})
    state.pop("lire_journal_depuis_debut", None)
    if "--depuis-debut" in sys.argv:
        state.pop("chatlog_offset", None)
        state["lire_journal_depuis_debut"] = True
    wow = cfg.get("wow_path") or DEFAULT_WOW
    chat = ChatTail(os.path.join(wow, "Logs", "WoWChatLog.txt"), state)
    sender = Sender(cfg, state, test)
    sv_path = find_savedvars(wow)
    sv_mtime = state.get("sv_mtime", 0)
    sent_ids = set(state.get("passages_envoyes", []))
    log("Browz Forever — client pont %s. Dossier : %s" % ("(MODE TEST)" if test else "", wow))
    if not sv_path:
        log("BrowzForever.lua introuvable pour l'instant (il apparaît après un /reload avec l'addon).")
    once = "--une-fois" in sys.argv

    while True:
        # 1) journal de chat
        found = chat.poll()
        evs = [x for k, x in found if k == "E" and x["id"] not in sent_ids]
        if evs:
            sender.push("events", evs)
            sent_ids.update(e["id"] for e in evs)
        cards = {x["name"]: x for k, x in found if k == "C"}
        if cards:
            sender.push("chars", cards)
        lays = {x["key"]: x for k, x in found if k == "T"}
        if lays:
            sender.push("layouts", lays)
        # 2) SavedVariables (après /reload, déconnexion ou sortie du jeu)
        sv_path = sv_path or find_savedvars(wow)
        if sv_path and os.path.getmtime(sv_path) > sv_mtime:
            try:
                db = read_savedvars(sv_path)
                sv_mtime = os.path.getmtime(sv_path)
                state["sv_mtime"] = sv_mtime
                bank = bank_to_json(db.get("bank"))
                if bank:
                    sender.push("bank", bank)
                cat = db.get("items") or {}
                if isinstance(cat, dict) and cat:
                    sender.push("items", {str(k): {"n": v.get("n"), "q": v.get("q"), "c": v.get("c"), "i": v.get("i")}
                                          for k, v in cat.items() if isinstance(v, dict) and v.get("n")})
                elif isinstance(cat, list) and cat:
                    sender.push("items", {str(i + 1): v for i, v in enumerate(cat) if isinstance(v, dict) and v.get("n")})
                cards = {}
                for _, it in (db.get("cards") or {}).items():
                    card = parse_card(it.get("data", "")) if isinstance(it, dict) else None
                    if card:
                        cards[card["name"]] = card
                if cards:
                    sender.push("chars", cards)
                lays = {}
                for _, it in (db.get("layouts") or {}).items():
                    lay = parse_layout(it.get("data", "")) if isinstance(it, dict) else None
                    if lay:
                        lays[lay["key"]] = lay
                if lays:   # renvoyés à chaque lecture (quelques Ko) : le bot les a toujours
                    sender.push("layouts", lays)
                roster = db.get("roster")
                if isinstance(roster, dict) and isinstance(roster.get("members"), dict):
                    sender.push("roster", {"t": roster.get("t"), "members": roster["members"]})
                logs = normalize_logs(db.get("logs"))
                if logs:
                    sender.push("logs", logs)
                evs = [e for e in outbox_events(db) if e["id"] not in sent_ids]
                if evs:
                    sender.push("events", evs)
                    sent_ids.update(e["id"] for e in evs)
            except (OSError, ValueError) as e:
                log("Lecture des SavedVariables impossible pour l'instant (%s)." % e)
        sender.flush()
        state["passages_envoyes"] = list(sent_ids)[-1000:]
        save_json(STATE_PATH, state)
        if once:
            break
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Arrêt.")
