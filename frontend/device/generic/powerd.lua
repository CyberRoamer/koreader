local UIManager -- will be updated when available
local Math = require("optmath")
local TimeVal = require("ui/timeval")
local logger = require("logger")
local BasePowerD = {
    fl_min = 0,                       -- min frontlight intensity
    fl_max = 10,                      -- max frontlight intensity
    fl_intensity = nil,               -- frontlight intensity
    fl_warmth_min = 0,                -- min warmth level
    fl_warmth_max = 100,              -- max warmth level
    fl_warmth = nil,                  -- warmth level
    batt_capacity = 0,                -- battery capacity
    aux_batt_capacity = 0,            -- auxiliary battery capacity
    device = nil,                     -- device object

    last_capacity_pull_time = TimeVal:new{ sec = -61, usec = 0},      -- timestamp of last pull
    last_aux_capacity_pull_time = TimeVal:new{ sec = -61, usec = 0},  -- timestamp of last pull

    is_fl_on = false,                 -- whether the frontlight is on
}

function BasePowerD:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    assert(o.fl_min < o.fl_max)
    if o.init then o:init() end
    if o.device and o.device:hasFrontlight() then
        o.fl_intensity = o:frontlightIntensityHW()
        o:_decideFrontlightState()
    end
    --- @note: Post-init, as the min/max values may be computed at runtime on some platforms
    assert(o.fl_warmth_min < o.fl_warmth_max)
    -- For historical reasons, the *public* PowerD warmth API always expects warmth to be in the [0...100] range...
    self.warmth_scale = 100 / o.fl_warmth_max
    --- @note: Some platforms cannot actually read fl/warmth level from the HW,
    --         in which case the implementation should just return self.fl_warmth (c.f., kobo).
    if o.device and o.device:hasNaturalLight() then
        o.fl_warmth = o:frontlightWarmthHW()
    end
    return o
end

function BasePowerD:readyUI()
    UIManager = require("ui/uimanager")
end

function BasePowerD:init() end
function BasePowerD:setIntensityHW(intensity) end
--- @note: Unlike the "public" setWarmth, this one takes a value in the *native* scale!
function BasePowerD:setWarmthHW(warmth) end
function BasePowerD:getCapacityHW() return 0 end
function BasePowerD:getAuxCapacityHW() return 0 end
function BasePowerD:isAuxBatteryConnectedHW() return false end
function BasePowerD:getDismissBatteryStatus() return self.battery_warning end
function BasePowerD:setDismissBatteryStatus(status) self.battery_warning = status end
function BasePowerD:isChargingHW() return false end
function BasePowerD:isAuxChargingHW() return false end
function BasePowerD:frontlightIntensityHW() return 0 end
function BasePowerD:isFrontlightOnHW() return self.fl_intensity > self.fl_min end
function BasePowerD:turnOffFrontlightHW() self:setIntensityHW(self.fl_min) end
function BasePowerD:turnOnFrontlightHW() self:setIntensityHW(self.fl_intensity) end --- @fixme: what if fl_intensity == fl_min (c.f., kindle)?
function BasePowerD:frontlightWarmthHW() return 0 end
-- Anything that needs to be done before doing a real hardware suspend.
-- (Such as turning the front light off).
function BasePowerD:beforeSuspend() end
-- Anything that needs to be done after doing a real hardware resume.
-- (Such as restoring front light state).
function BasePowerD:afterResume() end

function BasePowerD:isFrontlightOn()
    assert(self ~= nil)
    return self.is_fl_on
end

function BasePowerD:_decideFrontlightState()
    assert(self ~= nil)
    assert(self.device:hasFrontlight())
    self.is_fl_on = self:isFrontlightOnHW()
end

function BasePowerD:isFrontlightOff()
    return not self:isFrontlightOn()
end

function BasePowerD:frontlightIntensity()
    assert(self ~= nil)
    if not self.device:hasFrontlight() then return 0 end
    if self:isFrontlightOff() then return 0 end
    --- @note: We assume that nothing other than us will set the frontlight level,
    ---        so we only actually query the HW during initialization.
    ---        (Also, some platforms do not actually have any way of querying the HW).
    return self.fl_intensity
end

function BasePowerD:toggleFrontlight()
    assert(self ~= nil)
    if not self.device:hasFrontlight() then return false end
    if self:isFrontlightOn() then
        return self:turnOffFrontlight()
    else
        return self:turnOnFrontlight()
    end
end

function BasePowerD:turnOffFrontlight()
    assert(self ~= nil)
    if not self.device:hasFrontlight() then return end
    if self:isFrontlightOff() then return false end
    self:turnOffFrontlightHW()
    self.is_fl_on = false
    self:stateChanged()
    return true
end

function BasePowerD:turnOnFrontlight()
    assert(self ~= nil)
    if not self.device:hasFrontlight() then return end
    if self:isFrontlightOn() then return false end
    if self.fl_intensity == self.fl_min then return false end  --- @fixme what the hell?
    self:turnOnFrontlightHW()
    self.is_fl_on = true
    self:stateChanged()
    return true
end

function BasePowerD:frontlightWarmth()
    assert(self ~= nil)
    if not self.device:hasNaturalLight() then
        return 0
    end
    --- @note: No live query, much like frontlightIntensity
    return self.fl_warmth
