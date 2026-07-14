-- conf.lua -- LÖVE configuration (window + mobile orientation)
function love.conf(t)
  t.identity = "MidiVirtualPiano"          -- save-dir name (holds MidiFiles/)
  t.version  = "11.4"
  t.window.title  = "MIDI Virtual Piano (Lua)"
  t.window.width  = 900
  t.window.height = 520
  t.window.resizable = true
  t.window.minwidth  = 480
  t.window.minheight = 320
  t.window.orientation = "landscape"       -- best for the wide keyboard on phones
  t.modules.joystick = false
  t.modules.physics  = false
end
