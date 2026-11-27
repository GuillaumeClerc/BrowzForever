-- Browz Forever : fiche de personnage (métiers + spécialisations, équipement, spécialisation de talents,
-- rôle, rerolls, pseudo Discord) partagée avec la guilde et envoyée au bot par les ponts.
-- Les ponts envoient aussi la liste de guilde (dans les SavedVariables) pour les joueurs sans l'addon.
local _, BF = ...
local Profile = {}
BF.Profile = Profile

-- Spécialisations de métier : sort connu -> (compétence du métier). Le nom affiché vient du jeu (français).
local PROF_SPECS = {
  { spell = 20219, skill = 202, label = "Ingénieur gnome" },
  { spell = 20222, skill = 202, label = "Ingénieur gobelin" },
  { spell = 9788,  skill = 164, label = "Fabricant d'armures" },
  { spell = 17039, skill = 164, label = "Maître forgeron d'épées" },
  { spell = 17040, skill = 164, label = "Maître forgeron de marteaux" },
  { spell = 17041, skill = 164, label = "Maître forgeron de haches" },
  { spell = 9787,  skill = 164, label = "Fabricant d'armes" },   -- en dernier : un maître l'est aussi
  { spell = 10656, skill = 165, label = "Travail du cuir (écailles de dragon)" },
  { spell = 10658, skill = 165, label = "Travail du cuir élémentaire" },
  { spell = 10660, skill = 165, label = "Travail du cuir tribal" },
}
local GEAR_SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }

local function knows(spell)
  if IsPlayerSpell then return IsPlayerSpell(spell) end
  return IsSpellKnown and IsSpellKnown(spell)
end

local function spellName(id)
  if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
  return GetSpellInfo and (GetSpellInfo(id))
end

local function clean(s) return (tostring(s or ""):gsub("[%^;=,&~|#@!:]", " ")) end

