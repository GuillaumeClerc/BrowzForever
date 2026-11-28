-- Browz Forever : recettes et commandes de craft (en construction)
-- Étape 0 : /browz testmetier — relève ce que le jeu Forever donne sur la fenêtre de métier ouverte
-- (API moderne C_TradeSkillUI ou ancienne API GetTradeSkillInfo) et l'enregistre dans BrowzForeverDB.probe,
-- pour choisir la bonne façon de lire les recettes. Résultat lisible après /reload.
local _, BF = ...

local function keys(t)
  local out = {}
  if type(t) ~= "table" then return tostring(t) end
  for k, v in pairs(t) do
    local tv = type(v)
    if tv == "table" then
      local n = 0
      for _ in pairs(v) do n = n + 1 end
      out[#out + 1] = k .. "=table(" .. n .. ")"
    else
      out[#out + 1] = k .. "=" .. tostring(v)
    end
  end
  table.sort(out)
  return table.concat(out, " | ")
end

local function has(name)
  local t = _G
  for part in name:gmatch("[^%.]+") do
    t = type(t) == "table" and t[part] or nil
  end
  return type(t) == "function"
end

BF.commands["testmetier"] = function()
  local p = { t = GetServerTime(), api = {}, recipes = {}, notes = {} }
  for _, f in ipairs({
    "C_TradeSkillUI.GetAllRecipeIDs", "C_TradeSkillUI.GetRecipeInfo", "C_TradeSkillUI.GetRecipeSchematic",
    "C_TradeSkillUI.GetBaseProfessionInfo", "C_TradeSkillUI.GetChildProfessionInfo", "C_TradeSkillUI.GetProfessionInfoBySkillLineID",
    "C_TradeSkillUI.IsTradeSkillReady", "C_TradeSkillUI.GetTradeSkillLine", "C_TradeSkillUI.GetRecipeItemLink",
    "C_TradeSkillUI.GetRecipeOutputItemData", "C_TradeSkillUI.GetRecipeRequirements",
    "GetNumTradeSkills", "GetTradeSkillInfo", "GetTradeSkillLine", "GetTradeSkillReagentInfo", "GetTradeSkillNumReagents",
    "GetTradeSkillItemLink", "GetTradeSkillRecipeLink", "GetCraftInfo", "GetNumCrafts",
    "GetGuildTradeSkillInfo", "GetNumGuildTradeSkill", "QueryGuildMembersForRecipe", "C_GuildInfo.QueryGuildMembersForRecipe",
  }) do p.api[f] = has(f) end

  -- API moderne
  if has("C_TradeSkillUI.GetAllRecipeIDs") then
    local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if ok and type(ids) == "table" then
      p.notes[#p.notes + 1] = "GetAllRecipeIDs : " .. #ids .. " recettes"
      if has("C_TradeSkillUI.GetBaseProfessionInfo") then
        local ok2, base = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
        if ok2 then p.notes[#p.notes + 1] = "base : " .. keys(base) end
      end
      if has("C_TradeSkillUI.GetChildProfessionInfo") then
        local ok2, child = pcall(C_TradeSkillUI.GetChildProfessionInfo)
        if ok2 then p.notes[#p.notes + 1] = "child : " .. keys(child) end
      end
      for i = 1, math.min(#ids, 6) do
        local id = ids[i]
        local r = { id = id }
        local okI, info = pcall(C_TradeSkillUI.GetRecipeInfo, id)
        if okI then r.info = keys(info) end
        if has("C_TradeSkillUI.GetRecipeSchematic") then
          local okS, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, id, false)
          if okS and type(sch) == "table" then
            r.schematic = keys(sch)
            local reag = {}
            for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
              local first = slot.reagents and slot.reagents[1]
              reag[#reag + 1] = (first and first.itemID or "?") .. "x" .. tostring(slot.quantityRequired)
            end
            r.reagents = table.concat(reag, ",")
          end
        end
        if has("C_TradeSkillUI.GetRecipeRequirements") then
          local okR, req = pcall(C_TradeSkillUI.GetRecipeRequirements, id)
          if okR then r.requirements = keys(req) end
        end
        p.recipes[#p.recipes + 1] = r
      end
    else
      p.notes[#p.notes + 1] = "GetAllRecipeIDs : erreur ou vide (" .. tostring(ids) .. ")"
    end
  end

  -- ancienne API
  if has("GetNumTradeSkills") then
    local n = GetNumTradeSkills() or 0
    p.notes[#p.notes + 1] = "GetNumTradeSkills : " .. n
    if has("GetTradeSkillLine") then p.notes[#p.notes + 1] = "GetTradeSkillLine : " .. table.concat({ tostringall(GetTradeSkillLine()) }, ", ") end
    for i = 1, math.min(n, 6) do
      local r = { old = i, info = table.concat({ tostringall(GetTradeSkillInfo(i)) }, ", ") }
      if has("GetTradeSkillItemLink") then r.link = tostring(GetTradeSkillItemLink(i)) end
      if has("GetTradeSkillRecipeLink") then r.recipeLink = tostring(GetTradeSkillRecipeLink(i)) end
      if has("GetTradeSkillNumReagents") then
        local reag = {}
        for k = 1, (GetTradeSkillNumReagents(i) or 0) do
          reag[#reag + 1] = table.concat({ tostringall(GetTradeSkillReagentInfo(i, k)) }, "/")
        end
        r.reagents = table.concat(reag, " ; ")
      end
      p.recipes[#p.recipes + 1] = r
    end
  end

  -- métiers de guilde (liste des artisans du jeu)
  if has("GetNumGuildTradeSkill") then
    local ok, n = pcall(GetNumGuildTradeSkill)
    p.notes[#p.notes + 1] = "GetNumGuildTradeSkill : " .. tostring(n)
    if ok and n and n > 0 and has("GetGuildTradeSkillInfo") then
      for i = 1, math.min(n, 4) do
        p.notes[#p.notes + 1] = "guilde " .. i .. " : " .. table.concat({ tostringall(GetGuildTradeSkillInfo(i)) }, ", ")
      end
    end
  end

  BrowzForeverDB.probe = p
  BF.Print(("Relevé enregistré (%d recette(s) d'exemple). Fais /reload pour que Claude puisse le lire."):format(#p.recipes))
  if #p.recipes == 0 then BF.Print("|cffff5555Aucune recette lue :|r ouvre d'abord la fenêtre d'un métier, puis relance /browz testmetier.") end
end
