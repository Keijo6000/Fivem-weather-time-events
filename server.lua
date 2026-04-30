-- ============================================
-- servun sää ja aika ja eventit
-- ============================================

local WeatherState = { --state
    currentWeather = Config.WeatherSettings.StartupWeather or 'CLEAR',
    currentHour = Config.TimeSettings.DefaultHour,
    currentMinute = Config.TimeSettings.DefaultMinute,
    weatherFrozen = false,
    timeFrozen = false,
    weatherCycle = 'normal',
    snowOnGround = Config.WeatherSettings.SnowOnGround or false,
    rainLevel = 0.0,
    dynamicWeatherEnabled = true, --dynaaminen
    blackout = false, --sähköt
    vehicleLightsDisabled = false, --sähkökatkoksessa
    syncWithRealTime = Config.TimeSettings.SyncWithRealTime,
    fastForward = { active = false, targetHour = nil, targetMinute = nil, freezeOnComplete = false }, --smoothi
    weatherChangeTimer = Config.WeatherSettings.WeatherChangeInterval * 60,

    hypothermiaEnabled = Config.SurvivalSettings.HypothermiaEnabled,
    preFloodHypothermia = nil,

    activeEvent = 'none',
    eventLocked = false,
    eventLockReason = nil, --syy ui
    eventStartedAt = 0,
    eventElapsedMs = 0, --synkronointi

    -- eventit
    eventOptions = {
        fogDensity = 0.5, --sumu
        halloween = { storm = true },
        heavyfog = { canStop = false },
        earthquakePhase = 'none', --none, warning, active
        earthquake = { sirens = true, warning = true, intensity = 0.5 }, 
        blizzard = { intensity = 0.5, addSnow = true, keepSnow = true, manualSnowOverride = false, snowRampToken = 0, removeSnowOnStop = false, canStop = false } --lumyrskyvamma
    },

    floodActive = false,
    targetFloodLevel = 0.0,
    floodStorm = true, --ukkonen tulvan aikana
    floodTimerActive = false,
    floodTimerMinutes = 0,
    sirensActive = false, --atm
    sirensWillActivate = true, --sit ku alkaa
    floodWarningEnabled = true,
    floodRiseRate = 5.0,
    isWaterDropping = false,
    currentFloodLevel = 0.0,
    currentActualFloodLevel = 0.0,
    floodTransition = { fromLevel = 0.0, targetLevel = 0.0, startedAt = 0, rate = 5.0 },

    startupWeather = Config.WeatherSettings.StartupWeather or 'CLEAR', --ui
    normalWeatherTypes = Config.WeatherSettings.NormalWeatherTypes,
    winterType = Config.WeatherSettings.SnowWeatherType or 'SNOWLIGHT'
}

WeatherState.originalStartupWeather = Config.WeatherSettings.StartupWeather or 'CLEAR'
local function initSnowState()
    local startupW = WeatherState.originalStartupWeather --configin
    if startupW == 'SNOW' or startupW == 'SNOWLIGHT' or startupW == 'BLIZZARD' then
        WeatherState.weatherCycle = 'winter' --talvitila
        WeatherState.startupWeather = startupW --client
    else
        WeatherState.startupWeather = startupW
    end
end
initSnowState()

local ResourceName = GetCurrentResourceName()

local AllowedSpecialEvents = {
    halloween = true,
    heavyfog = true,
    earthquake = true,
    blizzard = true
}

local pendingFloodLevel = 0.0
local eventLockUntil = 0
local eventLockReason = nil
local eventLockToken = 0

local function serverNowMs() --ms
    if type(GetGameTimer) == 'function' then
        return GetGameTimer()
    end

    return os.time() * 1000 --back
end

local function clamp(value, minValue, maxValue)
    value = tonumber(value) or minValue
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value --vanha
end

local function toBool(value) --boolean
    return value == true or value == 'true'
end

-- tulvan taso
local function updateServerFloodLevel()
    local now = serverNowMs() --ms nyt
    local transition = WeatherState.floodTransition or {}
    local fromLevel = tonumber(transition.fromLevel) or 0.0
    local targetLevel = tonumber(transition.targetLevel) or tonumber(WeatherState.targetFloodLevel) or 0.0 --target
    local rate = clamp(transition.rate or WeatherState.floodRiseRate, 0.1, 20.0)
    local startedAt = tonumber(transition.startedAt) or now
    local distance = math.abs(targetLevel - fromLevel) --metrit

    if distance <= 0.001 then
        WeatherState.currentFloodLevel = targetLevel
    else
        local elapsedSeconds = math.max(0.0, (now - startedAt) / 1000.0) --aika kulunut
        local movedMeters = elapsedSeconds / rate --metrit siltä ajalta

        if movedMeters >= distance then
            WeatherState.currentFloodLevel = targetLevel
        elseif targetLevel > fromLevel then
            WeatherState.currentFloodLevel = fromLevel + movedMeters --nousu.
        else
            WeatherState.currentFloodLevel = fromLevel - movedMeters --lasku
        end
    end

    WeatherState.currentActualFloodLevel = WeatherState.currentFloodLevel
end

local function prepareStateForSync()
    updateServerFloodLevel() --tulvan korkeus
    if WeatherState.activeEvent ~= 'none' and WeatherState.eventStartedAt > 0 then
        WeatherState.eventElapsedMs = math.max(0, serverNowMs() - WeatherState.eventStartedAt) --eventin aika
    else
        WeatherState.eventElapsedMs = 0 --ei eventtiä
    end
end

-- täysi synkka
local function syncState(target)
    prepareStateForSync() --state valmiiksi
    TriggerClientEvent('weather:syncState', target or -1, WeatherState) --kaikille tai yhdelle
end

