local M = {}

local common = require("multiple-cursors.common")
local virtual_cursors = require("multiple-cursors.virtual_cursors")

local deferred_cr = false
local deferred_tab = false

-- Character to insert
local char = nil

-- Delete a charater if in replace mode
local function delete_if_replace_mode(vc, num)
  if common.is_mode("R") or common.is_mode("Rc") then
    vim.cmd("normal! \"_" .. num .. "x")
  end
end

-- Is lnum, col before the first non-whitespace character
local function is_before_first_non_whitespace_char(lnum, col)
  local idx = vim.fn.match(vim.fn.getline(lnum), "\\S")
  if idx < 0 then
    return true
  else
    return col <= idx + 1
  end
end


-- Escape key ------------------------------------------------------------------

function M.escape()

  -- Move the cursor back
  virtual_cursors.visit_with_cursor(function(vc)
    if vc.col ~= 1 then
      common.normal_bang(nil, 0, "h", nil)
      vc:save_cursor_position()
    end
  end)

  common.feedkeys(nil, 0, "<Esc>", nil)

end


-- Insert text -----------------------------------------------------------------

-- Callback for InsertCharPre event
function M.insert_char_pre(event)
  -- Save the inserted character
  char = vim.v.char
end

-- Callback for the TextChangedI event
function M.text_changed_i(event)

  -- If there's a saved character
  if char then
    -- Put it to virtual cursors
    virtual_cursors.edit_with_cursor(function(vc)
      delete_if_replace_mode(vc, 1)
      vim.api.nvim_put({char}, "c", false, true)
    end)
    char = nil
  end

end


-- Completion ------------------------------------------------------------------

-- Return the completion word without the part that triggered the completion
local function crop_completion_word(line, col, word)

  -- Start from the longest possible length
  local length = vim.fn.min({col - 1, word:len()})

  while length > 0 do
    local l = line:sub(col-length, col-1)
    local w = word:sub(1, length)

    if l == w then
      return word:sub(length + 1)
    end

    length = length - 1
  end

  return word

end

-- Callback for the CompleteDonePre event
function M.complete_done_pre(event)

  local complete_info = vim.fn.complete_info()

  -- If an item has been selected
  if complete_info.selected >= 0 then

    -- Get the word
    local word = complete_info.items[complete_info.selected + 1].word

    virtual_cursors.edit_with_cursor(function(vc)

      -- Remove the part of the word that triggered the completion
      local line = vim.fn.getline(vc.lnum)
      local cropped_word = crop_completion_word(line, vc.col, word)

      -- Delete characters for replace mode
      delete_if_replace_mode(vc, cropped_word:len())

      vim.api.nvim_put({cropped_word}, "c", false, true)

    end)

  end

  if deferred_cr then
    deferred_cr = false
    M.all_virtual_cursors_carriage_return()
  end

  if deferred_tab then
    deferred_tab = false
    M.all_virtual_cursors_tab()
  end

end


-- Backspace -------------------------------------------------------------------

-- Get the character at lnum, col
-- This is only used to check for a space or tab characters, and doesn't get an
-- extended character properly
local function get_char(lnum, col)
  local l = vim.fn.getline(lnum)
  local c = string.sub(l, col - 1, col - 1)
  return c
end

-- Is the character at lnum, col a space?
local function is_space(lnum, col)
  return get_char(lnum, col) == " "
end

-- Is the character at lnum, col a tab?
local function is_tab(lnum, col)
  return get_char(lnum, col) == "\t"
end

-- Count number of spaces back to a multiple of shiftwidth
local function count_spaces_back(lnum, col)

  -- Indentation
  local stop = vim.opt.shiftwidth._value

  if not is_before_first_non_whitespace_char(lnum, col) then
    -- Tabbing
    if vim.opt.softtabstop._value == 0 then
      return 1
    else
      stop = vim.opt.softtabstop._value
    end
  end

  local count = 0

  -- While col isn't the first column and the character is a spce
  while col >= 1 and is_space(lnum, col) do
    count = count + 1
    col = col - 1

    -- Stop counting when col is a multiple of stop
    if (col - 1) % stop == 0 then
      break
    end
  end

  return count

end

-- Insert mode backspace command for a virtual cursor
local function virtual_cursor_insert_mode_backspace(vc)

  if vc.col == 1 then -- Start of the line
    if vc.lnum ~= 1 then -- But not the first line
      -- If the line is empty
      if common.get_length_of_line(vc.lnum) == 0 then
        -- Delete line
        vim.cmd("normal! dd")

        -- Move up and to end
        vc.lnum = vc.lnum - 1
        vc.col = common.get_max_col(vc.lnum)
        vc.curswant = vim.v.maxcol
      else
        vim.cmd("normal! k$gJ") -- Join with previous line
        vc:save_cursor_position()
      end

    end
  else

    -- Number of times to execute command, this is to backspace over tab spaces
    local count = vim.fn.max({1, count_spaces_back(vc.lnum, vc.col)})

    for i = 1, count do vim.cmd("normal! \"_X") end

    vc.col = vc.col - count
    vc.curswant = vc.col
  end

end

