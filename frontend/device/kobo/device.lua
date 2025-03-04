local Generic = require("device/generic/device")
local Geom = require("ui/geometry")
local WakeupMgr = require("device/wakeupmgr")
local logger = require("logger")
local util = require("ffi/util")
local _ = require("gettext")

-- We're going to need a few <linux/fb.h> & <linux/input.h> constants...
local ffi = require("ffi")
local C = ffi.C
require("ffi/linux_fb_h")
require("ffi/linux_input_h")

local function yes() return true end
local function no() return false end

local function koboEnableWifi(toggle)
    if toggle == true then
        logger.info("Kobo Wi-Fi: enabling Wi-Fi")
        os.execute("./enable-wifi.sh")
    else
        logger.info("Kobo Wi-Fi: disabling Wi-Fi")
        os.execute("./disable-wifi.sh")
    end
end

-- checks if standby is available on the device
local function checkStandby()
    logger.dbg("Kobo: checking if standby is possible ...")
    local f = io.open("/sys/power/state")
    if not f then
        return no
    end
    local mode = f:read()
    logger.dbg("Kobo: available power states", mode)
    if mode:find("standby") then
        logger.dbg("Kobo: standby state allowed")
        return yes
    end
    logger.dbg("Kobo: standby state not allowed")
    return no
end

local function writeToSys(val, file)
    local f = io.open(file, "we")
    if not f then
        logger.err("Cannot open:", file)
        return
    end
    local re, err_msg, err_code = f:write(val, "\n")
    if not re then
        logger.err("Error writing value to file:", val, file, err_msg, err_code)
    end
    f:close()
    return re
end

local Kobo = Generic:new{
    model = "Kobo",
    isKobo = yes,
    isTouchDevice = yes, -- all of them are
    hasOTAUpdates = yes,
    hasFastWifiStatusQuery = yes,
    hasWifiManager = yes,
    canStandby = no, -- will get updated by checkStandby()
    canReboot = yes,
    canPowerOff = yes,
    -- most Kobos have X/Y switched for the touch screen
    touch_switch_xy = true,
    -- most Kobos have also mirrored X coordinates
    touch_mirrored_x = true,
    -- enforce portrait mode on Kobos
    --- @note: In practice, the check that is used for in ffi/framebuffer is no longer relevant,
    ---        since, in almost every case, we enforce a hardware Portrait rotation via fbdepth on startup by default ;).
    ---        We still want to keep it in case an unfortunate soul on an older device disables the bitdepth switch...
    isAlwaysPortrait = yes,
    -- we don't need an extra refreshFull on resume, thank you very much.
    needsScreenRefreshAfterResume = no,
    -- currently only the Aura One and Forma have coloured frontlights
    hasNaturalLight = no,
    hasNaturalLightMixer = no,
    -- HW inversion is generally safe on Kobo, except on a few boards/kernels
    canHWInvert = yes,
    home_dir = "/mnt/onboard",
    canToggleMassStorage = yes,
    -- New devices *may* be REAGL-aware, but generally don't expect explicit REAGL requests, default to not.
    isREAGL = no,
    -- Mark 7 devices sport an updated driver.
    isMk7 = no,
    -- MXCFB_WAIT_FOR_UPDATE_COMPLETE ioctls are generally reliable
    hasReliableMxcWaitFor = yes,
    -- Sunxi devices require a completely different fb backend...
    isSunxi = no,
    -- On sunxi, "native" panel layout used to compute the G2D rotation handle (e.g., deviceQuirks.nxtBootRota in FBInk).
    boot_rota = nil,
    -- Standard sysfs path to the battery directory
    battery_sysfs = "/sys/class/power_supply/mc13892_bat",
    -- Stable path to the NTX input device
    ntx_dev = "/dev/input/event0",
    -- Stable path to the Touch input device
    touch_dev = "/dev/input/event1",
    -- Event code to use to detect contact pressure
    pressure_event = nil,
    -- Device features multiple CPU cores
    isSMP = no,
    -- Device supports "eclipse" waveform modes (i.e., optimized for nightmode).
    hasEclipseWfm = no,

    unexpected_wakeup_count = 0
}

-- Kobo Touch:
local KoboTrilogy = Kobo:new{
    model = "Kobo_trilogy",
    needsTouchScreenProbe = yes,
    touch_switch_xy = false,
    hasKeys = yes,
    hasMultitouch = no,
}

-- Kobo Mini:
local KoboPixie = Kobo:new{
    model = "Kobo_pixie",
    display_dpi = 200,
    hasMultitouch = no,
    -- bezel:
    viewport = Geom:new{x=0, y=2, w=596, h=794},
}

-- Kobo Aura One:
local KoboDaylight = Kobo:new{
    model = "Kobo_daylight",
    hasFrontlight = yes,
    touch_phoenix_protocol = true,
    display_dpi = 300,
    hasNaturalLight = yes,
    frontlight_settings = {
        frontlight_white = "/sys/class/backlight/lm3630a_led1b",
        frontlight_red = "/sys/class/backlight/lm3630a_led1a",
        frontlight_green = "/sys/class/backlight/lm3630a_ledb",
    },
}