local function startFloodTransition(targetLevel, rate)
    updateServerFloodLevel() --nykyinen taso
    rate = clamp(rate or WeatherState.floodRiseRate, 0.1, 20.0) --nousunopeus
    targetLevel = math.max(0.0, tonumber(targetLevel) or 0.0) --ei miinusta

    WeatherState.floodRiseRate = rate --nopeus
    WeatherState.targetFloodLevel = targetLevel --target
    WeatherState.floodTransition = {
        fromLevel = WeatherState.currentFloodLevel or 0.0, --lähtötaso
        targetLevel = targetLevel, --lopputaso
        startedAt = serverNowMs(), --alkuaika
        rate = rate --nopeus
    }
end

local function resetFloodTransition()
    WeatherState.currentFloodLevel = 0.0 --vesi nollaan
    WeatherState.currentActualFloodLevel = 0.0 --ui nollaan
    WeatherState.targetFloodLevel = 0.0 --target nollaan
    WeatherState.floodTransition = {
        fromLevel = 0.0, --kuiva alku
        targetLevel = 0.0, --kuiva target
        startedAt = serverNowMs(), --uusi aika
        rate = WeatherState.floodRiseRate or 5.0 --viime nopeus
    }
end

local function isEventLockActive()
    return eventLockUntil > serverNowMs()
end

local function setEventLock(reason, durationMs)
    eventLockReason = reason
    eventLockUntil = serverNowMs() + (durationMs or 60000)
    eventLockToken = eventLockToken + 1
    local token = eventLockToken
    WeatherState.eventLocked = true
    WeatherState.eventLockReason = reason

    CreateThread(function()
        Wait((durationMs or 60000) + 250)
        if eventLockToken == token and eventLockReason == reason and not isEventLockActive() then
            eventLockUntil = 0
            eventLockReason = nil
            eventLockToken = eventLockToken + 1
            WeatherState.eventLocked = false
            WeatherState.eventLockReason = nil
            if reason == 'heavyfog_cleanup' then
                WeatherState.weatherFrozen = false
                WeatherState.weatherCycle = 'normal'
                WeatherState.currentWeather = 'CLEARING'
                TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
                TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen)
            end
            syncState()
        end
    end)
end

local function clearEventLock(reason)
    if reason and eventLockReason ~= reason then return end
    eventLockUntil = 0
    eventLockReason = nil
    eventLockToken = eventLockToken + 1
    WeatherState.eventLocked = false
    WeatherState.eventLockReason = nil
end

local function getWinterWeatherType()
    return Config.WeatherSettings.SnowWeatherType or 'SNOWLIGHT'
end

local function validateNormalWeatherTypes()
    local weatherTypes = Config.WeatherSettings.NormalWeatherTypes or {}
    local totalChance = 0

    for index, weather in ipairs(weatherTypes) do
        local chance = tonumber(weather.chance) or 0
        totalChance = totalChance + chance

        if chance < 0 then
            print(('[%s] VAROITUS: NormalWeatherTypes[%d] (%s) sisältää negatiivisen painon (%s).'):format(ResourceName, index, tostring(weather.type), tostring(weather.chance)))
        end
    end

    if #weatherTypes == 0 then
        print(('[%s] VAROITUS: NormalWeatherTypes on tyhjä, joten käytetään CLEAR-säätä.'):format(ResourceName))
        return
    end

    if totalChance <= 0 then
        print(('[%s] VAROITUS: NormalWeatherTypes-painojen summa on %s, joten käytetään CLEAR-säätä.'):format(ResourceName, tostring(totalChance)))
        return
    end

end

local function resetWeatherChangeTimer()
    WeatherState.weatherChangeTimer = Config.WeatherSettings.WeatherChangeInterval * 60
end

local function broadcastWeatherTimer(target)
    TriggerClientEvent('weather:updateWeatherTimer', target or -1, WeatherState.weatherChangeTimer)
end

local function getFinlandTimezoneOffset()
    local month = os.date('*t').month
    local day = os.date('*t').day
    if month >= 4 and month <= 9 then return 3
    elseif month == 10 then return 3
    elseif month == 3 then return (day >= 25) and 3 or 2
    else return 2 end
end

local function getRealTimeHour()
    local offset = Config.TimeSettings.UseFinlandTimezone and getFinlandTimezoneOffset() or Config.TimeSettings.ManualTimezoneOffset
    local utcHour = tonumber(os.date('!%H'))
    local utcMin = tonumber(os.date('!%M'))
    return (utcHour + offset) % 24, utcMin
end

local function isAdmin(source)
    -- identifierit
    local identifiers = GetPlayerIdentifiers(source)
    for _, identifier in ipairs(identifiers) do
        for _, permission in ipairs(Config.AdminPermissions) do
            -- suora identifier
            if string.match(permission, '^[a-zA-Z]+:') then
                if identifier == permission then
                    return true
                end
            else
                -- ace permission
                if IsPlayerAceAllowed(source, permission) then
                    return true
                end
            end
        end
    end

    -- ace ryhmä
    if Config.AdminAceGroup and IsPlayerAceAllowed(source, Config.AdminAceGroup) then
        return true
    end

    return false
end

-- ============================================
-- sää ja aika
-- ============================================

local function updateRainBasedOnState()
    local w = WeatherState.currentWeather

    if w == 'RAIN' or w == 'THUNDER' or w == 'CLEARING' then
        WeatherState.rainLevel = math.random(1, 100) / 100.0
    elseif w == 'RAIN_HALLOWEEN' then
        WeatherState.rainLevel = math.random(50, 100) / 100.0
    elseif w == 'HALLOWEEN' then
        WeatherState.rainLevel = 0.0
    elseif w == 'NEUTRAL' then
        WeatherState.rainLevel = 0.0
    else
        WeatherState.rainLevel = 0.0
    end

    if WeatherState.activeEvent == 'halloween' and WeatherState.currentWeather == 'RAIN_HALLOWEEN' then
        WeatherState.rainLevel = math.random(50, 100) / 100.0
    end

    if WeatherState.activeEvent == 'flood' or WeatherState.isWaterDropping then
        if WeatherState.floodStorm then
            WeatherState.rainLevel = 1.0
        elseif WeatherState.currentWeather == 'CLEARING' then
            WeatherState.rainLevel = math.random(1, 100) / 100.0
        end
    end

    TriggerClientEvent('weather:updateRainLevel', -1, WeatherState.rainLevel)
