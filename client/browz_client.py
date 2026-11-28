"""Browz Forever — client pont (PC -> bot Discord).

Lit deux sorties de l'addon BrowzForever :
  1. Logs\\WoWChatLog.txt : lignes « BRWZ1 » (passages au coffre, quasi en direct)
  2. WTF\\Account\\<compte>\\SavedVariables\\BrowzForever.lua : photo de la banque, journaux,
     boîte d'envoi (écrit au /reload, à la déconnexion ou en quittant le jeu)
et envoie le tout au bot. Python standard uniquement, rien à installer.

Lancement :  python browz_client.py            (normal)
             python browz_client.py --test     (affiche ce qui serait envoyé, sans rien envoyer)
             BrowzClient.exe                   (version sans Python, sans fenêtre, lancée avec Windows)
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CLIENT_VERSION = 15                             # à publier sur GitHub avec l'étiquette « client-v15 »
UPDATE_URL = "https://api.github.com/repos/GuillaumeClerc/BrowzForever/releases?per_page=20"
FROZEN = getattr(sys, "frozen", False)          # True dans BrowzClient.exe (PyInstaller)
HERE = os.path.dirname(sys.executable if FROZEN else os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")
STATE_PATH = os.path.join(HERE, "etat.json")
DEFAULT_WOW = r"C:\Program Files (x86)\World of Warcraft\_forever_"
POLL_SECONDS = 3


LOG_PATH = os.path.join(HERE, "browz_client.log")


def log(msg):
    line = "%s %s" % (time.strftime("%d/%m %H:%M:%S"), msg)
    if sys.stdout:
        try:
            print(line, flush=True)
        except (OSError, ValueError):
            pass
    try:   # journal sur disque (l'exe n'a pas de fenêtre) ; on repart à zéro au-delà de 1 Mo
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > 1_000_000:
            os.replace(LOG_PATH, LOG_PATH + ".old")
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


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


def ask_config(cfg):
    """Première installation de l'exe : petite fenêtre pour l'adresse du bot, la clé et le dossier de WoW."""
    try:
        import tkinter as tk
        from tkinter import filedialog
    except ImportError:
        return cfg
    root = tk.Tk()
    root.title("Browz Forever — client pont")
    root.resizable(False, False)
    tk.Label(root, text="Ces informations te sont données par Bellock (en privé).", pady=6).grid(row=0, columnspan=3)
    fields = {}
    for i, (key, label) in enumerate((("bot_url", "Adresse du bot"), ("cle_guilde", "Clé de guilde"),
                                       ("wow_path", "Dossier de WoW Forever")), start=1):
        tk.Label(root, text=label).grid(row=i, column=0, sticky="w", padx=8, pady=3)
        v = tk.StringVar(value=cfg.get(key) or (DEFAULT_WOW if key == "wow_path" else ""))
        tk.Entry(root, textvariable=v, width=52, show="•" if key == "cle_guilde" else "").grid(row=i, column=1, padx=4)
        fields[key] = v
    tk.Button(root, text="…", command=lambda: fields["wow_path"].set(
        filedialog.askdirectory(initialdir=fields["wow_path"].get()) or fields["wow_path"].get())).grid(row=3, column=2, padx=4)
    done = {"ok": False}

    def ok():
        done["ok"] = True
        root.destroy()
    tk.Button(root, text="Enregistrer", command=ok, width=16).grid(row=4, columnspan=3, pady=10)
    root.mainloop()
    if done["ok"]:
        for k, v in fields.items():
            cfg[k] = v.get().strip()
        save_json(CONFIG_PATH, cfg)
    return cfg


def load_config():
    cfg = load_json(CONFIG_PATH, None)
    if cfg is None:
        cfg = {"wow_path": DEFAULT_WOW, "bot_url": "", "cle_guilde": ""}
        save_json(CONFIG_PATH, cfg)
        log("config.json créé : renseigne bot_url et cle_guilde (mode test possible sans).")
    if FROZEN and not (cfg.get("bot_url") and cfg.get("cle_guilde")):
        cfg = ask_config(cfg)
    return cfg


# ---------------------------------------------------------------- mise à jour automatique (exe seulement)
# Le client regarde les « Releases » du dépôt GitHub : s'il y trouve une version plus récente (étiquette
# « client-vNN » avec un fichier BrowzClient.exe), il la télécharge, prend sa place et redémarre tout seul.
def check_update(lock):
    if not FROZEN:
        return
    try:
        req = urllib.request.Request(UPDATE_URL, headers={"User-Agent": "BrowzClient", "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=20) as r:
            releases = json.loads(r.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError):
        return
    best, url = CLIENT_VERSION, None
    for rel in releases if isinstance(releases, list) else []:
        m = re.match(r"^client-v(\d+)$", str(rel.get("tag_name", "")))
        if not m or rel.get("draft") or rel.get("prerelease") or int(m.group(1)) <= best:
            continue
        asset = next((a for a in rel.get("assets", []) if a.get("name") == "BrowzClient.exe"), None)
        if asset:
            best, url = int(m.group(1)), asset.get("browser_download_url")
    if not url or not url.startswith("https://github.com/GuillaumeClerc/BrowzForever/"):
        return
    exe = sys.executable
    new, old = exe + ".new", exe + ".old"
    try:
        log("Nouvelle version du client (v%d) : téléchargement…" % best)
        req = urllib.request.Request(url, headers={"User-Agent": "BrowzClient"})
        with urllib.request.urlopen(req, timeout=120) as r, open(new, "wb") as f:
            f.write(r.read())
        with open(new, "rb") as f:
            if f.read(2) != b"MZ" or os.path.getsize(new) < 1_000_000:
                raise OSError("fichier téléchargé invalide")
        if os.path.exists(old):
            os.remove(old)
        os.replace(exe, old)          # Windows permet de renommer un exe en cours d'exécution
        os.replace(new, exe)
    except OSError as e:
        log("Mise à jour impossible (%s) : on garde la version %d." % (e, CLIENT_VERSION))
        try:
            if os.path.exists(new):
                os.remove(new)
        except OSError:
            pass
        return
    log("Client mis à jour en v%d : redémarrage." % best)
    import subprocess
    if lock:
        lock.close()
    subprocess.Popen([exe], cwd=HERE, close_fds=True)
    os._exit(0)


LOCK_PORT = 47321


def single_instance():
    """Un seul client à la fois. Le client qui tourne écoute sur un port local : relancer l'exe lui demande de
    s'arrêter, et le nouveau prend sa place (il vérifie au passage s'il y a une mise à jour)."""
    import socket
    import threading
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if os.name == "nt" and hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
        s.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    else:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", LOCK_PORT))
        s.listen(1)
    except OSError:
        s.close()
        return None

    def listen():
        while True:
            try:
                conn, _ = s.accept()
                conn.settimeout(3)
                msg = conn.recv(16)
                try:
                    while conn.recv(16):   # on laisse l'autre côté fermer en premier (port libéré tout de suite)
                        pass
                except OSError:
                    pass
                conn.close()
            except OSError:
                return
            if msg.startswith(b"STOP"):
                log("Un nouveau lancement du client prend la relève : arrêt de celui-ci.")
                os._exit(0)
    threading.Thread(target=listen, daemon=True).start()
    return s          # garder la référence : le port reste pris tant que le client tourne


def ask_running_client_to_stop():
    import socket
    try:
        with socket.create_connection(("127.0.0.1", LOCK_PORT), timeout=3) as c:
            c.sendall(b"STOP")
        return True
    except OSError:
        return False


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
                   "import": (t[3].strip() or None) if len(t) > 3 else None,
                   "tf": (t[4].strip() or None) if len(t) > 4 else None}
        saved = []
        for entry in filter(None, (f[15] if len(f) > 15 else "").split("!")):
            x = entry.split("@")
            ch = []
            for c in filter(None, (x[1] if len(x) > 1 else "").split(":")):
                m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", c)
                if m:
                    ch.append([int(m.group(1)), int(m.group(2)), int(m.group(3))])
            saved.append({"name": " ".join(x[0].split()) or "Configuration", "chosen": ch,
                          "import": (x[2].strip() or None) if len(x) > 2 else None,
                          "selected": len(x) > 3 and x[3] == "1", "tf": (x[4].strip() or None) if len(x) > 4 else None})
        talents["saved"] = saved
    return {"name": f[1], "class": f[2] or None, "level": int(f[3] or 0), "rank": f[4] or None,
            "role": f[5] or None, "spec": f[6].strip() or None, "discord": f[7].strip() or None,
            "t": int(f[8] or 0), "profs": profs, "ilvl": int(f[10] or 0) or None,
            "gear": gear, "alts": [a for a in f[12].split("&") if a], "sets": sets, "talents": talents}


def parse_request(s):
    """Demande de retrait : 1^id^demandeur^heure^id,n;…^explication^statut^officier^décision^modif"""
    f = s.split("^")
    if len(f) < 10 or f[0] != "1":
        return None
    items = {}
    for pair in filter(None, f[4].split(";")):
        m = re.match(r"^(\d+),(\d+)$", pair)
        if m:
            items[m.group(1)] = int(m.group(2))
    try:
        return {"id": f[1], "who": f[2], "t": int(f[3] or 0), "items": items, "why": f[5].strip() or None,
                "status": f[6], "by": f[7].strip() or None, "at": int(f[8] or 0), "upd": int(f[9] or 0)}
    except ValueError:
        return None


def parse_order(s):
    """Commande de craft : 1^id^demandeur^heure^métier^recette^quantité^explication^statut^artisan^commission^modif^note"""
    f = s.split("^")
    if len(f) < 12 or f[0] != "1":
        return None
    try:
        return {"id": f[1], "who": f[2], "t": int(f[3] or 0), "prof": int(f[4] or 0), "recipe": int(f[5] or 0),
                "qty": int(f[6] or 1), "why": f[7].strip() or None, "status": f[8], "crafter": f[9].strip() or None,
                "fee": int(f[10] or 0), "upd": int(f[11] or 0), "note": (f[12].strip() or None) if len(f) > 12 else None}
    except ValueError:
        return None


def parse_crafter(s):
    """Recettes apprises : 1^nom^métier^niveau^heure^id;id…"""
    f = s.split("^")
    if len(f) < 6 or f[0] != "1":
        return None
    try:
        return {"name": f[1], "prof": int(f[2] or 0), "s": int(f[3] or 0), "t": int(f[4] or 0),
                "ids": [int(x) for x in f[5].split(";") if x.isdigit()]}
    except ValueError:
        return None


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
                elif kind == "R":
                    req = parse_request(full)
                    if req:
                        out.append(("R", req))
                elif kind == "T":
                    lay = parse_layout(full)
                    if lay:
                        out.append(("T", lay))
                elif kind == "O":
                    order = parse_order(full)
                    if order:
                        out.append(("O", order))
                elif kind == "W":
                    cr = parse_crafter(full)
                    if cr:
                        out.append(("W", cr))
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
                elif p["kind"] == "requests":
                    for r in pl.values():
                        log("[TEST] demande %s de %s : %s (%s)" % (r["id"], r["who"], r["items"], r["status"]))
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


# ---------------------------------------------------------------- demandes faites sur Discord -> jeu
# Le bot ne peut pas parler au jeu. Le client écrit les demandes Discord dans un fichier Lua de l'addon
# (Inbox.lua), que le jeu lit à la connexion ou au /reload ; l'addon les propose ensuite au joueur concerné.
def lua_str(v):
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def write_inbox(wow, inbox, state):
    reqs, decisions = inbox.get("requests") or [], inbox.get("decisions") or []
    rows = []
    for r in reqs:
        items = ", ".join("[%d] = %d" % (int(k), int(v)) for k, v in (r.get("items") or {}).items() if str(k).isdigit())
        rows.append("    { id = %s, who = %s, t = %d, upd = %d, why = %s, decision = %s, by = %s, at = %d, items = { %s } },"
                    % (lua_str(r["id"]), lua_str(r.get("who", "")), int(r.get("t") or 0), int(r.get("upd") or 0),
                       lua_str(r.get("why") or ""), lua_str(r.get("decision") or ""), lua_str(r.get("by") or ""),
                       int(r.get("at") or 0), items))
    drows = ["    { id = %s, status = %s, by = %s, at = %d },"
             % (lua_str(d["id"]), lua_str(d.get("status", "")), lua_str(d.get("by") or ""), int(d.get("at") or 0))
             for d in decisions if d.get("id")]
    body = "\n".join(rows) + "\n--\n" + "\n".join(drows)
    text = ("-- Écrit par le client Browz Forever (pont) : demandes et décisions faites sur Discord. Ne pas modifier.\n"
            "BrowzForeverInbox = {\n  t = %d,\n  requests = {\n%s\n  },\n  decisions = {\n%s\n  },\n}\n"
            % (int(time.time()), "\n".join(rows), "\n".join(drows)))
    if state.get("inbox_body") == body:
        return
    path = os.path.join(wow, "Interface", "AddOns", "BrowzForever", "Inbox.lua")
    if not os.path.isdir(os.path.dirname(path)):
        return
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)
    state["inbox_body"] = body
    if rows or drows:
        log("%d demande(s) et %d décision(s) Discord prêtes pour le jeu (lues au prochain /reload)." % (len(rows), len(drows)))


def fetch_inbox(cfg):
    url = cfg.get("bot_url")
    if not url:
        return None
    try:
        q = urllib.parse.urlencode({"cle": cfg.get("cle_guilde", "")})
        with urllib.request.urlopen(url.rstrip("/") + "/api/inbox?" + q, timeout=15) as r:
            data = json.loads(r.read().decode("utf-8"))
        return data if data.get("ok") else None
    except (urllib.error.URLError, OSError, ValueError):
        return None


def main():
    test = "--test" in sys.argv
    lock = single_instance()
    if lock is None:
        # un client tourne déjà : on lui demande de s'arrêter et on prend sa place (relancer l'exe = redémarrer
        # le client, et vérifier les mises à jour, sans passer par le Gestionnaire des tâches)
        ask_running_client_to_stop()
        for _ in range(20):
            time.sleep(0.5)
            lock = single_instance()
            if lock is not None:
                break
    if lock is None:
        log("Un client Browz tourne déjà et ne répond pas : celui-ci s'arrête.")
        return
    if FROZEN:
        try:
            if os.path.exists(sys.executable + ".old"):
                os.remove(sys.executable + ".old")
        except OSError:
            pass
    log("Client Browz Forever v%d." % CLIENT_VERSION)
    check_update(lock)
    cfg = load_config()
    state = load_json(STATE_PATH, {})
    state["maj_t"] = time.time()      # la vérification de mise à jour vient d'être faite au démarrage
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
        reqs = {x["id"]: x for k, x in found if k == "R"}
        if reqs:
            sender.push("requests", reqs)
        lays = {x["key"]: x for k, x in found if k == "T"}
        if lays:
            sender.push("layouts", lays)
        orders = {x["id"]: x for k, x in found if k == "O"}
        if orders:
            sender.push("orders", orders)
        crafts = ["%s|%d" % (x["name"], x["prof"]) for k, x in found if k == "W"]
        if crafts:
            sender.push("crafters", {key: x for key, x in zip(crafts, [x for k, x in found if k == "W"])})
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
                reqs = {}
                for rid, it in (db.get("requests") or {}).items():
                    if isinstance(it, dict) and it.get("id"):
                        items = it.get("items") or {}
                        if isinstance(items, list):
                            items = {str(i + 1): n for i, n in enumerate(items) if n}
                        reqs[it["id"]] = {"id": it["id"], "who": it.get("who"), "t": it.get("t") or 0,
                                          "items": {str(k): v for k, v in items.items()}, "why": it.get("why"),
                                          "status": it.get("status"), "by": it.get("by"), "at": it.get("at") or 0,
                                          "upd": it.get("upd") or 0}
                if reqs:
                    sender.push("requests", reqs)
                lays = {}
                for _, it in (db.get("layouts") or {}).items():
                    lay = parse_layout(it.get("data", "")) if isinstance(it, dict) else None
                    if lay:
                        lays[lay["key"]] = lay
                if lays:   # renvoyés à chaque lecture (quelques Ko) : le bot les a toujours
                    sender.push("layouts", lays)
                orders = {}
                for _, it in (db.get("orders") or {}).items():
                    if isinstance(it, dict) and it.get("id"):
                        orders[it["id"]] = {"id": it["id"], "who": it.get("who"), "t": it.get("t") or 0,
                                            "prof": it.get("prof") or 0, "recipe": it.get("recipe") or 0,
                                            "qty": it.get("qty") or 1, "why": it.get("why"), "status": it.get("status"),
                                            "crafter": it.get("crafter"), "fee": it.get("fee") or 0,
                                            "upd": it.get("upd") or 0, "note": it.get("note")}
                if orders:
                    sender.push("orders", orders)
                crafts = {}
                for name, c in (db.get("crafters") or {}).items():
                    if not isinstance(c, dict):
                        continue
                    for prof, p in (c.get("profs") or {}).items():
                        if isinstance(p, dict):
                            ids = [int(x) for x in str(p.get("ids") or "").split(";") if x.isdigit()]
                            crafts["%s|%s" % (name, prof)] = {"name": name, "prof": int(prof), "s": p.get("s") or 0,
                                                              "t": p.get("t") or 0, "ids": ids}
                if crafts:
                    sender.push("crafters", crafts)
                gprofs = db.get("guildProfs") or {}
                if isinstance(gprofs, dict) and gprofs:
                    sender.push("guild_profs", {n: [int(k) for k in (v or {}).keys() if str(k).isdigit()]
                                                for n, v in gprofs.items() if isinstance(v, dict)})
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
        if time.time() - state.get("maj_t", 0) > 6 * 3600:   # nouvelle version ? (toutes les 6 h)
            state["maj_t"] = time.time()
            check_update(lock)
        if not test and time.time() - state.get("inbox_t", 0) > 60:
            state["inbox_t"] = time.time()
            inbox = fetch_inbox(cfg)
            if inbox is not None:
                try:
                    write_inbox(wow, inbox, state)
                except OSError as e:
                    log("Inbox.lua impossible à écrire (%s)." % e)
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
