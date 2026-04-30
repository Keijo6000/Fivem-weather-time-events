-- ============================================
-- client sää ja eventit
-- ============================================

local WeatherState = {
    currentWeather = 'CLEAR', --sää
    currentHour = 12, --tunti
    currentMinute = 0, --minuutti
    weatherFrozen = false, --sää lukossa
    timeFrozen = false, --aika lukossa
    weatherCycle = 'normal', --sääsykli
    snowOnGround = false, --lumi maassa
    rainLevel = 0.0, --sade
    dynamicWeatherEnabled = true, --dynaaminen
    blackout = false, --sähköt
    vehicleLightsDisabled = false, --autovalot
    syncWithRealTime = false, --realiaika
    isTransitioning = false, --siirtymä
    weatherChangeTimer = 0, --sääajastin

    hypothermiaEnabled = false, --hypotermia

    activeEvent = 'none', --eventti
    eventLocked = false, --eventtilukko
    eventLockReason = nil, --syy ui
    eventStartedAt = 0, --aloitusaika
    eventElapsedMs = 0, --synkronointi
    eventOptions = {
        fogDensity = 0.5, --sumu
        halloween = { storm = true }, --halloween
        heavyfog = { canStop = false }, --sumun stop
        earthquakePhase = 'none', --järistysvaihe
        earthquake = { sirens = true, warning = true, intensity = 0.5 }, --järistys
        blizzard = { intensity = 0.5, addSnow = true, keepSnow = true, manualSnowOverride = false, snowRampToken = 0, removeSnowOnStop = false, canStop = false } --lumimyrsky
    },

    floodActive = false, --tulva päällä
    targetFloodLevel = 0.0, --tulvan target
    currentFloodLevel = 0.0, --tulvan taso
    currentActualFloodLevel = 0.0, --ui taso
    floodStorm = true, --tulvamyrsky
    floodTimerActive = false, --15min timer
    sirensActive = false, --sireenit
    floodRiseRate = 5.0, --nousunopeus
    isWaterDropping = false, --vesi laskee

    -- configista
    normalWeatherTypes = nil, --sääpainikkeet
    startupWeather = 'CLEAR' --aloitussää
}

local isPanelOpen = false --paneeli auki
local currentTargetWeather = nil --sää target
local transitionTime = 15.0 --siirtymäaika

local currentRainLevel = 0.0 --sade nyt
local targetRainLevel = 0.0 --sade target
local isRainTransitioning = false --sade siirtyy
local rainTransitionStep = 0.0 --sade askel

-- tulvan vesitaso
local isCustomWaterLoaded = false --flood xml
local currentFloodLevel = 0.0 --vesitaso
local baseWaterLevels = {} --alkutasot

-- säkkisumu
local currentFogStrength = 0.0 --sumu nyt
local targetFogStrength = 0.0 --sumu target
local fogTransitionStartStrength = 0.0 --sumu alku
local fogTransitionTargetStrength = 0.0 --sumu loppu
local fogTransitionStartAt = 0 --sumu aika
local fogTransitionDuration = 30000 --sumu kesto
local fogTransitionEasing = 'in' --sumu käyrä
local isFogModifierApplied = false --modifier päällä
local fogCleanupPending = false --sumu poistuu
local fogCleanupNotified = false --cleanup lähetetty
local fogStableSent = false --stable lähetetty
local floodOxygenRemaining = Config.FloodSettings.PlayerOxygenTime or 30.0 --happi
local nextFloodDrownDamageAt = 0 --hukkumisdamage
local nextFloodOxygenNotifyAt = 0 --happi notify

-- lumimyrsky
local currentBlizzardStrength = 0.0 --myrsky nyt
local targetBlizzardStrength = 0.0 --myrsky target
local blizzardTransitionStartStrength = 0.0 --myrsky alku
local blizzardTransitionTargetStrength = 0.0 --myrsky loppu
local blizzardTransitionStartAt = 0 --myrsky aika
local blizzardTransitionDuration = 30000 --myrsky kesto
local blizzardTransitionEasing = 'in' --myrsky käyrä

local isBlizzardModifierApplied = false --modifier päällä
local blizzardPeakStrength = 5.7 --huippuvoima
local blizzardPeakDuration = 45000 --huippukesto
local blizzardReturnDuration = 5000 --paluu
local lastBlizzardSnowRampToken = 0 --lumitoken
local blizzardWaitingForSnowPeak = false --odottaa huippua
local blizzardPeakHoldUntil = 0 --huippu asti
local blizzardRemovingSnowAtPeak = false --lumi pois huipussa
local blizzardCleanupPending = false --myrsky poistuu
local blizzardCleanupNotified = false --cleanup lähetetty
local blizzardStableSent = false --stable lähetetty
local currentWindSpeed = 0.0 --tuuli nyt
local targetWindSpeed = 0.0 --tuuli target

-- ============================================
-- ilmoitukset
-- ============================================

local function Notify(message, type, duration)
    type = type or 'info' --tyyppi
    duration = duration or 3000 --kesto

    if GetResourceState('ox_lib') == 'started' then
        exports.ox_lib:notify({ type = type, description = message, duration = duration }) --ox notify
    else
        SetNotificationTextEntry('STRING') --gta notify
        AddTextComponentString(message) --teksti
        DrawNotification(false, true) --näytä
    end
end

local function getFogTargetStrength(density)
    density = density or 0.5 --oletus
    return 2.4 + ((density ^ 1.25) * 21.0) --timecycle voima
end

local function shouldKeepFogModifier()
    return currentFogStrength > 0.01 --sumua näkyy
        or fogTransitionStartStrength > 0.01 --alku näkyy
        or fogTransitionTargetStrength > 0.01 --target näkyy
end

local function applyFogModifier(strength)
    if not isFogModifierApplied then
        SetTimecycleModifier("Sumu1") --sumu päälle
        isFogModifierApplied = true --modifier päällä
    end

    SetTimecycleModifierStrength(strength) --sumun voima
end

local function clearFogModifier()
    if isFogModifierApplied then
        SetTimecycleModifierStrength(0.0) --nollaan
        ClearTimecycleModifier() --pois
        isFogModifierApplied = false --modifier pois
    end
end

local function easeFogProgress(progress, mode)
    if progress <= 0.0 then return 0.0 end
    if progress >= 1.0 then return 1.0 end

    if mode == 'in' then
        return progress ^ 3.4
    elseif mode == 'out' then
        return 1.0 - ((1.0 - progress) ^ 1.8)
    elseif mode == 'inout' then
        return 0.5 - (math.cos(progress * math.pi) / 2.0)
    end

    return progress
end

local function getEventElapsedMs(state)
    return math.max(0, tonumber(state.eventElapsedMs) or 0) --eventtiaika
end

local function resumeFogTransition(fromStrength, targetStrength, duration, easingMode)
    currentFogStrength = fromStrength --voima nyt
    targetFogStrength = targetStrength --target
    fogTransitionStartStrength = fromStrength --alku
    fogTransitionTargetStrength = targetStrength --loppu
    fogTransitionStartAt = GetGameTimer() --aika nyt
    fogTransitionDuration = math.max(1, duration or 1) --kesto
    fogTransitionEasing = easingMode or 'inout' --käyrä

    if targetStrength > 0.01 or fromStrength > 0.01 then
        applyFogModifier(fromStrength) --modifier päälle
    end