-- Ensembles d'équipement (gestionnaire d'équipement du jeu) : nom, spécialisation liée, pièces
local function readSets()
  local out = {}
  if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs) then return out end
  for _, setID in ipairs(C_EquipmentSet.GetEquipmentSetIDs() or {}) do
    local name = C_EquipmentSet.GetEquipmentSetInfo(setID)
    local ids = C_EquipmentSet.GetItemIDs(setID) or {}
    local spec
    if C_EquipmentSet.GetEquipmentSetAssignedSpec and BF.Talents then
      spec = BF.Talents.SpecNameByIndex(C_EquipmentSet.GetEquipmentSetAssignedSpec(setID))
    end
    local items = {}
    for slot, id in pairs(ids) do
      if type(id) == "number" and id > 0 then
        items[#items + 1] = { slot = slot, id = id }
        if BF.Bank and BF.Bank.Remember then BF.Bank.Remember(id) end
      end
    end
    if name then out[#out + 1] = { name = name, spec = spec, items = items } end
  end
  return out
end

-- Construction de la fiche du personnage connecté ----------------------------------------------
function Profile.Build()
  if not BrowzForeverDB then return end
  if BF.RememberMe then BF.RememberMe() end
  local me = BF.MyName()
  local base = (BrowzForeverDB.chars or {})[me] or {}
  local card = {
    name = me, class = base.class, level = base.level, rank = base.rank,
    discord = BrowzForeverDB.discord, t = GetServerTime(), profs = {}, gear = {}, alts = {},
  }
  -- métiers + spécialisation
  for _, p in ipairs(base.profs or {}) do
    local spe
    for _, sp in ipairs(PROF_SPECS) do
      if sp.skill == p.sl and knows(sp.spell) then spe = spellName(sp.spell) or sp.label; break end
    end
    card.profs[#card.profs + 1] = { n = p.n, lvl = p.lvl, max = p.max, main = p.main, spe = spe, sl = p.sl }
  end
  -- spécialisation de talents et rôle
  if BF.Talents then
    local sp = BF.Talents.Spec()
    card.spec, card.role = sp.name, sp.role
    local ok, t = pcall(BF.Talents.Read)
    if ok and t then card.talents, card.layout = t.card, t end
  end
  -- équipement
  if GetAverageItemLevel then
    local _, equipped = GetAverageItemLevel()
    card.ilvl = equipped and math.floor(equipped + 0.5)
  end
  for _, slot in ipairs(GEAR_SLOTS) do
    local id = GetInventoryItemID("player", slot)
    if id then
      card.gear[#card.gear + 1] = { slot = slot, id = id }
      if BF.Bank and BF.Bank.Remember then BF.Bank.Remember(id) end
    end
  end
  card.sets = readSets()
  -- rerolls du même compte (tous les personnages enregistrés par l'addon)
  for name in pairs(BrowzForeverDB.chars or {}) do card.alts[#card.alts + 1] = name end
  table.sort(card.alts)
  return card
end

-- Format compact (messages d'addon et chuchotements du pont) --------------------------------------
function Profile.Serialize(c)
  local profs, gear, alts = {}, {}, {}
  for _, p in ipairs(c.profs or {}) do
    profs[#profs + 1] = table.concat({ clean(p.n), p.lvl or 0, p.max or 0, p.main and 1 or 0, clean(p.spe), p.sl or 0 }, "=")
  end
  for _, g in ipairs(c.gear or {}) do gear[#gear + 1] = g.slot .. "," .. g.id end
  for _, a in ipairs(c.alts or {}) do alts[#alts + 1] = clean(a) end
  local sets = {}
  for _, st in ipairs(c.sets or {}) do
    local items = {}
    for _, g in ipairs(st.items or {}) do items[#items + 1] = g.slot .. "," .. g.id end
    sets[#sets + 1] = clean(st.name) .. "@" .. clean(st.spec) .. "@" .. table.concat(items, ":")
  end
  return table.concat({ "1", clean(c.name), c.class or "", c.level or 0, clean(c.rank), c.role or "", clean(c.spec),
    clean(c.discord), c.t or 0, table.concat(profs, ";"), c.ilvl or 0, table.concat(gear, ";"), table.concat(alts, "&"),
    table.concat(sets, "!"), c.talents or "" }, "^")
end

function Profile.Parse(s)
  local f = { strsplit("^", s) }
  if f[1] ~= "1" then return end
  local c = { name = f[2], class = f[3], level = tonumber(f[4]), rank = f[5], role = f[6] ~= "" and f[6] or nil,
    spec = f[7] ~= "" and f[7] or nil, discord = f[8] ~= "" and f[8] or nil, t = tonumber(f[9]) or 0,
    profs = {}, ilvl = tonumber(f[11]), gear = {}, alts = {} }
  for entry in (f[10] or ""):gmatch("[^;]+") do
    local n, lvl, max, main, spe, sl = strsplit("=", entry)
    c.profs[#c.profs + 1] = { n = n, lvl = tonumber(lvl), max = tonumber(max), main = main == "1" or nil,
      spe = (spe and spe ~= "" and spe ~= " ") and spe or nil, sl = tonumber(sl) }
  end
  for entry in (f[12] or ""):gmatch("[^;]+") do
    local slot, id = entry:match("^(%d+),(%d+)$")
    if slot then c.gear[#c.gear + 1] = { slot = tonumber(slot), id = tonumber(id) } end
  end
  for a in (f[13] or ""):gmatch("[^&]+") do c.alts[#c.alts + 1] = a end
  c.sets = {}
  for chunk in (f[14] or ""):gmatch("[^!]+") do
    local name, spec, items = strsplit("@", chunk)
    local st = { name = name, spec = (spec and spec ~= "" and spec ~= " ") and spec or nil, items = {} }
    for pair in (items or ""):gmatch("[^:]+") do
      local slot, id = pair:match("^(%d+),(%d+)$")
      if slot then st.items[#st.items + 1] = { slot = tonumber(slot), id = tonumber(id) } end
    end
    c.sets[#c.sets + 1] = st
  end
  c.talents = (f[15] and f[15] ~= "") and f[15] or nil
  return c
end

-- Stockage des fiches reçues (les ponts les transmettent au bot) ---------------------------------
local function store(card, data)
  BrowzForeverDB.cards = BrowzForeverDB.cards or {}
  local cur = BrowzForeverDB.cards[card.name]
  if cur and (cur.t or 0) >= (card.t or 0) then return false end
  BrowzForeverDB.cards[card.name] = { t = card.t, data = data }
  return true
end

local lastSent = 0
function Profile.Publish(force)
  if not BF.active then return end
  if not force and GetServerTime() - lastSent < 300 then return end -- au plus une fois toutes les 5 min
  local card = Profile.Build()
  if not card then return end
  lastSent = GetServerTime()
  local data = Profile.Serialize(card)
  store(card, data)
  BF.Send("C", data)
  if BF.Bridge.IsOn() then BF.Bridge.Emit("C", data) end
  if card.layout and BF.Talents then BF.Talents.PublishLayout(card.layout) end
end

BF.OnMessage("C", function(data)
  local card = Profile.Parse(data)
  if not card or not card.name then return end
  if store(card, data) and BF.Bridge.IsOn() then BF.Bridge.Emit("C", data) end
end)

-- Un pont arrive : on lui renvoie notre fiche
BF.OnMessage("P", function()
  C_Timer.After(5 + math.random() * 10, function() Profile.Publish(true) end)
end)

-- Envoi à la connexion, puis après un changement (métier, niveau, équipement, spécialisation)
local pending
local function soon()
  if pending then pending:Cancel() end
  pending = C_Timer.NewTimer(20, function() pending = nil; Profile.Publish(false) end)
end
local ev = CreateFrame("Frame")
for _, e in ipairs({ "SKILL_LINES_CHANGED", "PLAYER_LEVEL_UP", "PLAYER_EQUIPMENT_CHANGED",
  "PLAYER_SPECIALIZATION_CHANGED", "ACTIVE_TALENT_GROUP_CHANGED", "EQUIPMENT_SETS_CHANGED",
  "CHARACTER_POINTS_CHANGED", "TRAIT_CONFIG_UPDATED" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function() if BF.active then soon() end end)
BF.OnActive(function() C_Timer.After(12, function() Profile.Publish(true) end) end)

-- Liste de guilde (ponts seulement, enregistrée dans les SavedVariables) -------------------------
local function seenText(i)
  if not GetGuildRosterLastOnline then return nil end
  local y, m, d, h = GetGuildRosterLastOnline(i)
  if not y then return nil end
  if y > 0 then return ("il y a %d an(s)"):format(y) end
  if m > 0 then return ("il y a %d mois"):format(m) end
  if d > 0 then return ("il y a %d jour(s)"):format(d) end
  if h > 0 then return ("il y a %d heure(s)"):format(h) end
  return "il y a moins d'une heure"
end

local function saveRoster()
  if not (BF.active and BF.Bridge.IsOn()) then return end
  local members = {}
  for i = 1, (GetNumGuildMembers() or 0) do
    local name, rankName, _, level, _, _, note, _, online, _, classFile = GetGuildRosterInfo(i)
    if name then
      members[name] = { class = classFile, level = level, rank = rankName, online = online and true or nil,
        seen = (not online) and seenText(i) or nil, note = (note and note ~= "") and note or nil }
    end
  end
  BrowzForeverDB.roster = { t = GetServerTime(), members = members }
end

local rosterTimer
local rf = CreateFrame("Frame")
rf:RegisterEvent("GUILD_ROSTER_UPDATE")
rf:SetScript("OnEvent", function()
  if rosterTimer then rosterTimer:Cancel() end
  rosterTimer = C_Timer.NewTimer(5, saveRoster)
end)
C_Timer.NewTicker(600, function()
  if BF.active and BF.Bridge.IsOn() then
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
  end
end)