-- Kobo Aura H2O:
local KoboDahlia = Kobo:new{
    model = "Kobo_dahlia",
    hasFrontlight = yes,
    touch_phoenix_protocol = true,
    -- There's no slot 0, the first finger gets assigned slot 1, and the second slot 2.
    -- NOTE: Could be queried at runtime via EVIOCGABS on C.ABS_MT_TRACKING_ID (minimum field).
    --       Used to be handled via an adjustTouchAlyssum hook that just mangled ABS_MT_TRACKING_ID values.
    main_finger_slot = 1,
    display_dpi = 265,
    -- the bezel covers the top 11 pixels:
    viewport = Geom:new{x=0, y=11, w=1080, h=1429},
}

-- Kobo Aura HD:
local KoboDragon = Kobo:new{
    model = "Kobo_dragon",
    hasFrontlight = yes,
    hasMultitouch = no,
    display_dpi = 265,
}

-- Kobo Glo:
local KoboKraken = Kobo:new{
    model = "Kobo_kraken",
    hasFrontlight = yes,
    hasMultitouch = no,
    display_dpi = 212,
}

-- Kobo Aura:
local KoboPhoenix = Kobo:new{
    model = "Kobo_phoenix",
    hasFrontlight = yes,
    touch_phoenix_protocol = true,
    display_dpi = 212,
    -- The bezel covers 10 pixels at the bottom:
    viewport = Geom:new{x=0, y=0, w=758, h=1014},
    -- NOTE: AFAICT, the Aura was the only one explicitly requiring REAGL requests...
    isREAGL = yes,
    -- NOTE: May have a buggy kernel, according to the nightmode hack...
    canHWInvert = no,
}

-- Kobo Aura H2O2:
local KoboSnow = Kobo:new{
    model = "Kobo_snow",
    hasFrontlight = yes,
    touch_snow_protocol = true,
    touch_mirrored_x = false,
    display_dpi = 265,
    hasNaturalLight = yes,
    frontlight_settings = {
        frontlight_white = "/sys/class/backlight/lm3630a_ledb",
        frontlight_red = "/sys/class/backlight/lm3630a_led",
        frontlight_green = "/sys/class/backlight/lm3630a_leda",
    },
}

-- Kobo Aura H2O2, Rev2:
--- @fixme Check if the Clara fix actually helps here... (#4015)
local KoboSnowRev2 = Kobo:new{
    model = "Kobo_snow_r2",
    isMk7 = yes,
    hasFrontlight = yes,
    touch_snow_protocol = true,
    display_dpi = 265,
    hasNaturalLight = yes,
    frontlight_settings = {
        frontlight_white = "/sys/class/backlight/lm3630a_ledb",
        frontlight_red = "/sys/class/backlight/lm3630a_leda",
    },
}

-- Kobo Aura second edition:
local KoboStar = Kobo:new{
    model = "Kobo_star",
    hasFrontlight = yes,
    touch_phoenix_protocol = true,
    display_dpi = 212,
}

-- Kobo Aura second edition, Rev 2:
local KoboStarRev2 = Kobo:new{
    model = "Kobo_star_r2",
    isMk7 = yes,
    hasFrontlight = yes,
    touch_phoenix_protocol = true,
    display_dpi = 212,
}

-- Kobo Glo HD:
local KoboAlyssum = Kobo:new{
    model = "Kobo_alyssum",
    hasFrontlight = yes,
    touch_phoenix_protocol = true,
    main_finger_slot = 1,
    display_dpi = 300,
}

-- Kobo Touch 2.0:
local KoboPika = Kobo:new{
    model = "Kobo_pika",
    touch_phoenix_protocol = true,
    main_finger_slot = 1,
}

-- Kobo Clara HD:
local KoboNova = Kobo:new{
    model = "Kobo_nova",
    isMk7 = yes,
    canToggleChargingLED = yes,
    hasFrontlight = yes,
    touch_snow_protocol = true,
    display_dpi = 300,
    hasNaturalLight = yes,
    frontlight_settings = {
        frontlight_white = "/sys/class/backlight/mxc_msp430.0/brightness",
        frontlight_mixer = "/sys/class/backlight/lm3630a_led/color",
        nl_min = 0,
        nl_max = 10,
        nl_inverted = true,
    },
}

-- Kobo Forma:
-- NOTE: Right now, we enforce Portrait orientation on startup to avoid getting touch coordinates wrong,
--       no matter the rotation we were started from (c.f., platform/kobo/koreader.sh).
-- NOTE: For the FL, assume brightness is WO, and actual_brightness is RO!
--       i.e., we could have a real KoboPowerD:frontlightIntensityHW() by reading actual_brightness ;).
-- NOTE: Rotation events *may* not be enabled if Nickel has never been brought up in that power cycle.
--       i.e., this will affect KSM users.
--       c.f., https://github.com/koreader/koreader/pull/4414#issuecomment-449652335
--       There's also a CM_ROTARY_ENABLE command, but which seems to do as much nothing as the STATUS one...
local KoboFrost = Kobo:new{
    model = "Kobo_frost",
    isMk7 = yes,
    canToggleChargingLED = yes,
    hasFrontlight = yes,
    hasKeys = yes,
    hasGSensor = yes,
    canToggleGSensor = yes,
    touch_snow_protocol = true,
    misc_ntx_gsensor_protocol = true,
    display_dpi = 300,
    hasNaturalLight = yes,
    frontlight_settings = {
        frontlight_white = "/sys/class/backlight/mxc_msp430.0/brightness",
        frontlight_mixer = "/sys/class/backlight/tlc5947_bl/color",
        -- Warmth goes from 0 to 10 on the device's side (our own internal scale is still normalized to [0...100])
        -- NOTE: Those three extra keys are *MANDATORY* if frontlight_mixer is set!
        nl_min = 0,
        nl_max = 10,
        nl_inverted = true,
    },
}