end

local function startFogTransition(targetStrength, duration, easingMode, startFromZero)
    if startFromZero then
        currentFogStrength = 0.0 --nollasta
        fogTransitionStartStrength = 0.0 --alku nolla
    else
        fogTransitionStartStrength = currentFogStrength --nykyisestä
    end

    targetFogStrength = targetStrength --target
    fogTransitionTargetStrength = targetStrength --siirtymä target
    fogTransitionStartAt = GetGameTimer() --alkuaika
    fogTransitionDuration = duration or 60000 --kesto
    fogTransitionEasing = easingMode or 'inout' --käyrä

    if targetStrength > 0.01 or currentFogStrength > 0.01 then
        applyFogModifier(currentFogStrength) --modifier päälle
    end
end

local function tryMarkFogStable()
    if fogStableSent then return end --vain kerran
    if WeatherState.activeEvent ~= 'heavyfog' or fogCleanupPending then return end --vain sumussa
    if math.abs(currentFogStrength - fogTransitionTargetStrength) > 0.01 then return end --ei valmis
    if math.abs(fogTransitionStartStrength - fogTransitionTargetStrength) > 0.001 then return end --siirtyy vielä

    fogStableSent = true --lähetetty
    TriggerServerEvent('weather:fogStable') --stop auki
end

local function syncFogTransition(state, previousEvent)
    local density = (state.eventOptions and state.eventOptions.fogDensity) or 0.5 --tiheys
    local nextFogTargetStrength = 0.0 --target

    if state.activeEvent == 'heavyfog' then
        nextFogTargetStrength = getFogTargetStrength(density) --voima
        fogCleanupPending = false --ei cleanup
        fogCleanupNotified = false --notify nollaan

        if previousEvent ~= 'heavyfog' then
            fogStableSent = false --stable nollaan
            local duration = 90000 --90s nousu
            local elapsed = getEventElapsedMs(state) --kulunut

            if elapsed >= duration or (state.eventOptions.heavyfog and state.eventOptions.heavyfog.canStop) then
                resumeFogTransition(nextFogTargetStrength, nextFogTargetStrength, 1, 'in') --täysi sumu
            else
                local progress = math.max(0.0, math.min(1.0, elapsed / duration)) --vaihe
                local currentStrength = nextFogTargetStrength * easeFogProgress(progress, 'in') --nykyvoima
                resumeFogTransition(currentStrength, nextFogTargetStrength, duration - elapsed, 'in') --jatko
            end
        elseif math.abs(fogTransitionTargetStrength - nextFogTargetStrength) > 0.01 then
            fogStableSent = false --muutos kesken
            startFogTransition(nextFogTargetStrength, 30000, 'inout', false) --uusi tiheys
        else
            targetFogStrength = nextFogTargetStrength --target synkassa
        end
    elseif previousEvent == 'heavyfog' or (shouldKeepFogModifier() and not fogCleanupPending) then
        fogCleanupPending = true
        fogCleanupNotified = false
        fogStableSent = false
        startFogTransition(0.0, 45000, 'out', false)
    elseif fogCleanupPending then
        targetFogStrength = 0.0
    else
        targetFogStrength = 0.0
        fogTransitionStartStrength = 0.0
        fogTransitionTargetStrength = 0.0
        currentFogStrength = 0.0
        fogCleanupPending = false
        fogCleanupNotified = false
        fogStableSent = false
        clearFogModifier()
    end
end

local function getBlizzardTargetStrength(intensity)
    intensity = intensity or 0.5
    intensity = math.max(0.1, math.min(1.0, intensity))
    return 3.0 + (((intensity - 0.1) / 0.9) * 2.0)
end

local function shouldKeepBlizzardModifier()
    return currentBlizzardStrength > 0.01
        or blizzardTransitionStartStrength > 0.01
        or blizzardTransitionTargetStrength > 0.01
end

local function applyBlizzardModifier(strength)
    if not isBlizzardModifierApplied then
        SetTimecycleModifier("Lumimyrsky1")
        isBlizzardModifierApplied = true
    end
    SetTimecycleModifierStrength(strength)
end

local function clearBlizzardModifier()
    if isBlizzardModifierApplied then
        ClearTimecycleModifier()
        isBlizzardModifierApplied = false
    end
end

local function markBlizzardUnstable()
    blizzardStableSent = false
end

local function tryMarkBlizzardStable()
    if blizzardStableSent then return end
    if WeatherState.activeEvent ~= 'blizzard' then return end
    if blizzardWaitingForSnowPeak or blizzardPeakHoldUntil > 0 or blizzardRemovingSnowAtPeak or blizzardCleanupPending then return end
    if math.abs(blizzardTransitionTargetStrength - blizzardTransitionStartStrength) > 0.001 then return end

    local blizzardOptions = (WeatherState.eventOptions and WeatherState.eventOptions.blizzard) or {}
    if blizzardOptions.addSnow and not blizzardOptions.manualSnowOverride and not WeatherState.snowOnGround then return end

    blizzardStableSent = true
    TriggerServerEvent('weather:blizzardStable')
end

local function easeBlizzardProgress(progress, mode)
    if progress <= 0.0 then return 0.0 end
    if progress >= 1.0 then return 1.0 end
    if mode == 'in' then
        return progress ^ 3.4
    elseif mode == 'out' then
        return 1.0 - ((1.0 - progress) ^ 1.8)
    elseif mode == 'inout' then
        return 0.5 - (math.cos(progress * math.pi) / 2.0)
    end
    return progress
end

local function startBlizzardTransition(targetStrength, duration, easingMode, startFromZero)
    markBlizzardUnstable()
    -- ulostulo poikki
    if startFromZero then
        currentBlizzardStrength = 0.0
        blizzardTransitionStartStrength = 0.0
    else
        blizzardTransitionStartStrength = currentBlizzardStrength
    end
    targetBlizzardStrength = targetStrength
    blizzardTransitionTargetStrength = targetStrength
    blizzardTransitionStartAt = GetGameTimer()
    blizzardTransitionDuration = duration or 60000
    blizzardTransitionEasing = easingMode or 'inout'
    if targetStrength > 0.01 or currentBlizzardStrength > 0.01 then
        applyBlizzardModifier(currentBlizzardStrength)
    end
end

local function resumeBlizzardTransition(fromStrength, targetStrength, duration, easingMode)
    markBlizzardUnstable()
    currentBlizzardStrength = fromStrength
    targetBlizzardStrength = targetStrength
    blizzardTransitionStartStrength = fromStrength
    blizzardTransitionTargetStrength = targetStrength
    blizzardTransitionStartAt = GetGameTimer()
    blizzardTransitionDuration = math.max(1, duration or 1)
    blizzardTransitionEasing = easingMode or 'inout'

    if targetStrength > 0.01 or fromStrength > 0.01 then
        applyBlizzardModifier(fromStrength)
    end
end

