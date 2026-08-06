-- PoisonCheck: Rogue poison reminder addon
-- Alerts when missing lethal or non-lethal poisons
-- Supports Dragon-Tempered Blades talent (requires 2 of each)

local addonName, addon = ...

-- Constants
local ROGUE_CLASS_ID = 4
local DRAGON_TEMPERED_BLADES_SPELL_ID = 381801
local LOW_DURATION_THRESHOLD = 900 -- 15 minutes in seconds

-- Poison buff spell IDs (as of 12.0 / Midnight)
-- These are the buff IDs that appear on the player when poisons are active
-- Use /pc debug to scan your current buffs and find poison spell IDs if these change
local LETHAL_POISONS = {
    [2823]   = "Deadly Poison",
    [315584] = "Instant Poison",
    [8679]   = "Wound Poison",
    [381664] = "Amplifying Poison",
}

local NON_LETHAL_POISONS = {
    [3408]   = "Crippling Poison",
    [5761]   = "Numbing Poison",
    [381637] = "Atrophic Poison",
}

-- Combined table for scanning
local ALL_KNOWN_POISONS = {}
for id, name in pairs(LETHAL_POISONS) do ALL_KNOWN_POISONS[id] = name end
for id, name in pairs(NON_LETHAL_POISONS) do ALL_KNOWN_POISONS[id] = name end

-- Local references for performance
local UnitClass = UnitClass
local C_UnitAuras = C_UnitAuras
local IsPlayerSpell = IsPlayerSpell
local GetTime = GetTime

-- Safely get spellId from aura (handles "secret" aura data)
-- Test table for validating spellId can be used as index
local spellIdTestTable = {}
local function SafeGetSpellId(aura)
    if not aura then return nil end
    -- Try to access and use the spellId as a table index
    local ok, result = pcall(function()
        local id = aura.spellId
        if id then
            -- Test that we can actually use it as a table key
            local _ = spellIdTestTable[id]
            return id
        end
        return nil
    end)
    if ok then return result end
    return nil
end

-- Addon state
local isRogue = false
local lastAlertTime = 0
local ALERT_COOLDOWN = 5 -- seconds between alerts
local lastAuraCheck = 0
local AURA_CHECK_THROTTLE = 0.3 -- seconds; only applied while in combat
local lastPoisonState = { lethal = 0, nonLethal = 0 } -- Track poison counts to detect changes

-- Frame for events
local frame = CreateFrame("Frame", "PoisonCheckFrame")

-- Saved variables defaults
local defaults = {
    enabled = true,
    alertSound = true,
    showChatMessage = true,
}

-- Initialize saved variables
local function InitializeDB()
    if not PoisonCheckDB then
        PoisonCheckDB = {}
    end
    for k, v in pairs(defaults) do
        if PoisonCheckDB[k] == nil then
            PoisonCheckDB[k] = v
        end
    end
end

-- Dragon-Tempered Blades is a talent, and talents cannot change in combat. Cache it on
-- spell/talent updates so the in-combat alert path never calls IsPlayerSpell -- whose
-- return would be a boolean test, which errors if it ever comes back secret.
local cachedDTB = false
local function RefreshDTB()
    if InCombatLockdown() then return end
    cachedDTB = IsPlayerSpell(DRAGON_TEMPERED_BLADES_SPELL_ID) and true or false
end

local function HasDragonTemperedBlades()
    return cachedDTB
end

-- Count active poisons of a specific type
-- Returns: count, minimum remaining duration (seconds), name of lowest duration poison
--
-- 12.1: index-based aura APIs (GetAuraDataByIndex, UnitBuff) Lua error while auras are
-- secret -- which now covers encounters, M+ and PvP, not just combat lockdown. Spell-ID
-- lookup stays callable and poison buffs are non-secret (verified on PTR), so query the
-- IDs we already know instead of walking the whole aura list.
local function CountActivePoisons(poisonTable)
    local count = 0
    local minDuration = nil
    local minDurationName = nil

    for spellId, name in pairs(poisonTable) do
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellId)
        if aura then
            count = count + 1

            -- expirationTime is absolute; subtract GetTime for remaining
            if aura.expirationTime and aura.expirationTime > 0 then
                local remaining = aura.expirationTime - GetTime()
                if remaining > 0 and (minDuration == nil or remaining < minDuration) then
                    minDuration = remaining
                    minDurationName = aura.name or name
                end
            end
        end
    end

    return count, minDuration, minDurationName
end