-- Kobo Libra:
-- NOTE: Assume the same quirks as the Forma apply.
local KoboStorm = Kobo:new{
    model = "Kobo_storm",
    isMk7 = yes,
    canToggleChargingLED = yes,
    hasFrontlight = yes,
    hasKeys = yes,
    hasGSensor = yes,
    canToggleGSensor = yes,
    touch_snow_protocol = true,
    misc_ntx_gsensor_protocol = true,
    display_dpi = 300,
    hasNaturalLight = yes,
    frontlight_settings = {
        frontlight_white = "/sys/class/backlight/mxc_msp430.0/brightness",
        frontlight_mixer = "/sys/class/backlight/lm3630a_led/color",
        -- Warmth goes from 0 to 10 on the device's side (our own internal scale is still normalized to [0...100])
        -- NOTE: Those three extra keys are *MANDATORY* if frontlight_mixer is set!
        nl_min = 0,
        nl_max = 10,
        nl_inverted = true,
    },
    -- NOTE: The Libra apparently suffers from a mysterious issue where completely innocuous WAIT_FOR_UPDATE_COMPLETE ioctls
    --       will mysteriously fail with a timeout (5s)...
    --       This obviously leads to *terrible* user experience, so, until more is understood avout the issue,
    --       bypass this ioctl on this device.
    --       c.f., https://github.com/koreader/koreader/issues/7340
    hasReliableMxcWaitFor = no,
}

-- Kobo Nia:
--- @fixme: Mostly untested, assume it's Clara-ish for now.
local KoboLuna = Kobo:new{
    model = "Kobo_luna",
    isMk7 = yes,
    canToggleChargingLED = yes,
    hasFrontlight = yes,
    touch_phoenix_protocol = true,
    display_dpi = 212,
}

-- Kobo Elipsa
local KoboEuropa = Kobo:new{
    model = "Kobo_europa",
    isSunxi = yes,
    hasEclipseWfm = yes,
    canToggleChargingLED = yes,
    hasFrontlight = yes,
    hasGSensor = yes,
    canToggleGSensor = yes,
    pressure_event = C.ABS_MT_PRESSURE,
    misc_ntx_gsensor_protocol = true,
    display_dpi = 227,
    boot_rota = C.FB_ROTATE_CCW,
    battery_sysfs = "/sys/class/power_supply/battery",
    ntx_dev = "/dev/input/by-path/platform-ntx_event0-event",
    touch_dev = "/dev/input/by-path/platform-0-0010-event",
    isSMP = yes,
}

-- Kobo Sage
local KoboCadmus = Kobo:new{
    model = "Kobo_cadmus",
    isSunxi = yes,
    hasEclipseWfm = yes,
    canToggleChargingLED = yes,
    hasFrontlight = yes,
    hasKeys = yes,
    hasGSensor = yes,
    canToggleGSensor = yes,
    pressure_event = C.ABS_MT_PRESSURE,
    misc_ntx_gsensor_protocol = true,
    display_dpi = 300,
    hasNaturalLight = yes,
    frontlight_settings = {
        frontlight_white = "/sys/class/backlight/mxc_msp430.0/brightness",
        frontlight_mixer = "/sys/class/leds/aw99703-bl_FL1/color",
        -- Warmth goes from 0 to 10 on the device's side (our own internal scale is still normalized to [0...100])
        -- NOTE: Those three extra keys are *MANDATORY* if frontlight_mixer is set!
        nl_min = 0,
        nl_max = 10,
        nl_inverted = false,
    },
    boot_rota = C.FB_ROTATE_CW,
    battery_sysfs = "/sys/class/power_supply/battery",
    hasAuxBattery = yes,
    aux_battery_sysfs = "/sys/class/misc/cilix",
    ntx_dev = "/dev/input/by-path/platform-ntx_event0-event",
    touch_dev = "/dev/input/by-path/platform-0-0010-event",
    isSMP = yes,
}