local function syncBlizzardTransition(state, previousEvent)
    local blizzardOptions = (state.eventOptions and state.eventOptions.blizzard) or {}
    local intensity = blizzardOptions.intensity or 0.5
    local nextBlizzardTargetStrength = getBlizzardTargetStrength(intensity)
    local targetWind = 10.0 + (intensity * 20.0)

    if state.activeEvent == 'blizzard' then
        local snowRampToken = blizzardOptions.snowRampToken or 0
        local shouldPlaceSnowAfterPeak = blizzardOptions.addSnow
            and not blizzardOptions.manualSnowOverride
            and not state.snowOnGround
            and (previousEvent ~= 'blizzard' or snowRampToken > lastBlizzardSnowRampToken)

        if shouldPlaceSnowAfterPeak then
            markBlizzardUnstable()
            lastBlizzardSnowRampToken = snowRampToken
            blizzardWaitingForSnowPeak = true
            blizzardPeakHoldUntil = 0
            blizzardRemovingSnowAtPeak = false
            blizzardCleanupPending = false
            blizzardCleanupNotified = false

            local elapsed = getEventElapsedMs(state)
            if previousEvent ~= 'blizzard' and elapsed > 0 then
                if elapsed < blizzardPeakDuration then
                    local progress = math.max(0.0, math.min(1.0, elapsed / blizzardPeakDuration))
                    local currentStrength = blizzardPeakStrength * easeBlizzardProgress(progress, 'inout')
                    resumeBlizzardTransition(currentStrength, blizzardPeakStrength, blizzardPeakDuration - elapsed, 'inout')
                else
                    blizzardWaitingForSnowPeak = false
                    currentBlizzardStrength = blizzardPeakStrength
                    applyBlizzardModifier(blizzardPeakStrength)
                    TriggerServerEvent('weather:blizzardSnowReady')

                    local afterPeak = elapsed - blizzardPeakDuration
                    if afterPeak < 5000 then
                        blizzardPeakHoldUntil = GetGameTimer() + (5000 - afterPeak)
                    elseif afterPeak < (5000 + blizzardReturnDuration) then
                        local progress = math.max(0.0, math.min(1.0, (afterPeak - 5000) / blizzardReturnDuration))
                        local currentStrength = blizzardPeakStrength + ((nextBlizzardTargetStrength - blizzardPeakStrength) * easeBlizzardProgress(progress, 'inout'))
                        resumeBlizzardTransition(currentStrength, nextBlizzardTargetStrength, (5000 + blizzardReturnDuration) - afterPeak, 'inout')
                    else
                        resumeBlizzardTransition(nextBlizzardTargetStrength, nextBlizzardTargetStrength, 1, 'inout')
                    end
                end
            else
                startBlizzardTransition(blizzardPeakStrength, blizzardPeakDuration, 'inout', previousEvent ~= 'blizzard')
            end
        elseif blizzardPeakHoldUntil > 0 or blizzardRemovingSnowAtPeak or blizzardCleanupPending then
            targetBlizzardStrength = blizzardTransitionTargetStrength
        elseif previousEvent ~= 'blizzard' then
            markBlizzardUnstable()
            blizzardWaitingForSnowPeak = false
            blizzardPeakHoldUntil = 0
            blizzardRemovingSnowAtPeak = false
            blizzardCleanupPending = false
            blizzardCleanupNotified = false

            local duration = 45000
            local elapsed = getEventElapsedMs(state)
            if elapsed >= duration or blizzardOptions.canStop then
                resumeBlizzardTransition(nextBlizzardTargetStrength, nextBlizzardTargetStrength, 1, 'in')
            else
                local progress = math.max(0.0, math.min(1.0, elapsed / duration))
                local currentStrength = nextBlizzardTargetStrength * easeBlizzardProgress(progress, 'in')
                resumeBlizzardTransition(currentStrength, nextBlizzardTargetStrength, duration - elapsed, 'in')
            end
        elseif not blizzardWaitingForSnowPeak and math.abs(blizzardTransitionTargetStrength - nextBlizzardTargetStrength) > 0.01 then
            startBlizzardTransition(nextBlizzardTargetStrength, 12000, 'inout', false)
        else
            targetBlizzardStrength = nextBlizzardTargetStrength
        end
    elseif previousEvent == 'blizzard' or (shouldKeepBlizzardModifier() and not blizzardCleanupPending) then
        blizzardWaitingForSnowPeak = false
        blizzardPeakHoldUntil = 0
        blizzardCleanupPending = true
        blizzardCleanupNotified = false

        if blizzardOptions.removeSnowOnStop and state.snowOnGround then
            blizzardRemovingSnowAtPeak = true
            startBlizzardTransition(blizzardPeakStrength, 5000, 'inout', false)
        else
            blizzardRemovingSnowAtPeak = false
            startBlizzardTransition(0.0, 45000, 'out', false)
            if currentBlizzardStrength <= 0.01 and not blizzardCleanupNotified then
                blizzardCleanupNotified = true
                blizzardCleanupPending = false
                TriggerServerEvent('weather:blizzardCleanupDone')
            end
        end
        targetWind = 0.0
        targetWindSpeed = 0.0
    elseif blizzardCleanupPending then
        targetWind = 0.0
        targetWindSpeed = 0.0
    else
        targetBlizzardStrength = 0.0
        blizzardTransitionStartStrength = 0.0
        blizzardTransitionTargetStrength = 0.0
        currentBlizzardStrength = 0.0
        targetWind = 0.0
        blizzardWaitingForSnowPeak = false
        blizzardPeakHoldUntil = 0
        blizzardRemovingSnowAtPeak = false
        blizzardCleanupPending = false
        blizzardCleanupNotified = false
        clearBlizzardModifier()
    end

    targetWindSpeed = targetWind
end

-- ============================================
-- sää ja aika
-- ============================================

local function SetWeather(weather)
    if currentTargetWeather == weather and not WeatherState.isTransitioning then
        return --ei muutosta
    end

    currentTargetWeather = weather --sää target

    SetWeatherTypeOvertimePersist(weather, transitionTime) --gta siirtymä
    WeatherState.isTransitioning = true --siirtyy
    if isPanelOpen then SendNUIMessage({ type = 'updateState', state = WeatherState }) end --ui heti

    local transitionTarget = weather --timeout target
    SetTimeout(math.floor(transitionTime * 1000) + 500, function()
        if currentTargetWeather == transitionTarget then
            WeatherState.isTransitioning = false --valmis
            if isPanelOpen then SendNUIMessage({ type = 'updateState', state = WeatherState }) end --ui valmis
        end
    end)
end

local function SetTime(hour, minute)
    NetworkOverrideClockTime(hour, minute, 0) --servun aika
end

local function sendPanelState(state)
    if isPanelOpen then
        SendNUIMessage({ type = 'updateState', state = state or WeatherState }) --ui state
    end
end

-- ============================================
-- nui kutsut
-- ============================================

RegisterNUICallback('setWeather', function(data, cb) TriggerServerEvent('weather:setWeather', data.weather); cb('ok') end) --sää
RegisterNUICallback('setWeatherCycle', function(data, cb) TriggerServerEvent('weather:setWeatherCycle', data.cycle); cb('ok') end) --sääsykli
RegisterNUICallback('toggleSnow', function(data, cb) TriggerServerEvent('weather:toggleSnow', data.enabled); cb('ok') end) --lumi
RegisterNUICallback('setRainLevel', function(data, cb) TriggerServerEvent('weather:setRainLevel', data.level); cb('ok') end) --sade
RegisterNUICallback('setTime', function(data, cb) TriggerServerEvent('weather:setTime', data.hour, data.minute); cb('ok') end) --aika

