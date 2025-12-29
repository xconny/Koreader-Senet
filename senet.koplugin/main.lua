--[[
Senet Plugin for KOReader

Two-player ancient Egyptian race/capture game on a 30-square board.
(See full rules in earlier comments / documentation.)
--]]

local _              = require("gettext")
local Geom           = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup  = require("ui/widget/verticalgroup")
local VerticalSpan   = require("ui/widget/verticalspan")
local ButtonTable    = require("ui/widget/buttontable")
local CenterContainer= require("ui/widget/container/centercontainer")
local Size           = require("ui/size")
local UIManager      = require("ui/uimanager")
local InfoMessage    = require("ui/widget/infomessage")
local GestureRange   = require("ui/gesturerange")
local Device         = require("device")
local Screen         = Device.screen
local Blitbuffer     = require("ffi/blitbuffer")
local RenderText     = require("ui/rendertext")
local Font           = require("ui/font")
local TextWidget     = require("ui/widget/textwidget")
local DataStorage    = require("datastorage")
local LuaSettings    = require("luasettings")
local json           = require("json")
local logger         = require("logger")
local T              = require("ffi/util").template

--------------------------------------------------------------------------------
-- Model: SenetBoard
--------------------------------------------------------------------------------

local BOARD_HOUSES      = 30
local PLAYER1           = 1
local PLAYER2           = 2
local AI_PLAYER         = PLAYER2

local SPECIAL_REBIRTH   = 15
local SPECIAL_HAPPINESS = 26
local SPECIAL_WATER     = 27
local SPECIAL_TRUTHS    = 28
local SPECIAL_RE_ATUM   = 29

-- Unicode icons for special houses
local SPECIAL_ICONS = {
    [SPECIAL_REBIRTH]   = "☥", -- House of Rebirth
    [SPECIAL_HAPPINESS] = "✺", -- House of Happiness
    [SPECIAL_WATER]     = "≋", -- House of Water
    [SPECIAL_TRUTHS]    = "✸", -- House of Three Truths
    [SPECIAL_RE_ATUM]   = "✶", -- House of Re-Atum
}

local SenetBoard = {}
SenetBoard.__index = SenetBoard

function SenetBoard:new()
    local o = {
        cells = {},             -- 1..30: 0 empty, 1 player1, 2 player2
        current_player = PLAYER1,
        winner = nil,
        game_over = false,
        pieces_off = { [PLAYER1] = 0, [PLAYER2] = 0 },
        last_roll = nil,
        last_extra = false,
    }
    setmetatable(o, self)
    o:reset()
    return o
end

function SenetBoard:reset()
    for i = 1, BOARD_HOUSES do
        self.cells[i] = 0
    end
    -- Player 1 on 1,3,5,7,9
    for pos = 1, 9, 2 do
        self.cells[pos] = PLAYER1
    end
    -- Player 2 on 2,4,6,8,10
    for pos = 2, 10, 2 do
        self.cells[pos] = PLAYER2
    end

    self.current_player = PLAYER1
    self.winner = nil
    self.game_over = false
    self.pieces_off[PLAYER1] = 0
    self.pieces_off[PLAYER2] = 0
    self.last_roll = nil
    self.last_extra = false
end

function SenetBoard:getCell(pos)
    return self.cells[pos]
end

function SenetBoard:getCurrentPlayer()
    return self.current_player
end

function SenetBoard:getPiecesOff(player)
    return self.pieces_off[player] or 0
end

function SenetBoard:isGameOver()
    return self.game_over
end

function SenetBoard:switchPlayer()
    if self.current_player == PLAYER1 then
        self.current_player = PLAYER2
    else
        self.current_player = PLAYER1
    end
end

-- Four-stick "finger" throw.
-- Returns (steps, extra_turn, color_count).
function SenetBoard:throwSticks()
    local colors = 0
    for _i = 1, 4 do
        if math.random(0, 1) == 1 then
            colors = colors + 1
        end
    end
    local steps
    if colors == 0 then
        steps = 5
    else
        steps = colors
    end
    local extra = (steps == 1 or steps == 4 or steps == 5)
    self.last_roll = steps
    self.last_extra = extra
    return steps, extra, colors
end

local function isProtected(cells, pos)
    local owner = cells[pos]
    if owner == 0 or owner == nil then
        return false
    end
    local left  = (pos > 1)            and cells[pos - 1] or 0
    local right = (pos < BOARD_HOUSES) and cells[pos + 1] or 0
    return (left == owner) or (right == owner)
end

function SenetBoard:postMoveTriggers()
    -- House of Water → House of Rebirth when Rebirth becomes free.
    local water_piece = self.cells[SPECIAL_WATER]
    if water_piece ~= 0 and self.cells[SPECIAL_REBIRTH] == 0 then
        self.cells[SPECIAL_WATER] = 0
        self.cells[SPECIAL_REBIRTH] = water_piece
    end
end

