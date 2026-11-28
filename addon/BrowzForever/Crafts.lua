-- Browz Forever : artisans et recettes de la guilde (onglet Craft)
-- Données des recettes (noms, niveau requis, composants, objet créé, maître ou non) : bibliothèque LibProfessionDB
-- (addon « ProfessionDB », licence MIT, Pimptasty) — rien à scanner. L'addon ne lit que les recettes APPRISES
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

function Craft.Lib()
  local L = LibStub and LibStub("LibProfessionDB-1.0", true)
  if L and L.IsGameVersion and L:IsGameVersion("Forever") and L:IsReady() then return L end
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
  for _, id in ipairs(T.GetAllRecipeIDs() or {}) do
    local info = T.GetRecipeInfo(id)
    if info and info.learned then learned[#learned + 1] = id end
  end
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

function Craft.Search(text, limit)
  local L = Craft.Lib()
  if not L then return {} end
  limit = limit or 300
  local q = norm(strtrim(text or ""))
  local out = {}
  for prof in pairs(Craft.GuildProfessions()) do
    if L:HasProfession(prof) then
      for id in pairs(L:GetRecipes(prof) or {}) do
        local name = L:GetName(prof, id)
        if name and (q == "" or norm(name):find(q, 1, true)) then
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
  if q == "" then
    -- sans recherche : seulement les recettes que quelqu'un a (ou a sûrement) ; sinon les « niveau inconnu » et
    -- « patron à obtenir » feraient remonter toutes les recettes de leur métier
    local known = {}
    for _, r in ipairs(out) do
      for _, w in ipairs(r.who) do if w.kind == "addon" or w.kind == "suppose" then known[#known + 1] = r; break end end
    end
    out = known
    -- haut du panier : pour chaque métier, les recettes à 25 points ou moins du plus haut niveau atteint
    local top = {}
    for _, r in ipairs(out) do top[r.prof] = math.max(top[r.prof] or 0, r.need) end
    local filtered = {}
    for _, r in ipairs(out) do if r.need >= (top[r.prof] or 0) - 25 then filtered[#filtered + 1] = r end end
    out = filtered
  end
  while #out > limit do table.remove(out) end
  return out
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

-- Onglet Craft ------------------------------------------------------------------------------------
local panel = BF.CraftPanel
if not panel then return end
-- Deux vues dans l'onglet : « Recettes » (ici) et « Commandes » (Orders.lua)
local view = CreateFrame("Frame", nil, panel)
view:SetAllPoints(panel)
Craft.RecipesView = view

local LIST_W, ROW_H, ROWS = 300, 20, 12
local selected, results = nil, {}

local title = view:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 20, -32); title:SetText("Recettes de la guilde")

local search = CreateFrame("EditBox", nil, view, "InputBoxTemplate")
search:SetSize(LIST_W - 10, 20); search:SetPoint("TOPLEFT", 26, -56)
search:SetAutoFocus(false)
search.hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
search.hint:SetPoint("LEFT", 4, 0); search.hint:SetText("Rechercher une recette (ex. « rouage »)")

local info = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
info:SetPoint("TOPLEFT", 20, -80); info:SetWidth(LIST_W); info:SetJustifyH("LEFT")

local rows = {}
for i = 1, ROWS do
  local r = CreateFrame("Button", nil, view)
  r:SetSize(LIST_W, ROW_H)
  r:SetPoint("TOPLEFT", 20, -96 - (i - 1) * ROW_H)
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

-- Détail à droite
local DX = LIST_W + 48
local dTitle = view:CreateFontString(nil, "OVERLAY", "GameFontNormal")
dTitle:SetPoint("TOPLEFT", DX, -58); dTitle:SetPoint("RIGHT", -16, 0); dTitle:SetJustifyH("LEFT")
local dText = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
dText:SetPoint("TOPLEFT", dTitle, "BOTTOMLEFT", 0, -8); dText:SetPoint("RIGHT", -16, 0)
dText:SetJustifyH("LEFT"); dText:SetJustifyV("TOP"); dText:SetSpacing(2)
local craftBtn = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
craftBtn:SetSize(170, 22); craftBtn:SetPoint("BOTTOMRIGHT", -16, 14)
craftBtn:SetText("Demander ce craft"); craftBtn:Disable()
craftBtn:SetScript("OnClick", function()
  if selected and BF.Orders then BF.Orders.OpenNew(selected.prof, selected.id) end
end)

local function itemName(iid)
  local n = C_Item.GetItemInfo(iid)
  if not n and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(iid) end
  return n or ("objet " .. iid)
end

local function short(name) return (name or ""):match("^[^-]+") or name end

local function showDetail()
  local r = selected
  craftBtn:SetEnabled(r ~= nil and BF.Orders ~= nil)
  if not r then
    dTitle:SetText("")
    dText:SetText("|cffaaaaaaChoisis une recette dans la liste.\n\nSans recherche, seules les recettes de plus haut niveau " ..
      "de chaque métier sont affichées : tape un nom pour trouver les autres.|r")
    return
  end
  dTitle:SetText(r.name)
  local lines = { ("%s · niveau %d"):format(PROF_NAMES[r.prof] or r.prof, r.need), "", "|cffffd100Artisans|r" }
  for i, w in ipairs(r.who) do
    if i > 8 then lines[#lines + 1] = ("… et %d autre(s)"):format(#r.who - 8); break end
    local tag = ({ addon = "", suppose = " |cff999999(supposé)|r", apprendre = " |cffff9933(à apprendre chez un maître)|r",
                   patron = " |cffff9933(patron à obtenir)|r", metier = " |cff999999(niveau inconnu)|r" })[w.kind] or ""
    lines[#lines + 1] = ("%s%s%s"):format(short(w.name), w.s and (" · " .. w.s) or "", tag)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "|cffffd100Composants (en BDG)|r"
  local all = true
  for _, g in ipairs(Craft.Reagents(r.prof, r.id)) do
    local ok = g.bank >= g.n
    if not ok then all = false end
    lines[#lines + 1] = ("%s%d × %s|r (%d)"):format(ok and "|cff33ff33" or "|cffff5555", g.n, itemName(g.id), g.bank)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = all and "|cff33ff33Tout est en BDG.|r" or "|cffff9933Il manque des composants en BDG.|r"
  dText:SetText(table.concat(lines, "\n"))
end

local function refreshRows()
  local L = Craft.Lib()
  local off = math.floor(scroll:GetValue() + 0.5)
  for i, row in ipairs(rows) do
    local r = results[i + off]
    row.r = r
    if r then
      local item = L and L:GetCraftedItemID(r.prof, r.id)
      local icon = item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(item)
      row.icon:SetTexture(icon or 134400)
      row.name:SetText(r.name)
      row.need:SetText(r.need)
      row.count:SetText(#r.who)
      row.sel:SetShown(selected ~= nil and selected.prof == r.prof and selected.id == r.id)
      row:Show()
    else row:Hide() end
  end
end

function Craft.Refresh()
  if not view:IsVisible() then return end
  if not Craft.Lib() then
    results = {}
    info:SetText("|cffff5555L'addon « ProfessionDB » (LibProfessionDB) n'est pas installé ou pas activé.|r")
    refreshRows(); showDetail(); return
  end
  results = Craft.Search(search:GetText())
  scroll:SetMinMaxValues(0, math.max(0, #results - ROWS))
  local q = strtrim(search:GetText() or "")
  info:SetText(q == "" and ("%d recette(s) de plus haut niveau   (niveau · artisans)"):format(#results)
    or ("%d recette(s) trouvée(s)   (niveau · artisans)"):format(#results))
  refreshRows(); showDetail()
end

for _, row in ipairs(rows) do
  row:SetScript("OnClick", function(self) selected = self.r; refreshRows(); showDetail() end)
  row:SetScript("OnEnter", function(self)
    local L = Craft.Lib()
    local item = self.r and L and L:GetCraftedItemID(self.r.prof, self.r.id)
    if item then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(item); GameTooltip:Show() end
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
  C_Timer.After(0.3, function() itemPending = false; showDetail() end)
end)