RegisterNUICallback('startSpecialEvent', function(data, cb) TriggerServerEvent('weather:startSpecialEvent', data.eventName, data.options); cb('ok') end) --eventti start
RegisterNUICallback('stopSpecialEvent', function(data, cb) TriggerServerEvent('weather:stopSpecialEvent'); cb('ok') end) --eventti stop

RegisterNUICallback('setFloodAction', function(data, cb) TriggerServerEvent('weather:setFloodAction', data.action, data.targetHeight, data.storm, data.sirens, data.warning, data.riseRate); cb('ok') end) --tulva action
RegisterNUICallback('toggleFloodOption', function(data, cb) TriggerServerEvent('weather:toggleFloodOption', data.option, data.state, data.riseRate); cb('ok') end) --tulva optio
RegisterNUICallback('updateEventOption', function(data, cb) TriggerServerEvent('weather:updateEventOption', data.eventName, data.option, data.value); cb('ok') end) --eventti optio

RegisterNUICallback('toggleHypothermia', function(data, cb) TriggerServerEvent('weather:toggleHypothermia', data.enabled); cb('ok') end) --hypotermia

RegisterNUICallback('toggleWeatherFreeze', function(data, cb) TriggerServerEvent('weather:toggleWeatherFreeze', data.frozen); cb('ok') end) --sää lukko
RegisterNUICallback('toggleTimeFreeze', function(data, cb) TriggerServerEvent('weather:toggleTimeFreeze', data.frozen); cb('ok') end) --aika lukko
RegisterNUICallback('toggleBlackout', function(data, cb) TriggerServerEvent('weather:toggleBlackout', data.enabled); cb('ok') end) --blackout
RegisterNUICallback('toggleVehicleLights', function(data, cb) TriggerServerEvent('weather:toggleVehicleLights', data.disabled); cb('ok') end) --autovalot
RegisterNUICallback('toggleSyncWithRealTime', function(data, cb) TriggerServerEvent('weather:toggleSyncWithRealTime', data.enabled); cb('ok') end) --realiaika
RegisterNUICallback('closePanel', function(data, cb) SetNuiFocus(false, false); isPanelOpen = false; SendNUIMessage({ type = 'hide' }); cb('ok') end) --paneeli kiinni
RegisterNUICallback('getState', function(data, cb) cb(WeatherState) end) --state

-- ============================================
-- servulta
-- ============================================

RegisterNetEvent('weather:updateSync')
AddEventHandler('weather:updateSync', function(enabled)
    WeatherState.syncWithRealTime = enabled
    if enabled then WeatherState.timeFrozen = false end
    sendPanelState()
end)

RegisterNetEvent('weather:updateWeatherCycle')
AddEventHandler('weather:updateWeatherCycle', function(cycle) WeatherState.weatherCycle = cycle; sendPanelState() end)

RegisterNetEvent('weather:updateSnow')
AddEventHandler('weather:updateSnow', function(enabled) WeatherState.snowOnGround = enabled; sendPanelState() end)

RegisterNetEvent('weather:updateRainLevel')
AddEventHandler('weather:updateRainLevel', function(level)
    WeatherState.rainLevel = level
    targetRainLevel = level
    isRainTransitioning = true
    rainTransitionStep = (targetRainLevel - currentRainLevel) / (transitionTime * 20)
    sendPanelState()
end)

RegisterNetEvent('weather:updateWeather')
AddEventHandler('weather:updateWeather', function(weather) WeatherState.currentWeather = weather; SetWeather(weather); sendPanelState() end)

RegisterNetEvent('weather:updateWeatherTimer')
AddEventHandler('weather:updateWeatherTimer', function(timer)
    WeatherState.weatherChangeTimer = timer or 0
    sendPanelState()
end)

RegisterNetEvent('weather:updateTime')
AddEventHandler('weather:updateTime', function(hour, minute) WeatherState.currentHour = hour; WeatherState.currentMinute = minute; SetTime(hour, minute); sendPanelState() end)

RegisterNetEvent('weather:updateMode')
AddEventHandler('weather:updateMode', function(activeEvent, weatherFrozen, timeFrozen) WeatherState.activeEvent = activeEvent; WeatherState.weatherFrozen = weatherFrozen; WeatherState.timeFrozen = timeFrozen; sendPanelState() end)

RegisterNetEvent('weather:updateBlackout')
AddEventHandler('weather:updateBlackout', function(enabled)
    WeatherState.blackout = enabled
    if not enabled then WeatherState.vehicleLightsDisabled = false end
    SetArtificialLightsState(enabled)
    SetArtificialLightsStateAffectsVehicles(enabled and WeatherState.vehicleLightsDisabled)
    sendPanelState()
end)

RegisterNetEvent('weather:updateVehicleLights')
AddEventHandler('weather:updateVehicleLights', function(disabled)
    WeatherState.vehicleLightsDisabled = disabled
    SetArtificialLightsStateAffectsVehicles(WeatherState.blackout and disabled)
    sendPanelState()
end)

RegisterNetEvent('weather:toggleSirens')
AddEventHandler('weather:toggleSirens', function(enabled)
    WeatherState.sirensActive = enabled
    sendPanelState()
end)

RegisterNetEvent('weather:resetWater')
AddEventHandler('weather:resetWater', function()
    if isCustomWaterLoaded then
        ResetWater()
        isCustomWaterLoaded = false
    end
    currentFloodLevel = 0.0
    WeatherState.currentFloodLevel = 0.0
    WeatherState.currentActualFloodLevel = 0.0
    sendPanelState()
end)

RegisterNetEvent('weather:syncState')
AddEventHandler('weather:syncState', function(state)
    local previousEvent = WeatherState.activeEvent
    WeatherState = state
    SetWeather(state.currentWeather)
    SetTime(state.currentHour, state.currentMinute)

    -- config ui:lle
    if state.normalWeatherTypes then
        WeatherState.normalWeatherTypes = state.normalWeatherTypes
    end
    if state.startupWeather then
        WeatherState.startupWeather = state.startupWeather
    end

    if targetRainLevel ~= state.rainLevel then
        targetRainLevel = state.rainLevel
        isRainTransitioning = true
        rainTransitionStep = (targetRainLevel - currentRainLevel) / (transitionTime * 20)
    end

    local shouldUseFloodWater = state.floodActive
        or state.isWaterDropping
        or (state.currentFloodLevel or state.currentActualFloodLevel or 0.0) > 0.01
        or (state.targetFloodLevel or 0.0) > 0.01

    if shouldUseFloodWater and not isCustomWaterLoaded then
        LoadWaterFromPath(GetCurrentResourceName(), 'flood.xml')
        Wait(500)
        isCustomWaterLoaded = true

        baseWaterLevels = {}
        local count = GetWaterQuadCount()
        for i = 1, count do
            local success, lvl = GetWaterQuadLevel(i)
            if success == 1 then baseWaterLevels[i] = lvl else baseWaterLevels[i] = 0.0 end
        end
    elseif not shouldUseFloodWater and isCustomWaterLoaded then
        ResetWater()
        isCustomWaterLoaded = false
        currentFloodLevel = 0.0
    end

    if shouldUseFloodWater then
        currentFloodLevel = state.currentFloodLevel or state.currentActualFloodLevel or currentFloodLevel
        WeatherState.currentFloodLevel = currentFloodLevel
        WeatherState.currentActualFloodLevel = currentFloodLevel
    end

    syncFogTransition(state, previousEvent)
    syncBlizzardTransition(state, previousEvent)

    WeatherState.targetFloodLevel = state.targetFloodLevel

    SetArtificialLightsState(state.blackout)
    SetArtificialLightsStateAffectsVehicles(state.blackout and state.vehicleLightsDisabled)

    sendPanelState()
end)