function SenetBoard:canMove(start_pos, steps, player)
    player = player or self.current_player

    if self.game_over then
        return false, "game_over"
    end
    if steps <= 0 then
        return false, "no_steps"
    end
    if start_pos < 1 or start_pos > BOARD_HOUSES then
        return false, "invalid_start"
    end
    if self.cells[start_pos] ~= player then
        return false, "not_your_piece"
    end

    -- House of Water: if you're sitting there while Rebirth is occupied, you must wait.
    if start_pos == SPECIAL_WATER and self.cells[SPECIAL_REBIRTH] ~= 0 then
        return false, "water_wait"
    end

    local raw_dest = start_pos + steps

    -- Barrier of 3+ opponent pieces: cannot jump over.
    local opponent = (player == PLAYER1) and PLAYER2 or PLAYER1
    local run_start = nil
    local run_len = 0
    for i = 1, BOARD_HOUSES + 1 do
        local v = (i <= BOARD_HOUSES) and self.cells[i] or 0
        if v == opponent then
            if not run_start then
                run_start = i
            end
            run_len = run_len + 1
        else
            if run_start and run_len >= 3 then
                local run_end = i - 1
                if start_pos < run_start and raw_dest > run_end then
                    return false, "blocked_by_barrier"
                end
            end
            run_start = nil
            run_len = 0
        end
    end

    -- Exit-only logic for 28–30: once there, you may only roll off.
    if start_pos == SPECIAL_TRUTHS then
        if steps == 3 then
            return true, { offboard = true, start_pos = start_pos }
        else
            return false, "need_three_from_28"
        end
    elseif start_pos == SPECIAL_RE_ATUM then
        if steps == 2 then
            return true, { offboard = true, start_pos = start_pos }
        else
            return false, "need_two_from_29"
        end
    elseif start_pos == BOARD_HOUSES then
        if steps == 1 then
            return true, { offboard = true, start_pos = start_pos }
        else
            return false, "need_one_from_30"
        end
    end

    -- House of Happiness: cannot jump from below 26 directly beyond it
    -- to 28–30 (but may still land on 27/Water).
    if start_pos < SPECIAL_HAPPINESS
       and raw_dest > SPECIAL_HAPPINESS
       and raw_dest ~= SPECIAL_WATER then
        return false, "cannot_jump_over_26"
    end

    -- From 26 you cannot exit directly (26 + steps > 30).
    if start_pos == SPECIAL_HAPPINESS and raw_dest > BOARD_HOUSES then
        return false, "cannot_exit_from_26"
    end

    -- Off-board from any other squares is not allowed.
    if raw_dest > BOARD_HOUSES then
        return false, "cannot_exit_from_here"
    end

    -- Water logic: landing may redirect to 15 or wait on 27.
    local final_dest
    if raw_dest == SPECIAL_WATER then
        if self.cells[SPECIAL_REBIRTH] ~= 0 then
            -- Rebirth occupied: we can only occupy Water if it is free.
            if self.cells[SPECIAL_WATER] ~= 0 then
                return false, "water_blocked"
            end
            final_dest = SPECIAL_WATER
        else
            -- Rebirth free: fall back to 15.
            final_dest = SPECIAL_REBIRTH
        end
    else
        final_dest = raw_dest
    end

    if not final_dest or final_dest < 1 or final_dest > BOARD_HOUSES then
        return false, "invalid_dest"
    end

    local occupant = self.cells[final_dest]

    -- Protected houses: 15, 26, 28–30
    if (final_dest == SPECIAL_REBIRTH or
        final_dest == SPECIAL_HAPPINESS or
        final_dest == SPECIAL_TRUTHS or
        final_dest == SPECIAL_RE_ATUM or
        final_dest == BOARD_HOUSES) then
        if occupant ~= 0 and occupant ~= player then
            return false, "protected_house"
        end
    end

    if occupant == player then
        return false, "own_piece_block"
    end

    local capture = false
    if occupant ~= 0 then
        if isProtected(self.cells, final_dest) then
            return false, "protected_piece"
        else
            capture = true
        end
    end

    return true, {
        offboard      = false,
        start_pos     = start_pos,
        final_dest    = final_dest,
        capture       = capture,
        captured_from = capture and final_dest or nil,
    }
end

function SenetBoard:move(start_pos, steps)
    local player = self.current_player
    local ok, info_or_reason = self:canMove(start_pos, steps, player)
    if not ok then
        return false, info_or_reason
    end
    local info = info_or_reason

    self.cells[start_pos] = 0

    if info.offboard then
        self.pieces_off[player] = (self.pieces_off[player] or 0) + 1
    else
        local dest = info.final_dest
        local prev = self.cells[dest]

        if prev ~= 0 and prev ~= player then
            self.cells[start_pos] = prev
        end

        self.cells[dest] = player
    end

    self:postMoveTriggers()

    if self.pieces_off[player] >= 5 then
        self.game_over = true
        self.winner = player
    end

    return true, info
end

function SenetBoard:getLegalMoves(steps)
    local player = self.current_player
    local moves = {}
    for pos = 1, BOARD_HOUSES do
        if self.cells[pos] == player then
            local ok, info = self:canMove(pos, steps, player)
            if ok then
                table.insert(moves, {
                    from     = pos,
                    to       = info.offboard and 0 or info.final_dest,
                    offboard = info.offboard,
                })
            end
        end
    end
    return moves
end

function SenetBoard:serialize()
    local cells_copy = {}
    for i = 1, BOARD_HOUSES do
        cells_copy[i] = self.cells[i] or 0
    end
    return {
        cells          = cells_copy,
        current_player = self.current_player,
        winner         = self.winner,
        game_over      = self.game_over,
        pieces_off     = {
            [PLAYER1] = self.pieces_off[PLAYER1] or 0,
            [PLAYER2] = self.pieces_off[PLAYER2] or 0,
        },
        last_roll      = self.last_roll,
        last_extra     = self.last_extra,
    }
end

