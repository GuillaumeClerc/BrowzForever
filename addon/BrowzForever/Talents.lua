-- Browz Forever : arbres de talents (système Dragonflight, C_Traits).
-- La fiche du joueur contient ses choix ; la FORME de l'arbre (positions, liens, sorts) est envoyée
-- à part, une fois par spécialisation, avec une empreinte : si un patch déplace ou change un talent,
-- l'empreinte change et la nouvelle forme repart toute seule vers le bot.
local _, BF = ...
local Talents = {}
BF.Talents = Talents

local DAY = 86400

local function db() return BrowzForeverDB end

-- Spécialisation active : {id, name, role} (les fonctions ont changé de place selon les versions)
function Talents.Spec()
  local idx
  if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then idx = C_SpecializationInfo.GetSpecialization()
  elseif GetSpecialization then idx = GetSpecialization() end
  local id, name, role
  if idx then
    local getInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or GetSpecializationInfo
    if getInfo then
      local r = { pcall(getInfo, idx) }
      if r[1] then id, name, role = r[2], r[3], r[6] end
    end
  end
  if not id and PlayerUtil and PlayerUtil.GetCurrentSpecID then id = PlayerUtil.GetCurrentSpecID() end
  if id and not name and GetSpecializationInfoByID then
    local _, n, _, _, r = GetSpecializationInfoByID(id)
    name, role = n, role or r
  end
  if id and not role and GetSpecializationRoleByID then role = GetSpecializationRoleByID(id) end
  return { id = id, name = name, role = role, index = idx }
end

