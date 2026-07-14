-- backend_windows.lua -- a concrete keyboard backend for LuaJIT on Windows.
-- Sends hardware SCAN CODES via SendInput -- the same low-level path the Python
-- desktop version and AutoHotkey use, which games read reliably.
--
-- Requires LuaJIT (for FFI). If your environment isn't LuaJIT, use the
-- press/release examples in init.lua instead.
--
-- USAGE (in init.lua):
--   local kb = require("backend_windows")
--   backend.keyDown, backend.keyUp   = kb.keyDown, kb.keyUp
--   backend.shiftDown, backend.shiftUp = kb.shiftDown, kb.shiftUp
--   backend.now, backend.sleep       = kb.now, kb.sleep   -- optional

local ok, ffi = pcall(require, "ffi")
if not ok then error("backend_windows requires LuaJIT (FFI not available)") end

ffi.cdef[[
typedef struct { long dx, dy; unsigned long mouseData, dwFlags, time; uintptr_t dwExtraInfo; } MOUSEINPUT;
typedef struct { unsigned short wVk, wScan; unsigned long dwFlags, time; uintptr_t dwExtraInfo; } KEYBDINPUT;
typedef struct { unsigned long uMsg; unsigned short wParamL, wParamH; } HARDWAREINPUT;
typedef struct { unsigned long type; union { MOUSEINPUT mi; KEYBDINPUT ki; HARDWAREINPUT hi; } u; } INPUT;
unsigned int SendInput(unsigned int, INPUT*, int);
void Sleep(unsigned long);
unsigned long long GetTickCount64(void);
]]
local user32 = ffi.load("user32")
local kernel32 = ffi.C

local KEYEVENTF_SCANCODE = 0x0008
local KEYEVENTF_KEYUP    = 0x0002
local INPUT_KEYBOARD      = 1
local LSHIFT_SCAN         = 0x2A

-- virtual-piano characters -> Set-1 scan codes
local SCAN = {
  ["1"]=0x02,["2"]=0x03,["3"]=0x04,["4"]=0x05,["5"]=0x06,["6"]=0x07,["7"]=0x08,
  ["8"]=0x09,["9"]=0x0A,["0"]=0x0B,
  q=0x10,w=0x11,e=0x12,r=0x13,t=0x14,y=0x15,u=0x16,i=0x17,o=0x18,p=0x19,
  a=0x1E,s=0x1F,d=0x20,f=0x21,g=0x22,h=0x23,j=0x24,k=0x25,l=0x26,
  z=0x2C,x=0x2D,c=0x2E,v=0x2F,b=0x30,n=0x31,m=0x32,
}

local M = {}

local function sendScan(scan, keyup)
  local inp = ffi.new("INPUT")
  inp.type = INPUT_KEYBOARD
  inp.u.ki.wVk = 0
  inp.u.ki.wScan = scan
  inp.u.ki.dwFlags = KEYEVENTF_SCANCODE + (keyup and KEYEVENTF_KEYUP or 0)
  user32.SendInput(1, inp, ffi.sizeof("INPUT"))
end

function M.keyDown(c) local s = SCAN[c]; if s then sendScan(s, false) end end
function M.keyUp(c)   local s = SCAN[c]; if s then sendScan(s, true)  end end
function M.shiftDown() sendScan(LSHIFT_SCAN, false) end
function M.shiftUp()   sendScan(LSHIFT_SCAN, true)  end

function M.now()     return tonumber(kernel32.GetTickCount64()) / 1000 end
function M.sleep(s)  kernel32.Sleep(s * 1000) end

return M