function SenetBoard:load(state)
    if not state then
        return
    end
    if state.cells then
        for i = 1, BOARD_HOUSES do
            self.cells[i] = state.cells[i] or 0
        end
    end
    self.current_player = state.current_player or PLAYER1
    self.winner         = state.winner
    self.game_over      = state.game_over or false
    self.pieces_off[PLAYER1] = (state.pieces_off and state.pieces_off[PLAYER1]) or 0
    self.pieces_off[PLAYER2] = (state.pieces_off and state.pieces_off[PLAYER2]) or 0
    self.last_roll = state.last_roll
    self.last_extra = state.last_extra or false
end

--------------------------------------------------------------------------------
-- View: SenetGrid (board)
--------------------------------------------------------------------------------

local ROWS = 3
local COLS = 10

local SenetGrid = InputContainer:extend{
    board = nil,
}

local function posToRowCol(pos)
    if pos >= 1 and pos <= 10 then
        return 1, pos
    elseif pos >= 11 and pos <= 20 then
        return 2, 21 - pos
    else
        return 3, pos - 20
    end
end

local function rowColToPos(row, col)
    if row == 1 then
        return col
    elseif row == 2 then
        return 21 - col
    else
        return 20 + col
    end
end

function SenetGrid:init()
    self:computeGeometry()

    -- Dynamically choose the largest circle font that still fits inside
    -- the cell on this device, with a small margin.
    local base = math.min(self.cell_w, self.cell_h)
    local target_size = math.max(20, math.floor(base * 0.6))
    local max_w = self.cell_w - 4
    local max_h = self.cell_h - 4
    local size = target_size
    local face = Font:getFace("cfont", size)
    local metrics = RenderText:sizeUtf8Text(0, self.cell_h, face, "●", true, false)
    local glyph_h = metrics.y_top - metrics.y_bottom

    while (metrics.x > max_w or glyph_h > max_h) and size > 8 do
        size = size - 1
        face = Font:getFace("cfont", size)
        metrics = RenderText:sizeUtf8Text(0, self.cell_h, face, "●", true, false)
        glyph_h = metrics.y_top - metrics.y_bottom
    end

    self.piece_face = face
    self.icon_face  = Font:getFace("cfont", math.max(14, math.floor(base * 0.35)))

    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    return self.paint_rect
                end,
            },
        },
    }
end

function SenetGrid:setBoard(board)
    self.board = board
end

-- Geometry: wide "landscape" board at the top of the screen.
function SenetGrid:computeGeometry()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Board can take ~90% of width, and up to ~45% of height.
    local max_w = math.floor(screen_w * 0.9)
    local max_h = math.floor(screen_h * 0.45)

    local cell_w = math.floor(max_w / COLS)
    if cell_w < 10 then cell_w = 10 end

    -- Start with square-ish cells using width, clamp if too tall.
    local cell_h = cell_w
    if cell_h * ROWS > max_h then
        cell_h = math.floor(max_h / ROWS)
        if cell_h < 10 then cell_h = 10 end
        cell_w = cell_h
    end

    self.cell_w = cell_w
    self.cell_h = cell_h

    local grid_w = self.cell_w * COLS
    local grid_h = self.cell_h * ROWS

    self.dimen = Geom:new{ w = grid_w, h = grid_h }
    self.paint_rect = Geom:new{ x = 0, y = 0, w = grid_w, h = grid_h }
end

function SenetGrid:getPosFromPoint(x, y)
    local rect = self.paint_rect
    local lx = x - rect.x
    local ly = y - rect.y

    if lx < 0 or ly < 0 or lx > rect.w or ly > rect.h then
        return nil
    end

    local col = math.floor(lx / self.cell_w) + 1
    local row = math.floor(ly / self.cell_h) + 1

    if col < 1 or col > COLS or row < 1 or row > ROWS then
        return nil
    end

    return rowColToPos(row, col)
end

function SenetGrid:onTap(_, ges)
    if not (ges and ges.pos and self.onCellTapped) then
        return false
    end
    local pos = self:getPosFromPoint(ges.pos.x, ges.pos.y)
    if not pos then
        return false
    end
    self.onCellTapped(pos)
    return true
end

