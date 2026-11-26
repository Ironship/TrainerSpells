local _, TrainerSpells = ...
function TrainerSpells:AddHeaderItem(items, text, colorCode, totalCost, groupKey, prefixText, spellCount, headerDepth, countKind)
    local price = type(totalCost) == "table" and totalCost or nil
    if price then totalCost = price.cost end
    table.insert(items, {
        isHeader = true,
        text = text,
        color = colorCode,
        totalCost = totalCost,
        baseCost = price and price.baseCost,
        baseCostEstimated = price and price.baseCostEstimated,
        priceFaction = price and price.priceFaction,
        priceDiscount = price and price.priceDiscount,
        priceEligible = price ~= nil,
        groupKey = groupKey,
        collapsed = TrainerSpells:IsGroupCollapsed(groupKey),
        prefixText = prefixText,
        spellCount = spellCount,
        headerDepth = headerDepth,
        countKind = countKind
    })
end

function TrainerSpells:AddEntryItems(items, list, colorCode, showLevel, showCostTooltip, dimName, levelLabel, rowDepth)
    for _, entry in ipairs(list) do
        table.insert(items, {
            isHeader = false,
            entry = entry,
            color = colorCode,
            showLevel = showLevel,
            showCostTooltip = showCostTooltip,
            dimName = dimName,
            levelLabel = levelLabel,
            rowDepth = rowDepth,
        })
    end
end

function TrainerSpells:SumCost(list)
    local total = 0
    local baseCost, estimated, complete, eligible = 0, false, true, false
    for _, entry in ipairs(list) do
        total = total + (entry.cost or 0)
        baseCost = baseCost + (entry.baseCost or 0)
        estimated = estimated or entry.baseCostEstimated
        eligible = eligible or entry.priceEligible
        if entry.baseCost == nil and not entry.questReward then complete = false end
    end
    if not eligible then return total end
    local discount, factionName = TrainerSpells.Pricing.GetBestDiscount()
    return {cost = total, baseCost = complete and baseCost or nil, baseCostEstimated = estimated, priceFaction = factionName, priceDiscount = discount}
end

function TrainerSpells:AddCostColumn(items)
    local column = {
        costs = {},
        widths = {}
    }

    local seen = {}
    for _, item in ipairs(items) do
        local cost = item.entry and item.showCostTooltip and item.entry.cost
        if item.entry and item.entry.questReward then
            cost = "!"
        elseif item.entry and item.entry.baseCost ~= nil then
            cost = TrainerSpells.Pricing.Text(item.entry.baseCost, cost, item.entry.baseCostEstimated)
        end
        if cost and (type(cost) == "string" or cost > 0) and not seen[cost] then
            seen[cost] = true
            table.insert(column.costs, cost)
        end
    end

    if #column.costs == 0 then return end
    for _, item in ipairs(items) do
        if item.entry and item.showCostTooltip then item.costColumn = column end
    end
end

local function CountGroupEntries(groups)
    return #groups.available + #groups.soon + #groups.higher + #groups.missingTalents + #groups.ignored + #groups.known
end

local function RaceMatches(race, playerRace)
    if not race or not playerRace then return true end
    if type(race) ~= "table" then return race == playerRace end
    for _, raceToken in ipairs(race) do
        if raceToken == playerRace then return true end
    end

    return false
end

local function GetSourceLocations(locations, playerFaction)
    if type(locations) ~= "table" then return nil end
    local result = {}
    for _, location in ipairs(locations) do
        if not location.faction or location.faction == "Neutral" or (playerFaction and location.faction == playerFaction) then table.insert(result, location) end
    end
    return #result > 0 and result or nil
end