-- Kobo Libra 2:
local KoboIo = Kobo:new{
    model = "Kobo_io",
    isMk7 = yes,
    hasEclipseWfm = yes,
    canToggleChargingLED = yes,
    hasFrontlight = yes,
    hasKeys = yes,
    hasGSensor = yes,
    canToggleGSensor = yes,
    pressure_event = C.ABS_MT_PRESSURE,
    touch_mirrored_x = false,
    misc_ntx_gsensor_protocol = true,
    display_dpi = 300,
    hasNaturalLight = yes,
    frontlight_settings = {
        frontlight_white = "/sys/class/backlight/mxc_msp430.0/brightness",
        frontlight_mixer = "/sys/class/backlight/lm3630a_led/color",
        -- Warmth goes from 0 to 10 on the device's side (our own internal scale is still normalized to [0...100])
        -- NOTE: Those three extra keys are *MANDATORY* if frontlight_mixer is set!
        nl_min = 0,
        nl_max = 10,
        nl_inverted = true,
    },
    -- It would appear that the Libra 2 inherited its ancestor's quirks, and more...
    -- c.f., https://github.com/koreader/koreader/issues/8414 & https://github.com/koreader/koreader/issues/8664
    hasReliableMxcWaitFor = no,
}

function Kobo:setupChargingLED()
    if G_reader_settings:nilOrTrue("enable_charging_led") then
        if self:hasAuxBattery() and self.powerd:isAuxBatteryConnected() then
            self:toggleChargingLED(self.powerd:isAuxCharging())
        else
            self:toggleChargingLED(self.powerd:isCharging())
        end
    end
end

function Kobo:init()
    -- Check if we need to disable MXCFB_WAIT_FOR_UPDATE_COMPLETE ioctls...
    local mxcfb_bypass_wait_for
    if G_reader_settings:has("mxcfb_bypass_wait_for") then
        mxcfb_bypass_wait_for = G_reader_settings:isTrue("mxcfb_bypass_wait_for")
    else
        mxcfb_bypass_wait_for = not self:hasReliableMxcWaitFor()
    end

    if self:isSunxi() then
        self.screen = require("ffi/framebuffer_sunxi"):new{
            device = self,
            debug = logger.dbg,
            is_always_portrait = self.isAlwaysPortrait(),
            mxcfb_bypass_wait_for = mxcfb_bypass_wait_for,
            boot_rota = self.boot_rota,
        }

        -- Sunxi means no HW inversion :(
        self.canHWInvert = no
    else
        self.screen = require("ffi/framebuffer_mxcfb"):new{
            device = self,
            debug = logger.dbg,
            is_always_portrait = self.isAlwaysPortrait(),
            mxcfb_bypass_wait_for = mxcfb_bypass_wait_for,
        }
        if self.screen.fb_bpp == 32 then
            -- Ensure we decode images properly, as our framebuffer is BGRA...
            logger.info("Enabling Kobo @ 32bpp BGR tweaks")
            self.hasBGRFrameBuffer = yes
        end
    end

    -- Automagically set this so we never have to remember to do it manually ;p
    if self:hasNaturalLight() and self.frontlight_settings and self.frontlight_settings.frontlight_mixer then
        self.hasNaturalLightMixer = yes
    end
    -- Ditto
    if self:isMk7() then
        self.canHWDither = yes
    end

    self.powerd = require("device/kobo/powerd"):new{
        device = self,
        battery_sysfs = self.battery_sysfs,
        aux_battery_sysfs = self.aux_battery_sysfs,
    }
    -- NOTE: For the Forma, with the buttons on the right, 193 is Top, 194 Bottom.
    self.input = require("device/input"):new{
        device = self,
        event_map = {
            [35] = "SleepCover",  -- KEY_H, Elipsa
            [59] = "SleepCover",
            [90] = "LightButton",
            [102] = "Home",
            [116] = "Power",
            [193] = "RPgBack",
            [194] = "RPgFwd",
            [331] = "Eraser",
            [332] = "Highlighter",
        },
        event_map_adapter = {
            SleepCover = function(ev)
                if self.input:isEvKeyPress(ev) then
                    return "SleepCoverClosed"
                elseif self.input:isEvKeyRelease(ev) then
                    return "SleepCoverOpened"
                end
            end,
            LightButton = function(ev)
                if self.input:isEvKeyRelease(ev) then
                    return "Light"
                end
            end,
        },
        main_finger_slot = self.main_finger_slot or 0,
        pressure_event = self.pressure_event,
    }
    self.wakeup_mgr = WakeupMgr:new()

    Generic.init(self)

    -- When present, event2 is the raw accelerometer data (3-Axis Orientation/Motion Detection)
    self.input.open(self.ntx_dev) -- Various HW Buttons, Switches & Synthetic NTX events
    self.input.open(self.touch_dev)
    -- fake_events is only used for usb plug event so far
    -- NOTE: usb hotplug event is also available in /tmp/nickel-hardware-status (... but only when Nickel is running ;p)
    self.input.open("fake_events")

    if not self.needsTouchScreenProbe() then
        self:initEventAdjustHooks()
    else
        -- if touch probe is required, we postpone EventAdjustHook
        -- initialization to when self:touchScreenProbe is called
        self.touchScreenProbe = function()
            -- if user has not set KOBO_TOUCH_MIRRORED yet
            if KOBO_TOUCH_MIRRORED == nil then
                -- and has no probe before
                if G_reader_settings:hasNot("kobo_touch_switch_xy") then
                    local TouchProbe = require("tools/kobo_touch_probe")
                    local UIManager = require("ui/uimanager")
                    UIManager:show(TouchProbe:new{})
                    UIManager:run()
                    -- assuming TouchProbe sets kobo_touch_switch_xy config
                end
                self.touch_switch_xy = G_reader_settings:readSetting("kobo_touch_switch_xy")
            end
            self:initEventAdjustHooks()
        end
    end

    -- We have no way of querying the current state of the charging LED, so, start from scratch.
    -- Much like Nickel, start by turning it off.
    self:toggleChargingLED(false)
    self:setupChargingLED()

    -- Only enable a single core on startup
    self:enableCPUCores(1)

    self.canStandby = checkStandby()
    if self.canStandby() and (self:isMk7() or self:isSunxi())  then
        self.canPowerSaveWhileCharging = yes
    end

    -- Check if the device has a Neonode IR grid (to tone down the chatter on resume ;)).
    if lfs.attributes("/sys/devices/virtual/input/input1/neocmd", "mode") == "file" then
        self.hasIRGrid = true
    end