end

local function advanceWeather()
    resetWeatherChangeTimer()
    broadcastWeatherTimer()
    if WeatherState.weatherFrozen or WeatherState.activeEvent == 'halloween' then return end

    if WeatherState.weatherCycle == 'winter' then
        if WeatherState.currentWeather ~= getWinterWeatherType() then
            WeatherState.currentWeather = getWinterWeatherType()
            updateRainBasedOnState()
            TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
            syncState()
        end
        return
    end

    -- sääarvonta
    local weatherTypes = Config.WeatherSettings.NormalWeatherTypes
    local totalWeight = 0
    for _, w in ipairs(weatherTypes) do
        totalWeight = totalWeight + w.chance
    end

    if totalWeight <= 0 then
        WeatherState.currentWeather = 'CLEAR'
        updateRainBasedOnState()
        TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
        syncState()
        return
    end

    local roll = math.random(1, totalWeight)
    local currentWeight = 0
    local selectedWeather = 'CLEAR'

    for _, w in ipairs(weatherTypes) do
        currentWeight = currentWeight + w.chance
        if roll <= currentWeight then
            selectedWeather = w.type
            break
        end
    end

    WeatherState.currentWeather = selectedWeather
    updateRainBasedOnState()
    TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
    syncState()
end

validateNormalWeatherTypes()

local function advanceTime()
    if WeatherState.timeFrozen then return end
    if WeatherState.activeEvent == 'halloween' then return end
    if WeatherState.fastForward.active then return end

    if WeatherState.syncWithRealTime then
        local realHour, realMin = getRealTimeHour()
        WeatherState.currentHour = realHour
        WeatherState.currentMinute = realMin
        TriggerClientEvent('weather:updateTime', -1, WeatherState.currentHour, WeatherState.currentMinute)
        return
    end

    WeatherState.currentMinute = WeatherState.currentMinute + 1
    if WeatherState.currentMinute >= 60 then
        WeatherState.currentMinute = 0
        WeatherState.currentHour = WeatherState.currentHour + 1
        if WeatherState.currentHour >= 24 then WeatherState.currentHour = 0 end
    end
    TriggerClientEvent('weather:updateTime', -1, WeatherState.currentHour, WeatherState.currentMinute)
end

local function startFastForward(targetHour, targetMinute, freezeOnComplete)
    WeatherState.fastForward.active = true
    WeatherState.fastForward.targetHour = targetHour
    WeatherState.fastForward.targetMinute = targetMinute
    WeatherState.fastForward.freezeOnComplete = freezeOnComplete or false
    WeatherState.timeFrozen = false
end

-- ============================================
-- eventit
-- ============================================

RegisterNetEvent('weather:startSpecialEvent')
AddEventHandler('weather:startSpecialEvent', function(eventName, options)
    if not isAdmin(source) then return end --vain admin
    if not AllowedSpecialEvents[eventName] then
        syncState(source) --väärä eventti
        return --stop
    end

    if WeatherState.eventLocked and not isEventLockActive() then
        clearEventLock() --lukko pois
    end
    if WeatherState.activeEvent ~= 'none' or WeatherState.floodActive or WeatherState.floodTimerActive or WeatherState.isWaterDropping or isEventLockActive() then
        syncState(source) --ui takaisin
        return --ei ristiin
    end

    WeatherState.activeEvent = eventName --eventti
    WeatherState.eventStartedAt = serverNowMs() --aloitusaika
    WeatherState.fastForward.active = false --ff pois
    WeatherState.fastForward.targetHour = nil --tunti pois
    WeatherState.fastForward.targetMinute = nil --minuutti pois
    WeatherState.weatherCycle = 'normal' --normisykli
    TriggerClientEvent('weather:updateWeatherCycle', -1, 'normal') --ui sykli

    if eventName == 'halloween' then
        WeatherState.syncWithRealTime = false --realiaika pois
        TriggerClientEvent('weather:updateSync', -1, false) --ui sync

        WeatherState.eventOptions.halloween.storm = not options or options.storm ~= false --myrskyvalinta
        WeatherState.currentWeather = WeatherState.eventOptions.halloween.storm and 'RAIN_HALLOWEEN' or 'HALLOWEEN' --halloween sää

        WeatherState.weatherFrozen = true --sää lukkoon
        updateRainBasedOnState() --sade
        TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather) --sää kaikille
        startFastForward(0, 0, true) --yöhön

    elseif eventName == 'heavyfog' then
        local density = options and tonumber(options.density) or 0.5 --sumun tiheys
        WeatherState.eventOptions.fogDensity = math.max(0.1, math.min(1.0, density)) --rajaus
        WeatherState.eventOptions.heavyfog.canStop = false --stop lukossa
        WeatherState.currentWeather = 'RAIN' --taustasää
        WeatherState.weatherFrozen = true --sää lukkoon
        WeatherState.rainLevel = 0.0 --ei sadetta
        updateRainBasedOnState() --sade
        TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather) --sää kaikille
        TriggerClientEvent('weather:updateRainLevel', -1, WeatherState.rainLevel) --sade kaikille
        TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen) --ui mode

    elseif eventName == 'earthquake' then
        WeatherState.eventOptions.earthquakePhase = 'warning' --varoitus
        WeatherState.eventOptions.earthquake.intensity = clamp(options and options.intensity or 0.5, 0.1, 1.0) --voima
        WeatherState.eventOptions.earthquake.sirens = not options or options.sirens ~= false --sireenit
        WeatherState.eventOptions.earthquake.warning = not options or options.warning ~= false --tiedote

        if WeatherState.eventOptions.earthquake.sirens then
            WeatherState.sirensActive = true --sireenit päälle
            TriggerClientEvent('weather:toggleSirens', -1, true) --sireenit kaikille
        end

        if WeatherState.eventOptions.earthquake.warning then
            TriggerClientEvent('txcl:showAnnouncement', -1, "Äärimmäisen voimakas maanjäristys iskee alueelle. Pysykää poissa rakennusten lähettyviltä.", "VAARATIEDOTE") --tiedote
        end

        CreateThread(function()
            Wait(10000) --varoitusaika
            if WeatherState.activeEvent == 'earthquake' then
                WeatherState.eventOptions.earthquakePhase = 'active' --aktiivinen
                syncState() --vaihe kaikille
            end
        end)

    elseif eventName == 'blizzard' then
        local intensity = options and tonumber(options.intensity) or 0.5
        WeatherState.eventOptions.blizzard.intensity = math.max(0.1, math.min(1.0, intensity))
        WeatherState.eventOptions.blizzard.addSnow = (not options) or options.addSnow == true
        WeatherState.eventOptions.blizzard.keepSnow = (not options) or options.keepSnow ~= false
        WeatherState.eventOptions.blizzard.manualSnowOverride = false
        WeatherState.eventOptions.blizzard.removeSnowOnStop = false
        WeatherState.eventOptions.blizzard.canStop = false
        if WeatherState.eventOptions.blizzard.addSnow and not WeatherState.snowOnGround then
            WeatherState.snowOnGround = false
            WeatherState.eventOptions.blizzard.snowRampToken = (WeatherState.eventOptions.blizzard.snowRampToken or 0) + 1
        end

        WeatherState.currentWeather = 'BLIZZARD'
        WeatherState.rainLevel = 0.0
        WeatherState.weatherFrozen = true

        updateRainBasedOnState()
        TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
        TriggerClientEvent('weather:updateRainLevel', -1, WeatherState.rainLevel)
        TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen)
    end

    TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen) --mode kaikille
    syncState() --täysi state