local function FormatSourceLocationsText(locations)
    local vendors, seenVendors = {}, {}
    local quests, seenQuests = {}, {}
    for _, loc in ipairs(locations or {}) do
        if loc.questID then
            local name = loc.questName or tostring(loc.questID)
            if not seenQuests[name] then
                seenQuests[name] = true
                table.insert(quests, name)
            end
        else
            local label = loc.npcName and loc.zoneName and (loc.npcName .. " (" .. loc.zoneName .. ")") or loc.npcName or loc.zoneName
            if label and not seenVendors[label] then
                seenVendors[label] = true
                table.insert(vendors, label)
            end
        end
    end
    local parts = {}
    if #vendors > 0 then table.insert(parts, "Sold by " .. table.concat(vendors, ", ")) end
    if #quests > 0 then table.insert(parts, "Quest reward: " .. table.concat(quests, ", ")) end
    return parts
end

local function ExtractNonLocationSourceParts(rawSource)
    local parts = {}
    if type(rawSource) ~= "string" or rawSource == "" then return parts end
    local start = 1
    while true do
        local sepStart, sepEnd = rawSource:find(" / ", start, true)
        local segment = sepStart and rawSource:sub(start, sepStart - 1) or rawSource:sub(start)
        if segment ~= "" and not segment:find("^Sold by ") and not segment:find("^Quest reward:") then
            table.insert(parts, segment)
        end
        if not sepStart then break end
        start = sepEnd + 1
    end
    return parts
end

local function ResolveRecipeSource(rawSource, rawLocations, playerFaction)
    if type(rawLocations) ~= "table" or #rawLocations == 0 then
        return true, rawSource, nil
    end
    local filtered = GetSourceLocations(rawLocations, playerFaction)
    local extraParts = ExtractNonLocationSourceParts(rawSource)
    if not filtered then
        if #extraParts == 0 then return false, nil, nil end
        return true, table.concat(extraParts, " / "), nil
    end
    if #filtered < #rawLocations then
        local parts = FormatSourceLocationsText(filtered)
        for _, part in ipairs(extraParts) do
            table.insert(parts, part)
        end
        local text = #parts > 0 and table.concat(parts, " / ") or rawSource
        return true, text, filtered
    end
    return true, rawSource, filtered
end

local function PrepareBuildContext(dataTable, questSpells)
    local playerFaction = TrainerSpells:GetPlayerFaction()
    local playerRace = TrainerSpells:GetPlayerRace()
    local discount, factionName = TrainerSpells.Pricing.GetBestDiscount()
    local classToken = select(2, UnitClass("player"))
    local priceEligible = TrainerSpells_Data and dataTable == TrainerSpells_Data[classToken]
    for _, professionData in pairs(TrainerSpells_ProfessionData or {}) do
        if dataTable == professionData then priceEligible = true; break end
    end
    if questSpells then
        local questLevels = {}
        local _, _, raceID = UnitRace("player")
        for spellID, levels in pairs(questSpells) do
            questLevels[spellID] = type(levels) == "table" and levels[raceID] or type(levels) == "number" and levels or nil
        end

        local merged = {}
        for level, spells in pairs(dataTable) do
            merged[level] = {}
            for spellID, data in pairs(spells) do
                local id = type(data) == "table" and data.spellID or spellID
                if not questLevels[id] then merged[level][spellID] = data end
            end
        end

        if not (TrainerSpells_Character and TrainerSpells_Character.spoilerFree) then
            for spellID, level in pairs(questLevels) do
                merged[level] = merged[level] or {}
                local start = TrainerSpells.QuestSpellStarts and TrainerSpells.QuestSpellStarts[spellID]
                if start and not start.questID then start = start[raceID] or start[playerFaction] end
                local rank = TrainerSpells.QuestSpellRanks and TrainerSpells.QuestSpellRanks[spellID]
                merged[level][spellID] = {questReward = true, questStart = start, rank = rank}
            end
        end

        dataTable = merged
    end

    return dataTable, {
        playerFaction = playerFaction,
        playerRace = playerRace,
        discount = discount,
        factionName = factionName,
        priceEligible = priceEligible,
        beasts = TrainerSpells.HunterBeasts,
    }
end

