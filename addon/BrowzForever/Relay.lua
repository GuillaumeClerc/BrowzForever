-- Browz Forever : « réveil » à la connexion — l'info circule en jeu même sans pont et sans l'auteur.
-- Le membre qui arrive envoie « H » (Bank.lua) avec l'heure de ce qu'il connaît de plus récent :
--   photo de la banque ; demandes ; commandes ; recettes ; fiches.
-- UN SEUL membre répond en principe, avec seulement ce qui est plus récent que ça :
--   * un pont répond en premier (il a normalement tout) ;
--   * sinon chacun attend un délai au hasard, et avant d'envoyer annonce « Y » (pour qui, et jusqu'où il est à
--     jour) : les autres ne renvoient alors que ce qui est encore plus récent (en pratique : rien).
local _, BF = ...
local Relay = {}
BF.Relay = Relay

local DAY = 86400
local N = 4   -- demandes, commandes, recettes, fiches

function Relay.Maxima()
  local m = { 0, 0, 0, 0 }
  local db = BrowzForeverDB or {}
  for _, r in pairs(db.requests or {}) do m[1] = math.max(m[1], r.upd or 0) end
  for _, o in pairs(db.orders or {}) do m[2] = math.max(m[2], o.upd or 0) end
  for _, c in pairs(db.crafters or {}) do
    for _, p in pairs(c.profs or {}) do m[3] = math.max(m[3], p.t or 0) end
  end
  for _, c in pairs(db.cards or {}) do m[4] = math.max(m[4], c.t or 0) end
  return m
end

local floor = {}     -- [membre qui arrive] = { ce qu'il a déjà, ou ce qu'un autre lui a déjà envoyé }
local timers = {}

local function parse(list, from)
  local out = {}
  for i = 1, N do out[i] = tonumber(list[from + i - 1]) or 0 end
  return out
end

local function raise(who, m)
  local f = floor[who] or { 0, 0, 0, 0 }
  for i = 1, N do f[i] = math.max(f[i], m[i] or 0) end
  floor[who] = f
end

local function newer(mine, f)
  for i = 1, N do if (mine[i] or 0) > (f[i] or 0) then return true end end
  return false
end

local function sendDelta(who)
  local f = floor[who] or { 0, 0, 0, 0 }
  local mine = Relay.Maxima()
  if not newer(mine, f) then return end
  BF.Send("Y", who .. ";" .. table.concat(mine, ";"))   -- « je m'en occupe, jusqu'à ici »
  local db, now = BrowzForeverDB, GetServerTime()
  for _, r in pairs(db.requests or {}) do
    if (r.upd or 0) > f[1] and now - (r.upd or 0) < 14 * DAY then BF.Send("R", BF.Requests.Serialize(r)) end
  end
  for _, o in pairs(db.orders or {}) do
    if (o.upd or 0) > f[2] and now - (o.upd or 0) < 14 * DAY and BF.Orders then BF.Send("O", BF.Orders.Serialize(o)) end
  end
  for name, c in pairs(db.crafters or {}) do
    for prof, p in pairs(c.profs or {}) do
      if (p.t or 0) > f[3] and BF.Craft and BF.Craft.Serialize then BF.Send("W", BF.Craft.Serialize(name, prof, p)) end
    end
  end
  for _, c in pairs(db.cards or {}) do
    if (c.t or 0) > f[4] and now - (c.t or 0) < 30 * DAY and c.data then BF.Send("C", c.data) end
  end
  raise(who, mine)
end

BF.OnMessage("H", function(data, sender)
  if not sender then return end
  local fields = { strsplit(";", data or "") }
  if #fields < 1 + N then return end                       -- ancienne version de l'addon : rien à faire
  floor[sender] = parse(fields, 2)
  if not newer(Relay.Maxima(), floor[sender]) then return end
  if timers[sender] then timers[sender]:Cancel() end
  local delay = BF.Bridge.IsOn() and (0.5 + math.random()) or (3 + math.random() * 6)
  timers[sender] = C_Timer.NewTimer(delay, function() timers[sender] = nil; sendDelta(sender) end)
end)

BF.OnMessage("Y", function(data)
  local fields = { strsplit(";", data or "") }
  local who = fields[1]
  if not who or #fields < 1 + N then return end
  raise(who, parse(fields, 2))
  -- si celui qui s'en occupe est au moins aussi à jour que moi, je n'envoie rien
  if timers[who] and not newer(Relay.Maxima(), floor[who]) then timers[who]:Cancel(); timers[who] = nil end
end)