end)

RegisterNetEvent('weather:stopSpecialEvent')
AddEventHandler('weather:stopSpecialEvent', function()
    if not isAdmin(source) then return end

    local previousEvent = WeatherState.activeEvent
    local previousStartedAt = WeatherState.eventStartedAt
    WeatherState.activeEvent = 'none'
    WeatherState.eventStartedAt = 0
    WeatherState.eventElapsedMs = 0
    WeatherState.weatherFrozen = false
    WeatherState.timeFrozen = false
    WeatherState.fastForward.active = false
    WeatherState.fastForward.freezeOnComplete = false

    if previousEvent == 'earthquake' then
        WeatherState.eventOptions.earthquakePhase = 'none'
        WeatherState.sirensActive = false
        TriggerClientEvent('weather:toggleSirens', -1, false)
    elseif previousEvent == 'halloween' then
        WeatherState.currentWeather = 'CLEARING'
    elseif previousEvent == 'heavyfog' then
        if not WeatherState.eventOptions.heavyfog.canStop then
            WeatherState.activeEvent = previousEvent
            WeatherState.eventStartedAt = previousStartedAt
            WeatherState.weatherFrozen = true
            syncState()
            return
        end

        WeatherState.weatherFrozen = true
        WeatherState.currentWeather = 'RAIN'
        WeatherState.rainLevel = 0.0
        setEventLock('heavyfog_cleanup', 52000)
    elseif previousEvent == 'blizzard' then
        if not WeatherState.eventOptions.blizzard.canStop then
            WeatherState.activeEvent = previousEvent
            WeatherState.eventStartedAt = previousStartedAt
            WeatherState.weatherFrozen = true
            syncState()
            return
        end

        WeatherState.weatherFrozen = false
        WeatherState.weatherCycle = 'winter'
        WeatherState.currentWeather = 'BLIZZARD'
        WeatherState.eventOptions.blizzard.removeSnowOnStop =
            WeatherState.eventOptions.blizzard.addSnow
            and WeatherState.eventOptions.blizzard.keepSnow == false
            and WeatherState.snowOnGround
        setEventLock('blizzard_cleanup', 90000)
    end

    updateRainBasedOnState()

    TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
    TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen)
    syncState()
end)

RegisterNetEvent('weather:updateEventOption')
AddEventHandler('weather:updateEventOption', function(eventName, option, value)
    if not isAdmin(source) then return end
    if type(eventName) ~= 'string' or type(option) ~= 'string' then return end

    if not WeatherState.eventOptions[eventName] then WeatherState.eventOptions[eventName] = {} end
    if eventName == 'heavyfog' and option == 'density' then
        value = clamp(value, 0.1, 1.0)
        WeatherState.eventOptions.fogDensity = value
        if WeatherState.activeEvent == 'heavyfog' then
            WeatherState.eventOptions.heavyfog.canStop = false
        end
    elseif eventName == 'flood' and option == 'riseRate' then
        WeatherState.floodRiseRate = clamp(value, 0.1, 20.0)
        if WeatherState.floodActive or WeatherState.isWaterDropping then
            startFloodTransition(WeatherState.targetFloodLevel, WeatherState.floodRiseRate)
        end
    else
        WeatherState.eventOptions[eventName][option] = value
    end

    if WeatherState.activeEvent == eventName and option == 'sirens' then
        WeatherState.sirensActive = toBool(value)
        TriggerClientEvent('weather:toggleSirens', -1, WeatherState.sirensActive)
    end

    if eventName == 'halloween' and option == 'storm' then
        WeatherState.eventOptions.halloween.storm = toBool(value)
        if WeatherState.activeEvent == 'halloween' then
            WeatherState.currentWeather = WeatherState.eventOptions.halloween.storm and 'RAIN_HALLOWEEN' or 'HALLOWEEN'
            updateRainBasedOnState()
            TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
        end
    end

    if eventName == 'blizzard' then
        if option == 'intensity' then
            WeatherState.eventOptions.blizzard.intensity = clamp(value, 0.1, 1.0)
            if WeatherState.activeEvent == 'blizzard' then
                WeatherState.eventOptions.blizzard.canStop = false
            end
        elseif option == 'addSnow' then
            WeatherState.eventOptions.blizzard.addSnow = toBool(value)
            WeatherState.eventOptions.blizzard.manualSnowOverride = false
            if WeatherState.activeEvent == 'blizzard' then
                WeatherState.eventOptions.blizzard.canStop = false
                if WeatherState.eventOptions.blizzard.addSnow and not WeatherState.snowOnGround then
                    WeatherState.snowOnGround = false
                    WeatherState.eventOptions.blizzard.snowRampToken = (WeatherState.eventOptions.blizzard.snowRampToken or 0) + 1
                elseif not WeatherState.eventOptions.blizzard.addSnow then
                    WeatherState.snowOnGround = false
                    TriggerClientEvent('weather:updateSnow', -1, false)
                end
            end
        elseif option == 'keepSnow' then
            WeatherState.eventOptions.blizzard.keepSnow = toBool(value)
        end
    end

    syncState()
end)

