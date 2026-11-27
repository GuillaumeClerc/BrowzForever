"""Browz Forever — logique du bot (sans Discord) : stockage, fusion des journaux, textes.

Séparé de bot.py pour pouvoir être testé sans connexion à Discord.
"""
import json
import os
import time

CATS = [(9, "📜 Plans et recettes"), (7, "🧵 Composants d'artisanat"), (0, "🧪 Consommables"), (None, "📦 Autres")]
QUALITY = {0: "⚫", 1: "⚪", 2: "🟢", 3: "🔵", 4: "🟣", 5: "🟠", 6: "🟡", 7: "🟡"}
HOUR = 3600


def money(c, sign=False):
    c = int(c or 0)
    s = "-" if c < 0 else ("+" if sign and c > 0 else "")
    c = abs(c)
    po, pa, pc = c // 10000, (c // 100) % 100, c % 100
    parts = []
    if po:
        parts.append("%d po" % po)
    if pa:
        parts.append("%d pa" % pa)
    if pc or not parts:
        parts.append("%d pc" % pc)
    return s + " ".join(parts)


class Store:
    def __init__(self, path):
        self.path = path
        self.d = {}
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                self.d = json.load(f)
        for k, v in {"bank": None, "history": [], "items": {}, "events": {}, "log_items": [], "log_money": [],
                     "last_monthly": "", "links": {}}.items():
            self.d.setdefault(k, v)

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.d, f, ensure_ascii=False)
        os.replace(tmp, self.path)

    # ------------------------------------------------------------ objets
    def item(self, iid):
        return self.d["items"].get(str(iid)) or {}

    def name(self, iid):
        return self.item(iid).get("n") or "Objet #%s" % iid

    def quality_emoji(self, iid):
        return QUALITY.get(self.item(iid).get("q"), "▫️")

    def label(self, iid):
        q = self.item(iid).get("q")
        return "%s %s" % (QUALITY.get(q, "▫️"), self.name(iid))

    def category(self, iid):
        c = self.item(iid).get("c")
        return c if c in (9, 7, 0) else None

    def merge_items(self, cat):
        for k, v in (cat or {}).items():
            if isinstance(v, dict) and v.get("n"):
                cur = self.d["items"].setdefault(str(k), {})
                cur.update({kk: vv for kk, vv in v.items() if vv is not None})

    # ------------------------------------------------------------ banque
    def set_bank(self, bank):
        cur = self.d["bank"]
        if not bank or not bank.get("time") or (cur and cur.get("time", 0) >= bank["time"]):
            return False
        self.d["bank"] = bank
        self.d["history"].append([bank["time"], bank.get("money", 0)])
        self.d["history"] = self.d["history"][-2000:]
        return True

    def bank_totals(self):
        tot, where = {}, {}
        bank = self.d["bank"] or {}
        for tab in bank.get("tabs", []):
            for slot in tab.get("slots", {}).values():
                iid = str(slot["id"])
                tot[iid] = tot.get(iid, 0) + slot["n"]
                where.setdefault(iid, {})
                where[iid][tab.get("name") or "?"] = where[iid].get(tab.get("name") or "?", 0) + slot["n"]
        return tot, where

    def money_at(self, t):
        """Solde connu juste avant l'instant t (None si inconnu)."""
        best = None
        for ht, m in self.d["history"]:
            if ht <= t:
                best = m
        return best

    # ------------------------------------------------------------ passages au coffre
    def add_event(self, ev):
        if ev["id"] in self.d["events"]:
            return False
        self.merge_items(ev.get("names"))
        ev = dict(ev)
        ev.pop("names", None)
        self.d["events"][ev["id"]] = ev
        return True

    # ------------------------------------------------------------ journaux de la banque
    @staticmethod
    def _sig_item(e):
        return (e.get("tab"), e.get("typ"), e.get("who"), e.get("id"), e.get("n"))

    @staticmethod
    def _sig_money(e):
        return (e.get("typ"), e.get("who"), e.get("amount"))

    @staticmethod
    def _new_part(stored, new, sig):
        """Les journaux du jeu gardent les N dernières lignes : on cherche le plus grand
        recouvrement entre la fin de ce qu'on a et le début de la nouvelle lecture."""
        if not stored:
            return new
        s_sigs = [sig(e) for e in stored]
        n_sigs = [sig(e) for e in new]
        for k in range(min(len(s_sigs), len(n_sigs)), 0, -1):
            if s_sigs[-k:] == n_sigs[:k]:
                return new[k:]
        return new

    def merge_logs(self, logs):
        """Ajoute les nouvelles lignes ; renvoie (lignes objets nouvelles, lignes or nouvelles, première_fois)."""
        cap = logs.get("time") or int(time.time())
        first = not self.d["log_items"] and not self.d["log_money"]
        new_items = []
        by_tab = {}
        for e in self.d["log_items"]:
            by_tab.setdefault(e.get("tab"), []).append(e)
        for t_index, lst in enumerate(logs.get("tabs", []), start=1):
            entries = []
            for e in lst or []:
                if not isinstance(e, dict):
                    continue
                entries.append({"tab": t_index, "typ": e.get("typ"), "who": e.get("who") or "?", "id": e.get("id"),
                                "n": e.get("n"), "ago": e.get("ago", 0), "t": cap - int(e.get("ago") or 0) * HOUR})
            fresh = self._new_part(by_tab.get(t_index, []), entries, self._sig_item)
            new_items.extend(fresh)
        self.d["log_items"].extend(new_items)
        m_entries = [{"typ": e.get("typ"), "who": e.get("who") or "?", "amount": e.get("amount", 0),
                      "t": cap - int(e.get("ago") or 0) * HOUR}
                     for e in logs.get("money", []) if isinstance(e, dict)]
        new_money = self._new_part(self.d["log_money"], m_entries, self._sig_money)
        self.d["log_money"].extend(new_money)
        self.d["log_items"] = self.d["log_items"][-5000:]
        self.d["log_money"] = self.d["log_money"][-5000:]
        return new_items, new_money, first

    def uncovered(self, new_items, new_money):
        """Lignes du journal qui ne correspondent à aucun passage déjà publié (membres sans l'addon).
        Regroupées par personnage : {who: {"items": {id: delta}, "money": delta, "t": heure≈}}."""
        events = list(self.d["events"].values())

        def covered(who, t, check):
            for ev in events:
                if ev.get("who") == who and t - 2 * HOUR <= ev.get("t", 0) <= t + 2 * HOUR and check(ev):
                    return True
            return False

        groups = {}
        for e in new_items:
            if e["typ"] not in ("deposit", "withdraw") or not e.get("id"):
                continue
            d = e["n"] if e["typ"] == "deposit" else -e["n"]
            iid = str(e["id"])
            if covered(e["who"], e["t"], lambda ev: (ev.get("items", {}).get(iid, 0) * d) > 0):
                continue
            g = groups.setdefault(e["who"], {"items": {}, "money": 0, "t": e["t"]})
            g["items"][iid] = g["items"].get(iid, 0) + d
            g["t"] = max(g["t"], e["t"])
        for e in new_money:
            sign = 1 if e["typ"] in ("deposit",) else -1
            d = sign * int(e["amount"] or 0)
            if covered(e["who"], e["t"], lambda ev: (ev.get("money", 0) * d) > 0):
                continue
            g = groups.setdefault(e["who"], {"items": {}, "money": 0, "t": e["t"]})
            g["money"] += d
            g["t"] = max(g["t"], e["t"])
        return groups

    # ------------------------------------------------------------ requêtes
    def movements(self, who=None, kind="tout", since=0):
        """Mouvements connus (journaux + passages plus récents que le dernier journal), du plus récent au plus ancien."""
        out = []
        last_log = max([e["t"] for e in self.d["log_items"]] + [e["t"] for e in self.d["log_money"]] + [0])
        if kind in ("tout", "objets"):
            for e in self.d["log_items"]:
                if e["typ"] in ("deposit", "withdraw") and e.get("id"):
                    out.append({"t": e["t"], "who": e["who"], "id": str(e["id"]),
                                "d": e["n"] if e["typ"] == "deposit" else -e["n"], "tab": e.get("tab"), "approx": True})
                elif e["typ"] == "move":
                    continue
        if kind in ("tout", "or"):
            for e in self.d["log_money"]:
                sign = 1 if e["typ"] == "deposit" else -1
                out.append({"t": e["t"], "who": e["who"], "money": sign * int(e["amount"] or 0), "typ": e["typ"], "approx": True})
        for ev in self.d["events"].values():
            if ev.get("t", 0) <= last_log:
                continue
            if kind in ("tout", "objets"):
                for iid, d in ev.get("items", {}).items():
                    out.append({"t": ev["t"], "who": ev["who"], "id": str(iid), "d": d, "approx": False})
            if kind in ("tout", "or") and ev.get("money"):
                out.append({"t": ev["t"], "who": ev["who"], "money": ev["money"], "approx": False})
        if who:
            out = [m for m in out if m["who"].lower() == who.lower()]
        out = [m for m in out if m["t"] >= since]
        out.sort(key=lambda m: m["t"], reverse=True)
        return out

    def players(self):
        names = {e["who"] for e in self.d["log_items"]} | {e["who"] for e in self.d["log_money"]}
        names |= {ev["who"] for ev in self.d["events"].values()}
        names.discard("?")
        return sorted(names)

    def movement_line(self, m):
        when = "<t:%d:R>" % m["t"]
        if m["approx"]:
            when = "≈ " + when
        if "money" in m:
            icon = "💰" if m["money"] > 0 else "💸"
            extra = {"buyTab": " (achat d'onglet)", "withdrawForTab": " (pour un onglet)", "repair": " (réparations)"}.get(m.get("typ"), "")
            return "%s %s **%s** %s%s" % (when, icon, m["who"], money(m["money"], sign=True), extra)
        icon = "📥" if m["d"] > 0 else "📤"
        return "%s %s **%s** %d× %s" % (when, icon, m["who"], abs(m["d"]), self.name(m["id"]))

    def month_summary(self, start, end):
        moves = self.movements(since=start)
        moves = [m for m in moves if m["t"] < end]
        contrib, withdrawn, items_in = {}, {}, {}
        for m in moves:
            if "money" in m:
                if m["money"] > 0:
                    contrib[m["who"]] = contrib.get(m["who"], 0) + m["money"]
            elif m["d"] > 0:
                items_in[m["who"]] = items_in.get(m["who"], 0) + m["d"]
            else:
                withdrawn[m["id"]] = withdrawn.get(m["id"], 0) - m["d"]
        m0, m1 = self.money_at(start), self.money_at(end)
        return {"money_start": m0, "money_end": m1, "contrib": contrib, "items_in": items_in,
                "withdrawn": withdrawn, "count": len(moves)}