RegisterNetEvent('weather:openPanel')
AddEventHandler('weather:openPanel', function(state) WeatherState = state; OpenPanel() end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    Wait(1000)
    TriggerServerEvent('weather:requestState')
end)

-- ============================================
-- ui ja luupit
-- ============================================

function OpenPanel()
    if isPanelOpen then return end
    isPanelOpen = true
    SetNuiFocus(true, true)
    
    -- sulkunappi js:lle
    SendNUIMessage({ 
        type = 'show', 
        state = WeatherState,
        closeKey = Config.NUICloseKey 
    })
end

CreateThread(function()
    while true do
        Wait(1000)
        if isPanelOpen and isCustomWaterLoaded then
            SendNUIMessage({
                type = 'updateState',
                state = { currentActualFloodLevel = currentFloodLevel }
            })
        end
    end
end)

-- ============================================
-- säkkisumu luuppi
-- ============================================
CreateThread(function()
    while true do
        Wait(0)

        local hasActiveTransition = math.abs(fogTransitionTargetStrength - fogTransitionStartStrength) > 0.001

        if hasActiveTransition then
            local elapsed = GetGameTimer() - fogTransitionStartAt
            local duration = math.max(1, fogTransitionDuration)
            local progress = elapsed / duration
            if progress < 0.0 then progress = 0.0 end
            if progress > 1.0 then progress = 1.0 end

            local easedProgress = easeFogProgress(progress, fogTransitionEasing)
            currentFogStrength = fogTransitionStartStrength + ((fogTransitionTargetStrength - fogTransitionStartStrength) * easedProgress)

            if progress >= 1.0 then
                currentFogStrength = fogTransitionTargetStrength
                fogTransitionStartStrength = fogTransitionTargetStrength
                hasActiveTransition = false
            end
        else
            currentFogStrength = fogTransitionTargetStrength
        end

        if currentFogStrength > 0.0 or hasActiveTransition then
            applyFogModifier(currentFogStrength)
        end

        if not hasActiveTransition then
            if fogCleanupPending then
                currentFogStrength = 0.0
                fogTransitionStartStrength = 0.0
                fogTransitionTargetStrength = 0.0
                applyFogModifier(0.0)
                clearFogModifier()
                fogCleanupPending = false
                if not fogCleanupNotified then
                    fogCleanupNotified = true
                    TriggerServerEvent('weather:fogCleanupDone')
                end
            elseif currentFogStrength > 0.01 then
                tryMarkFogStable()
            else
                clearFogModifier()
            end
        end
    end
end)

-- ============================================
-- lumimyrsky luuppi
-- ============================================
CreateThread(function()
    while true do
        Wait(0)

        if blizzardPeakHoldUntil > 0 then
            currentBlizzardStrength = blizzardPeakStrength
            applyBlizzardModifier(blizzardPeakStrength)

            if GetGameTimer() >= blizzardPeakHoldUntil then
                blizzardPeakHoldUntil = 0
                local intensity = (WeatherState.eventOptions and WeatherState.eventOptions.blizzard and WeatherState.eventOptions.blizzard.intensity) or 0.5
                startBlizzardTransition(getBlizzardTargetStrength(intensity), blizzardReturnDuration, 'inout', false)
            end
        else
            -- normaali siirtymä
            local hasActiveBlizzardTransition = math.abs(blizzardTransitionTargetStrength - blizzardTransitionStartStrength) > 0.001

            if hasActiveBlizzardTransition then
                local elapsed = GetGameTimer() - blizzardTransitionStartAt
                local duration = math.max(1, blizzardTransitionDuration)
                local progress = elapsed / duration
                if progress < 0.0 then progress = 0.0 end
                if progress > 1.0 then progress = 1.0 end

                local easedProgress = easeBlizzardProgress(progress, blizzardTransitionEasing)
                currentBlizzardStrength = blizzardTransitionStartStrength + ((blizzardTransitionTargetStrength - blizzardTransitionStartStrength) * easedProgress)

                if progress >= 1.0 then
                    currentBlizzardStrength = blizzardTransitionTargetStrength
                    blizzardTransitionStartStrength = blizzardTransitionTargetStrength
                    hasActiveBlizzardTransition = false

                    if blizzardWaitingForSnowPeak and math.abs(currentBlizzardStrength - blizzardPeakStrength) < 0.01 then
                        blizzardWaitingForSnowPeak = false

                        local blizzardOptions = (WeatherState.eventOptions and WeatherState.eventOptions.blizzard) or {}
                        if WeatherState.activeEvent == 'blizzard' and blizzardOptions.addSnow and not blizzardOptions.manualSnowOverride then
                            TriggerServerEvent('weather:blizzardSnowReady')
                        end

                        blizzardPeakHoldUntil = GetGameTimer() + 5000
                    elseif blizzardRemovingSnowAtPeak and math.abs(currentBlizzardStrength - blizzardPeakStrength) < 0.01 then
                        blizzardRemovingSnowAtPeak = false
                        TriggerServerEvent('weather:blizzardRemoveSnowNow')
                        startBlizzardTransition(0.0, 45000, 'out', false)
                    elseif blizzardCleanupPending and currentBlizzardStrength <= 0.01 and not blizzardCleanupNotified then
                        blizzardCleanupNotified = true
                        blizzardCleanupPending = false
                        TriggerServerEvent('weather:blizzardCleanupDone')
                    end
                end
            else
                currentBlizzardStrength = blizzardTransitionTargetStrength
            end

            tryMarkBlizzardStable()

            if currentBlizzardStrength > 0.01 or hasActiveBlizzardTransition then
                applyBlizzardModifier(currentBlizzardStrength)
            else
                clearBlizzardModifier()
            end
        end
    end
end)

-- ============================================
-- sireeniluuppi
-- ============================================
CreateThread(function()
    local sirenTimer = 0
    while true do
        Wait(500)
        if WeatherState.sirensActive then
            if GetGameTimer() > sirenTimer then
                for _, loc in ipairs(Config.FloodSettings.SirenLocations) do
                    PlaySoundFromCoord(-1, "Alarm_Oneshot", loc.x, loc.y, loc.z, "DLC_H4_Island_Alarms_Sounds", false, 0, false)
                end
                sirenTimer = GetGameTimer() + 13000
            end
        else
            sirenTimer = 0
        end
    end
end)