-- Get names of missing poison types and duration info
local function GetMissingPoisonInfo()
    local lethalCount, lethalMinDur, lethalMinName = CountActivePoisons(LETHAL_POISONS)
    local nonLethalCount, nonLethalMinDur, nonLethalMinName = CountActivePoisons(NON_LETHAL_POISONS)

    local hasDTB = HasDragonTemperedBlades()
    local requiredLethal = hasDTB and 2 or 1
    local requiredNonLethal = hasDTB and 2 or 1

    local missingLethal = requiredLethal - lethalCount
    local missingNonLethal = requiredNonLethal - nonLethalCount

    -- Check for low duration warnings
    local lethalLowDuration = lethalMinDur and lethalMinDur < LOW_DURATION_THRESHOLD
    local nonLethalLowDuration = nonLethalMinDur and nonLethalMinDur < LOW_DURATION_THRESHOLD

    return {
        missingLethal = missingLethal > 0 and missingLethal or 0,
        missingNonLethal = missingNonLethal > 0 and missingNonLethal or 0,
        hasDTB = hasDTB,
        lethalCount = lethalCount,
        nonLethalCount = nonLethalCount,
        requiredLethal = requiredLethal,
        requiredNonLethal = requiredNonLethal,
        -- Duration info
        lethalMinDuration = lethalMinDur,
        lethalMinName = lethalMinName,
        lethalLowDuration = lethalLowDuration,
        nonLethalMinDuration = nonLethalMinDur,
        nonLethalMinName = nonLethalMinName,
        nonLethalLowDuration = nonLethalLowDuration,
    }
end

-- Format seconds into minutes:seconds string
local function FormatDuration(seconds)
    if not seconds then return "?" end
    local mins = math.floor(seconds / 60)
    local secs = math.floor(seconds % 60)
    return string.format("%d:%02d", mins, secs)
end

-- Display alert to the player
-- checkDurations: if true, also warn about low duration poisons (for pull events)
local function ShowAlert(info, checkDurations)
    if not PoisonCheckDB.enabled then return end

    local now = GetTime()
    if now - lastAlertTime < ALERT_COOLDOWN then return end

    local messages = {}

    -- Missing poison warnings (red/orange)
    if info.missingLethal > 0 then
        if info.hasDTB then
            table.insert(messages, string.format("|cffff0000Missing %d Lethal Poison(s)!|r (DTB: need %d)",
                info.missingLethal, info.requiredLethal))
        else
            table.insert(messages, "|cffff0000Missing Lethal Poison!|r")
        end
    end

    if info.missingNonLethal > 0 then
        if info.hasDTB then
            table.insert(messages, string.format("|cffff9900Missing %d Non-Lethal Poison(s)!|r (DTB: need %d)",
                info.missingNonLethal, info.requiredNonLethal))
        else
            table.insert(messages, "|cffff9900Missing Non-Lethal Poison!|r")
        end
    end

    -- Low duration warnings (yellow) - only on pull events
    if checkDurations then
        if info.lethalLowDuration and info.missingLethal == 0 then
            table.insert(messages, string.format("|cffffff00%s expiring soon (%s)!|r",
                info.lethalMinName or "Lethal Poison", FormatDuration(info.lethalMinDuration)))
        end

        if info.nonLethalLowDuration and info.missingNonLethal == 0 then
            table.insert(messages, string.format("|cffffff00%s expiring soon (%s)!|r",
                info.nonLethalMinName or "Non-Lethal Poison", FormatDuration(info.nonLethalMinDuration)))
        end
    end

    if #messages > 0 then
        lastAlertTime = now

        -- Chat message
        if PoisonCheckDB.showChatMessage then
            for _, msg in ipairs(messages) do
                print("|cff00ff00[PoisonCheck]|r " .. msg)
            end
        end

        -- Raid warning style alert
        RaidNotice_AddMessage(RaidWarningFrame, table.concat(messages, " | "), ChatTypeInfo["RAID_WARNING"])

        -- Sound alert
        if PoisonCheckDB.alertSound then
            PlaySound(SOUNDKIT.RAID_WARNING, "Master")
        end
    end
end

-- Main check function
-- forceAlert: always show missing poison warnings regardless of state change
-- checkDurations: also warn about poisons expiring soon (for pull events)
local function CheckPoisons(forceAlert, checkDurations)
    if not isRogue or not PoisonCheckDB.enabled then return end

    -- Runs in combat: poison counting is spell-ID lookups on non-secret auras, and the
    -- DTB talent is cached, so nothing on this path is combat-restricted. Losing a poison
    -- mid-fight is exactly when you want to hear about it.
    local info = GetMissingPoisonInfo()

    -- Only alert if state changed (poison fell off) or forced
    local stateChanged = (info.lethalCount ~= lastPoisonState.lethal) or
                         (info.nonLethalCount ~= lastPoisonState.nonLethal)

    lastPoisonState.lethal = info.lethalCount
    lastPoisonState.nonLethal = info.nonLethalCount

    -- Check if we need to alert
    local hasMissing = info.missingLethal > 0 or info.missingNonLethal > 0
    local hasLowDuration = checkDurations and (info.lethalLowDuration or info.nonLethalLowDuration)

    if (hasMissing and (stateChanged or forceAlert)) or hasLowDuration then
        ShowAlert(info, checkDurations)
    end