function SenetGrid:paintTo(bb, x, y)
    self.paint_rect = Geom:new{
        x = x, y = y,
        w = self.dimen.w, h = self.dimen.h,
    }

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)

    local cell_w = self.cell_w
    local cell_h = self.cell_h
    local line_color = Blitbuffer.COLOR_GRAY_8

    -- Outer border
    bb:paintRect(x, y, self.dimen.w, 1, line_color)
    bb:paintRect(x, y + self.dimen.h - 1, self.dimen.w, 1, line_color)
    bb:paintRect(x, y, 1, self.dimen.h, line_color)
    bb:paintRect(x + self.dimen.w - 1, y, 1, self.dimen.h, line_color)

    -- Inner grid lines
    for c = 1, COLS - 1 do
        local gx = x + c * cell_w
        bb:paintRect(gx, y, 1, self.dimen.h, line_color)
    end
    for r = 1, ROWS - 1 do
        local gy = y + r * cell_h
        bb:paintRect(x, gy, self.dimen.w, 1, line_color)
    end

    if not self.board then
        return
    end

    local piece_face = self.piece_face
    local icon_face  = self.icon_face

    for pos = 1, BOARD_HOUSES do
        local row, col = posToRowCol(pos)
        local cell_x = x + (col - 1) * cell_w
        local cell_y = y + (row - 1) * cell_h

        -- Background color for special squares
        local bg_color = Blitbuffer.COLOR_WHITE
        if pos == SPECIAL_REBIRTH or pos == SPECIAL_HAPPINESS then
            bg_color = Blitbuffer.COLOR_LIGHT_GRAY
        elseif pos == SPECIAL_WATER then
            bg_color = Blitbuffer.COLOR_GRAY_7
        elseif pos == SPECIAL_TRUTHS or pos == SPECIAL_RE_ATUM or pos == BOARD_HOUSES then
            -- 28, 29, 30 all same darker shade
            bg_color = Blitbuffer.COLOR_GRAY
        end
        bb:paintRect(cell_x + 1, cell_y + 1, cell_w - 2, cell_h - 2, bg_color)

        -- Draw special icon (if any), centered in the square.
        local icon = SPECIAL_ICONS[pos]
        if icon and icon_face then
            local metrics = RenderText:sizeUtf8Text(0, cell_h, icon_face, icon, true, false)
            local icon_x = cell_x + math.floor((cell_w - metrics.x) / 2)
            local icon_baseline = cell_y + math.floor((cell_h + metrics.y_top - metrics.y_bottom) / 2)
            RenderText:renderUtf8Text(
                bb,
                icon_x,
                icon_baseline,
                icon_face,
                icon,
                true,
                false,
                Blitbuffer.COLOR_BLACK
            )
        end

        -- Draw piece
        local v = self.board:getCell(pos)
        local mark = ""
        if v == PLAYER1 then
            mark = "●"
        elseif v == PLAYER2 then
            mark = "○"
        end
        if mark ~= "" then
            local metrics = RenderText:sizeUtf8Text(0, cell_h, piece_face, mark, true, false)
            local text_x = cell_x + math.floor((cell_w - metrics.x) / 2)
            local baseline = cell_y + math.floor((cell_h + metrics.y_top - metrics.y_bottom) / 2)
            RenderText:renderUtf8Text(
                bb,
                text_x,
                baseline,
                piece_face,
                mark,
                true,
                false,
                Blitbuffer.COLOR_BLACK
            )
        end
    end
end

function SenetGrid:refresh()
    local rect = self.paint_rect
    UIManager:setDirty(self, function()
        return "ui", Geom:new{
            x = rect.x, y = rect.y,
            w = rect.w, h = rect.h,
        }
    end)
end

--------------------------------------------------------------------------------
-- Screen: SenetScreen
--------------------------------------------------------------------------------

local SenetScreen = InputContainer:extend{}

local function playerSymbol(player)
    return (player == PLAYER1) and "●" or "○"
end

-- Used to force visible blank lines (so KOReader actually allocates the height).
local ZERO_WIDTH_SPACE = "\226\128\139" -- U+200B

-- Small padding around bottom button labels.
local BUTTON_PAD = " "  -- 1 space

local MODE_HUMAN_VS_HUMAN = "human_vs_human"
local MODE_VS_AI_EASY     = "vs_ai_easy"
local MODE_VS_AI_NORMAL   = "vs_ai_normal"

-- Button labels (all uppercase) showing active mode
local MODE_LABELS = {
    [MODE_HUMAN_VS_HUMAN] = _("MODE: PLAYER VS PLAYER"),
    [MODE_VS_AI_EASY]     = _("MODE: AI EASY"),
    [MODE_VS_AI_NORMAL]   = _("MODE: AI NORMAL"),
}

function SenetScreen:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.covers_fullscreen = true

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end

    self.board = self.plugin:getBoard()
    self.game_mode = self.plugin:getGameMode()

    self.grid_widget = SenetGrid:new{
        board = self.board,
        onCellTapped = function(pos)
            self:onCellTapped(pos)
        end,
    }

    -- Two-line status: top = main info, bottom = instruction/extra text
    self.status_label_top = TextWidget:new{
        face = Font:getFace("smallinfofont"),
        text = "",
    }
    self.status_label_bottom = TextWidget:new{
        face = Font:getFace("smallinfofont"),
        text = "",
    }

    self.info_label = TextWidget:new{
        face = Font:getFace("smallinfofont"),
        text = "",
    }

    self.pending_steps = nil
    self.extra_turn = false
    self.last_roll = self.board.last_roll

    self:buildLayout()
    self:updateStatusAndInfo(true)

    self:maybeStartAITurn()
end

function SenetScreen:isAITurn()
    return (self.game_mode ~= MODE_HUMAN_VS_HUMAN
        and self.board:getCurrentPlayer() == AI_PLAYER
        and not self.board:isGameOver())
end

function SenetScreen:getAIDifficulty()
    if self.game_mode == MODE_VS_AI_NORMAL then
        return "normal"
    elseif self.game_mode == MODE_VS_AI_EASY then
        return "easy"
    else
        return nil
    end
end

-- Cycle game mode, reset board, rebuild layout with updated button text.
function SenetScreen:cycleGameMode()
    local mode = self.game_mode
    if mode == MODE_HUMAN_VS_HUMAN then
        mode = MODE_VS_AI_EASY
    elseif mode == MODE_VS_AI_EASY then
        mode = MODE_VS_AI_NORMAL
    else
        mode = MODE_HUMAN_VS_HUMAN
    end

    self.game_mode = mode
    self.plugin:setGameMode(mode)

    -- Reset the game whenever mode changes.
    self.board:reset()
    self.pending_steps = nil
    self.extra_turn = false
    self.last_roll = nil
    self.grid_widget:refresh()
    self.plugin.board = self.board
    self.plugin:saveState()

    -- Rebuild layout so the Mode button text updates.
    self:buildLayout()
    self:updateStatusAndInfo(true)
    self:refreshScreen()
    self:maybeStartAITurn()