-- ============================================
-- npc paniikki
-- ============================================
CreateThread(function()
    while true do
        Wait(1000)
        local ev = WeatherState.activeEvent
        if ev == 'earthquake' then
            local playerPed = PlayerPedId()
            local pCoords = GetEntityCoords(playerPed)
            local allPeds = GetGamePool('CPed')

            for i = 1, #allPeds do
                local ped = allPeds[i]
                if ped ~= 0 and DoesEntityExist(ped) and ped ~= playerPed and not IsEntityDead(ped) then
                    local pedCoords = GetEntityCoords(ped)
                    if #(pCoords - pedCoords) < 150.0 then
                        if not IsPedFleeing(ped) then
                            TaskSmartFleeCoord(ped, pedCoords.x, pedCoords.y, pedCoords.z, 150.0, -1, false, false)
                        end
                    end
                end
            end
        end
    end
end)

-- ============================================
-- hypotermia
-- ============================================
local hypoPhase = 0
local nextShakeTime = 0
local wrongDirTimer = 0
local hypoActiveTime = 0
local lastHypoWarning = 0

-- merivesi check
-- waterquad = meri
-- ei quadia = ei hypotermiaa
local function isPlayerOnWaterQuad()
    local ped = PlayerPedId()
    local pCoords = GetEntityCoords(ped)
    
    local waterQuad = GetWaterQuadAtCoords(pCoords.x, pCoords.y, pCoords.z)
    if waterQuad and waterQuad ~= -1 then
        return true
    end
    return false
end

CreateThread(function()
    local timeInWater = 0.0
    RequestAnimSet("move_m@injured")
    while not HasAnimSetLoaded("move_m@injured") do Wait(10) end

    while true do
        Wait(1000)
        local ped = PlayerPedId()

        if WeatherState.hypothermiaEnabled and not IsEntityDead(ped) then
            local maxT = Config.SurvivalSettings.MaxTimeInWater
            
            -- vesiquad check
            local isOnWater = isPlayerOnWaterQuad()
            local isSwimming = IsPedSwimming(ped) or IsPedSwimmingUnderWater(ped)

            -- vesiaika
            if isOnWater and isSwimming then
                timeInWater = timeInWater + 1.0
                if timeInWater > maxT then timeInWater = maxT end
            else
                if timeInWater > 0 then
                    local recoveryStep = maxT / Config.SurvivalSettings.HypothermiaRecoveryTime
                    timeInWater = timeInWater - recoveryStep
                    if timeInWater < 0 then timeInWater = 0 end
                end
            end

            -- tila
            if timeInWater == maxT then
                if hypoPhase ~= 2 then
                    hypoPhase = 2
                    Notify("Olet saanut hypotermian! Palaa välittömästi takaisin rannalle lämmittelemään.", "error", 10000)
                    AnimpostfxPlay("Dont_tazeme_bro", 0, true)
                    SetPedMovementClipset(ped, "move_m@injured", 0.5)
                    hypoActiveTime = 0
                    lastHypoWarning = 0
                end

                hypoActiveTime = hypoActiveTime + 1.0
                local maxHypo = Config.SurvivalSettings.MaxHypothermiaTime or 60.0
                local interval = maxHypo / 3
                
                if hypoActiveTime >= maxHypo then
                    SetEntityHealth(ped, 0)
                    Notify("Kuolit hypotermiaan.", "error", 5000)
                else
                    local currentWarning = math.floor(hypoActiveTime / interval)
                    if currentWarning > lastHypoWarning and currentWarning <= 2 then
                        lastHypoWarning = currentWarning
                        local timeLeft = math.ceil(maxHypo - hypoActiveTime)
                        Notify("Hypotermia pahenee! Aikaa jäljellä: " .. timeLeft .. "s", "warning", 5000)
                    end
                end
            elseif timeInWater > 0 then
                if timeInWater >= (maxT / 2.0) then
                    if hypoPhase == 0 then
                        hypoPhase = 1
                        Notify("Vesi on jäätävää! Hypotermia iskee pian, nouse ylös.", "warning", 7000)
                    elseif hypoPhase == 2 and not IsPedSwimming(ped) and not IsPedSwimmingUnderWater(ped) then
                        -- rannalla märkä
                        hypoPhase = 3
                    end
                else
                    -- toipuu
                    if hypoPhase == 3 or hypoPhase == 2 or hypoPhase == 1 then
                        hypoPhase = 4
                        AnimpostfxStop("Dont_tazeme_bro")
                        ResetPedMovementClipset(ped, 0.5)
                    end
                end
            else
                -- palautunut
                if hypoPhase ~= 0 then
                    hypoPhase = 0
                    AnimpostfxStop("Dont_tazeme_bro")
                    ResetPedMovementClipset(ped, 0.5)
                    StopGameplayCamShaking(true)
                end
            end
        else
            if hypoPhase ~= 0 then
                hypoPhase = 0
                timeInWater = 0.0
                AnimpostfxStop("Dont_tazeme_bro")
                ResetPedMovementClipset(ped, 0.5)
                StopGameplayCamShaking(true)
            end
        end
    end
end)

-- uintikontrolli
CreateThread(function()
    while true do
        Wait(0)
        if WeatherState.hypothermiaEnabled and hypoPhase > 0 then
            local ped = PlayerPedId()

            -- tärinä
            if GetGameTimer() > nextShakeTime then
                local amp = 0.5
                local delay = 3000
                if hypoPhase == 2 or hypoPhase == 3 then
                    amp = 1.5
                    delay = 1500
                elseif hypoPhase == 1 or hypoPhase == 4 then
                    amp = 0.5
                    delay = 3000
                end
                ShakeGameplayCam("FPS_MELEE_HIT_SHAKE", amp)
                nextShakeTime = GetGameTimer() + delay
            end

            -- sprint esto rannalla
            if not IsPedSwimming(ped) and not IsPedSwimmingUnderWater(ped) then
                if hypoPhase >= 2 then
                    DisableControlAction(0, 21, true)
                end
            end

            -- sprint ja uinti
            if IsPedSwimming(ped) and not IsEntityDead(ped) then
                if IsPedSwimmingUnderWater(ped) then
                    -- pintaan pääsy
                else
                    if hypoPhase >= 2 then
                        -- sukellus esto
                        DisableControlAction(0, 55, true)

                        local pCoords = GetEntityCoords(ped)
                        local fw = GetEntityForwardVector(ped)
                        local isSwimmingTowardsShore = false

                        -- joka frame
                        -- lähimmät rannat
                        local validNodes = {}
                        for i = 1, 3 do
                            local found, node = GetNthClosestVehicleNode(pCoords.x, pCoords.y, pCoords.z, i, 0, 3.0, 0)
                            if found then
                                table.insert(validNodes, node)
                            end
                        end

                        if #validNodes > 0 then
                            for i, node in ipairs(validNodes) do
                                local dir = vector2(node.x - pCoords.x, node.y - pCoords.y)
                                local dist = #(dir)

                                -- lähin sallittu
                                -- lähellä sallittu
                                if i == 1 or dist <= 30.0 then
                                    if dist > 0 then
                                        dir = dir / dist
                                        local dot = (fw.x * dir.x) + (fw.y * dir.y)

                                        -- suunta rannalle
                                        if dot >= 0.8 then
                                            isSwimmingTowardsShore = true
                                            break
                                        end
                                    end
                                end
                            end
                        end

                        if not isSwimmingTowardsShore then
                            DisableControlAction(0, 21, true)
                            if GetGameTimer() > wrongDirTimer then
                                Notify("Vesi on jäätävää! Käänny ja palaa kohti lähintä rantaa.", "error", 4000)
                                wrongDirTimer = GetGameTimer() + 5000
                            end
                        end
                    end
                end
            end
        else
            Wait(500)
        end
    end
end)