end

function Kobo:setDateTime(year, month, day, hour, min, sec)
    if hour == nil or min == nil then return true end
    local command
    if year and month and day then
        command = string.format("date -s '%d-%d-%d %d:%d:%d'", year, month, day, hour, min, sec)
    else
        command = string.format("date -s '%d:%d'",hour, min)
    end
    if os.execute(command) == 0 then
        os.execute('hwclock -u -w')
        return true
    else
        return false
    end
end

function Kobo:initNetworkManager(NetworkMgr)
    function NetworkMgr:turnOffWifi(complete_callback)
        self:releaseIP()
        koboEnableWifi(false)
        if complete_callback then
            complete_callback()
        end
    end

    function NetworkMgr:turnOnWifi(complete_callback)
        koboEnableWifi(true)
        self:reconnectOrShowNetworkMenu(complete_callback)
    end

    local net_if = os.getenv("INTERFACE")
    if not net_if then
        net_if = "eth0"
    end
    function NetworkMgr:getNetworkInterfaceName()
        return net_if
    end
    NetworkMgr:setWirelessBackend(
        "wpa_supplicant", {ctrl_interface = "/var/run/wpa_supplicant/" .. net_if})

    function NetworkMgr:obtainIP()
        os.execute("./obtain-ip.sh")
    end

    function NetworkMgr:releaseIP()
        os.execute("./release-ip.sh")
    end

    function NetworkMgr:restoreWifiAsync()
        os.execute("./restore-wifi-async.sh")
    end

    -- NOTE: Cheap-ass way of checking if Wi-Fi seems to be enabled...
    --       Since the crux of the issues lies in race-y module unloading, this is perfectly fine for our usage.
    function NetworkMgr:isWifiOn()
        local needle = os.getenv("WIFI_MODULE") or "sdio_wifi_pwr"
        local nlen = #needle
        -- /proc/modules is usually empty, unless Wi-Fi or USB is enabled
        -- We could alternatively check if lfs.attributes("/proc/sys/net/ipv4/conf/" .. os.getenv("INTERFACE"), "mode") == "directory"
        -- c.f., also what Cervantes does via /sys/class/net/eth0/carrier to check if the interface is up.
        -- That said, since we only care about whether *modules* are loaded, this does the job nicely.
        local f = io.open("/proc/modules", "re")
        if not f then
            return false
        end

        local found = false
        for haystack in f:lines() do
            if haystack:sub(1, nlen) == needle then
                found = true
                break
            end
        end
        f:close()
        return found
    end
end

function Kobo:supportsScreensaver() return true end

function Kobo:initEventAdjustHooks()
    -- it's called KOBO_TOUCH_MIRRORED in defaults.lua, but what it
    -- actually did in its original implementation was to switch X/Y.
    -- NOTE: for kobo touch, adjustTouchSwitchXY needs to be called before
    -- adjustTouchMirrorX
    if (self.touch_switch_xy and not KOBO_TOUCH_MIRRORED)
            or (not self.touch_switch_xy and KOBO_TOUCH_MIRRORED)
    then
        self.input:registerEventAdjustHook(self.input.adjustTouchSwitchXY)
    end

    if self.touch_mirrored_x then
        self.input:registerEventAdjustHook(
            self.input.adjustTouchMirrorX,
            --- @fixme what if we change the screen portrait mode?
            self.screen:getWidth()
        )
    end

    if self.touch_snow_protocol then
        self.input.snow_protocol = true
    end

    if self.touch_phoenix_protocol then
        self.input.handleTouchEv = self.input.handleTouchEvPhoenix
    end

    -- Accelerometer on the Forma
    if self.misc_ntx_gsensor_protocol then
        if G_reader_settings:isTrue("input_ignore_gsensor") then
            self.input.isNTXAccelHooked = false
        else
            self.input.handleMiscEv = self.input.handleMiscEvNTX
            self.input.isNTXAccelHooked = true
        end
    end
end