-- Rôles du joueur : ceux cochés dans la recherche de groupe (un paladin peut être Tank ET DPS),
-- sinon le rôle du groupe, sinon celui de la spécialisation. Renvoie "TANK,DAMAGER" par exemple.
function Talents.Roles(specRole)
  local out = {}
  if GetLFGRoles then
    local ok, _, tank, heal, dps = pcall(GetLFGRoles)
    if ok then
      if tank then out[#out + 1] = "TANK" end
      if heal then out[#out + 1] = "HEALER" end
      if dps then out[#out + 1] = "DAMAGER" end
    end
  end
  if #out == 0 and UnitGroupRolesAssigned then
    local r = UnitGroupRolesAssigned("player")
    if r and r ~= "NONE" then out[1] = r end
  end
  if #out == 0 and specRole then out[1] = specRole end
  return table.concat(out, ",")
end

-- Nom d'une spécialisation à partir de son numéro (1 à 4), pour les ensembles d'équipement
function Talents.SpecNameByIndex(i)
  if not i then return nil end
  local getInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or GetSpecializationInfo
  if not getInfo then return nil end
  local ok, _, name = pcall(getInfo, i)
  return ok and name or nil
end

local function spellOfEntry(configID, entryID)
  local e = C_Traits.GetEntryInfo(configID, entryID)
  if not (e and e.definitionID) then return 0 end
  local d = C_Traits.GetDefinitionInfo(e.definitionID)
  return (d and (d.spellID or d.overriddenSpellID)) or 0
end

local function isPassive(spell)
  if spell == 0 then return false end
  if C_Spell and C_Spell.IsSpellPassive then return C_Spell.IsSpellPassive(spell) end
  return IsPassiveSpell and IsPassiveSpell(spell)
end

local function checksum(s)
  local a, b = 1, 0
  for i = 1, #s do a = (a + s:byte(i)) % 65521; b = (b + a) % 65521 end
  return ("%x"):format(b * 65536 + a)
end
Talents.Checksum = checksum

-- Choix d'une configuration (active ou enregistrée) : "nœud.rang.sort:…"
local function chosenOf(configID, nodeIDs)
  local out = {}
  for _, nodeID in ipairs(nodeIDs) do
    local n = C_Traits.GetNodeInfo(configID, nodeID)
    if n then
      local rank = n.activeRank or 0
      if rank == 0 then rank = n.ranksPurchased or n.currentRank or 0 end
      if rank > 0 then
        local sp = 0
        if n.activeEntry and n.activeEntry.entryID then sp = spellOfEntry(configID, n.activeEntry.entryID) end
        out[#out + 1] = nodeID .. "." .. rank .. "." .. sp
      end
    end
  end
  return out
end

local function importOf(configID)
  if not C_Traits.GenerateImportString then return "" end
  local ok, s = pcall(C_Traits.GenerateImportString, configID)
  return (ok and type(s) == "string") and s:gsub("[^%w%+/]", "") or ""
end

-- Lien talentsforever.com, si l'addon Talents Forever est installé (il sait lire le code du jeu)
local function tfLink(import)
  local TF = TalentsForeverBook
  if import == "" or type(TF) ~= "table" or not (TF.DecodeBlizzard and TF.Encode) then return "" end
  local _, classFile = UnitClass("player")
  local ok, p = pcall(TF.DecodeBlizzard, import, classFile)
  if not ok or type(p) ~= "table" then return "" end
  local ok2, code = pcall(TF.Encode, p)
  return (ok2 and type(code) == "string") and code:gsub("[^%w/%-%._~]", "") or ""
end

local function cleanName(s) return (tostring(s or ""):gsub("[%^;=,&~|#@!:%.]", " ")) end

-- Lecture complète : forme de l'arbre + choix du joueur
function Talents.Read()
  if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetTreeNodes) then return end
  local configID = C_ClassTalents.GetActiveConfigID()
  if not configID then return end
  local info = C_Traits.GetConfigInfo(configID)
  local treeID = info and info.treeIDs and info.treeIDs[1]
  if not treeID then return end
  local spec = Talents.Spec()
  local nodes, chosen, points, visible = {}, {}, 0, {}
  for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
    local n = C_Traits.GetNodeInfo(configID, nodeID)
    -- talents de héros (sous-arbres) et nœuds d'autres spécialisations ignorés
    if n and n.isVisible and not n.subTreeID and n.type ~= 3 then
      local spells = {}
      for _, entryID in ipairs(n.entryIDs or {}) do
        local sp = spellOfEntry(configID, entryID)
        spells[#spells + 1] = sp .. (isPassive(sp) and "p" or "")
      end
      visible[#visible + 1] = nodeID
      local edges = {}
      for _, e in ipairs(n.visibleEdges or {}) do edges[#edges + 1] = e.targetNode end
      nodes[#nodes + 1] = table.concat({ nodeID, math.floor((n.posX or 0) / 100 + 0.5), math.floor((n.posY or 0) / 100 + 0.5),
        n.maxRanks or 1, n.type or 0, table.concat(edges, "/"), table.concat(spells, "/") }, ",")
      local rank = n.activeRank or n.currentRank or 0
      if rank > 0 then
        local sp = 0
        if n.activeEntry and n.activeEntry.entryID then sp = spellOfEntry(configID, n.activeEntry.entryID) end
        chosen[#chosen + 1] = nodeID .. "." .. rank .. "." .. sp
        points = points + (n.ranksPurchased or rank)
      end
    end
  end
  if #nodes == 0 then return end
  local shape = table.concat(nodes, ";")
  local key = treeID .. "-" .. (spec.id or 0) .. "-" .. checksum(shape)
  local import = importOf(configID)
  local loadout = info.name and info.name ~= "" and cleanName(info.name) or ""
  -- configurations enregistrées de la spécialisation (autres « arbres » du joueur), 6 au plus
  local saved, nSaved = {}, 0
  if spec.id and C_ClassTalents.GetConfigIDsBySpecID then
    local last = C_ClassTalents.GetLastSelectedSavedConfigID and C_ClassTalents.GetLastSelectedSavedConfigID(spec.id)
    for _, cid in ipairs(C_ClassTalents.GetConfigIDsBySpecID(spec.id) or {}) do
      if nSaved >= 6 then break end
      local ci = C_Traits.GetConfigInfo(cid)
      local ok, list = pcall(chosenOf, cid, visible)
      if ci and ok then
        local imp = importOf(cid)
        nSaved = nSaved + 1
        saved[nSaved] = table.concat({ cleanName(ci.name), table.concat(list, ":"), imp, cid == last and 1 or 0, tfLink(imp) }, "@")
      end
    end
  end
  return {
    key = key, spec = spec, points = points, nodes = #nodes,
    -- champ de la fiche : clé@nom de la config@choix@code d'import
    card = key .. "@" .. loadout .. "@" .. table.concat(chosen, ":") .. "@" .. import .. "@" .. tfLink(import),
    -- configurations enregistrées (17e champ) : nom@choix@code@sélectionnée@lien TF!…
    saved = table.concat(saved, "!"), nSaved = nSaved,
    -- forme de l'arbre (message « T ») : 1^clé^spé^forme
    layout = "1^" .. key .. "^" .. (spec.id or 0) .. "^" .. shape,
  }
end

-- Formes d'arbres : envoi (jusqu'à ce qu'un pont confirme) et relais ---------------------------
local function keep(key, data)
  local L = db().layouts or {}
  db().layouts = L
  L[key] = { data = data, t = GetServerTime() }
  local keys = {}
  for k, v in pairs(L) do keys[#keys + 1] = { k = k, t = v.t or 0 } end
  if #keys > 30 then
    table.sort(keys, function(a, b) return a.t < b.t end)
    for i = 1, #keys - 30 do L[keys[i].k] = nil end
  end
end

function Talents.PublishLayout(t, force)
  if not t then return end
  db().layoutAck = db().layoutAck or {}
  local acked = db().layoutAck[t.key]
  if not force and acked and GetServerTime() - acked < 30 * DAY then return end
  if BF.Bridge.IsOn() then
    keep(t.key, t.layout)
    BF.Bridge.Emit("T", t.layout)
    db().layoutAck[t.key] = GetServerTime()
  elseif not acked then
    BF.Send("T", t.layout)
  end
end

local relayed = {}
BF.OnMessage("T", function(data)
  if not BF.Bridge.IsOn() then return end
  local key = data:match("^1%^([^%^]+)%^")
  if not key then return end
  BF.Send("L", key)   -- accusé : l'envoyeur n'a plus besoin de renvoyer cet arbre
  if relayed[key] then return end
  relayed[key] = true
  keep(key, data)
  BF.Bridge.Emit("T", data)
end)

BF.OnMessage("L", function(key)
  db().layoutAck = db().layoutAck or {}
  db().layoutAck[key] = GetServerTime()
end)

-- Test (/browz testtalents) -------------------------------------------------------------------
local function has(path)
  local t = _G
  for part in path:gmatch("[^%.]+") do
    if type(t) ~= "table" then return false end
    t = t[part]
  end
  return t ~= nil
end

BF.commands["testtalents"] = function()
  local apis = { "C_SpecializationInfo.GetSpecialization", "C_SpecializationInfo.GetSpecializationInfo",
    "PlayerUtil.GetCurrentSpecID", "GetSpecializationInfoByID", "C_ClassTalents.GetActiveConfigID",
    "C_Traits.GetConfigInfo", "C_Traits.GetTreeNodes", "C_Traits.GetNodeInfo", "C_Traits.GetEntryInfo",
    "C_Traits.GetDefinitionInfo", "C_Traits.GenerateImportString", "C_Spell.IsSpellPassive" }
  local yes, no = {}, {}
  for _, a in ipairs(apis) do if has(a) then yes[#yes + 1] = a else no[#no + 1] = a end end
  BF.Print("Présentes : " .. table.concat(yes, ", "))
  BF.Print("Absentes : " .. (#no > 0 and table.concat(no, ", ") or "aucune"))
  local s = Talents.Spec()
  BF.Print(("Spécialisation : %s (id %s, rôle %s)"):format(tostring(s.name), tostring(s.id), tostring(s.role)))
  BF.Print("Rôles cochés (recherche de groupe) : " .. (Talents.Roles(nil) ~= "" and Talents.Roles(nil) or "aucun"))
  local ok, t = pcall(Talents.Read)
  if not ok then BF.Print("|cffff4444Erreur de lecture des talents :|r " .. tostring(t)); return end
  if not t then BF.Print("|cffff4444Aucun arbre de talents lu.|r"); return end
  local _, _, chosen, import = strsplit("@", t.card)
  local nChosen = 0
  for _ in (chosen or ""):gmatch("[^:]+") do nChosen = nChosen + 1 end
  BF.Print(("Arbre %s : %d talents visibles, %d choisis, %d points. Forme : %d octets, code d'import : %d caractères.")
    :format(t.key, t.nodes, nChosen, t.points, #t.layout, #(import or "")))
  local tf = select(5, strsplit("@", t.card))
  BF.Print("Lien Talents Forever : " .. ((tf and tf ~= "") and ("talentsforever.com/" .. tf) or "aucun (addon Talents Forever absent ?)"))
  BF.Print(("Configurations enregistrées : %d"):format(t.nSaved))
  for entry in (t.saved or ""):gmatch("[^!]+") do
    local name, list, imp, sel = strsplit("@", entry)
    local n = 0
    for _ in (list or ""):gmatch("[^:]+") do n = n + 1 end
    BF.Print(("  « %s » : %d talents%s, code %d car.%s"):format(name, n, "", #(imp or ""), sel == "1" and " (sélectionnée)" or ""))
  end
end

-- Test de la double spécialisation (/browz testspe) : liste ce que le jeu propose pour un 2e jeu de talents
BF.commands["testspe"] = function()
  local function names(tbl)
    local o = {}
    if type(tbl) == "table" then for k, v in pairs(tbl) do if type(v) == "function" then o[#o + 1] = k end end end
    table.sort(o)
    return table.concat(o, ", ")
  end
  BF.Print("C_ClassTalents : " .. names(C_ClassTalents))
  BF.Print("C_SpecializationInfo : " .. names(C_SpecializationInfo))
  local g = {}
  for k, v in pairs(_G) do
    if type(k) == "string" and type(v) == "function" and (k:find("SpecGroup") or k:find("TalentGroup") or k:find("DualSpec")
      or k:find("Specialization")) then g[#g + 1] = k end
  end
  table.sort(g)
  BF.Print("Fonctions globales : " .. table.concat(g, ", "))
  local function try(label, fn, ...)
    if not fn then return end
    local r = { pcall(fn, ...) }
    local o = {}
    for i = 2, math.min(#r, 7) do o[#o + 1] = tostring(r[i]) end
    BF.Print(label .. " = " .. (r[1] and table.concat(o, " | ") or ("erreur " .. tostring(r[2]))))
  end
  try("GetNumSpecializations()", GetNumSpecializations)
  try("GetActiveSpecGroup()", GetActiveSpecGroup)
  try("GetNumSpecGroups()", GetNumSpecGroups)
  try("C_SpecializationInfo.GetActiveSpecGroup()", C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup)
  try("C_SpecializationInfo.GetNumSpecGroups()", C_SpecializationInfo and C_SpecializationInfo.GetNumSpecGroups)
  local spec = Talents.Spec()
  for i = 1, 4 do try("GetSpecializationInfo(" .. i .. ")", C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo, i) end
  if spec.id and C_ClassTalents and C_ClassTalents.GetConfigIDsBySpecID then
    local ids = C_ClassTalents.GetConfigIDsBySpecID(spec.id) or {}
    BF.Print("Configurations de la spé " .. spec.id .. " : " .. #ids)
  end
  try("GetActiveConfigID()", C_ClassTalents and C_ClassTalents.GetActiveConfigID)
  try("GetLastSelectedSavedConfigID()", C_ClassTalents and C_ClassTalents.GetLastSelectedSavedConfigID, spec.id)
end
