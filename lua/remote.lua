-- remote.lua -- list and fetch MIDI files from a GitHub repo.
-- Defaults to the user's "Jonah-Midi-Collection". Uses an injected http_get so
-- it works in whatever Lua environment you're running in.

local Remote = {}

-- ==== which repo to pull from (change here if you rename/move it) ==========
Remote.OWNER  = "Dyno3862"
Remote.REPO   = "Jonah-Midi-Collection"
Remote.BRANCH = "main"

local function contentsURL(self)
  return ("https://api.github.com/repos/%s/%s/contents/?ref=%s")
         :format(self.OWNER, self.REPO, self.BRANCH)
end

local function rawBase(self)
  return ("https://raw.githubusercontent.com/%s/%s/%s/")
         :format(self.OWNER, self.REPO, self.BRANCH)
end

-- percent-encode a path (keeps it valid for raw.githubusercontent, incl. UTF-8)
local function urlencode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end
Remote.urlencode = urlencode

-- list .mid/.midi files. http_get(url) must return the response body (string).
-- returns: { { name=..., url=<raw download url> }, ... } , err
function Remote.list(http_get)
  local body, err = http_get(contentsURL(Remote))
  if not body then return nil, ("Could not reach GitHub: %s"):format(err or "?") end
  local files, seen = {}, {}
  -- pull every "path":"..." entry from the JSON and keep the MIDI ones
  for path in body:gmatch('"path"%s*:%s*"([^"]-)"') do
    local low = path:lower()
    if (low:sub(-4) == ".mid" or low:sub(-5) == ".midi") and not seen[path] then
      seen[path] = true
      files[#files + 1] = {
        name = (path:gsub("%.midi?$", "")),        -- pretty title
        file = path,
        url  = rawBase(Remote) .. urlencode(path),  -- direct download
      }
    end
  end
  table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
  if #files == 0 then
    return nil, "No .mid files found in the repo (or JSON couldn't be parsed)."
  end
  return files, nil
end

-- filter a listing by a search substring (case-insensitive)
function Remote.search(files, query)
  query = (query or ""):lower()
  if query == "" then return files end
  local out = {}
  for _, f in ipairs(files) do
    if f.name:lower():find(query, 1, true) then out[#out + 1] = f end
  end
  return out
end

-- download the raw bytes of one file entry. returns data(string), err
function Remote.fetch(http_get, entry)
  local data, err = http_get(entry.url)
  if not data then return nil, err or "download failed" end
  if data:sub(1, 4) ~= "MThd" then
    return nil, "downloaded data is not a MIDI file (no MThd header)"
  end
  return data, nil
end

return Remote