RegisterNetEvent('weather:blizzardSnowReady')
AddEventHandler('weather:blizzardSnowReady', function()
    local options = WeatherState.eventOptions.blizzard
    if WeatherState.activeEvent ~= 'blizzard' then return end
    if not options.addSnow or options.manualSnowOverride then return end
    if WeatherState.snowOnGround then return end

    WeatherState.snowOnGround = true
    options.canStop = false
    TriggerClientEvent('weather:updateSnow', -1, true)
    syncState()
end)

RegisterNetEvent('weather:blizzardStable')
AddEventHandler('weather:blizzardStable', function()
    if WeatherState.activeEvent ~= 'blizzard' then return end

    local options = WeatherState.eventOptions.blizzard
    if options.addSnow and not options.manualSnowOverride and not WeatherState.snowOnGround then return end

    options.canStop = true
    syncState()
end)

RegisterNetEvent('weather:blizzardCleanupDone')
AddEventHandler('weather:blizzardCleanupDone', function()
    if WeatherState.activeEvent ~= 'none' then return end
    if WeatherState.currentWeather ~= 'BLIZZARD' then return end

    WeatherState.currentWeather = getWinterWeatherType()
    WeatherState.eventOptions.blizzard.removeSnowOnStop = false
    clearEventLock('blizzard_cleanup')
    updateRainBasedOnState()
    TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
    syncState()
end)

RegisterNetEvent('weather:fogCleanupDone')
AddEventHandler('weather:fogCleanupDone', function()
    if WeatherState.activeEvent ~= 'none' then return end
    WeatherState.weatherFrozen = false
    WeatherState.weatherCycle = 'normal'
    WeatherState.currentWeather = 'CLEARING'
    clearEventLock('heavyfog_cleanup')
    updateRainBasedOnState()
    TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
    TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen)
    syncState()
end)

RegisterNetEvent('weather:fogStable')
AddEventHandler('weather:fogStable', function()
    if WeatherState.activeEvent ~= 'heavyfog' then return end
    WeatherState.eventOptions.heavyfog.canStop = true
    syncState()
end)

RegisterNetEvent('weather:blizzardRemoveSnowNow')
AddEventHandler('weather:blizzardRemoveSnowNow', function()
    local options = WeatherState.eventOptions.blizzard
    if WeatherState.activeEvent ~= 'none' then return end
    if WeatherState.currentWeather ~= 'BLIZZARD' then return end
    if not options.removeSnowOnStop then return end

    WeatherState.snowOnGround = false
    TriggerClientEvent('weather:updateSnow', -1, false)
    syncState()
end)

-- ============================================
-- hypotermia ja tulva
-- ============================================

RegisterNetEvent('weather:toggleHypothermia')
AddEventHandler('weather:toggleHypothermia', function(enabled)
    if not isAdmin(source) then return end
    WeatherState.hypothermiaEnabled = toBool(enabled)
    syncState()
end)

RegisterNetEvent('weather:toggleFloodOption')
AddEventHandler('weather:toggleFloodOption', function(option, state, riseRate)
    if not isAdmin(source) then return end
    if tonumber(riseRate) then
        WeatherState.floodRiseRate = clamp(riseRate, 0.1, 20.0)
        if WeatherState.floodActive or WeatherState.isWaterDropping then
            startFloodTransition(WeatherState.targetFloodLevel, WeatherState.floodRiseRate)
        end
    end

    state = toBool(state)

    if option == 'storm' then
        WeatherState.floodStorm = state
        if WeatherState.activeEvent == 'flood' or WeatherState.isWaterDropping then
            if state then
                WeatherState.currentWeather = 'THUNDER'
                WeatherState.weatherFrozen = true
            else
                WeatherState.currentWeather = 'CLEARING'
                WeatherState.weatherCycle = 'normal'
                WeatherState.weatherFrozen = false
                WeatherState.rainLevel = math.random(1, 100) / 100.0
            end
            updateRainBasedOnState()
            TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
        end
    elseif option == 'sirens' then
        WeatherState.sirensWillActivate = state
        if WeatherState.activeEvent == 'flood' and WeatherState.floodActive == true and WeatherState.isWaterDropping == false then
            WeatherState.sirensActive = state
            TriggerClientEvent('weather:toggleSirens', -1, state)
        else
            WeatherState.sirensActive = false
            TriggerClientEvent('weather:toggleSirens', -1, false)
        end
    elseif option == 'warning' then
        WeatherState.floodWarningEnabled = state
    end

    syncState()
end)