-- ============================================
-- maanjäristys
-- ============================================
CreateThread(function()
    local nextEqSoundTime = 0
    local nextEqCheckTime = 0
    local currentEqAmplitude = 0.0
    local targetEqAmplitude = 0.0
    local isEqShaking = false

    while true do
        Wait(0)
        if WeatherState.activeEvent == 'earthquake' and WeatherState.eventOptions.earthquakePhase == 'active' then
            local intensity = WeatherState.eventOptions.earthquake.intensity or 0.5
            targetEqAmplitude = 8.0 * intensity

            -- äänen kierto
            if GetGameTimer() > nextEqSoundTime and currentEqAmplitude > 0.1 then
                PlaySoundFrontend(-1, "Explosion_Shake", "dlc_xm_avngr_sounds", 1)

                -- max viive
                local interval = math.floor(200 / math.max(0.2, currentEqAmplitude))
                if interval < 50 then interval = 50 end
                if interval > 350 then interval = 350 end

                nextEqSoundTime = GetGameTimer() + interval
            end

            if GetGameTimer() > nextEqCheckTime then
                local ped = PlayerPedId()
                local pCoords = GetEntityCoords(ped)

                local vehicles = GetGamePool('CVehicle')
                for _, veh in ipairs(vehicles) do
                    if #(pCoords - GetEntityCoords(veh)) < 50.0 then
                        -- autohälyt
                        if IsVehicleSeatFree(veh, -1) and not GetIsVehicleEngineRunning(veh) then
                            if not IsVehicleAlarmSet(veh) then
                                SetVehicleAlarm(veh, true)
                            end
                            StartVehicleAlarm(veh)
                            SetVehicleAlarmTimeLeft(veh, 30000)
                        end
                    end
                end

                local ragdollChance = math.floor(5 + (intensity * 10))
                if math.random(1, 100) <= ragdollChance then
                    if not IsPedInAnyVehicle(ped, false) then
                        SetPedToRagdoll(ped, 2000, 2000, 0, false, false, false)
                    end
                end

                -- npc ragdoll
                local allPeds = GetGamePool('CPed')
                for i = 1, #allPeds do
                    local npc = allPeds[i]
                    if npc ~= 0 and npc ~= ped and DoesEntityExist(npc) and not IsEntityDead(npc) and not IsPedInAnyVehicle(npc, false) then
                        local npcCoords = GetEntityCoords(npc)
                        if #(pCoords - npcCoords) < 50.0 then
                            if math.random(1, 100) <= ragdollChance then
                                SetPedToRagdoll(npc, 2000, 2000, 0, false, false, false)
                            end
                        end
                    end
                end

                nextEqCheckTime = GetGameTimer() + 1000
            end
        else
            targetEqAmplitude = 0.0
        end

        -- pehmeä feidi
        if currentEqAmplitude < targetEqAmplitude then
            currentEqAmplitude = currentEqAmplitude + 0.02
            if currentEqAmplitude > targetEqAmplitude then currentEqAmplitude = targetEqAmplitude end
        elseif currentEqAmplitude > targetEqAmplitude then
            currentEqAmplitude = currentEqAmplitude - 0.02
            if currentEqAmplitude < targetEqAmplitude then currentEqAmplitude = targetEqAmplitude end
        end

        -- kamera tärisee
        if currentEqAmplitude > 0.0 then
            if not isEqShaking then
                ShakeGameplayCam("SKY_DIVING_SHAKE", currentEqAmplitude)
                isEqShaking = true
            else
                SetGameplayCamShakeAmplitude(currentEqAmplitude)
            end

            -- ääni jatkuu
            if WeatherState.activeEvent ~= 'earthquake' and currentEqAmplitude > 0.1 and GetGameTimer() > nextEqSoundTime then
                PlaySoundFrontend(-1, "Explosion_Shake", "dlc_xm_avngr_sounds", 1)
                local interval = math.floor(200 / math.max(0.2, currentEqAmplitude))
                if interval > 350 then interval = 350 end
                nextEqSoundTime = GetGameTimer() + interval
            end
        else
            if isEqShaking then
                StopGameplayCamShaking(true)
                isEqShaking = false
            end
        end

        if WeatherState.activeEvent ~= 'earthquake' and currentEqAmplitude <= 0.0 then
            Wait(1000)
        end
    end
end)

-- ============================================
-- tulvauinti
-- ============================================
CreateThread(function()
    local wasUnderwater = false
    local oxygenMax = Config.FloodSettings.PlayerOxygenTime or 30.0

    while true do
        Wait(100)
        if isCustomWaterLoaded and currentFloodLevel > 2.0 then
            local ped = PlayerPedId()
            if not IsEntityDead(ped) then
                local pCoords = GetEntityCoords(ped)
                local headZ = pCoords.z + 0.75

                local underwater = (headZ + 0.35) <= currentFloodLevel

                if underwater then
                    if not wasUnderwater then
                        wasUnderwater = true
                        floodOxygenRemaining = oxygenMax
                        nextFloodDrownDamageAt = 0
                        nextFloodOxygenNotifyAt = 0
                    end
                    floodOxygenRemaining = math.max(0.0, floodOxygenRemaining - 0.1)
                    if floodOxygenRemaining > 0.0 and GetGameTimer() >= nextFloodOxygenNotifyAt then
                        local oxygenPercent = math.max(0, math.min(100, math.ceil((floodOxygenRemaining / oxygenMax) * 100)))
                        if GetResourceState('ox_lib') == 'started' then
                            exports.ox_lib:notify({
                                type = oxygenPercent <= 25 and 'error' or 'warning',
                                description = 'Happea jäljellä: ' .. oxygenPercent .. '%',
                                duration = 900
                            })
                        end
                        nextFloodOxygenNotifyAt = GetGameTimer() + 1000
                    end
                    if floodOxygenRemaining <= 0.0 and GetGameTimer() >= nextFloodDrownDamageAt then
                        ApplyDamageToPed(ped, 10, false)
                        nextFloodDrownDamageAt = GetGameTimer() + 1000
                    end
                else
                    if wasUnderwater then
                        wasUnderwater = false
                    end
                    floodOxygenRemaining = oxygenMax
                    nextFloodDrownDamageAt = 0
                    nextFloodOxygenNotifyAt = 0
                end
            else
                wasUnderwater = false
                floodOxygenRemaining = oxygenMax
                nextFloodDrownDamageAt = 0
                nextFloodOxygenNotifyAt = 0
            end
        else
            if wasUnderwater then
                wasUnderwater = false
                floodOxygenRemaining = oxygenMax
                nextFloodDrownDamageAt = 0
                nextFloodOxygenNotifyAt = 0
            end
            Wait(1000)
        end
    end
end)