function Kobo:getCodeName()
    -- Try to get it from the env first
    local codename = os.getenv("PRODUCT")
    -- If that fails, run the script ourselves
    if not codename then
        local std_out = io.popen("/bin/kobo_config.sh 2>/dev/null", "re")
        codename = std_out:read("*line")
        std_out:close()
    end
    return codename
end

function Kobo:getFirmwareVersion()
    local version_file = io.open("/mnt/onboard/.kobo/version", "re")
    if not version_file then
        self.firmware_rev = "none"
    end
    local version_str = version_file:read("*line")
    version_file:close()

    local i = 0
    for field in util.gsplit(version_str, ",", false, false) do
        i = i + 1
        if (i == 3) then
             self.firmware_rev = field
        end
    end
end

local function getProductId()
    -- Try to get it from the env first (KSM only)
    local product_id = os.getenv("MODEL_NUMBER")
    -- If that fails, devise it ourselves
    if not product_id then
        local version_file = io.open("/mnt/onboard/.kobo/version", "re")
        if not version_file then
            return "000"
        end
        local version_str = version_file:read("*line")
        version_file:close()

        product_id = string.sub(version_str, -3, -1)
    end

    return product_id
end

function Kobo:checkUnexpectedWakeup()
    local UIManager = require("ui/uimanager")
    -- just in case other events like SleepCoverClosed also scheduled a suspend
    UIManager:unschedule(Kobo.suspend)

    -- Do an initial validation to discriminate unscheduled wakeups happening *outside* of the alarm proximity window.
    if WakeupMgr:isWakeupAlarmScheduled() and WakeupMgr:validateWakeupAlarmByProximity() then
        logger.info("Kobo suspend: scheduled wakeup.")
        local res = WakeupMgr:wakeupAction()
        if not res then
            logger.err("Kobo suspend: wakeup action failed.")
        end
        logger.info("Kobo suspend: putting device back to sleep.")
        -- Most wakeup actions are linear, but we need some leeway for the
        -- poweroff action to send out close events to all requisite widgets.
        UIManager:scheduleIn(30, Kobo.suspend, self)
    else
        logger.dbg("Kobo suspend: checking unexpected wakeup:",
                   self.unexpected_wakeup_count)
        if self.unexpected_wakeup_count == 0 or self.unexpected_wakeup_count > 20 then
            -- Don't put device back to sleep under the following two cases:
            --   1. a resume event triggered Kobo:resume() function
            --   2. trying to put device back to sleep more than 20 times after unexpected wakeup
            -- Broadcast a specific event, so that AutoSuspend can pick up the baton...
            local Event = require("ui/event")
            UIManager:broadcastEvent(Event:new("UnexpectedWakeupLimit"))
            return
        end

        logger.err("Kobo suspend: putting device back to sleep. Unexpected wakeups:",
                   self.unexpected_wakeup_count)
        Kobo:suspend()
    end
end

function Kobo:getUnexpectedWakeup() return self.unexpected_wakeup_count end

--- The function to put the device into standby, with enabled touchscreen.
-- max_duration ... maximum time for the next standby, can wake earlier (e.g. Tap, Button ...)
function Kobo:standby(max_duration)
    -- just for wake up, dummy function
    local function dummy() end

    if max_duration then
        self.wakeup_mgr:addTask(max_duration, dummy)
    end

    local TimeVal = require("ui/timeval")
    local standby_time_tv = TimeVal:boottime_or_realtime_coarse()

    local ret = writeToSys("standby", "/sys/power/state")

    self.last_standby_tv = TimeVal:boottime_or_realtime_coarse() - standby_time_tv
    self.total_standby_tv = self.total_standby_tv + self.last_standby_tv

    logger.info("Kobo suspend: asked the kernel to put subsystems to standby, ret:", ret)

    if max_duration then
        self.wakeup_mgr:removeTask(nil, nil, dummy)
    end
end