RegisterNetEvent('weather:setFloodAction')
AddEventHandler('weather:setFloodAction', function(action, targetHeight, stormEnabled, sirensEnabled, warningEnabled, riseRate)
    if not isAdmin(source) then return end --vain admin
    if WeatherState.eventLocked and not isEventLockActive() then
        clearEventLock() --lukko pois
    end

    if action == 'start_now' or action == 'start_15min' then
        if WeatherState.activeEvent ~= 'none' or WeatherState.floodActive or WeatherState.floodTimerActive or WeatherState.isWaterDropping or isEventLockActive() then
            syncState(source) --ui takaisin
            return --ei ristiin
        end
    end

    WeatherState.floodWarningEnabled = toBool(warningEnabled) --tiedote

    local rateNum = clamp(riseRate, 0.1, 20.0) --nopeus
    WeatherState.floodRiseRate = rateNum --nopeus stateen
    stormEnabled = toBool(stormEnabled) --myrsky bool
    sirensEnabled = toBool(sirensEnabled) --sireeni bool

    if action == 'start_now' then
        WeatherState.preFloodHypothermia = WeatherState.preFloodHypothermia or WeatherState.hypothermiaEnabled --hypo talteen
        WeatherState.hypothermiaEnabled = false --hypo pois

        WeatherState.activeEvent = 'flood' --tulva eventti
        WeatherState.eventStartedAt = serverNowMs() --aloitusaika
        WeatherState.floodTimerActive = false --ei timeria
        WeatherState.floodActive = true --tulva päälle
        WeatherState.floodStorm = stormEnabled --myrsky
        WeatherState.sirensWillActivate = sirensEnabled --sireenit myöhemmin
        WeatherState.isWaterDropping = false --ei laskua
        startFloodTransition(math.floor(clamp(targetHeight, 1, 100)) + 0.0, rateNum) --nousu

        if stormEnabled then
            WeatherState.currentWeather = 'THUNDER' --ukkonen
            WeatherState.weatherFrozen = true --sää lukkoon
            updateRainBasedOnState() --sade
            TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather) --sää kaikille
            TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen) --ui mode
        else
            WeatherState.weatherCycle = 'normal' --normisykli
            WeatherState.weatherFrozen = false --ei lukkoa
        end

        if sirensEnabled then
            WeatherState.sirensActive = true --sireenit soi
            TriggerClientEvent('weather:toggleSirens', -1, true) --sireenit kaikille
        end

        syncState() --state kaikille

        if WeatherState.floodWarningEnabled then
            TriggerClientEvent('txcl:showAnnouncement', -1, "Meriveden korkeus nousee vaarallisen korkealle. Kaupungin asukkaita kehotetaan hakeutumaan korkealle paikalle välittömästi.", "VAARATIEDOTE") --tiedote
        end

    elseif action == 'start_15min' then
        WeatherState.activeEvent = 'flood' --tulva varaus
        WeatherState.eventStartedAt = serverNowMs() --timer alku
        pendingFloodLevel = math.floor(clamp(targetHeight, 1, 100)) + 0.0 --tuleva korkeus
        startFloodTransition(0.0, rateNum) --kuiva timer
        WeatherState.floodTimerActive = true --timer päälle
        WeatherState.floodTimerMinutes = 15 --15min
        WeatherState.floodStorm = stormEnabled --myrsky
        WeatherState.sirensWillActivate = sirensEnabled --sireenit alussa
        WeatherState.isWaterDropping = false --ei laskua

        if stormEnabled then
            WeatherState.currentWeather = 'THUNDER'
            WeatherState.weatherFrozen = true
            updateRainBasedOnState()
            TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
            TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen)
        else
            WeatherState.weatherCycle = 'normal'
            WeatherState.weatherFrozen = false
        end

        syncState()

        if WeatherState.floodWarningEnabled then
            TriggerClientEvent('txcl:showAnnouncement', -1, "Meriveden korkeus nousee vaarallisen korkealle. Kaupungin asukkaita kehotetaan hakeutumaan korkealle paikalle.", "VAARATIEDOTE")
        end

    elseif action == 'stop' then
        WeatherState.floodTimerActive = false --timer pois
        WeatherState.isWaterDropping = true --vesi laskee
        startFloodTransition(0.0, rateNum) --lasku

        WeatherState.sirensActive = false --sireenit pois
        TriggerClientEvent('weather:toggleSirens', -1, false) --sireenit kaikilta

        if WeatherState.floodStorm then
            WeatherState.currentWeather = 'CLEARING' --selkenee
            WeatherState.weatherCycle = 'normal' --normisykli
            WeatherState.rainLevel = math.random(1, 100) / 100.0 --jälkisade
            WeatherState.weatherFrozen = false --sää vapaaksi
        end

        updateRainBasedOnState() --sade
        TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather) --sää kaikille
        TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen) --ui mode
        syncState() --state kaikille
    elseif action == 'heavyfog_stop' then
        WeatherState.activeEvent = 'none'
        WeatherState.weatherFrozen = false

        updateRainBasedOnState()
        TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen)
        syncState()

    elseif action == 'reset' then
        local wasStorm = WeatherState.floodStorm --myrsky talteen

        WeatherState.floodTimerActive = false --timer pois
        WeatherState.floodActive = false --tulva pois
        WeatherState.activeEvent = 'none' --eventti pois
        WeatherState.eventStartedAt = 0 --alku nollaan
        WeatherState.eventElapsedMs = 0 --aika nollaan
        WeatherState.isWaterDropping = false --lasku pois
        resetFloodTransition() --vesi nollaan

        if WeatherState.preFloodHypothermia ~= nil then
            WeatherState.hypothermiaEnabled = WeatherState.preFloodHypothermia --hypo takaisin
            WeatherState.preFloodHypothermia = nil --muisti tyhjäksi
        end

        WeatherState.sirensActive = false --sireenit pois
        TriggerClientEvent('weather:toggleSirens', -1, false) --sireenit kaikilta

        if wasStorm then
            WeatherState.currentWeather = 'CLEARING' --selkenee
            WeatherState.weatherCycle = 'normal' --normisykli
            WeatherState.rainLevel = math.random(1, 100) / 100.0 --jälkisade
            WeatherState.weatherFrozen = false --sää vapaaksi
        else
            WeatherState.weatherFrozen = false --lukko pois
        end

        TriggerClientEvent('weather:resetWater', -1) --vesi nollaan

        updateRainBasedOnState() --sade
        TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather) --sää kaikille
        syncState() --puhdas state
    end
end)