end

function BasePowerD:read_int_file(file)
    local fd = io.open(file, "r")
    if fd then
        local int = fd:read("*number")
        fd:close()
        return int or 0
    else
        return 0
    end
end

function BasePowerD:unchecked_read_int_file(file)
    local fd = io.open(file, "r")
    if fd then
        local int = fd:read("*number")
        fd:close()
        return int
    else
        return
    end
end

function BasePowerD:read_str_file(file)
    local fd = io.open(file, "r")
    if fd then
        local str = fd:read("*line")
        fd:close()
        return str
    else
        return ""
    end
end

function BasePowerD:normalizeIntensity(intensity)
    intensity = intensity < self.fl_min and self.fl_min or intensity
    return intensity > self.fl_max and self.fl_max or intensity
end

--- @note: Takes an intensity in the native scale (i.e., [self.fl_min, self.fl_max])
function BasePowerD:setIntensity(intensity)
    if not self.device:hasFrontlight() then return false end
    if intensity == self:frontlightIntensity() then return false end
    self.fl_intensity = self:normalizeIntensity(intensity)
    self:_decideFrontlightState()
    logger.dbg("set light intensity", self.fl_intensity)
    self:setIntensityHW(self.fl_intensity)
    self:stateChanged()
    return true
end

function BasePowerD:normalizeWarmth(warmth)
    warmth = warmth < 0 and 0 or warmth
    return warmth > 100 and 100 or warmth
end

function BasePowerD:toNativeWarmth(ko_warmth)
    return Math.round(ko_warmth / self.warmth_scale)
end

function BasePowerD:fromNativeWarmth(nat_warmth)
    return Math.round(nat_warmth * self.warmth_scale)
end

--- @note: Takes a warmth in the *KOReader* scale (i.e., [0, 100], *sic*)
function BasePowerD:setWarmth(warmth)
    if not self.device:hasNaturalLight() then return false end
    if warmth == self:frontlightWarmth() then return false end
    -- Which means that fl_warmth is *also* in the KOReader scale (unlike fl_intensity)
    self.fl_warmth = self:normalizeWarmth(warmth)
    local nat_warmth = self:toNativeWarmth(self.fl_warmth)
    logger.dbg("set light warmth", self.fl_warmth, "->", nat_warmth)
    self:setWarmthHW(nat_warmth)
    self:stateChanged()
    return true
end

function BasePowerD:getCapacity()
    -- BasePowerD is loaded before UIManager.
    -- Nothing *currently* calls this before UIManager is actually loaded, but future-proof this anyway.
    local now_btv
    if UIManager then
        now_btv = UIManager:getElapsedTimeSinceBoot()
    else
        now_btv = TimeVal:now() + self.device.total_standby_tv -- Add time the device was in standby
    end

    if (now_btv - self.last_capacity_pull_time):tonumber() >= 60 then
        self.batt_capacity = self:getCapacityHW()
        self.last_capacity_pull_time = now_btv
    end
    return self.batt_capacity
end

function BasePowerD:isCharging()
    return self:isChargingHW()
end

function BasePowerD:getAuxCapacity()
    local now_btv

    if UIManager then
        now_btv = UIManager:getElapsedTimeSinceBoot()
    else
        now_btv = TimeVal:now() + self.device.total_standby_tv -- Add time the device was in standby
    end

    if (now_btv - self.last_aux_capacity_pull_time):tonumber() >= 60 then
        local aux_batt_capa = self:getAuxCapacityHW()
        -- If the read failed, don't update our cache, and retry next time.
        if aux_batt_capa then
            self.aux_batt_capacity = aux_batt_capa
            self.last_aux_capacity_pull_time = now_btv
        end
    end
    return self.aux_batt_capacity
end

function BasePowerD:invalidateCapacityCache()
    self.last_capacity_pull_time = TimeVal:new{ sec = -61, usec = 0}
    self.last_aux_capacity_pull_time = TimeVal:new{ sec = -61, usec = 0}
end

function BasePowerD:isAuxCharging()
    return self:isAuxChargingHW()
end

function BasePowerD:isAuxBatteryConnected()
    return self:isAuxBatteryConnectedHW()
end

function BasePowerD:stateChanged()
    -- BasePowerD is loaded before UIManager. So we cannot broadcast events before UIManager has been loaded.
    if UIManager then
        local Event = require("ui/event")
        UIManager:broadcastEvent(Event:new("FrontlightStateChanged"))
    end
end

-- Silly helper to avoid code duplication ;).
function BasePowerD:getBatterySymbol(is_charging, capacity)
    if is_charging then
        return ""
    else
        if capacity >= 100 then
            return ""
        elseif capacity >= 90 then
            return ""
        elseif capacity >= 80 then
            return ""
        elseif capacity >= 70 then
            return ""
        elseif capacity >= 60 then
            return ""
        elseif capacity >= 50 then
            return ""
        elseif capacity >= 40 then
            return ""
        elseif capacity >= 30 then
            return ""
        elseif capacity >= 20 then
            return ""
        elseif capacity >= 10 then
            return ""
        else
            return ""
        end
    end
end

return BasePowerD