local function AppendBuiltEntry(lvl, key, data, ctx, allEntries, knownMaxRank)
    local cost, rank, status, requires, faction, race, spellID, icon, levelReq
    local source, sourceLocations
    if type(data) == "table" then
        cost, rank, status, requires, faction, race = data.cost, data.rank, data.status, data.requires, data.faction, data.race
        spellID, icon, levelReq = data.spellID, data.icon, data.levelReq
        source, sourceLocations = data.source, data.sourceLocations
    else
        cost = data
    end

    local raceMatches = RaceMatches(race, ctx.playerRace)
    local sourceMatches, resolvedSource, resolvedLocations = ResolveRecipeSource(source, sourceLocations, ctx.playerFaction)

    if (not faction or not ctx.playerFaction or faction == ctx.playerFaction) and raceMatches and sourceMatches then
        local name
        if type(key) == "number" then
            spellID = spellID or key
            name, _, icon = TrainerSpells:GetSpellInfo(key)
        else
            name = key
        end

        name = name or ("SpellID " .. tostring(key))
        if not icon and spellID then
            local _, _, resolvedIcon = TrainerSpells:GetSpellInfo(spellID)
            icon = resolvedIcon
        end

        icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark"
        local hasRealRank = (type(rank) == "number") or (type(rank) == "string" and rank:match("%d+") ~= nil)
        local rankNum = (type(rank) == "number" and rank) or (type(rank) == "string" and tonumber(rank:match("%d+"))) or 1
        local beasts = ctx.beasts
        local isLearnedPetSpell = spellID and (TrainerSpells:IsPetSpellKnown(spellID) or (beasts and beasts.IsKnown and beasts.rankBySpell and beasts.rankBySpell[spellID] and beasts.IsKnown(spellID)))
        local directlyKnown = (spellID and IsPlayerSpell and IsPlayerSpell(spellID)) or isLearnedPetSpell or status == "used"
        local entry = {
            level = lvl,
            key = key,
            spellID = spellID,
            cost = cost,
            name = name,
            icon = icon,
            recipeItemID = type(data) == "table" and data.recipeItemID,
            rankNum = rankNum,
            hasRealRank = hasRealRank,
            directlyKnown = directlyKnown,
            requires = requires,
            levelReq = levelReq,
            source = resolvedSource,
            questReward = type(data) == "table" and data.questReward,
            questStart = type(data) == "table" and data.questStart,
            sourceLocations = resolvedLocations,
        }

        if ctx.priceEligible and not entry.questReward then TrainerSpells.Pricing.Apply(entry, data, ctx.discount, ctx.factionName) end

        table.insert(allEntries, entry)
        if directlyKnown and hasRealRank then knownMaxRank[name] = math.max(knownMaxRank[name] or 0, rankNum) end
    end
end

function TrainerSpells:BuildEntriesFromData(dataTable, questSpells)
    local allEntries = {}
    local knownMaxRank = {}
    local resolvedTable, ctx = PrepareBuildContext(dataTable, questSpells)
    for lvl, spells in pairs(resolvedTable) do
        for key, data in pairs(spells) do
            AppendBuiltEntry(lvl, key, data, ctx, allEntries, knownMaxRank)
        end
    end
    return allEntries, knownMaxRank
end