RegisterNetEvent('weather:floodEnded')
AddEventHandler('weather:floodEnded', function()
    updateServerFloodLevel()
    if (WeatherState.activeEvent == 'flood' or WeatherState.isWaterDropping)
        and WeatherState.targetFloodLevel == 0.0
        and (WeatherState.currentFloodLevel or 0.0) <= 0.05 then
        local wasStorm = WeatherState.floodStorm

        WeatherState.floodActive = false
        WeatherState.activeEvent = 'none'
        WeatherState.eventStartedAt = 0
        WeatherState.eventElapsedMs = 0
        WeatherState.isWaterDropping = false
        resetFloodTransition()

        if WeatherState.preFloodHypothermia ~= nil then
            WeatherState.hypothermiaEnabled = WeatherState.preFloodHypothermia
            WeatherState.preFloodHypothermia = nil
        end

        if wasStorm then
            WeatherState.currentWeather = 'CLEARING'
            WeatherState.weatherCycle = 'normal'
            WeatherState.rainLevel = math.random(1, 100) / 100.0
            WeatherState.weatherFrozen = false
        else
            WeatherState.weatherFrozen = false
        end

        updateRainBasedOnState()
        TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
        syncState()
    end
end)

-- ============================================
-- ajastimet
-- ============================================

CreateThread(function()
    while true do
        Wait(1000)
        local normalWeatherAllowed = WeatherState.activeEvent == 'none'
            or WeatherState.activeEvent == 'heavyfog'
            or (WeatherState.activeEvent == 'flood' and not WeatherState.floodStorm)

        if WeatherState.weatherChangeTimer > 0 and not WeatherState.weatherFrozen and normalWeatherAllowed and WeatherState.weatherCycle == 'normal' then
            WeatherState.weatherChangeTimer = WeatherState.weatherChangeTimer - 1
            broadcastWeatherTimer()
            if WeatherState.weatherChangeTimer <= 0 then
                advanceWeather()
            end
        end
    end
end)

CreateThread(function()
    local tick = 0
    while true do
        Wait(50)

        if WeatherState.fastForward.active then
            local current = WeatherState.currentHour * 60 + WeatherState.currentMinute
            local target = WeatherState.fastForward.targetHour * 60 + WeatherState.fastForward.targetMinute
            local diff = target - current

            if diff > 720 then diff = diff - 1440
            elseif diff < -720 then diff = diff + 1440 end

            if diff ~= 0 then
                local step = 5
                if math.abs(diff) < step then step = math.abs(diff) end
                if diff < 0 then step = -step end

                WeatherState.currentMinute = WeatherState.currentMinute + step

                if WeatherState.currentMinute >= 60 then
                    WeatherState.currentHour = WeatherState.currentHour + math.floor(WeatherState.currentMinute / 60)
                    WeatherState.currentMinute = WeatherState.currentMinute % 60
                elseif WeatherState.currentMinute < 0 then
                    local subtractHours = math.ceil(math.abs(WeatherState.currentMinute) / 60)
                    WeatherState.currentHour = WeatherState.currentHour - subtractHours
                    WeatherState.currentMinute = WeatherState.currentMinute + (subtractHours * 60)
                end
                WeatherState.currentHour = WeatherState.currentHour % 24
                TriggerClientEvent('weather:updateTime', -1, WeatherState.currentHour, WeatherState.currentMinute)
            end

            if diff == 0 then
                WeatherState.fastForward.active = false
                if not WeatherState.syncWithRealTime then
                    WeatherState.timeFrozen = WeatherState.fastForward.freezeOnComplete
                end
                TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen)
            end
        else
            tick = tick + 50
            local interval = math.floor(Config.TimeSettings.DayLengthInMinutes * 60 * 1000 / 1440)
            if tick >= interval then
                tick = 0
                advanceTime()
            end
        end
    end
end)

-- tulva 15min
CreateThread(function()
    while true do
        Wait(60000)

        if WeatherState.floodTimerActive then
            WeatherState.floodTimerMinutes = WeatherState.floodTimerMinutes - 1
            syncState()

            if WeatherState.floodTimerMinutes == 5 then
                if WeatherState.floodWarningEnabled then
                    TriggerClientEvent('txcl:showAnnouncement', -1, "Meriveden korkeus nousee vaarallisen korkealle. Hakeudu korkealle paikalle!", "VAARATIEDOTE")
                end
            elseif WeatherState.floodTimerMinutes <= 0 then
                if WeatherState.sirensWillActivate then
                    WeatherState.sirensActive = true
                    TriggerClientEvent('weather:toggleSirens', -1, true)
                end
                if WeatherState.floodWarningEnabled then
                    TriggerClientEvent('txcl:showAnnouncement', -1, "Meriveden korkeus nousee vaarallisen korkealle. Hakeudu korkealle paikalle välittömästi!", "VAARATIEDOTE")
                end

                WeatherState.preFloodHypothermia = WeatherState.preFloodHypothermia or WeatherState.hypothermiaEnabled
                WeatherState.hypothermiaEnabled = false
                WeatherState.floodTimerActive = false
                WeatherState.floodActive = true
                WeatherState.eventStartedAt = serverNowMs()
                startFloodTransition(pendingFloodLevel, WeatherState.floodRiseRate)
                syncState()
            end
        end
    end
end)

CreateThread(function()
    while true do
        local dynamicFlood = WeatherState.floodActive or WeatherState.isWaterDropping or WeatherState.floodTimerActive
        Wait((dynamicFlood or WeatherState.eventLocked) and 1000 or 30000)

        if WeatherState.eventLocked and not isEventLockActive() then
            clearEventLock()
        end
        syncState()
    end
end)

-- ============================================
-- komennot + synkron
-- ============================================
RegisterCommand(Config.CommandName, function(source)
    if not isAdmin(source) then
        return
    end
    prepareStateForSync()
    TriggerClientEvent('weather:openPanel', source, WeatherState)
end)