end

-- Debug: scan all player buffs to find poison spell IDs
local function ScanPlayerBuffs()
    print("|cff00ff00[PoisonCheck] Scanning all player buffs:|r")
    local poisonKeywords = {"poison", "venom", "toxin", "lethal", "deadly", "instant", "wound", "crippling", "numbing", "atrophic", "amplifying"}

    local i = 1
    local foundAny = false
    while true do
        -- Discovering *unknown* poison IDs needs the full aura list, so there is no
        -- spell-ID equivalent for this one. 12.1 errors on index access while auras are
        -- secret, so degrade with an explanation instead of throwing.
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok then
            print("  |cffff0000Can't scan here - auras are restricted in combat, raids, M+ and PvP.|r")
            print("  |cff888888Run /pc debug in the open world, out of combat.|r")
            return
        end
        if not aura then break end

        local name = aura.name or "Unknown"
        local spellId = SafeGetSpellId(aura) or 0
        local lowerName = name:lower()

        -- Check if it looks like a poison
        local isPoisonLike = false
        for _, keyword in ipairs(poisonKeywords) do
            if lowerName:find(keyword) then
                isPoisonLike = true
                break
            end
        end

        -- Check if it's a known poison
        local isKnown = ALL_KNOWN_POISONS[spellId]

        if isPoisonLike or isKnown then
            local status = isKnown and "|cff00ff00[KNOWN]|r" or "|cffffff00[NEW?]|r"
            print(string.format("  %s %s (ID: %d)", status, name, spellId))
            foundAny = true
        end

        i = i + 1
    end

    if not foundAny then
        print("  No poison-like buffs found. Apply poisons and try again.")
    end

    print("|cff00ff00[PoisonCheck]|r Dragon-Tempered Blades talent detected: " ..
        (HasDragonTemperedBlades() and "|cff00ff00Yes|r" or "|cffff0000No|r"))
end

-- Slash commands
local function HandleSlashCommand(msg)
    local cmd = msg:lower():trim()

    if cmd == "" or cmd == "help" then
        print("|cff00ff00[PoisonCheck] Commands:|r")
        print("  /pc status - Show current poison status")
        print("  /pc toggle - Enable/disable alerts")
        print("  /pc sound - Toggle sound alerts")
        print("  /pc check - Force a poison check now")
        print("  /pc debug - Scan buffs to find poison spell IDs")
        if not isRogue then
            print("")
            print("|cff888888Note: You are not playing a Rogue. Alerts are disabled.|r")
        end
    elseif cmd == "debug" then
        if not isRogue then
            print("|cff00ff00[PoisonCheck]|r |cff888888You are not playing a Rogue. This command is only useful for Rogues.|r")
            return
        end
        ScanPlayerBuffs()
    elseif cmd == "status" then
        if not isRogue then
            print("|cff00ff00[PoisonCheck]|r |cff888888You are not playing a Rogue. Alerts are disabled.|r")
            return
        end
        local info = GetMissingPoisonInfo()
        print("|cff00ff00[PoisonCheck] Status:|r")
        print(string.format("  Dragon-Tempered Blades: %s", info.hasDTB and "|cff00ff00Yes|r" or "|cffff0000No|r"))
        print(string.format("  Lethal Poisons: %d/%d", info.lethalCount, info.requiredLethal))
        if info.lethalMinDuration then
            local durColor = info.lethalLowDuration and "|cffffff00" or "|cff00ff00"
            print(string.format("    Lowest duration: %s%s|r (%s)", durColor, FormatDuration(info.lethalMinDuration), info.lethalMinName or "Unknown"))
        end
        print(string.format("  Non-Lethal Poisons: %d/%d", info.nonLethalCount, info.requiredNonLethal))
        if info.nonLethalMinDuration then
            local durColor = info.nonLethalLowDuration and "|cffffff00" or "|cff00ff00"
            print(string.format("    Lowest duration: %s%s|r (%s)", durColor, FormatDuration(info.nonLethalMinDuration), info.nonLethalMinName or "Unknown"))
        end
        if info.missingLethal > 0 or info.missingNonLethal > 0 then
            print("  |cffff0000You are missing poisons!|r")
        elseif info.lethalLowDuration or info.nonLethalLowDuration then
            print("  |cffffff00Poisons expiring soon!|r")
        else
            print("  |cff00ff00All poisons applied!|r")
        end
    elseif cmd == "toggle" then
        PoisonCheckDB.enabled = not PoisonCheckDB.enabled
        print(string.format("|cff00ff00[PoisonCheck]|r Alerts %s",
            PoisonCheckDB.enabled and "|cff00ff00enabled|r" or "|cffff0000disabled|r"))
    elseif cmd == "sound" then
        PoisonCheckDB.alertSound = not PoisonCheckDB.alertSound
        print(string.format("|cff00ff00[PoisonCheck]|r Sound alerts %s",
            PoisonCheckDB.alertSound and "|cff00ff00enabled|r" or "|cffff0000disabled|r"))
    elseif cmd == "check" then
        if not isRogue then
            print("|cff00ff00[PoisonCheck]|r |cff888888You are not playing a Rogue. Alerts are disabled.|r")
            return
        end
        lastAlertTime = 0 -- Reset cooldown for manual check
        CheckPoisons(true, true) -- Also check durations on manual check
        local info = GetMissingPoisonInfo()
        if info.missingLethal == 0 and info.missingNonLethal == 0 then
            if info.lethalLowDuration or info.nonLethalLowDuration then
                -- Alert was shown for low duration
            else
                print("|cff00ff00[PoisonCheck]|r All poisons are applied!")
            end
        end
    else
        print("|cff00ff00[PoisonCheck]|r Unknown command. Type /pc help for options.")
    end