-- Replace mode backspace command for a virtual cursor
-- This only moves back a character, it doesn't undo
local function virtual_cursor_replace_mode_backspace(vc)

  -- First column but not first line
  if vc.col == 1 and vc.lnum ~= 1 then
    -- Move to end of previous line
    vc.lnum = vc.lnum - 1
    vc.col = common.get_max_col(vc.lnum)
    vc.curswant = vc.col
    return
  end

  -- For handling tab spaces
  local count = vim.fn.max({1, count_spaces_back(vc.lnum, vc.col)})

  -- Move left
  vc.col = vc.col - count
  vc.curswant = vc.col

end

-- Backspace command for all virtual cursors
local function all_virtual_cursors_backspace()
  -- Replace mode
  if common.is_mode("R") then
    virtual_cursors.edit_with_cursor_no_save(function(vc)
      virtual_cursor_replace_mode_backspace(vc)
    end)
  else
    virtual_cursors.edit_with_cursor_no_save(function(vc)
      virtual_cursor_insert_mode_backspace(vc)
    end)
  end
end

-- Backspace command
function M.bs()
  common.feedkeys(nil, 0, "<BS>", nil)
  all_virtual_cursors_backspace()
end


-- Delete ----------------------------------------------------------------------

-- Delete command for a virtual cursor
local function virtual_cursor_delete(vc)

  if vc.col == common.get_max_col(vc.lnum) then -- End of the line
    -- Join next line
    vim.cmd("normal! gJ")
  else -- Anywhere else on the line
    vim.cmd("normal! \"_x")
  end

  -- Cursor doesn't change
end

-- Delete command for all virtual cursors
local function all_virtual_cursors_delete()
  virtual_cursors.edit_with_cursor_no_save(function(vc)
    virtual_cursor_delete(vc)
  end)
end

-- Delete command
function M.del()
  common.feedkeys(nil, 0, "<Del>", nil)
  all_virtual_cursors_delete()
end


-- Carriage return -------------------------------------------------------------

-- Carriage return command for a virtual cursor
-- This isn't local because it's used by normal_mode_change
function M.virtual_cursor_carriage_return(vc)
  if vc.col <= common.get_length_of_line(vc.lnum) then
    vim.api.nvim_put({"", ""}, "c", false, true)
    vim.cmd("normal! ==^")
    vc:save_cursor_position()
  else
    -- Special case for EOL: add a character to auto indent, then delete it
    vim.api.nvim_put({"", "x"}, "c", false, true)
    vim.cmd("normal! ==^\"_x")
    vc:save_cursor_position()
    vc.col = common.get_col(vc.lnum, vc.col + 1) -- Shift cursor 1 right limited to max col
    vc.curswant = vc.col
  end
end

-- Carriage return command for all virtual cursors
-- This isn't local because it's used by normal_mode_change
function M.all_virtual_cursors_carriage_return()
  virtual_cursors.edit_with_cursor_no_save(function(vc)
    M.virtual_cursor_carriage_return(vc)
  end)
end

-- Carriage return command
-- Also for <kEnter>
function M.cr()

  common.feedkeys(nil, 0, "<CR>", nil)

  -- If a completion item has been selected
  if vim.fn.complete_info().selected >= 0 then
    -- Delay calling all_virtual_cursors_carriage_return() until the end of complete_done_pre
    deferred_cr = true
  else
    M.all_virtual_cursors_carriage_return()
  end

end


-- Tab -------------------------------------------------------------------------

-- Get the number of spaces to put for a tab character
local function get_num_spaces_to_put(stop, col)
  return stop - ((col-1) % stop)
end

-- Put a character multiple times
local function put_multiple(char, num)
  for i = 1, num do
    vim.api.nvim_put({char}, "c", false, true)
  end
end

-- Tab command for a virtual cursor
local function virtual_cursor_tab(vc)

  local expandtab = vim.opt.expandtab._value
  local tabstop = vim.opt.tabstop._value
  local softtabstop = vim.opt.softtabstop._value
  local shiftwidth = vim.opt.shiftwidth._value

  if expandtab then
    -- Spaces
    if is_before_first_non_whitespace_char(vc.lnum, vc.col) then
      -- Indenting
      put_multiple(" ", get_num_spaces_to_put(shiftwidth, vc.col))
    else
      -- Tabbing
      if softtabstop == 0 then
        put_multiple(" ", get_num_spaces_to_put(tabstop, vc.col))
      else
        put_multiple(" ", get_num_spaces_to_put(softtabstop, vc.col))
      end
    end
  else -- noexpandtab
    -- TODO
    return
  end

end

-- Tab command for all virtual cursors
function M.all_virtual_cursors_tab()
  virtual_cursors.edit_with_cursor(function(vc)
    delete_if_replace_mode(vc, 1)
    virtual_cursor_tab(vc)
  end)
end

-- Tab command
function M.tab()

  common.feedkeys(nil, 0, "<Tab>", nil)

  -- If a completion item has been selected
  if vim.fn.complete_info().selected >= 0 then
    -- Delay calling all_virtual_cursors_tab() until the end of complete_done_pre
    deferred_tab = true
  else
    M.all_virtual_cursors_tab()
  end

end

return M