RegisterNetEvent('weather:setWeatherCycle')
AddEventHandler('weather:setWeatherCycle', function(cycle)
    if not isAdmin(source) then return end
    if WeatherState.activeEvent == 'heavyfog' or WeatherState.activeEvent == 'blizzard' then return end
    cycle = cycle == 'winter' and 'winter' or 'normal'
    WeatherState.weatherCycle = cycle
    resetWeatherChangeTimer()

    if cycle == 'normal' then
        WeatherState.currentWeather = 'CLEAR'
    else
        WeatherState.currentWeather = getWinterWeatherType()
    end

    TriggerClientEvent('weather:updateWeatherCycle', -1, cycle)
    broadcastWeatherTimer()
    updateRainBasedOnState()
    TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
    syncState()
end)

RegisterNetEvent('weather:setWeather')
AddEventHandler('weather:setWeather', function(weather)
    if not isAdmin(source) then return end
    if type(weather) ~= 'string' then return end
    if WeatherState.activeEvent == 'halloween' then return end
    if WeatherState.activeEvent == 'heavyfog' or WeatherState.activeEvent == 'blizzard' then return end

    WeatherState.currentWeather = string.upper(weather)
    resetWeatherChangeTimer()

    if WeatherState.activeEvent == 'flood' or WeatherState.isWaterDropping then
        if WeatherState.currentWeather ~= 'THUNDER' then
            WeatherState.floodStorm = false
        else
            WeatherState.floodStorm = true
        end
    end

    updateRainBasedOnState()
    broadcastWeatherTimer()
    TriggerClientEvent('weather:updateWeather', -1, WeatherState.currentWeather)
    syncState()
end)

RegisterNetEvent('weather:toggleSnow')
AddEventHandler('weather:toggleSnow', function(enabled)
    if not isAdmin(source) then return end

    WeatherState.snowOnGround = toBool(enabled)

    if WeatherState.activeEvent == 'blizzard' then
        WeatherState.eventOptions.blizzard.manualSnowOverride = true
    end

    TriggerClientEvent('weather:updateSnow', -1, WeatherState.snowOnGround)
    syncState()
end)

RegisterNetEvent('weather:setRainLevel')
AddEventHandler('weather:setRainLevel', function(level)
    if not isAdmin(source) then return end
    if WeatherState.activeEvent == 'heavyfog' or WeatherState.activeEvent == 'blizzard' then return end
    WeatherState.rainLevel = clamp(level, 0.0, 0.99)
    TriggerClientEvent('weather:updateRainLevel', -1, WeatherState.rainLevel)
    syncState()
end)

RegisterNetEvent('weather:setTime')
AddEventHandler('weather:setTime', function(hour, minute)
    if not isAdmin(source) then return end
    if WeatherState.activeEvent == 'halloween' then return end

    WeatherState.syncWithRealTime = false
    TriggerClientEvent('weather:updateSync', -1, false)

    local targetHour = tonumber(hour) or 12
    local targetMinute = tonumber(minute) or 0
    if targetHour < 0 or targetHour > 23 then targetHour = 0 end
    if targetMinute < 0 or targetMinute > 59 then targetMinute = 0 end

    startFastForward(targetHour, targetMinute, WeatherState.timeFrozen)
    syncState()
end)

RegisterNetEvent('weather:toggleWeatherFreeze')
AddEventHandler('weather:toggleWeatherFreeze', function(frozen)
    if not isAdmin(source) then return end
    WeatherState.weatherFrozen = toBool(frozen)
    TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen)
    syncState()
end)

RegisterNetEvent('weather:toggleTimeFreeze')
AddEventHandler('weather:toggleTimeFreeze', function(frozen)
    if not isAdmin(source) then return end
    WeatherState.timeFrozen = toBool(frozen)
    TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen)
    syncState()
end)

RegisterNetEvent('weather:toggleSyncWithRealTime')
AddEventHandler('weather:toggleSyncWithRealTime', function(enabled)
    if not isAdmin(source) then return end
    if WeatherState.activeEvent == 'halloween' then return end

    enabled = toBool(enabled)
    WeatherState.fastForward.active = false
    if enabled then
        local realHour, realMin = getRealTimeHour()
        WeatherState.syncWithRealTime = true
        WeatherState.timeFrozen = false
        TriggerClientEvent('weather:updateSync', -1, true)
        TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, false)
        startFastForward(realHour, realMin, false)
    else
        WeatherState.syncWithRealTime = false
        TriggerClientEvent('weather:updateSync', -1, false)
        TriggerClientEvent('weather:updateMode', -1, WeatherState.activeEvent, WeatherState.weatherFrozen, WeatherState.timeFrozen)
    end
    syncState()
end)

RegisterNetEvent('weather:toggleBlackout')
AddEventHandler('weather:toggleBlackout', function(enabled)
    if not isAdmin(source) then return end
    WeatherState.blackout = toBool(enabled)
    if not WeatherState.blackout then
        WeatherState.vehicleLightsDisabled = false
        TriggerClientEvent('weather:updateVehicleLights', -1, false)
    end
    TriggerClientEvent('weather:updateBlackout', -1, WeatherState.blackout)
    syncState()
end)

RegisterNetEvent('weather:toggleVehicleLights')
AddEventHandler('weather:toggleVehicleLights', function(disabled)
    if not isAdmin(source) then return end
    local vehicleLightsDisabled = WeatherState.blackout and toBool(disabled)
    WeatherState.vehicleLightsDisabled = vehicleLightsDisabled
    TriggerClientEvent('weather:updateVehicleLights', -1, vehicleLightsDisabled)
    syncState()
end)

RegisterNetEvent('weather:requestState')
AddEventHandler('weather:requestState', function()
    syncState(source)
    broadcastWeatherTimer(source)
end)

RegisterNetEvent('weather:openPanelRequest')
AddEventHandler('weather:openPanelRequest', function()
    if isAdmin(source) then
        prepareStateForSync()
        TriggerClientEvent('weather:openPanel', source, WeatherState)
        broadcastWeatherTimer(source)
    end
end)

CreateThread(function()
    Wait(100)
    syncState()
    broadcastWeatherTimer()
end)

AddEventHandler('playerJoining', function()
    Wait(100)
    local playerId = source
    if playerId then
        syncState(playerId)
        broadcastWeatherTimer(playerId)
    end
end)