end

SLASH_POISONCHECK1 = "/poisoncheck"
SLASH_POISONCHECK2 = "/pc"
SlashCmdList["POISONCHECK"] = HandleSlashCommand

-- Event handlers
local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == addonName then
            InitializeDB()
            local _, _, classId = UnitClass("player")
            isRogue = (classId == ROGUE_CLASS_ID)

            if isRogue then
                print("|cff00ff00[PoisonCheck]|r Loaded! Type /pc for options.")
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if isRogue then
            RefreshDTB()
            -- Delay check to allow buffs to load, force alert on login
            C_Timer.After(2, function() CheckPoisons(true) end)
        end

    elseif event == "SPELLS_CHANGED" then
        -- Talent swap: refresh the cached DTB state (no-op if it fires in combat)
        if isRogue then
            RefreshDTB()
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        local unit = ...
        -- Spec swap changes whether DTB is talented, which changes how many poisons are
        -- required -- but not how many are applied, so the count-based stateChanged test
        -- would never fire. Delay for the spellbook to settle, then force a re-evaluation.
        if unit == "player" and isRogue then
            C_Timer.After(1, function()
                RefreshDTB()
                lastAlertTime = 0
                CheckPoisons(true)
            end)
        end

    elseif event == "UNIT_AURA" then
        local unit = ...
        -- 12.1: the updateInfo payload is fully secret while auras are restricted, so it
        -- can't be inspected to pre-filter as it was before. In combat UNIT_AURA fires
        -- constantly (every proc, stack and bleed), so throttle there; out of combat
        -- events are rare and every one is checked so a drop is never missed.
        if unit == "player" and isRogue then
            local now = GetTime()
            if not InCombatLockdown() or (now - lastAuraCheck) >= AURA_CHECK_THROTTLE then
                lastAuraCheck = now
                CheckPoisons(false)
            end
        end

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        -- Force check on zone change (entering dungeon/raid)
        if isRogue then
            C_Timer.After(1, function() CheckPoisons(true) end)
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Check after combat ends (reminder to reapply if needed)
        if isRogue then
            C_Timer.After(1, function() CheckPoisons(false) end)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Check when joining a group
        if isRogue then
            C_Timer.After(1, function() CheckPoisons(true) end)
        end

    elseif event == "READY_CHECK" then
        -- Critical: Ready check means pull is imminent - check durations
        if isRogue then
            lastAlertTime = 0
            CheckPoisons(true, true) -- forceAlert=true, checkDurations=true
        end

    elseif event == "LFG_PROPOSAL_SHOW" then
        -- Queue popped, check before accepting - check durations
        if isRogue then
            lastAlertTime = 0
            CheckPoisons(true, true)
        end

    elseif event == "CHALLENGE_MODE_RESET" or event == "CHALLENGE_MODE_START" then
        -- M+ is starting - check durations
        if isRogue then
            lastAlertTime = 0
            CheckPoisons(true, true)
        end
    end
end

-- Register events
frame:SetScript("OnEvent", OnEvent)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("UNIT_AURA")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("READY_CHECK")
frame:RegisterEvent("LFG_PROPOSAL_SHOW")
frame:RegisterEvent("CHALLENGE_MODE_RESET")
frame:RegisterEvent("CHALLENGE_MODE_START")