function TrainerSpells:CreateSpoilerFreeCheckbox(parent, settingKey, descKey, onToggle)
    local checkbox = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    checkbox:SetSize(20, 20)
    checkbox.text = checkbox:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    checkbox.text:SetPoint("LEFT", checkbox, "RIGHT", 2, 0)
    checkbox.text:SetText(TrainerSpells:Trans("LID_SPOILERFREE"))
    checkbox:SetScript("OnShow", function(button) button:SetChecked(TrainerSpells_Character[settingKey] and true or false) end)
    checkbox:SetScript("OnClick", function(button)
        TrainerSpells_Character[settingKey] = button:GetChecked() and true or false
        onToggle()
    end)
    checkbox:SetScript("OnEnter", function(button)
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:SetText(TrainerSpells:Trans("LID_SPOILERFREE"))
        GameTooltip:AddLine(TrainerSpells:Trans(descKey), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    checkbox:SetScript("OnLeave", GameTooltip_Hide)
    return checkbox
end

local function FinalizeGroups(allEntries, knownMaxRank, searchText, selectedLevel, talentNames, learnedTalents, professionKey)
    local ignored, known, remaining = {}, {}, {}
    local spoilerLimit
    if professionKey then
        spoilerLimit = TrainerSpells_Character and TrainerSpells_Character.professionSpoilerFree and selectedLevel + 5
    else
        spoilerLimit = TrainerSpells_Character and TrainerSpells_Character.spoilerFree and selectedLevel + 2
    end
    local rankIgnoreStates = {}
    local knownRankless = {}
    if not professionKey then
        for _, entry in ipairs(allEntries) do
            if entry.directlyKnown and not entry.hasRealRank then knownRankless[entry.name] = true end
        end
    end

    for _, entry in ipairs(allEntries) do
        local isIgnored
        if not professionKey then
            isIgnored = TrainerSpells_IsIgnored(entry.spellID, entry.name)
            local rankState = rankIgnoreStates[entry.name]
            if not rankState then
                rankState = {entries = {}}
                rankIgnoreStates[entry.name] = rankState
            end

            entry.rankIgnoreState = rankState
            table.insert(rankState.entries, entry)
            if isIgnored then
                rankState.hasIgnored = true
            else
                rankState.hasUnignored = true
            end
        end

        if (not spoilerLimit or entry.level <= spoilerLimit) and TrainerSpells:EntryMatchesSearch(entry, searchText) then
            if professionKey then
                isIgnored = TrainerSpells_IsProfessionSpellIgnored and TrainerSpells_IsProfessionSpellIgnored(entry.spellID, professionKey)
            end

            if isIgnored then
                table.insert(ignored, entry)
            else
                local maxKnown = knownMaxRank[entry.name] or 0
                local isKnown = entry.directlyKnown or (entry.hasRealRank and entry.rankNum <= maxKnown) or (not entry.hasRealRank and knownRankless[entry.name])
                if isKnown then
                    table.insert(known, entry)
                else
                    table.insert(remaining, entry)
                end
            end
        end
    end

    local available, missingTalents, future = {}, {}, {}
    for _, entry in ipairs(remaining) do
        local looksTalentGated = talentNames and ((talentNames[entry.name] and not learnedTalents[entry.name]) or TrainerSpells:RequiresUnknownTalent(entry, talentNames, learnedTalents))
        if looksTalentGated then
            table.insert(missingTalents, entry)
        elseif entry.level > selectedLevel then
            table.insert(future, entry)
        else
            table.insert(available, entry)
        end
    end

    local nextLevel
    for _, entry in ipairs(future) do
        if not nextLevel or entry.level < nextLevel then nextLevel = entry.level end
    end

    local soon, higher = {}, {}
    for _, entry in ipairs(future) do
        if entry.level == nextLevel then
            table.insert(soon, entry)
        else
            table.insert(higher, entry)
        end
    end

    TrainerSpells:SortEntries(available)
    TrainerSpells:SortEntries(missingTalents)
    TrainerSpells:SortEntries(ignored)
    TrainerSpells:SortEntries(soon)
    TrainerSpells:SortEntries(higher)
    TrainerSpells:SortEntries(known)
    return {
        available = available,
        soon = soon,
        higher = higher,
        missingTalents = missingTalents,
        ignored = ignored,
        known = known,
        nextLevel = nextLevel,
    }
end

function TrainerSpells:ClassifyEntries(dataTable, searchText, selectedLevel, skipTalentCheck, professionKey, questSpells)
    local allEntries, knownMaxRank = TrainerSpells:BuildEntriesFromData(dataTable, questSpells)
    local talentNames, learnedTalents
    if not skipTalentCheck then talentNames, learnedTalents = TrainerSpells:GetTalentNameSet() end
    return FinalizeGroups(allEntries, knownMaxRank, searchText, selectedLevel, talentNames, learnedTalents, professionKey)
end

function TrainerSpells:ClassifyEntriesAsync(dataTable, searchText, selectedLevel, skipTalentCheck, professionKey, questSpells, callbacks)
    local resolvedTable, ctx = PrepareBuildContext(dataTable, questSpells)
    local levels = {}
    for lvl in pairs(resolvedTable) do levels[#levels + 1] = lvl end
    table.sort(levels)
    local work = {}
    for _, lvl in ipairs(levels) do
        for key, data in pairs(resolvedTable[lvl]) do
            work[#work + 1] = {lvl, key, data}
        end
    end

    local total = #work
    local talentNames, learnedTalents
    if not skipTalentCheck then talentNames, learnedTalents = TrainerSpells:GetTalentNameSet() end
    local allEntries = {}
    local knownMaxRank = {}
    if not C_Timer or total <= 25 then
        for i = 1, total do
            local item = work[i]
            AppendBuiltEntry(item[1], item[2], item[3], ctx, allEntries, knownMaxRank)
        end
        callbacks.onComplete(FinalizeGroups(allEntries, knownMaxRank, searchText, selectedLevel, talentNames, learnedTalents, professionKey))
        return
    end

    local cursor = 1
    local sentFirst = false
    local lastProgress = 0
    local function Step()
        if callbacks.isCancelled and callbacks.isCancelled() then return end
        local startTime = debugprofilestop and debugprofilestop() or nil
        local count = 0
        while cursor <= total and count < 18 do
            local item = work[cursor]
            cursor = cursor + 1
            AppendBuiltEntry(item[1], item[2], item[3], ctx, allEntries, knownMaxRank)
            count = count + 1
            if startTime and (debugprofilestop() - startTime) >= 1.8 then break end
        end

        if cursor > total then
            callbacks.onComplete(FinalizeGroups(allEntries, knownMaxRank, searchText, selectedLevel, talentNames, learnedTalents, professionKey))
            return
        end

        local now = GetTime and GetTime() or 0
        if callbacks.onProgress and (not sentFirst or (now - lastProgress) >= 0.12) then
            sentFirst = true
            lastProgress = now
            callbacks.onProgress(FinalizeGroups(allEntries, knownMaxRank, searchText, selectedLevel, talentNames, learnedTalents, professionKey))
        end

        C_Timer.After(0, Step)
    end

    Step()
end

function TrainerSpells:AppendGroupItems(items, groups, keyPrefix, labelPrefix, unitLabel, showCost, headerDepth, countKind)
    local Colors = TrainerSpells.UIColors
    if showCost == nil then showCost = true end
    local entryLevelLabel = unitLabel and unitLabel ~= TrainerSpells:Trans("LID_LVL") and unitLabel or nil
    unitLabel = unitLabel or TrainerSpells:Trans("LID_LVL")
    if #groups.available > 0 then
        TrainerSpells:AddHeaderItem(items, TrainerSpells:Trans("LID_AVAILABLENOW"), Colors.AVAILABLE, showCost and TrainerSpells:SumCost(groups.available) or nil, keyPrefix .. "available", labelPrefix, #groups.available, headerDepth, countKind)
        if not TrainerSpells:IsGroupCollapsed(keyPrefix .. "available") then TrainerSpells:AddEntryItems(items, groups.available, Colors.AVAILABLE, true, showCost, false, entryLevelLabel, headerDepth) end
    end

    if #groups.soon > 0 then
        TrainerSpells:AddHeaderItem(items, ("%s (%s %d)"):format(TrainerSpells:Trans("LID_COMINGSOON"), unitLabel, groups.nextLevel), Colors.SOON, showCost and TrainerSpells:SumCost(groups.soon) or nil, keyPrefix .. "soon", labelPrefix, #groups.soon, headerDepth, countKind)
        if not TrainerSpells:IsGroupCollapsed(keyPrefix .. "soon") then TrainerSpells:AddEntryItems(items, groups.soon, Colors.SOON, true, showCost, false, entryLevelLabel, headerDepth) end
    end

    if #groups.higher > 0 then
        TrainerSpells:AddHeaderItem(items, TrainerSpells:Trans("LID_NOTYETAVAILABLE"), Colors.NOTYET, showCost and TrainerSpells:SumCost(groups.higher) or nil, keyPrefix .. "higher", labelPrefix, #groups.higher, headerDepth, countKind)
        if not TrainerSpells:IsGroupCollapsed(keyPrefix .. "higher") then TrainerSpells:AddEntryItems(items, groups.higher, Colors.NOTYET, true, showCost, false, entryLevelLabel, headerDepth) end
    end

    if #groups.missingTalents > 0 then
        TrainerSpells:AddHeaderItem(items, TrainerSpells:Trans("LID_MISSINGREQUIREDTALENTS"), Colors.TALENT, showCost and TrainerSpells:SumCost(groups.missingTalents) or nil, keyPrefix .. "missingTalents", labelPrefix, #groups.missingTalents, headerDepth, countKind)
        if not TrainerSpells:IsGroupCollapsed(keyPrefix .. "missingTalents") then TrainerSpells:AddEntryItems(items, groups.missingTalents, Colors.TALENT, true, showCost, false, entryLevelLabel, headerDepth) end
    end

    if #groups.ignored > 0 then
        TrainerSpells:AddHeaderItem(items, TrainerSpells:Trans("LID_IGNORED"), Colors.IGNORED, nil, keyPrefix .. "ignored", labelPrefix, #groups.ignored, headerDepth, countKind)
        if not TrainerSpells:IsGroupCollapsed(keyPrefix .. "ignored") then TrainerSpells:AddEntryItems(items, groups.ignored, Colors.IGNORED, true, showCost, true, entryLevelLabel, headerDepth) end
    end

    if #groups.known > 0 then
        TrainerSpells:AddHeaderItem(items, TrainerSpells:Trans("LID_ALREADYKNOWN"), Colors.KNOWN, showCost and TrainerSpells:SumCost(groups.known) or nil, keyPrefix .. "known", labelPrefix, #groups.known, headerDepth, countKind)
        if not TrainerSpells:IsGroupCollapsed(keyPrefix .. "known") then TrainerSpells:AddEntryItems(items, groups.known, Colors.KNOWN, true, showCost, true, entryLevelLabel, headerDepth) end
    end
end

local function MergePetData(keys)
    local merged = {}
    for _, key in ipairs(keys) do
        local data = TrainerSpells_PetData and TrainerSpells_PetData[key]
        if data then
            for lvl, spells in pairs(data) do
                merged[lvl] = merged[lvl] or {}
                for spellID, entryData in pairs(spells) do
                    merged[lvl][spellID] = entryData
                end
            end
        end
    end
    return merged
end

function TrainerSpells:AppendPetAbilities(items, searchText, selectedLevel)
    local Colors = TrainerSpells.UIColors
    for _, petGroup in ipairs(TrainerSpells.PetGroups) do
        local merged = MergePetData(petGroup.keys)
        if next(merged) then
            local groupKey = "pet_" .. table.concat(petGroup.keys, "_")
            local groups = TrainerSpells:ClassifyEntries(merged, searchText, selectedLevel, true)
            local subItems = {}
            TrainerSpells:AppendGroupItems(subItems, groups, groupKey .. "_", nil, nil, nil, 1)
            if #subItems > 0 then
                local groupCount = CountGroupEntries(groups)
                TrainerSpells:AddHeaderItem(items, petGroup.label, Colors.PET_HEADER, nil, groupKey, nil, groupCount)
                if not TrainerSpells:IsGroupCollapsed(groupKey) then
                    for _, item in ipairs(subItems) do
                        table.insert(items, item)
                    end
                end
            end
        end
    end
end

function TrainerSpells:AppendPetTrainerAbilities(items, searchText, selectedLevel, classToken)
    local petTrainerData = TrainerSpells_PetTrainerData and TrainerSpells_PetTrainerData[classToken]
    if not petTrainerData or not next(petTrainerData) then return end
    local groups = TrainerSpells:ClassifyEntries(petTrainerData, searchText, selectedLevel, true)
    TrainerSpells:AppendGroupItems(items, groups, "pettrainer_")
end