CreateThread(function()
    local wasForcedSwimming = false

    while true do
        Wait(0)
        if isCustomWaterLoaded and currentFloodLevel > 2.0 then
            local ped = PlayerPedId()
            if not IsEntityDead(ped) then
                local pCoords = GetEntityCoords(ped)
                local depth = currentFloodLevel - pCoords.z

                if not IsPedInAnyVehicle(ped, false) then

                    if depth > -1.0 then
                        if depth > 5.0 and GetEntityVelocity(ped).z < -5.0 then
                            FreezeEntityPosition(ped, true)
                            SetPedConfigFlag(ped, 65, true)
                            Wait(250)
                            FreezeEntityPosition(ped, false)
                            wasForcedSwimming = true
                        else
                            if not IsPedSwimming(ped) and not IsPedSwimmingUnderWater(ped) then
                                SetPedConfigFlag(ped, 65, true)
                                wasForcedSwimming = true
                            end
                        end
                    else
                        if wasForcedSwimming then
                            SetPedConfigFlag(ped, 65, false)
                            wasForcedSwimming = false
                        end
                    end
                else
                    if wasForcedSwimming then
                        SetPedConfigFlag(ped, 65, false)
                        wasForcedSwimming = false
                    end
                end
            else
                if wasForcedSwimming then
                    SetPedConfigFlag(ped, 65, false)
                    wasForcedSwimming = false
                end
            end
        else
            if wasForcedSwimming then
                SetPedConfigFlag(PlayerPedId(), 65, false)
                wasForcedSwimming = false
            end
            Wait(1000)
        end
    end
end)

-- ============================================
-- tulvafysiikat
-- ============================================
CreateThread(function()
    while true do
        Wait(500)

        if WeatherState.activeEvent == 'flood' or WeatherState.floodTimerActive or WeatherState.isWaterDropping then
            local playerPed = PlayerPedId()
            local pCoords = GetEntityCoords(playerPed)
            local pedProcessDist = 450.0
            local vehicleProcessDist = 550.0

            local allPeds = GetGamePool('CPed')
            for i = 1, #allPeds do
                local ped = allPeds[i]
                if ped ~= 0 and DoesEntityExist(ped) and ped ~= playerPed and not IsEntityDead(ped) then
                    local pedCoords = GetEntityCoords(ped)

                    if #(pCoords - pedCoords) < pedProcessDist then
                        if pedCoords.z <= currentFloodLevel and currentFloodLevel > 2.0 then
                            DisablePedPainAudio(ped, true)
                            StopPedSpeaking(ped, true)

                            if IsPedInAnyVehicle(ped, false) then
                                SetEntityHealth(ped, 0)
                            else
                                local headCoords = GetPedBoneCoords(ped, 31086, 0.0, 0.0, 0.0)
                                if headCoords.z <= currentFloodLevel then
                                    SetEntityHealth(ped, 0)
                                end
                            end
                        else
                            if not IsPedFleeing(ped) then
                                TaskSmartFleeCoord(ped, pedCoords.x, pedCoords.y, pedCoords.z, 200.0, -1, false, false)
                            end
                        end
                    end
                end
            end

            if currentFloodLevel > 2.0 then
                local allVehicles = GetGamePool('CVehicle')
                for i = 1, #allVehicles do
                    local veh = allVehicles[i]
                    if DoesEntityExist(veh) then
                        local vehCoords = GetEntityCoords(veh)
                        if #(pCoords - vehCoords) < vehicleProcessDist then
                            if currentFloodLevel > 2.0 and vehCoords.z < currentFloodLevel then
                                local vehClass = GetVehicleClass(veh)
                                if vehClass ~= 14 then
                                    if GetIsVehicleEngineRunning(veh) or IsVehicleDriveable(veh, false) then
                                        SetVehicleEngineHealth(veh, -4000.0)
                                        SetVehicleEngineOn(veh, false, true, true)
                                        SetVehicleUndriveable(veh, true)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- ============================================
-- pääsynkka
-- ============================================
CreateThread(function()
    while true do
        PauseClock(true)
        SetTime(WeatherState.currentHour, WeatherState.currentMinute)

        ForceSnowPass(WeatherState.snowOnGround)
        SetForceVehicleTrails(WeatherState.snowOnGround)
        SetForcePedFootstepsTracks(WeatherState.snowOnGround)

        if isRainTransitioning then
            currentRainLevel = currentRainLevel + rainTransitionStep
            if (rainTransitionStep > 0 and currentRainLevel >= targetRainLevel) or
               (rainTransitionStep < 0 and currentRainLevel <= targetRainLevel) then
                currentRainLevel = targetRainLevel
                isRainTransitioning = false
            end
        end

        local safeRain = currentRainLevel
        if safeRain >= 1.0 then safeRain = 0.99 end
        SetRainLevel(safeRain)

        if isCustomWaterLoaded then

            local rateSecondsPerMeter = WeatherState.floodRiseRate or 5.0
            if rateSecondsPerMeter <= 0 then rateSecondsPerMeter = 1.0 end
            local risePerTick = 1.0 / (rateSecondsPerMeter * 20.0)

            if math.abs(currentFloodLevel - WeatherState.targetFloodLevel) > 0.01 then

                if currentFloodLevel < WeatherState.targetFloodLevel then
                    currentFloodLevel = currentFloodLevel + risePerTick
                    if currentFloodLevel > WeatherState.targetFloodLevel then currentFloodLevel = WeatherState.targetFloodLevel end
                else
                    currentFloodLevel = currentFloodLevel - risePerTick
                    if currentFloodLevel < WeatherState.targetFloodLevel then currentFloodLevel = WeatherState.targetFloodLevel end
                end
            end

            if currentFloodLevel <= 0.01 and WeatherState.targetFloodLevel == 0.0 and WeatherState.isWaterDropping then
                TriggerServerEvent('weather:floodEnded')
                currentFloodLevel = 0.0
            end

            WeatherState.currentFloodLevel = currentFloodLevel
            WeatherState.currentActualFloodLevel = currentFloodLevel

            local count = GetWaterQuadCount()
            for i = 1, count do
                local baseLvl = baseWaterLevels[i]
                if baseLvl ~= nil and type(baseLvl) == "number" then
                    SetWaterQuadLevel(i, math.max(baseLvl, currentFloodLevel))
                end
            end
        end

        -- myrskytuuli
        if targetWindSpeed > 0.0 then
            if math.abs(currentWindSpeed - targetWindSpeed) > 0.1 then
                if currentWindSpeed < targetWindSpeed then
                    currentWindSpeed = currentWindSpeed + 0.1
                    if currentWindSpeed > targetWindSpeed then currentWindSpeed = targetWindSpeed end
                else
                    currentWindSpeed = currentWindSpeed - 0.1
                    if currentWindSpeed < targetWindSpeed then currentWindSpeed = targetWindSpeed end
                end
            end
            SetWind(1.0)
            SetWindSpeed(currentWindSpeed)
        else
            SetWind(-1.0)
            SetWindSpeed(-1.0)
            currentWindSpeed = 0.0
        end

        Wait(50)
    end
end)

-- ============================================
-- sammutussiivous
-- ============================================
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        if isCustomWaterLoaded then
            ResetWater()
        end
        ClearTimecycleModifier()
        SetWind(-1.0)
        SetWindSpeed(-1.0)
        SetArtificialLightsState(false)
        SetArtificialLightsStateAffectsVehicles(false)
    end
end)
