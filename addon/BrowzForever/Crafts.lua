-- Browz Forever : artisans et recettes de la guilde (onglet Craft)
-- Données des recettes (noms, niveau requis, composants, objet créé, maître ou non) : RecipeData.lua, tiré de
-- LibProfessionDB (Pimptasty, licence MIT) et intégré à l'addon — rien à scanner, rien à installer en plus. L'addon ne lit que les recettes APPRISES
-- du personnage quand il ouvre un métier, et les partage à la guilde (message W).
-- Artisans connus :
--   « addon »   : recettes réellement apprises (lues dans la fenêtre de métier) ;
--   « supposé » : métier connu avec son niveau (fiche Browz) mais recettes jamais lues → on suppose toutes les recettes
--                 de maître (et apprises d'office) jusqu'à ce niveau ;
--   « métier »  : métier vu dans la liste des artisans de la guilde du jeu (membres sans addon, niveau inconnu).
local _, BF = ...
local Craft = {}
BF.Craft = Craft

local PROF_NAMES = {
  [171] = "Alchimie", [164] = "Forge", [185] = "Cuisine", [333] = "Enchantement", [202] = "Ingénierie",
  [129] = "Secourisme", [165] = "Travail du cuir", [197] = "Couture", [186] = "Minage", [356] = "Pêche",
  [182] = "Herboristerie", [393] = "Dépeçage",
}
Craft.PROF_NAMES = PROF_NAMES

-- Base des recettes intégrée (RecipeData.lua, tirée de LibProfessionDB, MIT) : pas d'addon à installer en plus.
-- Petit objet qui répond comme LibProfessionDB, pour ne rien changer au reste.
local DB = {}
local byId = {}
for prof, recs in pairs(BF.RecipeData or {}) do
  for id, r in pairs(recs) do byId[id] = r end
end
function DB:IsReady() return BF.RecipeData ~= nil end
function DB:HasProfession(prof) return BF.RecipeData[prof] ~= nil end
function DB:GetRecipes(prof) return BF.RecipeData[prof] end
function DB:GetName(prof, id) local r = BF.RecipeData[prof] and BF.RecipeData[prof][id]; return r and r[1] end
function DB:GetRequiredSkill(prof, id) local r = BF.RecipeData[prof] and BF.RecipeData[prof][id]; return r and r[2] end
function DB:GetCraftedItemID(prof, id)
  local r = BF.RecipeData[prof] and BF.RecipeData[prof][id]
  return r and r[3] ~= 0 and r[3] or nil
end
function DB:IsAutoTaughtRecipe(id) local r = byId[id]; return r ~= nil and r[4] == true end   -- maître ou d'office
local reagentCache = {}
function DB:GetReagents(prof, id)
  local key = prof .. ":" .. id
  if reagentCache[key] then return reagentCache[key] end
  local r = BF.RecipeData[prof] and BF.RecipeData[prof][id]
  local out = {}
  for item, n in ((r and r[5]) or ""):gmatch("(%d+):(%d+)") do out[tonumber(item)] = tonumber(n) end
  reagentCache[key] = out
  return out
end

function Craft.Lib()
  if BF.RecipeData then return DB end
end

local function crafters()
  BrowzForeverDB.crafters = BrowzForeverDB.crafters or {}
  return BrowzForeverDB.crafters
end
local function guildProfs()
  BrowzForeverDB.guildProfs = BrowzForeverDB.guildProfs or {}
  return BrowzForeverDB.guildProfs
end

local listeners = {}
local memo, memoAt = {}, 0          -- artisans par recette, recalculés seulement quand les données changent
function Craft.OnChange(fn) listeners[#listeners + 1] = fn end
local function changed() memo = {}; for _, fn in ipairs(listeners) do pcall(fn) end end

-- Ensembles de recettes apprises (cache) ----------------------------------------------------------
local setCache = {}
local function learnedSet(name, prof)
  local c = crafters()[name]
  local p = c and c.profs and c.profs[prof]
  if not p then return nil end
  local key = name .. "|" .. prof .. "|" .. (p.t or 0)
  local s = setCache[key]
  if not s then
    s = {}
    for id in (p.ids or ""):gmatch("%d+") do s[tonumber(id)] = true end
    setCache[key] = s
  end
  return s, p
end

-- Lecture de MES recettes quand une fenêtre de métier est ouverte -----------------------------------
function Craft.Serialize(name, prof, p) return table.concat({ "1", name, prof, p.s or 0, p.t or 0, p.ids or "" }, "^") end
local function serialize(name, prof, p)
  return table.concat({ "1", name, prof, p.s or 0, p.t or 0, p.ids or "" }, "^")
end

local function publish(prof)
  local me = BF.MyName()
  local c = crafters()[me]
  local p = c and c.profs[prof]
  if p then
    local data = serialize(me, prof, p)
    BF.Send("W", data)
    if BF.Bridge.IsOn() then BF.Bridge.Emit("W", data) end
  end
end

local function scanOpen()
  local T = C_TradeSkillUI
  if not (T and T.IsTradeSkillReady and T.IsTradeSkillReady()) then return end
  if (T.IsTradeSkillLinked and T.IsTradeSkillLinked()) or (T.IsTradeSkillGuild and T.IsTradeSkillGuild())
    or (T.IsNPCCrafting and T.IsNPCCrafting()) then return end              -- métier d'un autre joueur : on ne lit pas
  local okB, base = pcall(T.GetBaseProfessionInfo)
  local prof = okB and base and base.professionID
  if not prof or prof == 0 then return end
  local learned = {}
  local catNames, catIdx, catMap = {}, {}, {}
  for _, id in ipairs(T.GetAllRecipeIDs() or {}) do
    local info = T.GetRecipeInfo(id)
    if info and info.learned then learned[#learned + 1] = id end
    -- catégorie du jeu (« Explosifs », « Pièces »…) : toutes les recettes du métier, apprises ou non
    local cid = info and info.categoryID
    if cid and T.GetCategoryInfo then
      local ok, ci = pcall(T.GetCategoryInfo, cid)
      local nm = ok and type(ci) == "table" and ci.name
      if nm and nm ~= "" then
        nm = nm:gsub("[%^;,:]", " ")
        if not catIdx[nm] then catNames[#catNames + 1] = nm; catIdx[nm] = #catNames end
        catMap[#catMap + 1] = id .. ":" .. catIdx[nm]
      end
    end
  end
  if #catMap > 0 then Craft.StoreCategories(prof, GetServerTime(), table.concat(catNames, ";"), table.concat(catMap, ","), true) end
  if #learned == 0 then return end
  table.sort(learned)
  local ids = table.concat(learned, ";")
  local me = BF.MyName()
  local c = crafters()[me] or { profs = {} }
  local old = c.profs[prof]
  if old and old.ids == ids and old.s == base.skillLevel then return end
  c.profs[prof] = { s = base.skillLevel, ids = ids, t = GetServerTime() }
  c.t = GetServerTime()
  crafters()[me] = c
  publish(prof)
  BF.Debug(("Recettes de %s enregistrées : %d"):format(PROF_NAMES[prof] or prof, #learned))
  changed()
end

local pending
local scanFrame = CreateFrame("Frame")
scanFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
scanFrame:RegisterEvent("TRADE_SKILL_SHOW")
scanFrame:RegisterEvent("NEW_RECIPE_LEARNED")
scanFrame:SetScript("OnEvent", function()
  if pending or not BF.active then return end
  pending = true
  C_Timer.After(1.5, function() pending = false; pcall(scanOpen) end)
end)

-- Catégories des recettes (lues dans la fenêtre de métier du jeu, partagées : message V) -------------
local function recipeCats()
  BrowzForeverDB.recipeCats = BrowzForeverDB.recipeCats or {}
  return BrowzForeverDB.recipeCats
end
local catCache = {}
function Craft.StoreCategories(prof, t, names, map, mine)
  local cur = recipeCats()[prof]
  if cur and cur.names == names and cur.map == map then return end
  if cur and not mine and (cur.t or 0) >= (t or 0) then return end
  recipeCats()[prof] = { t = t, names = names, map = map }
  catCache = {}
  local data = table.concat({ "1", prof, t or 0, names, map }, "^")
  if mine then BF.Send("V", data) end
  memo = {}
  for _, fn in ipairs(listeners) do pcall(fn) end
end
BF.OnMessage("V", function(data)
  local v, prof, t, names, map = strsplit("^", data)
  prof, t = tonumber(prof), tonumber(t)
  if v ~= "1" or not prof or not names or not map then return end
  Craft.StoreCategories(prof, t, names, map, false)
end)
local function resendCats()
  for prof, c in pairs(recipeCats()) do
    if c.names and c.map then BF.Send("V", table.concat({ "1", prof, c.t or 0, c.names, c.map }, "^")) end
  end
end

-- Catégorie d'une recette : celle du jeu si un membre a ouvert ce métier, sinon le type de l'objet fabriqué.
-- Renvoie nom, ordre (ordre du jeu, sinon après)
local function parsedCats(prof)
  local c = recipeCats()[prof]
  if not c then return nil end
  if not c._m then
    c._n, c._m = {}, {}
    for nm in (c.names or ""):gmatch("[^;]+") do c._n[#c._n + 1] = nm end
    for id, i in (c.map or ""):gmatch("(%d+):(%d+)") do c._m[tonumber(id)] = tonumber(i) end
  end
  return c
end
function Craft.CategoryOf(prof, id)
  local key = prof .. ":" .. id
  local hit = catCache[key]
  if hit then return hit[1], hit[2] end
  local name, order
  local c = parsedCats(prof)
  local i = c and c._m[id]
  if i and c._n[i] then
    name, order = c._n[i], i
  else
    local item = DB:GetCraftedItemID(prof, id)
    if not item then
      name, order = (prof == 333 and "Enchantements" or "Autres"), 990
    else
      local _, itype, isub, equip, _, classID = C_Item.GetItemInfoInstant(item)
      if classID == 4 and equip and _G[equip] and _G[equip] ~= "" then
        name = _G[equip]                                 -- armure : par emplacement (Torse, Jambes…)
      else
        name = isub or itype or "Autres"
      end
      order = 500
    end
  end
  catCache[key] = { name, order }
  return name, order
end

-- Réception des recettes des autres ---------------------------------------------------------------
function Craft.Receive(data, sender, relayed)
  local v, name, prof, s, t, ids = strsplit("^", data)
  if v ~= "1" or not name then return end
  if not relayed and sender and not BF.SameName(sender, name) then return end   -- chacun n'envoie que ses recettes
  prof, s, t = tonumber(prof), tonumber(s), tonumber(t)
  if not prof then return end
  local c = crafters()[name] or { profs = {} }
  local old = c.profs[prof]
  if old and (old.t or 0) >= (t or 0) then return end
  c.profs[prof] = { s = s, ids = ids or "", t = t }
  c.t = math.max(c.t or 0, t or 0)
  crafters()[name] = c
  if BF.Bridge.IsOn() then BF.Bridge.Emit("W", data) end
  changed()
end
BF.OnMessage("W", function(data, sender) Craft.Receive(data, sender, false) end)

-- À la connexion : on renvoie nos recettes connues (et quand un pont arrive)
local function resendMine()
  local c = crafters()[BF.MyName()]
  if not c then return end
  for prof in pairs(c.profs) do publish(prof) end
  resendCats()
end
BF.OnMessage("P", function() C_Timer.After(5 + math.random() * 10, resendMine) end)

-- Liste des artisans du jeu (membres sans addon : connectés seulement, sans niveau) ------------------
local function scanGuildProfs()
  if not (GetNumGuildTradeSkill and GetGuildTradeSkillInfo) then return end
  if ExpandGuildTradeSkillHeader then
    for i = 1, GetNumGuildTradeSkill() do
      local skillID, isCollapsed = GetGuildTradeSkillInfo(i)
      if skillID and isCollapsed then pcall(ExpandGuildTradeSkillHeader, skillID) end
    end
  end
  local g, now, found = guildProfs(), GetServerTime(), false
  for i = 1, GetNumGuildTradeSkill() do
    local skillID, _, _, header, _, _, _, playerName, fullName = GetGuildTradeSkillInfo(i)
    local who = fullName or playerName
    if skillID and not header and who then
      g[who] = g[who] or {}
      if not g[who][skillID] then found = true end
      g[who][skillID] = now
    end
  end
  if found then changed() end
end
local gpFrame = CreateFrame("Frame")
gpFrame:RegisterEvent("PLAYER_LOGIN")
gpFrame:RegisterEvent("GUILD_TRADESKILL_UPDATE")
local gpBusy
gpFrame:SetScript("OnEvent", function(_, e)
  if e == "PLAYER_LOGIN" then
    C_Timer.After(25, function()
      if not BF.active then return end
      pcall(scanGuildProfs)
      resendMine()
    end)
    return
  end
  if gpBusy or not BF.active then return end
  gpBusy = true
  C_Timer.After(5, function() gpBusy = false; pcall(scanGuildProfs) end)
end)

-- Niveaux de métier connus par les fiches Browz (membres qui ont l'addon) ---------------------------
local levelsCache, levelsAt = nil, 0
local function cardLevels()
  if levelsCache and GetTime() - levelsAt < 10 then return levelsCache end
  local out = {}
  for name, c in pairs(BrowzForeverDB.cards or {}) do
    local ok, card = pcall(BF.Profile.Parse, c.data)
    if ok and card then
      for _, p in ipairs(card.profs or {}) do
        if p.sl and p.lvl then out[name] = out[name] or {}; out[name][p.sl] = p.lvl end
      end
    end
  end
  for name, ch in pairs(BrowzForeverDB.chars or {}) do   -- mes personnages
    for _, p in ipairs(ch.profs or {}) do
      if p.sl and p.lvl then out[name] = out[name] or {}; out[name][p.sl] = p.lvl end
    end
  end
  levelsCache, levelsAt = out, GetTime()
  return out
end

-- Recette « de base » : apprise d'office ou chez un maître
local function isBasic(L, id)
  if L.IsAutoTaughtRecipe and L:IsAutoTaughtRecipe(id) then return true end
  if L.GetRecipeSourceKinds then
    local ok, kinds = pcall(L.GetRecipeSourceKinds, L, id)
    if ok and type(kinds) == "table" and kinds.trainer then return true end
  end
  return false
end

-- Qui peut fabriquer une recette : liste triée (addon d'abord, puis supposés, puis « métier seulement »)
function Craft.CraftersFor(prof, id)
  if GetTime() - memoAt > 30 then memo, memoAt = {}, GetTime() end   -- les fiches reçues comptent au plus tard 30 s après
  local key = prof .. ":" .. id
  if memo[key] then return memo[key] end
  local out = Craft.ComputeCrafters(prof, id)
  memo[key] = out
  return out
end

function Craft.ComputeCrafters(prof, id)
  local L = Craft.Lib()
  local out, seen = {}, {}
  for name in pairs(crafters()) do
    local set, p = learnedSet(name, prof)
    if set and set[id] then
      out[#out + 1] = { name = name, s = p.s, kind = "addon" }; seen[name] = true
    end
  end
  local need = L and L:GetRequiredSkill(prof, id) or 0
  local basic = L and isBasic(L, id)
  -- ceux qui ont le niveau mais pas (encore) la recette : la commande reste possible, le patron est à obtenir
  -- (le demandeur le farm ou l'achète à l'HV, l'artisan le farme avec lui, ou une commission paie le patron)
  for name, c in pairs(crafters()) do
    local p = c.profs and c.profs[prof]
    if p and not seen[name] and (p.s or 0) >= need then
      out[#out + 1] = { name = name, s = p.s, kind = basic and "apprendre" or "patron" }; seen[name] = true
    end
  end
  if L and not basic then
    for name, levels in pairs(cardLevels()) do
      local lvl = levels[prof]
      if lvl and not seen[name] and not (crafters()[name] and crafters()[name].profs[prof]) and lvl >= need then
        out[#out + 1] = { name = name, s = lvl, kind = "patron" }; seen[name] = true
      end
    end
  end
  if L and basic then
    for name, levels in pairs(cardLevels()) do
      local lvl = levels[prof]
      if lvl and not seen[name] and not (crafters()[name] and crafters()[name].profs[prof]) and lvl >= need then
        out[#out + 1] = { name = name, s = lvl, kind = "suppose" }; seen[name] = true
      end
    end
    for name, profs in pairs(guildProfs()) do
      if profs[prof] and not seen[name] and not (crafters()[name] and crafters()[name].profs[prof])
        and not (cardLevels()[name] and cardLevels()[name][prof]) then
        out[#out + 1] = { name = name, kind = "metier" }; seen[name] = true
      end
    end
  end
  local rank = { addon = 1, suppose = 2, apprendre = 3, patron = 4, metier = 5 }
  table.sort(out, function(a, b)
    if rank[a.kind] ~= rank[b.kind] then return rank[a.kind] < rank[b.kind] end
    if (a.s or 0) ~= (b.s or 0) then return (a.s or 0) > (b.s or 0) end
    return a.name < b.name
  end)
  return out
end

-- Ce personnage peut-il fabriquer cette recette ? (recette lue, sinon supposée par le niveau)
function Craft.CanCraft(name, prof, id)
  for _, w in ipairs(Craft.CraftersFor(prof, id)) do
    if w.name == name and w.kind ~= "metier" then return true, w.kind end
  end
  return false
end
function Craft.RecipeName(prof, id)
  local L = Craft.Lib()
  return (L and L:GetName(prof, id)) or ("recette " .. tostring(id))
end
function Craft.CraftedItem(prof, id)
  local L = Craft.Lib()
  return L and L:GetCraftedItemID(prof, id)
end

-- Métiers présents dans la guilde (au moins un artisan connu)
function Craft.GuildProfessions()
  local profs = {}
  for _, c in pairs(crafters()) do for prof in pairs(c.profs or {}) do profs[prof] = true end end
  for _, levels in pairs(cardLevels()) do for prof in pairs(levels) do profs[prof] = true end end
  for _, g in pairs(guildProfs()) do for prof in pairs(g) do profs[prof] = true end end
  return profs
end

-- Recherche : recettes que quelqu'un de la guilde peut fabriquer.
-- Sans texte : seulement les recettes de plus haut niveau (pour ne pas être inondé).
-- Avec texte : toutes les recettes dont le nom contient le texte, niveau décroissant.
local ACCENTS = { ["é"] = "e", ["è"] = "e", ["ê"] = "e", ["ë"] = "e", ["à"] = "a", ["â"] = "a", ["î"] = "i",
                  ["ï"] = "i", ["ô"] = "o", ["û"] = "u", ["ù"] = "u", ["ç"] = "c", ["’"] = "'" }
local function norm(s)
  s = (s or ""):lower()
  for a, b in pairs(ACCENTS) do s = s:gsub(a, b) end
  return s
end

-- Nom de l'objet fabriqué (s'il est déjà connu du jeu)
local function craftedName(prof, id)
  local item = DB:GetCraftedItemID(prof, id)
  if not item then return nil end
  return (C_Item.GetItemNameByID and C_Item.GetItemNameByID(item)) or C_Item.GetItemInfo(item)
end

-- opts : { prof = métier, cat = catégorie, all = tous les niveaux }
-- Avec texte : toutes les recettes de la guilde dont le nom (ou celui de l'objet) contient le texte, tous métiers.
-- Sans texte : recettes qu'au moins un membre a sûrement, à 25 points ou moins du plus haut niveau du métier
--              (ou de la catégorie) ; « all » montre aussi les plus basses et celles à apprendre / patron à obtenir.
function Craft.Search(text, limit, opts)
  local L = Craft.Lib()
  if not L then return {} end
  opts = opts or {}
  limit = limit or 400
  local q = norm(strtrim(text or ""))
  local out = {}
  for prof in pairs(Craft.GuildProfessions()) do
    if L:HasProfession(prof) and (q ~= "" or not opts.prof or opts.prof == prof) then
      for id in pairs(L:GetRecipes(prof) or {}) do
        local name = L:GetName(prof, id)
        local ok = name ~= nil
        if ok and q ~= "" then
          ok = norm(name):find(q, 1, true) ~= nil
          if not ok then local iname = craftedName(prof, id); ok = iname ~= nil and norm(iname):find(q, 1, true) ~= nil end
        end
        if ok and q == "" and opts.cat then ok = Craft.CategoryOf(prof, id) == opts.cat end
        if ok then
          local who = Craft.CraftersFor(prof, id)
          if #who > 0 then
            out[#out + 1] = { prof = prof, id = id, name = name, need = L:GetRequiredSkill(prof, id) or 0, who = who }
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.need ~= b.need then return a.need > b.need end
    return a.name < b.name
  end)
  if q == "" and not opts.all then
    -- seulement les recettes que quelqu'un a (ou a sûrement) ; sinon les « niveau inconnu » et
    -- « patron à obtenir » feraient remonter toutes les recettes de leur métier
    local known = {}
    for _, r in ipairs(out) do
      for _, w in ipairs(r.who) do if w.kind == "addon" or w.kind == "suppose" then known[#known + 1] = r; break end end
    end
    out = known
    -- haut du panier : à 25 points ou moins du plus haut niveau (par métier, ou dans la catégorie choisie)
    local top = {}
    for _, r in ipairs(out) do top[r.prof] = math.max(top[r.prof] or 0, r.need) end
    local filtered = {}
    for _, r in ipairs(out) do if r.need >= (top[r.prof] or 0) - 25 then filtered[#filtered + 1] = r end end
    out = filtered
  end
  while #out > limit do table.remove(out) end
  return out
end

-- Catégories d'un métier, dans l'ordre du jeu : { {name, n (recettes montrées par défaut), total, top, icon} }
function Craft.Categories(prof, all)
  local L = Craft.Lib()
  local byName, list = {}, {}
  for _, r in ipairs(Craft.Search("", nil, { prof = prof, all = true })) do
    local name, order = Craft.CategoryOf(r.prof, r.id)
    local c = byName[name]
    if not c then
      c = { name = name, order = order, n = 0, total = 0, top = 0, known = {} }
      byName[name] = c; list[#list + 1] = c
    end
    c.total = c.total + 1
    for _, w in ipairs(r.who) do
      if w.kind == "addon" or w.kind == "suppose" then c.known[#c.known + 1] = r; break end
    end
    if not c.icon then c.icon = L:GetCraftedItemID(r.prof, r.id) end
  end
  for _, c in ipairs(list) do
    for _, r in ipairs(c.known) do c.top = math.max(c.top, r.need) end
    for _, r in ipairs(c.known) do if r.need >= c.top - 25 then c.n = c.n + 1 end end
    c.known = nil
  end
  table.sort(list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)
  return list
end

-- Composants et stock dans la banque de guilde
function Craft.Reagents(prof, id)
  local L = Craft.Lib()
  local list, stock = {}, {}
  local b = BF.Bank and BF.Bank.Get and BF.Bank.Get()
  for _, tab in pairs(b and b.tabs or {}) do
    for iid, n in pairs(tab.items or {}) do stock[iid] = (stock[iid] or 0) + n end
  end
  for iid, n in pairs(L and L:GetReagents(prof, id) or {}) do
    list[#list + 1] = { id = iid, n = n, bank = stock[iid] or 0 }
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

BF.commands["recettes"] = function()
  local c = crafters()[BF.MyName()]
  if not c then BF.Print("Aucune recette enregistrée : ouvre tes métiers une fois."); return end
  for prof, p in pairs(c.profs) do
    local n = 0
    for _ in (p.ids or ""):gmatch("%d+") do n = n + 1 end
    BF.Print(("%s (%d) : %d recette(s) apprise(s) enregistrée(s)."):format(PROF_NAMES[prof] or prof, p.s or 0, n))
  end
end

-- Bouton-icône d'objet : infobulle du jeu au survol, Maj+clic = lien dans le chat --------------------
function Craft.ItemButton(parent, size)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(size, size)
  b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetPoint("TOPLEFT", -1, 1); b.bg:SetPoint("BOTTOMRIGHT", 1, -1)
  b.bg:SetColorTexture(0.3, 0.3, 0.3)
  b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetAllPoints(); b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal"); b.count:SetPoint("BOTTOMRIGHT", -1, 2)
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  b:SetScript("OnEnter", function(self)
    if not (self.item or self.spell) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self.item then GameTooltip:SetItemByID(self.item) else GameTooltip:SetSpellByID(self.spell) end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  b:SetScript("OnClick", function(self)
    if not (self.item and IsModifiedClick("CHATLINK")) then return end
    local _, link = C_Item.GetItemInfo(self.item)
    if link and BF.InsertChatLink then BF.InsertChatLink(link) end
  end)
  function b:SetItem(id, count)
    self.item, self.spell = id, nil
    self.icon:SetTexture(id and C_Item.GetItemIconByID(id) or 134400)
    local q = id and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
    local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c and q >= 2 then self.bg:SetColorTexture(c.r, c.g, c.b) else self.bg:SetColorTexture(0.3, 0.3, 0.3) end
    self.count:SetText(count and count > 1 and count or "")
  end
  function b:SetRecipe(prof, id)
    local item = Craft.CraftedItem(prof, id)
    if item then self:SetItem(item); return end
    self.item, self.spell = nil, id                 -- enchantement : pas d'objet, infobulle du sort
    local tex = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id)) or (GetSpellTexture and GetSpellTexture(id))
    self.icon:SetTexture(tex or 136244); self.bg:SetColorTexture(0.3, 0.3, 0.3); self.count:SetText("")
  end
  return b
end

-- Onglet Craft ------------------------------------------------------------------------------------
local panel = BF.CraftPanel
if not panel then return end
-- Deux vues dans l'onglet : « Recettes » (ici) et « Commandes » (Orders.lua)
local view = CreateFrame("Frame", nil, panel)
view:SetAllPoints(panel)
Craft.RecipesView = view

local PROF_ICONS = {
  [171] = "Interface\\Icons\\Trade_Alchemy", [164] = "Interface\\Icons\\Trade_BlackSmithing",
  [185] = "Interface\\Icons\\INV_Misc_Food_15", [333] = "Interface\\Icons\\Trade_Engraving",
  [202] = "Interface\\Icons\\Trade_Engineering", [129] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
  [165] = "Interface\\Icons\\INV_Misc_ArmorKit_17", [197] = "Interface\\Icons\\Trade_Tailoring",
}
local LIST_W, ROW_H, ROWS = 300, 20, 11
-- état de navigation : métier choisi, catégorie choisie, tous les niveaux
local nav = { prof = nil, cat = nil, all = false }
local selected, results, mode = nil, {}, "recettes"   -- mode : « recettes » ou « categories »

local title = view:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 20, -32); title:SetText("Recettes de la guilde")

-- barre des métiers
local profBtns = {}
local function profButton(i)
  local b = profBtns[i]
  if b then return b end
  b = CreateFrame("Button", nil, view)
  b:SetSize(24, 24)
  b:SetPoint("TOPLEFT", 22 + (i - 1) * 29, -54)
  b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetAllPoints()
  b.sel = b:CreateTexture(nil, "OVERLAY"); b.sel:SetPoint("TOPLEFT", -3, 3); b.sel:SetPoint("BOTTOMRIGHT", 3, -3)
  b.sel:SetTexture("Interface\\Buttons\\CheckButtonHilight"); b.sel:SetBlendMode("ADD"); b.sel:Hide()
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(self.prof and (PROF_NAMES[self.prof] or self.prof) or "Tous les métiers")
    GameTooltip:AddLine(self.prof and "Clic : ses catégories" or "Clic : les recettes de plus haut niveau de chaque métier", 1, 1, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  profBtns[i] = b
  return b
end

local search = CreateFrame("EditBox", nil, view, "InputBoxTemplate")
search:SetSize(LIST_W - 10, 20); search:SetPoint("TOPLEFT", 26, -84)
search:SetAutoFocus(false)
search.hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
search.hint:SetPoint("LEFT", 4, 0); search.hint:SetText("Rechercher une recette ou un objet (ex. « bombe »)")

local info = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
info:SetPoint("TOPLEFT", 20, -108); info:SetWidth(LIST_W - 70); info:SetJustifyH("LEFT"); info:SetWordWrap(false)
local back = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
back:SetSize(64, 18); back:SetPoint("TOPLEFT", 20 + LIST_W - 64, -104); back:SetText("Retour"); back:Hide()
local allBox = CreateFrame("CheckButton", nil, view, "UICheckButtonTemplate")
allBox:SetSize(20, 20); allBox:SetPoint("TOPLEFT", 20 + LIST_W + 4, -82)
allBox.label = allBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
allBox.label:SetPoint("LEFT", allBox, "RIGHT", 0, 1); allBox.label:SetText("Tous les niveaux")
allBox:Hide()

local rows = {}
for i = 1, ROWS do
  local r = CreateFrame("Button", nil, view)
  r:SetSize(LIST_W, ROW_H)
  r:SetPoint("TOPLEFT", 20, -124 - (i - 1) * ROW_H)
  r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  r.sel = r:CreateTexture(nil, "BACKGROUND"); r.sel:SetAllPoints(); r.sel:SetColorTexture(1, 0.82, 0, 0.15); r.sel:Hide()
  r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", 2, 0)
  r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0); r.name:SetPoint("RIGHT", -64, 0); r.name:SetJustifyH("LEFT")
  r.need = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); r.need:SetPoint("RIGHT", -30, 0)
  r.count = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); r.count:SetPoint("RIGHT", -4, 0)
  r:Hide()
  rows[i] = r
end

local scroll = CreateFrame("Slider", nil, view, "UIPanelScrollBarTemplate")
scroll:SetPoint("TOPLEFT", rows[1], "TOPRIGHT", 4, -16)
scroll:SetPoint("BOTTOMLEFT", rows[ROWS], "BOTTOMRIGHT", 4, 16)
scroll:SetMinMaxValues(0, 0); scroll:SetValueStep(1); scroll:SetObeyStepOnDrag(true); scroll:SetValue(0)

-- Détail à droite : icône de l'objet (infobulle), artisans, composants en icônes
local DX = LIST_W + 48
local dIcon = Craft.ItemButton(view, 36)
dIcon:SetPoint("TOPLEFT", DX, -110); dIcon:Hide()
local dTitle = view:CreateFontString(nil, "OVERLAY", "GameFontNormal")
dTitle:SetPoint("TOPLEFT", dIcon, "TOPRIGHT", 8, -2); dTitle:SetPoint("RIGHT", view, "RIGHT", -16, 0); dTitle:SetJustifyH("LEFT")
local dSub = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
dSub:SetPoint("TOPLEFT", dTitle, "BOTTOMLEFT", 0, -4); dSub:SetPoint("RIGHT", view, "RIGHT", -16, 0); dSub:SetJustifyH("LEFT")
local dText = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
dText:SetPoint("TOPLEFT", dIcon, "BOTTOMLEFT", 0, -10); dText:SetPoint("RIGHT", view, "RIGHT", -16, 0)
dText:SetJustifyH("LEFT"); dText:SetJustifyV("TOP"); dText:SetSpacing(2)
local compLabel = view:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
compLabel:SetPoint("TOPLEFT", dText, "BOTTOMLEFT", 0, -10); compLabel:SetText("Composants (survol : détail ; chiffre : en BDG)")
local compBtns = {}
for i = 1, 8 do
  local b = Craft.ItemButton(view, 30)
  b:SetPoint("TOPLEFT", compLabel, "BOTTOMLEFT", ((i - 1) % 6) * 36, -6 - math.floor((i - 1) / 6) * 46)
  b.bank = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); b.bank:SetPoint("TOP", b, "BOTTOM", 0, -2)
  b:Hide()
  compBtns[i] = b
end
local dStatus = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
dStatus:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT", DX, 44); dStatus:SetPoint("RIGHT", view, "RIGHT", -16, 0); dStatus:SetJustifyH("LEFT")

local craftBtn = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
craftBtn:SetSize(170, 22); craftBtn:SetPoint("BOTTOMRIGHT", -16, 14)
craftBtn:SetText("Demander ce craft"); craftBtn:Disable()
craftBtn:SetScript("OnClick", function()
  if selected and BF.Orders then BF.Orders.OpenNew(selected.prof, selected.id) end
end)

local function short(name) return (name or ""):match("^[^-]+") or name end
Craft.Short = short
local KIND_TAG = { addon = "", suppose = " |cff999999(supposé)|r", apprendre = " |cffff9933(à apprendre chez un maître)|r",
                   patron = " |cffff9933(patron à obtenir)|r", metier = " |cff999999(niveau inconnu)|r" }
Craft.KIND_TAG = KIND_TAG

local function showDetail()
  local r = selected
  craftBtn:SetEnabled(r ~= nil and BF.Orders ~= nil)
  for _, b in ipairs(compBtns) do b:Hide() end
  if not r then
    dIcon:Hide(); dTitle:SetText(""); dSub:SetText(""); compLabel:Hide(); dStatus:SetText("")
    dText:SetText("|cffaaaaaaChoisis un métier (icônes) puis une catégorie, ou tape le nom d'une recette ou d'un objet.\n\n" ..
      "Par défaut, seules les recettes de plus haut niveau sont affichées : coche « Tous les niveaux » dans une " ..
      "catégorie pour voir les autres.|r")
    return
  end
  dIcon:SetRecipe(r.prof, r.id); dIcon:Show()
  dTitle:SetText(r.name)
  dSub:SetText(("%s · niveau %d · %s"):format(PROF_NAMES[r.prof] or r.prof, r.need, Craft.CategoryOf(r.prof, r.id)))
  local lines = { "|cffffd100Artisans|r" }
  for i, w in ipairs(r.who) do
    if i > 5 then lines[#lines + 1] = ("… et %d autre(s)"):format(#r.who - 5); break end
    lines[#lines + 1] = ("%s%s%s"):format(short(w.name), w.s and (" · " .. w.s) or "", KIND_TAG[w.kind] or "")
  end
  dText:SetText(table.concat(lines, "\n"))
  compLabel:Show()
  local all = true
  for i, g in ipairs(Craft.Reagents(r.prof, r.id)) do
    local b = compBtns[i]
    if not b then break end
    b:SetItem(g.id, g.n)
    local ok = g.bank >= g.n
    if not ok then all = false end
    b.bank:SetText((ok and "|cff33ff33" or "|cffff5555") .. g.bank .. "|r")
    b:Show()
  end
  dStatus:SetText(all and "|cff33ff33Tout est en BDG.|r" or "|cffff9933Il manque des composants en BDG.|r")
end

local function refreshRows()
  local L = Craft.Lib()
  local off = math.floor(scroll:GetValue() + 0.5)
  for i, row in ipairs(rows) do
    local r = results[i + off]
    row.r = r
    if r and mode == "categories" then
      row.icon:SetTexture(r.icon and C_Item.GetItemIconByID(r.icon) or PROF_ICONS[nav.prof] or 134400)
      row.name:SetText("|cffffd100" .. r.name .. "|r")
      row.need:SetText(r.top > 0 and r.top or "")
      row.count:SetText(nav.all and r.total or r.n)
      row.sel:Hide()
      row:Show()
    elseif r then
      local item = L and L:GetCraftedItemID(r.prof, r.id)
      local icon = item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(item)
      row.icon:SetTexture(icon or PROF_ICONS[r.prof] or 134400)
      row.name:SetText(r.name)
      row.need:SetText(r.need)
      row.count:SetText(#r.who)
      row.sel:SetShown(selected ~= nil and selected.prof == r.prof and selected.id == r.id)
      row:Show()
    else row:Hide() end
  end
end

local function refreshProfBar()
  local L = Craft.Lib()
  local list = {}
  for prof in pairs(Craft.GuildProfessions()) do
    if L and L:HasProfession(prof) then list[#list + 1] = prof end
  end
  table.sort(list, function(a, b) return (PROF_NAMES[a] or "") < (PROF_NAMES[b] or "") end)
  local all = profButton(1)
  all.prof = nil; all.icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09"); all.sel:SetShown(nav.prof == nil); all:Show()
  for i, prof in ipairs(list) do
    local b = profButton(i + 1)
    b.prof = prof; b.icon:SetTexture(PROF_ICONS[prof] or 134400); b.sel:SetShown(nav.prof == prof); b:Show()
  end
  for i = #list + 2, #profBtns do profBtns[i]:Hide() end
end

function Craft.Refresh()
  if not view:IsVisible() then return end
  if not Craft.Lib() then
    results = {}
    info:SetText("|cffff5555Base des recettes introuvable (RecipeData.lua) : réinstalle l'addon.|r")
    refreshRows(); showDetail(); return
  end
  refreshProfBar()
  local q = strtrim(search:GetText() or "")
  if q ~= "" then
    mode = "recettes"
    results = Craft.Search(q)
    info:SetText(("%d recette(s) trouvée(s), tous métiers"):format(#results))
  elseif nav.prof and not nav.cat then
    mode = "categories"
    results = Craft.Categories(nav.prof, nav.all)
    info:SetText(("%s : %d catégorie(s)"):format(PROF_NAMES[nav.prof] or nav.prof, #results))
  else
    mode = "recettes"
    results = Craft.Search("", nil, { prof = nav.prof, cat = nav.cat, all = nav.all and nav.cat ~= nil })
    if nav.cat then
      info:SetText(("%s › %s : %d"):format(PROF_NAMES[nav.prof] or nav.prof, nav.cat, #results))
    else
      info:SetText(("%d recette(s) de plus haut niveau   (niveau · artisans)"):format(#results))
    end
  end
  back:SetShown(q == "" and nav.prof ~= nil)
  allBox:SetShown(q == "" and nav.cat ~= nil); allBox:SetChecked(nav.all)
  scroll:SetMinMaxValues(0, math.max(0, #results - ROWS))
  refreshRows(); showDetail()
end

local function go(prof, cat)
  nav.prof, nav.cat = prof, cat
  if not cat then nav.all = false end
  scroll:SetValue(0)
  Craft.Refresh()
end
for i = 1, 14 do
  profButton(i):SetScript("OnClick", function(self)
    if search:GetText() ~= "" then search:SetText("") end
    go(self.prof, nil)
  end)
  profBtns[i]:Hide()
end
back:SetScript("OnClick", function() if nav.cat then go(nav.prof, nil) else go(nil, nil) end end)
allBox:SetScript("OnClick", function(self) nav.all = self:GetChecked() and true or false; scroll:SetValue(0); Craft.Refresh() end)

for _, row in ipairs(rows) do
  row:SetScript("OnClick", function(self)
    if mode == "categories" then go(nav.prof, self.r.name); return end
    selected = self.r; refreshRows(); showDetail()
  end)
  row:SetScript("OnDoubleClick", function(self)
    if mode ~= "categories" and self.r and BF.Orders then BF.Orders.OpenNew(self.r.prof, self.r.id) end
  end)
  row:SetScript("OnEnter", function(self)
    if mode == "categories" or not self.r then return end
    local L = Craft.Lib()
    local item = L and L:GetCraftedItemID(self.r.prof, self.r.id)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if item then GameTooltip:SetItemByID(item) else GameTooltip:SetSpellByID(self.r.id) end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", GameTooltip_Hide)
end
scroll:SetScript("OnValueChanged", refreshRows)
view:EnableMouseWheel(true)
view:SetScript("OnMouseWheel", function(_, d) scroll:SetValue(scroll:GetValue() - d * 3) end)
local typing
search:SetScript("OnTextChanged", function(self)
  self.hint:SetShown(self:GetText() == "")
  -- on attend que la frappe se calme (0,3 s) avant de chercher : pas de calcul à chaque lettre
  if typing then typing:Cancel() end
  typing = C_Timer.NewTimer(0.3, function() typing = nil; scroll:SetValue(0); Craft.Refresh() end)
end)
search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
view:HookScript("OnShow", Craft.Refresh)
panel:HookScript("OnShow", Craft.Refresh)
Craft.OnChange(Craft.Refresh)
if BF.Bank and BF.Bank.OnChange then BF.Bank.OnChange(Craft.Refresh) end
local itemFrame = CreateFrame("Frame")
itemFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
local itemPending
itemFrame:SetScript("OnEvent", function()
  if itemPending or not view:IsVisible() then return end
  itemPending = true
  C_Timer.After(0.3, function() itemPending = false; catCache = {}; refreshRows(); showDetail() end)
end)
