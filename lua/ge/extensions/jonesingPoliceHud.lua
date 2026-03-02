-- lua/ge/extensions/jonesingPoliceHud.lua
-- On-screen wanted-level HUD for jonesingPoliceManager.
-- Renders 5 star indicators in the top-right corner using BeamNG's imgui.
-- Stars glow gold at low wanted; pulse orange-red at higher levels.
-- Automatically hidden when wanted heat is zero.

local M = {}
local TAG = "jonesingPoliceHud"

-- Layout
local HUD_W      = 230   -- window width  (px)
local HUD_H      = 75    -- window height (px)
local HUD_MARGIN = 20    -- distance from screen edges (px)
local STAR_R     = 13    -- star circle radius (px)
local STAR_STEP  = 42    -- horizontal gap between star centres (px)
local STAR_Y     = 24    -- star centre Y offset from window top (px)

-- Colours packed as imgui u32 (0xAABBGGRR)
local function rgba(r, g, b, a)
    return bit.bor(
        bit.lshift(a or 255, 24),
        bit.lshift(b,        16),
        bit.lshift(g,         8),
        r)
end

local C_GOLD   = rgba(255, 210,   0, 255)  -- active star
local C_ORANGE = rgba(255,  70,   0, 255)  -- high-level blink
local C_RED    = rgba(220,  20,  20, 255)  -- level-5 blink
local C_DARK   = rgba( 45,  45,  45, 220)  -- inactive fill
local C_RING   = rgba(105, 105, 105, 200)  -- inactive ring

local _ft  = 0   -- flash accumulator
local _pl  = 0   -- previous wanted level (for blink-on-gain)

function M.onPreRender(dt)
    local pm = extensions and extensions.jonesingPoliceManager
    if not pm then return end

    local lvl  = pm.getWantedLevel() or 0
    local heat = pm.getWantedHeat()  or 0
    local pcnt = pm.getPoliceCount() or 0
    local cfg  = pm.getConfig()
    if not cfg or not cfg.enabled then return end

    -- Hide completely when calm
    if lvl == 0 and heat < 0.05 then
        _ft = 0
        return
    end

    _ft = _ft + (dt or 0)

    -- Blink behaviour: faster and redder at higher wanted levels
    local blink = false
    if lvl >= 5 then
        blink = math.sin(_ft * 14) > 0   -- rapid red flash at max wanted
    elseif lvl >= 3 then
        blink = math.sin(_ft * 7) > 0    -- medium pulse
    end

    -- Screen size (safe fallback)
    local sw = 1920
    local ok, io_ = pcall(function() return im.GetIO() end)
    if ok and io_ and io_.DisplaySize then
        sw = io_.DisplaySize.x or sw
    end

    im.SetNextWindowPos(im.ImVec2(sw - HUD_W - HUD_MARGIN, HUD_MARGIN), im.Cond_Always)
    im.SetNextWindowSize(im.ImVec2(HUD_W, HUD_H), im.Cond_Always)
    im.SetNextWindowBgAlpha(0.85)

    local wflags = bit.bor(
        im.WindowFlags_NoTitleBar,
        im.WindowFlags_NoResize,
        im.WindowFlags_NoMove,
        im.WindowFlags_NoScrollbar,
        im.WindowFlags_NoSavedSettings,
        im.WindowFlags_NoBringToFrontOnFocus)

    if im.Begin("JonesingWantedHUD", nil, wflags) then
        local dl = im.GetWindowDrawList()
        local wp = im.GetWindowPos()

        -- Draw 5 star circles directly on the draw list
        for i = 1, 5 do
            local cx  = wp.x + 22 + (i - 1) * STAR_STEP
            local ctr = im.ImVec2(cx, wp.y + STAR_Y)

            if i <= lvl then
                -- Active: choose colour based on level / blink
                local col
                if blink then
                    col = (lvl >= 5) and C_RED or C_ORANGE
                else
                    col = C_GOLD
                end
                dl:AddCircleFilled(ctr, STAR_R, col, 20)
            else
                -- Inactive: dark fill + subtle ring
                dl:AddCircleFilled(ctr, STAR_R, C_DARK, 20)
                dl:AddCircle(ctr, STAR_R, C_RING, 20, 1.5)
            end
        end

        -- Advance the imgui cursor below the hand-drawn stars
        im.Dummy(im.ImVec2(1, STAR_Y + STAR_R + 4))

        -- Status text
        local txt
        if lvl > 0 then
            txt = string.format(" WANTED %d  |  %d cop%s",
                lvl, pcnt, pcnt == 1 and "" or "s")
            im.PushStyleColor2(im.Col_Text, im.ImVec4(1.0, 1.0, 0.80, 0.95))
        else
            -- Sub-star heat indicator
            local pct = math.min(99, (heat - math.floor(heat)) * 100)
            txt = string.format(" accumulating... %d%%", pct)
            im.PushStyleColor2(im.Col_Text, im.ImVec4(0.72, 0.72, 0.72, 0.75))
        end
        im.Text(txt)
        im.PopStyleColor()
    end
    im.End()

    _pl = lvl
end

function M.onExtensionLoaded()
    log("I", TAG, "Jonesing Police HUD loaded – will render when wanted heat > 0.")
end

return M