end

function SenetScreen:buildLayout()
    local grid_frame = FrameContainer:new{
        padding    = Size.padding.large,
        margin     = Size.margin.default,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        self.grid_widget,
    }

    -- Blank lines underneath the board (using ZWSP so they actually take space)
    local blank_after_board_1 = TextWidget:new{
        face = Font:getFace("smallinfofont"),
        text = ZERO_WIDTH_SPACE,
    }
    local blank_after_board_2 = TextWidget:new{
        face = Font:getFace("smallinfofont"),
        text = ZERO_WIDTH_SPACE,
    }

    local status_group = VerticalGroup:new{
        align = "center",
        self.status_label_top,
        self.status_label_bottom,
    }

    local status_frame = FrameContainer:new{
        padding    = Size.padding.small,
        margin     = Size.margin.default,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        status_group,
    }

    local info_frame = FrameContainer:new{
        padding    = Size.padding.small,
        margin     = Size.margin.default,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        self.info_label,
    }

    -- Blank line between info and THROW STICKS
    local blank_between_info_and_throw = TextWidget:new{
        face = Font:getFace("smallinfofont"),
        text = ZERO_WIDTH_SPACE,
    }

    -- Single centered "THROW STICKS" button row
    self.throw_button_table = ButtonTable:new{
        shrink_unneeded_width = true,
        width = math.floor(Screen:getWidth() * 0.6),
        buttons = {
            {
                {
                    text = ZERO_WIDTH_SPACE .. _("THROW STICKS") .. ZERO_WIDTH_SPACE,
                    callback = function()
                        self:onThrow()
                    end,
                },
            },
        },
    }

    -- Wrap Throw sticks in a frame to look like a solid button.
    local throw_frame = FrameContainer:new{
        padding    = Size.padding.small,
        margin     = Size.margin.default,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 1,
        self.throw_button_table,
    }

    -- Two blank lines underneath Throw sticks
    local blank_below_throw_1 = TextWidget:new{
        face = Font:getFace("smallinfofont"),
        text = ZERO_WIDTH_SPACE,
    }
    local blank_below_throw_2 = TextWidget:new{
        face = Font:getFace("smallinfofont"),
        text = ZERO_WIDTH_SPACE,
    }

    -- Bottom row: RESTART | RULES | MODE: ... | CLOSE
    self.bottom_button_table = ButtonTable:new{
        shrink_unneeded_width = true,
        width = math.floor(Screen:getWidth() * 0.9),
        buttons = {
            {
                {
                    text = _("RESTART") .. BUTTON_PAD,
                    callback = function()
                        self:onNewGame()
                    end,
                },
                {
                    text = _("RULES"),
                    callback = function()
                        self:onHelp()
                    end,
                },
                {
                    text = BUTTON_PAD .. (MODE_LABELS[self.game_mode] or _("MODE")) .. BUTTON_PAD,
                    callback = function()
                        self:cycleGameMode()
                    end,
                },
                {
                    text = _("CLOSE"),
                    callback = function()
                        self:onClose()
                    end,
                },
            },
        },
    }

    local content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.span.vertical_small },
        grid_frame,
        blank_after_board_1,
        blank_after_board_2,
        status_frame,
        info_frame,
        blank_between_info_and_throw,
        throw_frame,
        blank_below_throw_1,
        blank_below_throw_2,
        self.bottom_button_table,
        VerticalSpan:new{ width = Size.span.vertical_small },
    }

    content.dimen = self.dimen

    self[1] = CenterContainer:new{
        dimen = self.dimen,
        align = "center",
        content,
    }
end

function SenetScreen:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    InputContainer.paintTo(self, bb, x, y)
end

function SenetScreen:updateStatusAndInfo(initial)
    local player = self.board:getCurrentPlayer()
    local sym = playerSymbol(player)

    if self.board:isGameOver() and self.board.winner then
        local win_sym = playerSymbol(self.board.winner)
        self.status_label_top:setText(T(_("Player %1 wins!"), win_sym))
        self.status_label_bottom:setText("")
    else
        if self.pending_steps then
            -- After a roll
            if self:isAITurn() then
                local line1 = T(_("Player %1 rolled %2."), sym, self.pending_steps)
                local line2 = T(_("They're playing their move of %1."), self.pending_steps)
                self.status_label_top:setText(line1)
                self.status_label_bottom:setText(line2)
            else
                local line1 = T(_("Player %1 rolled %2."), sym, self.pending_steps)
                local line2 = _("Tap a piece to move.")
                self.status_label_top:setText(line1)
                self.status_label_bottom:setText(line2)
            end
        else
            -- No roll yet this turn: two lines
            local line1 = T(_("Player %1's turn."), sym)
            local line2
            if self:isAITurn() then
                line2 = _("They're throwing the sticks.")
            else
                line2 = _("Throw the sticks.")
            end
            self.status_label_top:setText(line1)
            self.status_label_bottom:setText(line2)
        end
    end

    local off1 = self.board:getPiecesOff(PLAYER1)
    local off2 = self.board:getPiecesOff(PLAYER2)
    local roll_text = self.last_roll and T(_("Last throw: %1"), self.last_roll) or _("Last throw: –")
    local off_text  = T(_("Off-board ●: %1   ○: %2"), off1, off2)

    self.info_label:setText(roll_text .. "   ·   " .. off_text)

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function SenetScreen:refreshScreen()
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

