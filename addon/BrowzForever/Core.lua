-- Browz Forever : noyau (guilde, nom complet, base de données, commandes)
local ADDON, BF = ...
_G.BrowzForever = BF

BF.VERSION = "0.13.0"
BF.GUILD_NAME = "Browz Forever"   -- l'addon ne fait rien en dehors de cette guilde

local function defaults()
  return {
    bank = nil,        -- dernière photo connue de la banque (scan local ou reçu de la guilde)
    logs = nil,        -- derniers journaux bruts lus au coffre (pont : envoyés au bot)
    outbox = {},       -- passages au coffre à transmettre au bot (lu par le client du pont)
    bridge = false,    -- ce PC fait le pont vers Discord
    items = {},        -- catalogue des objets vus : [id] = { n = nom, q = qualité, c = catégorie, i = icône }
    ui = {},
    requests = {},     -- demandes de retrait de la guilde : [id] = { who, t, items, why, status, by, upd… }
  }
end

function BF.Print(msg) print("|cffff9933[Browz]|r " .. tostring(msg)) end
function BF.Debug(msg) if BrowzForeverDB and BrowzForeverDB.debug then BF.Print("|cff888888" .. tostring(msg) .. "|r") end end

-- État de la guilde ------------------------------------------------------------
BF.active = false
BF.fullName = nil

local function findFullName()
  local myGUID = UnitGUID("player")
  local n = GetNumGuildMembers and GetNumGuildMembers() or 0
  for i = 1, n do
    local name, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, guid = GetGuildRosterInfo(i)
    if guid and guid == myGUID and name then return name end
  end
end

function BF.IsOfficer()
  if C_GuildInfo and C_GuildInfo.CanViewOfficerNote then return C_GuildInfo.CanViewOfficerNote() and true or false end
  return false
end

local listeners = {}
function BF.OnActive(fn) listeners[#listeners + 1] = fn end

local function refreshGuild()
  local gName = GetGuildInfo("player")
  local wasActive = BF.active
  BF.active = (gName == BF.GUILD_NAME)
  if BF.active then
    BF.fullName = BF.fullName or findFullName()
    if not wasActive then
      for _, fn in ipairs(listeners) do pcall(fn) end
    end
  end
end

function BF.MyName()
  return BF.fullName or findFullName() or UnitName("player")
end

-- Formatage --------------------------------------------------------------------
function BF.Money(c)
  c = c or 0
  local sign = c < 0 and "-" or ""
  c = math.abs(c)
  if GetCoinTextureString then return sign .. GetCoinTextureString(c) end
  return string.format("%s%d po %d pa %d pc", sign, math.floor(c / 10000), math.floor(c / 100) % 100, c % 100)
end

function BF.Ago(t)
  if not t then return "jamais" end
  local d = GetServerTime() - t
  if d < 60 then return "à l'instant" end
  if d < 3600 then return ("il y a %d min"):format(math.floor(d / 60)) end
  if d < 86400 then return ("il y a %d h"):format(math.floor(d / 3600)) end
  return ("il y a %d j"):format(math.floor(d / 86400))
end

-- Événements -------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_GUILD_UPDATE")
f:RegisterEvent("GUILD_ROSTER_UPDATE")
f:SetScript("OnEvent", function(_, e, a1)
  if e == "ADDON_LOADED" and a1 == ADDON then
    BrowzForeverDB = BrowzForeverDB or defaults()
    for k, v in pairs(defaults()) do if BrowzForeverDB[k] == nil then BrowzForeverDB[k] = v end end
  elseif e == "PLAYER_LOGIN" then
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
    C_Timer.After(5, refreshGuild)
  else
    refreshGuild()
  end
end)

-- Commandes ----------------------------------------------------------------------
BF.commands = {}
SLASH_BROWZ1 = "/browz"
SlashCmdList.BROWZ = function(msg)
  if not BF.active then return end -- hors de la guilde : silence total
  local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  local fn = BF.commands[cmd]
  if fn then fn(rest) else
    BF.Print("Commande inconnue. |cffffd100/browz aide|r pour la liste.")
  end
end