function Kobo:suspend()
    logger.info("Kobo suspend: going to sleep . . .")
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(self.checkUnexpectedWakeup)
    local f, re, err_msg, err_code
    -- NOTE: Sleep as little as possible here, sleeping has a tendency to make
    -- everything mysteriously hang...

    -- Depending on device/FW version, some kernels do not support
    -- wakeup_count, account for that
    --
    -- NOTE: ... and of course, it appears to be broken, which probably
    -- explains why nickel doesn't use this facility...
    -- (By broken, I mean that the system wakes up right away).
    -- So, unless that changes, unconditionally disable it.

    --[[

    local has_wakeup_count = false
    f = io.open("/sys/power/wakeup_count", "re")
    if f ~= nil then
        f:close()
        has_wakeup_count = true
    end

    -- Clear the kernel ring buffer... (we're missing a proper -C flag...)
    --dmesg -c >/dev/null

    -- Go to sleep
    local curr_wakeup_count
    if has_wakeup_count then
        curr_wakeup_count = "$(cat /sys/power/wakeup_count)"
        logger.info("Kobo suspend: Current WakeUp count:", curr_wakeup_count)
    end

    -]]

    -- NOTE: Sets gSleep_Mode_Suspend to 1. Used as a flag throughout the
    -- kernel to suspend/resume various subsystems
    -- cf. kernel/power/main.c @ L#207
    local ret = writeToSys("1", "/sys/power/state-extended")
    logger.info("Kobo suspend: asked the kernel to put subsystems to sleep, ret:", ret)

    util.sleep(2)
    logger.info("Kobo suspend: waited for 2s because of reasons...")

    os.execute("sync")
    logger.info("Kobo suspend: synced FS")

    --[[

    if has_wakeup_count then
        f = io.open("/sys/power/wakeup_count", "we")
        if not f then
            logger.err("cannot open /sys/power/wakeup_count")
            return false
        end
        re, err_msg, err_code = f:write(tostring(curr_wakeup_count), "\n")
        logger.info("Kobo suspend: wrote WakeUp count:", curr_wakeup_count)
        if not re then
            logger.err("Kobo suspend: failed to write WakeUp count:",
                       err_msg,
                       err_code)
        end
        f:close()
    end

    --]]

    logger.info("Kobo suspend: asking for a suspend to RAM . . .")
    f = io.open("/sys/power/state", "we")
    if not f then
        -- reset state-extend back to 0 since we are giving up
        local ext_fd = io.open("/sys/power/state-extended", "we")
        if not ext_fd then
            logger.err("cannot open /sys/power/state-extended for writing!")
        else
            ext_fd:write("0\n")
            ext_fd:close()
        end
        return false
    end

    local TimeVal = require("ui/timeval")
    local suspend_time_tv = TimeVal:boottime_or_realtime_coarse()

    re, err_msg, err_code = f:write("mem\n")
    if not re then
        logger.err("write error: ", err_msg, err_code)
    end
    f:close()

    -- NOTE: At this point, we *should* be in suspend to RAM, as such,
    -- execution should only resume on wakeup...

    self.last_suspend_tv = TimeVal:boottime_or_realtime_coarse() - suspend_time_tv
    self.total_suspend_tv = self.total_suspend_tv + self.last_suspend_tv

    logger.info("Kobo suspend: ZzZ ZzZ ZzZ? Write syscall returned: ", re)
    -- NOTE: Ideally, we'd need a way to warn the user that suspending
    -- gloriously failed at this point...
    -- We can safely assume that just from a non-zero return code, without
    -- looking at the detailed stderr message
    -- (most of the failures we'll see are -EBUSY anyway)
    -- For reference, when that happens to nickel, it appears to keep retrying
    -- to wakeup & sleep ad nauseam,
    -- which is where the non-sensical 1 -> mem -> 0 loop idea comes from...
    -- cf. nickel_suspend_strace.txt for more details.

    logger.info("Kobo suspend: woke up!")

    --[[

    if has_wakeup_count then
        logger.info("wakeup count: $(cat /sys/power/wakeup_count)")
    end

    -- Print tke kernel log since our attempt to sleep...
    --dmesg -c

    --]]

    -- NOTE: We unflag /sys/power/state-extended in Kobo:resume() to keep
    -- things tidy and easier to follow

    -- Kobo:resume() will reset unexpected_wakeup_count = 0 to signal an
    -- expected wakeup, which gets checked in checkUnexpectedWakeup().
    self.unexpected_wakeup_count = self.unexpected_wakeup_count + 1
    -- assuming Kobo:resume() will be called in 15 seconds
    logger.dbg("Kobo suspend: scheduling unexpected wakeup guard")
    UIManager:scheduleIn(15, self.checkUnexpectedWakeup, self)
end

function Kobo:resume()
    logger.info("Kobo resume: clean up after wakeup")
    -- reset unexpected_wakeup_count ASAP
    self.unexpected_wakeup_count = 0
    require("ui/uimanager"):unschedule(self.checkUnexpectedWakeup)

    -- Now that we're up, unflag subsystems for suspend...
    -- NOTE: Sets gSleep_Mode_Suspend to 0. Used as a flag throughout the
    -- kernel to suspend/resume various subsystems
    -- cf. kernel/power/main.c @ L#207

    local ret = writeToSys("0", "/sys/power/state-extended")
    logger.info("Kobo resume: unflagged kernel subsystems for resume, ret:", ret)

    -- HACK: wait a bit (0.1 sec) for the kernel to catch up
    util.usleep(100000)

    if self.hasIRGrid then
        -- cf. #1862, I can reliably break IR touch input on resume...
        -- cf. also #1943 for the rationale behind applying this workaorund in every case...
        writeToSys("a", "/sys/devices/virtual/input/input1/neocmd")
    end

    -- A full suspend may have toggled the LED off.
    self:setupChargingLED()
end

function Kobo:saveSettings()
    -- save frontlight state to G_reader_settings (and NickelConf if needed)
    self.powerd:saveSettings()
end

function Kobo:powerOff()
    -- Much like Nickel itself, disable the RTC alarm before powering down.
    WakeupMgr:unsetWakeupAlarm()

    -- Then shut down without init's help
    os.execute("poweroff -f")
end

function Kobo:reboot()
    os.execute("reboot")
end

function Kobo:toggleGSensor(toggle)
    if self:canToggleGSensor() and self.input then
        -- Currently only supported on the Forma
        if self.misc_ntx_gsensor_protocol then
            self.input:toggleMiscEvNTX(toggle)
        end
    end
end

function Kobo:toggleChargingLED(toggle)
    if not self:canToggleChargingLED() then
        return
    end

    -- We have no way of querying the current state from the HW!
    if toggle == nil then
        return
    end

    -- NOTE: While most/all Kobos actually have a charging LED, and it can usually be fiddled with in a similar fashion,
    --       we've seen *extremely* weird behavior in the past when playing with it on older devices (c.f., #5479).
    --       In fact, Nickel itself doesn't provide this feature on said older devices
    --       (when it does, it's an option in the Energy saving settings),
    --       which is why we also limit ourselves to "true" on devices where this was tested.
    -- c.f., drivers/misc/ntx_misc_light.c
    local f = io.open("/sys/devices/platform/ntx_led/lit", "we")
    if not f then
        logger.err("cannot open /sys/devices/platform/ntx_led/lit for writing!")
        return false
    end

    -- c.f., strace -fittvyy -e trace=ioctl,file,signal,ipc,desc -s 256 -o /tmp/nickel.log -p $(pidof -s nickel) &
    -- This was observed on a Forma, so I'm mildly hopeful that it's safe on other Mk. 7 devices ;).
    -- NOTE: ch stands for channel, cur for current, dc for duty cycle. c.f., the driver source.
    if toggle == true then
        -- NOTE: Technically, Nickel forces a toggle off before that, too.
        --       But since we do that on startup, it shouldn't be necessary here...
        if self:isSunxi() then
            f:write("ch 3")
            f:flush()
            f:write("cur 1")
            f:flush()
            f:write("dc 63")
            f:flush()
        end
        f:write("ch 4")
        f:flush()
        f:write("cur 1")
        f:flush()
        f:write("dc 63")
        f:flush()
    else
        f:write("ch 3")
        f:flush()
        f:write("cur 1")
        f:flush()
        f:write("dc 0")
        f:flush()
        f:write("ch 4")
        f:flush()
        f:write("cur 1")
        f:flush()
        f:write("dc 0")
        f:flush()
        f:write("ch 5")
        f:flush()
        f:write("cur 1")
        f:flush()
        f:write("dc 0")
        f:flush()
    end

    f:close()
end

-- Return the highest core number
local function getCPUCount()
    local fd = io.open("/sys/devices/system/cpu/possible", "re")
    if fd then
        local str = fd:read("*line")
        fd:close()

        -- Format is n-N, where n is the first core, and N the last (e.g., 0-3)
        return tonumber(str:match("%d+$")) or 0
    else
        return 0
    end
end

function Kobo:enableCPUCores(amount)
    if not self:isSMP() then
        return
    end

    if not self.cpu_count then
        self.cpu_count = getCPUCount()
    end

    -- Not actually SMP or getCPUCount failed...
    if self.cpu_count == 0 then
        return
    end

    -- CPU0 is *always* online ;).
    for n=1, self.cpu_count do
        local path = "/sys/devices/system/cpu/cpu" .. n .. "/online"
        local up
        if n >= amount then
            up = "0"
        else
            up = "1"
        end

        local f = io.open(path, "we")
        if f then
            f:write(up)
            f:close()
        end
    end
end

function Kobo:isStartupScriptUpToDate()
    -- Compare the hash of the *active* script (i.e., the one in /tmp) to the *potential* one (i.e., the one in KOREADER_DIR)
    local current_script = "/tmp/koreader.sh"
    local new_script = os.getenv("KOREADER_DIR") .. "/" .. "koreader.sh"

    local md5 = require("ffi/MD5")
    return md5.sumFile(current_script) == md5.sumFile(new_script)
end

-------------- device probe ------------

local codename = Kobo:getCodeName()
local product_id = getProductId()

if codename == "dahlia" then
    return KoboDahlia
elseif codename == "dragon" then
    return KoboDragon
elseif codename == "kraken" then
    return KoboKraken
elseif codename == "phoenix" then
    return KoboPhoenix
elseif codename == "trilogy" then
    return KoboTrilogy
elseif codename == "pixie" then
    return KoboPixie
elseif codename == "alyssum" then
    return KoboAlyssum
elseif codename == "pika" then
    return KoboPika
elseif codename == "star" and product_id == "379" then
    return KoboStarRev2
elseif codename == "star" then
    return KoboStar
elseif codename == "daylight" then
    return KoboDaylight
elseif codename == "snow" and product_id == "378" then
    return KoboSnowRev2
elseif codename == "snow" then
    return KoboSnow
elseif codename == "nova" then
    return KoboNova
elseif codename == "frost" then
    return KoboFrost
elseif codename == "storm" then
    return KoboStorm
elseif codename == "luna" then
    return KoboLuna
elseif codename == "europa" then
    return KoboEuropa
elseif codename == "cadmus" then
    return KoboCadmus
elseif codename == "io" then
    return KoboIo
else
    error("unrecognized Kobo model "..codename)
end