-- Centralized handling when the current player has no legal moves.
-- IMPORTANT CHANGE: this now flips the turn *synchronously* before showing the popup.
function SenetScreen:passTurnNoMoves(steps, prefix_text)
    local sym = playerSymbol(self.board:getCurrentPlayer())
    local base_msg = T(_("Player %1 has no legal moves with %2. Turn passes."), sym, steps)
    local full_text = base_msg

    if prefix_text and prefix_text ~= "" then
        full_text = prefix_text .. "\n\n" .. base_msg
    end

    -- Turn logic happens immediately, not in the callback.
    self.pending_steps = nil
    self.extra_turn = false

    if not self.board:isGameOver() then
        self.board:switchPlayer()
    end

    self.plugin.board = self.board
    self.plugin:saveState()
    self:updateStatusAndInfo(false)
    self:refreshScreen()

    -- If the next player is AI, start their turn.
    if self:isAITurn() then
        self:maybeStartAITurn()
    end

    -- Popup is now purely informational.
    local msg = InfoMessage:new{
        text = full_text,
        timeout = 3,
    }
    msg.close_callback = function()
        self:refreshScreen()
    end

    UIManager:show(msg)
end

function SenetScreen:onThrow()
    -- SAFETY: If it's AI's turn and something got stuck, let this button kick the AI logic.
    if self:isAITurn() then
        if not self.pending_steps and not self.board:isGameOver() then
            self:aiTakeTurn()
        end
        return
    end

    if self.board:isGameOver() then
        local msg = InfoMessage:new{
            text = _("Game is over. Start a new game to play again."),
            timeout = 3,
        }
        msg.close_callback = function()
            self:refreshScreen()
        end
        UIManager:show(msg)
        return
    end

    if self.pending_steps then
        local msg = InfoMessage:new{
            text = _("You must move a piece before throwing again."),
            timeout = 3,
        }
        msg.close_callback = function()
            self:refreshScreen()
        end
        UIManager:show(msg)
        return
    end

    local steps, extra = self.board:throwSticks()
    self.last_roll = steps
    self.extra_turn = extra

    local legal_moves = self.board:getLegalMoves(steps)
    if #legal_moves == 0 then
        -- Immediate pass of turn (human)
        self:passTurnNoMoves(steps)
        return
    end

    self.pending_steps = steps
    self.plugin.board = self.board
    self.plugin:saveState()
    self:updateStatusAndInfo(false)
end

