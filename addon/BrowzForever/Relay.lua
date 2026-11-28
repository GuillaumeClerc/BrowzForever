-- Browz Forever : « réveil » à la connexion — l'info circule en jeu même sans pont et sans l'auteur.
--  1. Le membre qui arrive envoie « H » (Bank.lua) : heure de sa photo de la banque, puis une EMPREINTE de chaque
--     liste qu'il connaît (demandes, commandes, recettes, fiches) — une empreinte de tous les « id = version ».
--  2. Si mes empreintes diffèrent, je me propose ; UN SEUL répond en principe : un pont d'abord (0,5–1,5 s), sinon
--     un délai au hasard ; celui qui répond annonce « Y » (pour qui, et ses empreintes) : ceux qui ont les mêmes
--     données que lui se taisent.
--  3. Celui qui répond envoie en privé à l'arrivant la LISTE « id = version » de chaque liste différente (« X ») ;
--     l'arrivant répond en privé ce qui lui manque ou qu'il a en plus vieux (« G ») ; il reçoit exactement ça
--     (copies relayées « ZR », « ZO », « ZW », « ZC »). Ce que l'arrivant a de plus récent, il le renvoie à la
--     guilde. Les copies relayées ne vérifient pas l'auteur (il peut être hors ligne) : on fait confiance à ce que
--     les membres ont vu ; les messages directs, eux, sont vérifiés (voir Requests.lua, Orders.lua…).
local _, BF = ...
local Relay = {}
BF.Relay = Relay

local DAY = 86400
local KIND = { "R", "O", "W", "C" }   -- demandes, commandes, recettes, fiches

-- Les 4 listes : [clé] = { v = version, data = fonction qui donne le message à envoyer }
local function lists()
  local db, now = BrowzForeverDB or {}, GetServerTime()
  local L = { {}, {}, {}, {} }
  for id, r in pairs(db.requests or {}) do
    if now - (r.upd or 0) < 14 * DAY then L[1][id] = { v = r.upd or 0, data = function() return BF.Requests.Serialize(r) end } end
  end
  for id, o in pairs(db.orders or {}) do
    if now - (o.upd or 0) < 14 * DAY and BF.Orders then
      L[2][id] = { v = o.upd or 0, data = function() return BF.Orders.Serialize(o) end }
    end
  end
  for name, c in pairs(db.crafters or {}) do
    for prof, p in pairs(c.profs or {}) do
      if BF.Craft and BF.Craft.Serialize then
        L[3][name .. "#" .. prof] = { v = p.t or 0, data = function() return BF.Craft.Serialize(name, prof, p) end }
      end
    end
  end
  for name, c in pairs(db.cards or {}) do
    if now - (c.t or 0) < 30 * DAY and c.data then L[4][name] = { v = c.t or 0, data = function() return c.data end } end
  end
  return L
end

local function clean(k) return (tostring(k):gsub("[,;=~|]", " ")) end

local function digest(list)
  local keys = {}
  for k, e in pairs(list) do keys[#keys + 1] = clean(k) .. "=" .. e.v end
  table.sort(keys)
  return #keys == 0 and "0" or tostring(BF.Talents.Checksum(table.concat(keys, ",")))
end

function Relay.Hashes()
  local L, out = lists(), {}
  for i = 1, #KIND do out[i] = digest(L[i]) end
  return out
end

-- Copies relayées : mêmes traitements que les messages normaux, sans vérification de l'auteur
local RECEIVE = {
  R = function(d) if BF.Requests.Receive then BF.Requests.Receive(d, nil, true) end end,
  O = function(d) if BF.Orders and BF.Orders.Receive then BF.Orders.Receive(d, nil, true) end end,
  W = function(d) if BF.Craft and BF.Craft.Receive then BF.Craft.Receive(d, nil, true) end end,
  C = function(d) if BF.Profile and BF.Profile.Receive then BF.Profile.Receive(d, nil, true) end end,
}
for _, k in ipairs(KIND) do BF.OnMessage("Z" .. k, function(data) RECEIVE[k](data) end) end

-- 2. Quelqu'un arrive ---------------------------------------------------------------------------
local pending = {}   -- [arrivant] = { timer, diff = { [i] = true }, theirs = {…} }

BF.OnMessage("H", function(data, sender)
  if not sender then return end
  local f = { strsplit(";", data or "") }
  if f[6] == "pont" then BF.SeenBridge(sender) end
  local mine = Relay.Hashes()
  local diff, any = {}, false
  for i = 1, #KIND do
    if (f[i + 1] or "") ~= mine[i] then diff[i] = true; any = true end
  end
  if not any then return end
  if pending[sender] and pending[sender].timer then pending[sender].timer:Cancel() end
  local p = { diff = diff }
  pending[sender] = p
  local delay = BF.Bridge.IsOn() and (0.5 + math.random()) or (3 + math.random() * 6)
  p.timer = C_Timer.NewTimer(delay, function()
    p.timer = nil
    local L, hashes = lists(), Relay.Hashes()
    BF.Send("Y", sender .. ";" .. table.concat(hashes, ";"))
    for i in pairs(p.diff) do
      local parts = {}
      for k, e in pairs(L[i]) do parts[#parts + 1] = clean(k) .. "=" .. e.v end
      BF.Send("X", i .. ";" .. table.concat(parts, ","), "WHISPER", sender)
    end
  end)
end)

-- un autre membre s'en occupe : si ses données sont les mêmes que les miennes, je me tais
BF.OnMessage("Y", function(data)
  local f = { strsplit(";", data or "") }
  local p = f[1] and pending[f[1]]
  if not p or not p.timer then return end
  local mine = Relay.Hashes()
  for i in pairs(p.diff) do
    if (f[i + 1] or "") ~= mine[i] then return end   -- j'ai autre chose que lui : je réponds aussi
  end
  p.timer:Cancel(); p.timer = nil
end)

-- 3. Je suis l'arrivant : on m'envoie la liste « id = version » d'une liste ------------------------
BF.OnMessage("X", function(data, sender)
  local i, body = (data or ""):match("^(%d);(.*)$")
  i = tonumber(i)
  if not i or not KIND[i] or not sender then return end
  local theirs = {}
  for k, v in (body or ""):gmatch("([^,=]+)=(%d+)") do theirs[k] = tonumber(v) end
  local mine = lists()[i]
  local want, give = {}, 0
  local cleaned = {}
  for k, e in pairs(mine) do cleaned[clean(k)] = e end
  for k, v in pairs(theirs) do
    local e = cleaned[k]
    if not e or e.v < v then want[#want + 1] = k end
  end
  -- ce que j'ai de plus récent ou en plus : je le renvoie à toute la guilde (copie relayée)
  for k, e in pairs(cleaned) do
    if (theirs[k] or -1) < e.v and give < 40 then BF.Send("Z" .. KIND[i], e.data()); give = give + 1 end
  end
  if #want > 0 then BF.Send("G", i .. ";" .. table.concat(want, ","), "WHISPER", sender) end
end)

-- l'arrivant demande ce qui lui manque
BF.OnMessage("G", function(data, sender)
  local i, body = (data or ""):match("^(%d);(.*)$")
  i = tonumber(i)
  if not i or not KIND[i] or not sender then return end
  local cleaned = {}
  for k, e in pairs(lists()[i]) do cleaned[clean(k)] = e end
  for k in (body or ""):gmatch("[^,]+") do
    local e = cleaned[k]
    if e then BF.Send("Z" .. KIND[i], e.data(), "WHISPER", sender) end
  end
end)
