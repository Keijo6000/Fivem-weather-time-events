Config = {}
-- ============================================
Config.CommandName = 'maailma' --paneelin aukasu
Config.NUICloseKey = "Escape" --sulkunappi
-- ============================================
-- adminit
-- ============================================
Config.AdminPermissions = { --pelaajat
    -- 'license:123456789',
    -- 'discord:123456789',
    -- jne
}
Config.AdminAceGroup = 'weather.admin' --ace oikeus
-- server.cfg ace
-- ============================================
-- sää
-- ============================================
Config.WeatherSettings = {
    StartupWeather = 'CLEAR', --aloitussää
    WeatherChangeInterval = 45, --vaihtoväli min
    SnowOnGround = false,      --lumi maassa

    NormalWeatherTypes = { --sääprosentit (yhteensä 100%)
        { type = 'EXTRASUNNY', chance = 15 },
        { type = 'CLEAR', chance = 20 },
        { type = 'CLOUDS', chance = 15 },
        { type = 'SMOG', chance = 5 },
        { type = 'FOGGY', chance = 5 },
        { type = 'OVERCAST', chance = 10 },
        { type = 'RAIN', chance = 10 },
        { type = 'THUNDER', chance = 5 },
        { type = 'CLEARING', chance = 15 }
    },

    SnowWeatherType = 'SNOWLIGHT' --lumisää
}
-- ============================================
-- aika
-- ============================================
Config.TimeSettings = {
    DefaultHour = 12,          --aloitustunti
    DefaultMinute = 0,         --aloitusminuutti
    DayLengthInMinutes = 120,  --päivän kesto
    SyncWithRealTime = false,  --realiaika
    UseFinlandTimezone = true, --suomen aika
    ManualTimezoneOffset = 0   --aikavyöhyke
}
-- ============================================
-- hypotermia
-- ============================================
Config.SurvivalSettings = {
    HypothermiaEnabled = true,
    MaxTimeInWater = 60,          --hypo alkaa
    HypothermiaRecoveryTime = 90, --palautuminen
    MaxHypothermiaTime = 300      --kuolema
}
-- ============================================
-- tulva eventti
-- ============================================
Config.FloodSettings = {
    PlayerOxygenTime = 30.0, --happi tulvassa, normi gta happi systeemi ei wörki

    SirenLocations = {
        vector3(98.6938, -870.7027, 151.0170), --helsinki
        vector3(1854.74, 3686.43, 34.26),      --vantaa
        vector3(-446.41, 6012.35, 31.71)       --espoo
    }
}
-- ============================================