function SenetScreen:onCellTapped(pos)
    if self.board:isGameOver() then
        return
    end
    if self:isAITurn() then
        -- Ignore taps while AI is resolving its turn.
        return
    end
    if not self.pending_steps then
        local msg = InfoMessage:new{
            text = _("Throw the sticks first."),
            timeout = 2,
        }
        msg.close_callback = function()
            self:refreshScreen()
        end
        UIManager:show(msg)
        return
    end

    local current_player = self.board:getCurrentPlayer()
    if self.board:getCell(pos) ~= current_player then
        local msg = InfoMessage:new{
            text = _("You must select one of your own pieces."),
            timeout = 2,
        }
        msg.close_callback = function()
            self:refreshScreen()
        end
        UIManager:show(msg)
        return
    end

    local ok, info_or_reason = self.board:move(pos, self.pending_steps)
    if not ok then
        local reason = info_or_reason
        local text

        if reason == "cannot_jump_over_26" then
            text = _(
                "Square 26 'House of Happiness': you must pass through this house before reaching the final row (28–30); you cannot jump directly beyond it (except when falling into the House of Water)."
            )
        elseif reason == "cannot_exit_from_26" then
            text = _(
                "Square 26 'House of Happiness': from here you may only move to houses 27–30 with rolls 1–4; you cannot leave the board directly."
            )
        elseif reason == "cannot_exit_from_here" then
            text = _("You cannot leave the board from this house with that roll.")
        elseif reason == "need_three_from_28" then
            text = _(
                "Square 28 'House of Three Truths': from here you may only leave the board with a throw of three."
            )
        elseif reason == "need_two_from_29" then
            text = _(
                "Square 29 'House of Re-Atum': from here you may only leave the board with a throw of two."
            )
        elseif reason == "need_one_from_30" then
            text = _(
                "Square 30 'Final House': from here you may only leave the board with a throw of one."
            )
        elseif reason == "protected_house" then
            local start_pos = pos
            local steps = self.pending_steps or 0
            local raw_dest = start_pos + steps
            local prefix = ""
            if raw_dest == SPECIAL_REBIRTH then
                prefix = _("Square 15 'House of Rebirth': ")
            elseif raw_dest == SPECIAL_HAPPINESS then
                prefix = _("Square 26 'House of Happiness': ")
            elseif raw_dest == SPECIAL_TRUTHS then
                prefix = _("Square 28 'House of Three Truths': ")
            elseif raw_dest == SPECIAL_RE_ATUM then
                prefix = _("Square 29 'House of Re-Atum': ")
            elseif raw_dest == BOARD_HOUSES then
                prefix = _("Square 30 'Final House': ")
            end
            text = prefix .. _(
                "that house is protected; you cannot land on it while another piece is there."
            )
        elseif reason == "own_piece_block" then
            text = _("You cannot land on one of your own pieces.")
        elseif reason == "protected_piece" then
            text = _(
                "You cannot capture that piece because it is protected by another piece next to it."
            )
        elseif reason == "blocked_by_barrier" then
            text = _(
                "You cannot jump over a row of three or more of your opponent's pieces."
            )
        elseif reason == "water_blocked" then
            text = _(
                "Square 27 'House of Water': you cannot move into the water because the House of Rebirth is blocked and the water is already occupied."
            )
        elseif reason == "water_wait" then
            text = _(
                "Square 27 'House of Water': your piece must wait here until the House of Rebirth is free."
            )
        elseif reason == "not_your_piece" then
            text = _("That is not your piece.")
        else
            text = _("That move is not allowed.")
        end

        -- If there are actually no legal moves for this roll, auto-pass the turn.
        local moves_now = self.board:getLegalMoves(self.pending_steps or 0)
        local has_any = (#moves_now > 0)

        if not has_any then
            -- Immediate pass with explanatory prefix.
            self:passTurnNoMoves(self.pending_steps or 0, text)
            return
        end

        local msg = InfoMessage:new{
            text = text,
            timeout = 3,
        }
        msg.close_callback = function()
            self:refreshScreen()
        end
        UIManager:show(msg)
        return
    end

    self.grid_widget:refresh()
    self.pending_steps = nil

    if self.board:isGameOver() and self.board.winner then
        local sym = playerSymbol(self.board.winner)
        local msg = InfoMessage:new{
            text = T(_("Player %1 wins!"), sym),
            timeout = 5,
        }
        msg.close_callback = function()
            self.plugin.board = self.board
            self.plugin:saveState()
            self:updateStatusAndInfo(false)
            self:refreshScreen()
        end
        UIManager:show(msg)
    else
        if self.extra_turn then
            self.extra_turn = false
        else
            self.board:switchPlayer()
        end
        self.plugin.board = self.board
        self.plugin:saveState()
        self:updateStatusAndInfo(false)
        self:refreshScreen()
        self:maybeStartAITurn()
    end
end

function SenetScreen:onNewGame()
    self.board:reset()
    self.pending_steps = nil
    self.extra_turn = false
    self.last_roll = nil
    self.grid_widget:refresh()
    self.plugin.board = self.board
    self.plugin:saveState()
    UIManager:setDirty(nil, "full")
    self:updateStatusAndInfo(true)
end

function SenetScreen:onHelp()
    local help_lines = {
        _("Senet – quick rules:"),
        "",
        _("• Two players, 5 pieces each (● and ○)."),
        _("• Start: houses 1–10 filled alternately: ● on 1,3,5,7,9; ○ on 2,4,6,8,10."),
        _("• Throw the four sticks and move one of your pieces forward."),
        _("• You cannot land on your own piece."),
        _("• Landing on a single enemy piece swaps places (capture)."),
        _("• Two or more enemy pieces in a row are protected from capture."),
        _("• A row of three or more enemy pieces cannot be jumped over."),
        "",
        _("Special houses:"),
        _("15 – House of Rebirth: a protected safe house; an opponent can never land here."),
        _("26 – House of Happiness: protected; every piece must pass through here before reaching 28–30 (you may still fall directly into 27, the House of Water)."),
        _("From 26 you may only move to houses 27–30 (rolls 1–4)."),
        _("27 – House of Water: you may land here directly, even from below 26;"),
        _("     if Rebirth is free you go straight to 15;"),
        _("     if Rebirth is occupied you wait on 27 until it opens."),
        _("28 – House of the Three Truths: protected; once here you can only leave the board with a 3."),
        _("29 – House of Re-Atum: protected; once here you can only leave the board with a 2."),
        _("30 – Final House: protected; once here you can only leave the board with a 1."),
        _("Houses 28–30 are exit-only: once you land there you cannot move between them, only roll off the board with the exact number."),
        "",
        _("First player to move all 5 of their pieces off the board wins."),
    }

    local msg = InfoMessage:new{
        text = table.concat(help_lines, "\n"),
        timeout = nil,
    }
    msg.close_callback = function()
        self:refreshScreen()
    end
    UIManager:show(msg)
end

function SenetScreen:onClose()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    self.plugin:onScreenClosed()
end

--------------------------------------------------------------------------------
-- AI logic
--------------------------------------------------------------------------------

function SenetScreen:maybeStartAITurn()
    if not self:isAITurn() or self.board:isGameOver() then
        return
    end
    -- Give a little time for the "Player ○'s turn. They're throwing the sticks." line to show.
    UIManager:scheduleIn(1.0, function()
        if self:isAITurn() and not self.board:isGameOver() and not self.pending_steps then
            self:aiTakeTurn()
        end
    end)
end

function SenetScreen:chooseAIMove(steps, legal_moves)
    local difficulty = self:getAIDifficulty()
    if not difficulty or #legal_moves == 0 then
        return nil
    end

    -- "Easy": mostly just move as far along the track as possible.
    if difficulty == "easy" then
        local best = legal_moves[1]
        local best_score = best.offboard and 100 or best.to
        for i = 2, #legal_moves do
            local m = legal_moves[i]
            local score = m.offboard and 100 or m.to
            if score > best_score then
                best = m
                best_score = score
            end
        end
        return best
    end

    -- "Normal": simple heuristic.
    local board = self.board
    local current = board:getCurrentPlayer()
    local opponent = (current == PLAYER1) and PLAYER2 or PLAYER1
    local best = legal_moves[1]
    local best_score = -1e9

    for _, m in ipairs(legal_moves) do
        local score = 0

        if m.offboard then
            score = score + 100
        else
            score = score + m.to
        end

        -- Prefer captures
        if not m.offboard and board.cells[m.to] == opponent then
            score = score + 25
        end

        -- Prefer special/protected houses and final row
        if m.to == SPECIAL_REBIRTH or m.to == SPECIAL_HAPPINESS
           or m.to == SPECIAL_TRUTHS or m.to == SPECIAL_RE_ATUM
           or m.to == BOARD_HOUSES then
            score = score + 15
        end

        if m.to >= SPECIAL_TRUTHS then
            score = score + 10
        end

        if score > best_score then
            best_score = score
            best = m
        end
    end

    return best
end

function SenetScreen:aiTakeTurn()
    if not self:isAITurn() or self.board:isGameOver() then
        return
    end
    if self.pending_steps then
        return
    end

    -- Throw sticks for AI.
    local steps, extra = self.board:throwSticks()
    self.last_roll = steps
    self.extra_turn = extra

    local legal_moves = self.board:getLegalMoves(steps)
    if #legal_moves == 0 then
        -- AI has no legal moves: immediate pass back to human.
        self.plugin.board = self.board
        self.plugin:saveState()
        self:passTurnNoMoves(steps)
        return
    end

    -- Only set pending_steps if there is at least one legal move.
    self.pending_steps = steps
    self.plugin.board = self.board
    self.plugin:saveState()
    self:updateStatusAndInfo(false)
    self:refreshScreen()

    local move = self:chooseAIMove(steps, legal_moves)
    if not move then
        move = legal_moves[1]
    end

    -- Wait so the human can see the roll, then move.
    UIManager:scheduleIn(3.0, function()
        if not self:isAITurn() or self.board:isGameOver() then
            return
        end

        local ok, _ = self.board:move(move.from, steps)
        self.pending_steps = nil
        self.grid_widget:refresh()

        if not ok then
            -- Safety net: if somehow the chosen move became invalid, treat as no-legal-moves.
            self:passTurnNoMoves(steps)
            return
        end

        if self.board:isGameOver() and self.board.winner then
            local sym = playerSymbol(self.board.winner)
            local msg = InfoMessage:new{
                text = T(_("Player %1 wins!"), sym),
                timeout = 5,
            }
            msg.close_callback = function()
                self.plugin.board = self.board
                self.plugin:saveState()
                self:updateStatusAndInfo(false)
                self:refreshScreen()
            end
            UIManager:show(msg)
        else
            if self.extra_turn then
                self.extra_turn = false
                self.plugin.board = self.board
                self.plugin:saveState()
                self:updateStatusAndInfo(false)
                self:refreshScreen()
                self:maybeStartAITurn()
            else
                self.board:switchPlayer()
                self.plugin.board = self.board
                self.plugin:saveState()
                self:updateStatusAndInfo(false)
                self:refreshScreen()
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- Plugin root: Senet
--------------------------------------------------------------------------------

local Senet = InputContainer:extend{
    name = "senet",
    is_doc_only = false,
}

function Senet:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/senet.lua"
    self.settings = LuaSettings:open(self.settings_file)
    self.state_file = DataStorage:getSettingsDir() .. "/senet_state.json"
    self.board = nil
    self.ui.menu:registerToMainMenu(self)
end

function Senet:addToMainMenu(menu_items)
    menu_items.senet = {
        text = _("Senet"),
        sorting_hint = "tools",
        callback = function()
            self:showGame()
        end,
    }
end

function Senet:getBoard()
    if not self.board then
        self.board = SenetBoard:new()
        local state = self:loadState()
        if state then
            self.board:load(state)
        end
    end
    return self.board
end

function Senet:getGameMode()
    local mode = self.settings:readSetting("game_mode", MODE_HUMAN_VS_HUMAN)
    if mode ~= MODE_HUMAN_VS_HUMAN
       and mode ~= MODE_VS_AI_EASY
       and mode ~= MODE_VS_AI_NORMAL then
        mode = MODE_HUMAN_VS_HUMAN
    end
    return mode
end

function Senet:setGameMode(mode)
    self.settings:saveSetting("game_mode", mode)
end

function Senet:showGame()
    if self.screen then
        return
    end
    self.screen = SenetScreen:new{
        plugin = self,
    }
    UIManager:show(self.screen)
    self:saveState()
end

function Senet:onScreenClosed()
    self.screen = nil
    self:saveState()
end

function Senet:saveState()
    if not self.board then
        return
    end
    local payload = {
        version = 3,
        board = self.board:serialize(),
    }
    local ok, encoded = pcall(json.encode, payload)
    if not ok then
        logger.err("Senet: failed to encode state", encoded)
        return
    end
    local file = io.open(self.state_file, "w")
    if not file then
        logger.err("Senet: cannot write state file", self.state_file)
        return
    end
    file:write(encoded)
    file:close()
end

function Senet:loadState()
    local file = io.open(self.state_file, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    if not content or content == "" then
        return nil
    end
    local ok, data = pcall(json.decode, content)
    if not ok then
        logger.err("Senet: failed to decode state", data)
        return nil
    end
    return data.board
end

return Senet
