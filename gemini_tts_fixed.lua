require "import"
import "com.androlua.Http"
import "cjson"
import "com.androlua.LuaDialog"
import "android.widget.*"
import "android.view.*"
import "android.content.Context"
import "android.content.Intent"
import "android.content.ContentValues"
import "android.net.Uri"
import "android.media.MediaPlayer"
import "android.util.Base64"
import "android.os.*"
import "android.graphics.Typeface"
import "android.graphics.Color"
import "java.io.*"
import "java.util.HashMap"
import "android.text.InputFilter"
import "android.view.accessibility.AccessibilityEvent"

local context = activity or service
local mainHandler = Handler(Looper.getMainLooper())
local mainDialog = nil
local settingDialog = nil
local apiDialog = nil
local playBtnRef = nil
local generateBtnRef = nil
local textInputRef = nil
local charCounterRef = nil
local resultLayoutRef = nil
local durationTextRef = nil
local statusTextRef = nil
local currentDurationStr = ""
local isUiInitializing = true

-- Lambi single-take audio ke liye timeout 4 minute (240,000 ms) rakha hai
pcall(function() Http.setConnTimeout(60000) end)
pcall(function() Http.setReadTimeout(240000) end)
pcall(function() Http.setTimeout(240000) end)

-- 30 prebuilt voices
local VOICE_LIST = {
    "Puck (Male)", "Kore (Female)", "Charon (Male)", "Zephyr (Female)",
    "Fenrir (Male)", "Leda (Female)", "Orus (Male)", "Aoede (Female)",
    "Callirrhoe (Female)", "Autonoe (Female)", "Enceladus (Male)", "Iapetus (Male)",
    "Umbriel (Male)", "Algieba (Female)", "Despina (Female)", "Erinome (Female)",
    "Algenib (Male)", "Rasalgethi (Male)", "Laomedeia (Female)", "Achernar (Male)",
    "Alnilam (Male)", "Schedar (Male)", "Gacrux (Male)", "Pulcherrima (Female)",
    "Achird (Friendly)", "Zubenelgenubi (Casual)", "Vindemiatrix (Gentle)",
    "Sadachbia (Lively)", "Sadaltager (Knowledgeable)", "Sulafat (Warm)"
}

local RAW_VOICES = {
    "Puck", "Kore", "Charon", "Zephyr", "Fenrir", "Leda",
    "Orus", "Aoede", "Callirrhoe", "Autonoe", "Enceladus", "Iapetus",
    "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi",
    "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima",
    "Achird", "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"
}

local STYLE_LIST = {
    "Default / Normal",
    "Islamic: Tilawat (Sudais/Shuraim - Fixed Pace)",
    "Islamic: Hadees (Arabic + Tarjuma)",
    "Islamic: Dua (Humble & Crying)",
    "Islamic: Naat / Kalam (Melodic)",
    "Islamic: Waqia / Story (Deep & Serious)",
    "Dynamic Human (Auto-Emotion: Laugh/Cry)",
    "Cartoon: Thin & Squeaky (Patli Aawaz)",
    "Cartoon: Thick & Goofy (Moti Aawaz)",
    "Storytelling (Expressive)",
    "Poetry / Shayari (Deep & Rhythmic)",
    "Horror / Scary / Suspense",
    "Angry / Aggressive (Gusse wala)",
    "Whispering / Secretive (Sargoshi)",
    "Happy / Joyful (Khushi)",
    "Comedy / Funny",
    "Romantic / Soft",
    "Dramatic / Thriller",
    "Sad / Emotional",
    "Sarcastic / Irony (Tanzana)",
    "Motivational / Inspiring",
    "News / Professional",
    "Documentary / Informative"
}

local MODEL_LIST = {
    "gemini-3.8-flash-tts",
    "gemini-3.8-flash-lite-tts"
}
local DEFAULT_MODEL = "gemini-3.8-flash-tts"

local MAX_CHAR_LIMIT = 15000
-- 4500 bytes (~4500 chars) rakhne se 4500 chars tak ka text BINA TOOTE 1 hi single part mein banega!
-- Aur 15,000 chars ka text bhi 12 parts ke bajaye sirf 3 ya 4 bade studio parts mein banega.
local CHUNK_MAX_CHARS = 4500
local PAUSE_DURATION_MS = 520

local selectedVoice = "Puck"
local selectedStyle = "Default / Normal"
local selectedModel = DEFAULT_MODEL
local userText = ""
local generatedAudioPath = nil
local mediaPlayer = nil
local isPlaying = false
local isGenerating = false
local cancelRequested = false
local googleApiKey = ""
local configMode = 1 -- 1: Full Strict Lock, 2: Temperature Zero Lock, 3: Standard

local activeHttpRequest = nil
local MAX_RETRY = 4

local PREFS_NAME = "Jieshuo_Gemini_TTS_Pro_Max"
local prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

local baseStorageDir = context.getFilesDir() or context.getCacheDir()
local chunksDir = File(baseStorageDir, "tts_resume_store")
if not chunksDir.exists() then chunksDir.mkdirs() end

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function trim(s)
    return (tostring(s or ""):match("^%s*(.-)%s*$"))
end

local function setBtnColor(btn, hex)
    pcall(function() btn.setBackgroundColor(Color.parseColor(hex)) end)
end

function runOnUi(callback)
    mainHandler.post(Runnable({ run = callback }))
end

function delay(ms, callback)
    mainHandler.postDelayed(Runnable({ run = callback }), ms)
end

function showToast(msg)
    runOnUi(function()
        pcall(function() Toast.makeText(context, tostring(msg), Toast.LENGTH_SHORT).show() end)
    end)
end

function showStatus(msg)
    runOnUi(function()
        if statusTextRef then
            pcall(function() statusTextRef.setText(tostring(msg)) end)
        end
    end)
end

function speakFeedback(msg)
    showStatus(msg)
    local success = pcall(function()
        service.speak(msg)
    end)
    if not success then
        showToast(msg)
    end
end

function vibrate()
    pcall(function()
        local vibrator = context.getSystemService(Context.VIBRATOR_SERVICE)
        if vibrator then vibrator.vibrate(35) end
    end)
end

local function safe(name, fn)
    return function(...)
        local args = {...}
        local ok, err = pcall(function() return fn(table.unpack(args)) end)
        if not ok then
            isGenerating = false
            speakFeedback("Code error (" .. name .. "): " .. tostring(err))
            if generateBtnRef then
                pcall(function() generateBtnRef.setEnabled(true) end)
            end
        end
    end
end

function saveSettings()
    local editor = prefs.edit()
    editor.putString("voice", selectedVoice)
    editor.putString("style", selectedStyle)
    editor.putString("model", selectedModel)
    editor.putString("apikey", googleApiKey)
    editor.commit()
end

function saveDraftText(txt)
    local editor = prefs.edit()
    editor.putString("saved_draft_text", txt or "")
    editor.commit()
end

function loadSettings()
    selectedVoice = prefs.getString("voice", "Puck")
    selectedStyle = prefs.getString("style", "Default / Normal")
    selectedModel = prefs.getString("model", DEFAULT_MODEL)
    googleApiKey = prefs.getString("apikey", "")
    userText = prefs.getString("saved_draft_text", "")

    local valid = false
    for _, m in ipairs(MODEL_LIST) do
        if m == selectedModel then valid = true break end
    end
    if not valid then
        selectedModel = DEFAULT_MODEL
        saveSettings()
    end
end

---------------------------------------------------------------------
-- Chunk save / resume
---------------------------------------------------------------------
local function hashText(s)
    local h = 5381
    for i = 1, #s do
        h = ((h * 33) + string.byte(s, i)) & 0xFFFFFFFF
    end
    return h
end

function makeChunkTag(chunkText, voice, style)
    return "v3|" .. tostring(selectedModel) .. "|" .. tostring(voice) .. "|" .. tostring(style) .. "|" .. tostring(#chunkText) .. "|" .. tostring(hashText(chunkText))
end

function getChunkFile(index)
    if not chunksDir.exists() then chunksDir.mkdirs() end
    return File(chunksDir, "part_" .. tostring(index) .. ".pcm")
end

function isChunkValidAndSaved(index, chunkText, voice, style)
    local pcmFile = getChunkFile(index)
    if not pcmFile.exists() or pcmFile.length() <= 100 then
        return false
    end
    local savedTag = prefs.getString("chunk_tag_" .. tostring(index), "")
    return (savedTag == makeChunkTag(chunkText, voice, style))
end

function markChunkSaved(index, chunkText, voice, style)
    local editor = prefs.edit()
    editor.putString("chunk_tag_" .. tostring(index), makeChunkTag(chunkText, voice, style))
    editor.commit()
end

function clearSavedChunks()
    local editor = prefs.edit()
    for i = 1, 150 do
        pcall(function()
            local f = getChunkFile(i)
            if f.exists() then f.delete() end
        end)
        editor.remove("chunk_tag_" .. tostring(i))
    end
    editor.commit()
end

function formatDurationText(totalSeconds)
    if not totalSeconds or totalSeconds < 0 then totalSeconds = 0 end
    totalSeconds = math.floor(totalSeconds + 0.5)
    local mins = math.floor(totalSeconds / 60)
    local secs = math.floor(totalSeconds % 60)
    if mins > 0 then
        return string.format("%d min %02d sec", mins, secs), string.format("%d minute %d second", mins, secs)
    else
        return string.format("0 min %02d sec", secs), string.format("%d second", secs)
    end
end

---------------------------------------------------------------------
-- Media player
---------------------------------------------------------------------
function initMediaPlayer()
    if mediaPlayer ~= nil then
        if isPlaying then
            pcall(function() mediaPlayer.stop() end)
            isPlaying = false
        end
        pcall(function() mediaPlayer.release() end)
    end
    mediaPlayer = MediaPlayer()

    mediaPlayer.setOnCompletionListener(MediaPlayer.OnCompletionListener({
        onCompletion = function(mp)
            isPlaying = false
            speakFeedback("Audio mukammal ho gayi.")
            runOnUi(function()
                if playBtnRef then
                    if currentDurationStr ~= "" then
                        playBtnRef.setText("PLAY (" .. currentDurationStr .. ")")
                    else
                        playBtnRef.setText("PLAY")
                    end
                end
            end)
        end
    }))
end

function togglePlayPause(playBtn)
    if mediaPlayer == nil then
        speakFeedback("Audio load nahi hui hai.")
        return false
    end

    if isPlaying then
        pcall(function() mediaPlayer.pause() end)
        isPlaying = false
        runOnUi(function()
            if currentDurationStr ~= "" then
                playBtn.setText("PLAY (" .. currentDurationStr .. ")")
            else
                playBtn.setText("PLAY")
            end
        end)
    else
        local ok = pcall(function() mediaPlayer.start() end)
        if ok then
            isPlaying = true
            runOnUi(function()
                if currentDurationStr ~= "" then
                    playBtn.setText("PAUSE (" .. currentDurationStr .. ")")
                else
                    playBtn.setText("PAUSE")
                end
            end)
        end
    end
    return true
end

function deleteOldAudioFile()
    if generatedAudioPath then
        pcall(function()
            local oldFile = File(generatedAudioPath)
            if oldFile.exists() then oldFile.delete() end
        end)
        generatedAudioPath = nil
    end
end

---------------------------------------------------------------------
-- WAV / PCM (Exact Data Size Parser + Smooth Boundary Silencer)
---------------------------------------------------------------------
function writeWavHeader(outStream, totalAudioLen)
    local sampleRate = 24000
    local channels = 1
    local bitsPerSample = 16
    local byteRate = sampleRate * channels * (bitsPerSample // 8)
    local blockAlign = channels * (bitsPerSample // 8)

    local totalSize = totalAudioLen + 36

    local function getBytes(val)
        val = math.floor(val)
        return { val & 0xff, (val >> 8) & 0xff, (val >> 16) & 0xff, (val >> 24) & 0xff }
    end

    local totalSizeB = getBytes(totalSize)
    local sampleRateB = getBytes(sampleRate)
    local byteRateB = getBytes(byteRate)
    local dataLenB = getBytes(totalAudioLen)

    local header = {
        0x52, 0x49, 0x46, 0x46,
        totalSizeB[1], totalSizeB[2], totalSizeB[3], totalSizeB[4],
        0x57, 0x41, 0x56, 0x45,
        0x66, 0x6d, 0x74, 0x20,
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00,
        channels & 0xff, (channels >> 8) & 0xff,
        sampleRateB[1], sampleRateB[2], sampleRateB[3], sampleRateB[4],
        byteRateB[1], byteRateB[2], byteRateB[3], byteRateB[4],
        blockAlign & 0xff, (blockAlign >> 8) & 0xff,
        bitsPerSample & 0xff, (bitsPerSample >> 8) & 0xff,
        0x64, 0x61, 0x74, 0x61,
        dataLenB[1], dataLenB[2], dataLenB[3], dataLenB[4]
    }

    for i = 1, #header do
        outStream.write(header[i])
    end
end

local function detectArrayBase(arr)
    local ok0, v0 = pcall(function() return arr[0] end)
    if ok0 and v0 ~= nil then
        return 0
    end
    return 1
end

local function readUnsignedByte(arr, zeroBasedPos, baseOffset)
    local ok, val = pcall(function() return arr[zeroBasedPos + baseOffset] end)
    if not ok or val == nil then return 0 end
    if val < 0 then return val + 256 end
    return val
end

function extractCleanPcmSegment(audioBytes)
    local totalLen = #audioBytes
    if totalLen <= 200 then return 0, 0 end

    local base = detectArrayBase(audioBytes)
    local pcmStart = 0
    local exactDataEnd = totalLen

    local b0 = readUnsignedByte(audioBytes, 0, base)
    local b1 = readUnsignedByte(audioBytes, 1, base)
    local b2 = readUnsignedByte(audioBytes, 2, base)
    local b3 = readUnsignedByte(audioBytes, 3, base)

    if b0 == 82 and b1 == 73 and b2 == 70 and b3 == 70 then
        pcmStart = 44
        local searchLimit = math.min(totalLen - 12, 1024)
        for i = 12, searchLimit do
            local d0 = readUnsignedByte(audioBytes, i, base)
            local d1 = readUnsignedByte(audioBytes, i + 1, base)
            local d2 = readUnsignedByte(audioBytes, i + 2, base)
            local d3 = readUnsignedByte(audioBytes, i + 3, base)
            if d0 == 100 and d1 == 97 and d2 == 116 and d3 == 97 then
                local s0 = readUnsignedByte(audioBytes, i + 4, base)
                local s1 = readUnsignedByte(audioBytes, i + 5, base)
                local s2 = readUnsignedByte(audioBytes, i + 6, base)
                local s3 = readUnsignedByte(audioBytes, i + 7, base)
                local declaredDataLen = s0 + (s1 * 256) + (s2 * 65536) + (s3 * 16777216)

                pcmStart = i + 8
                if declaredDataLen > 0 and (pcmStart + declaredDataLen) <= totalLen then
                    exactDataEnd = pcmStart + declaredDataLen
                end
                break
            end
        end
    end

    if pcmStart % 2 ~= 0 then
        pcmStart = pcmStart + 1
    end

    local startTrim = 960
    local endTrim = 2880
    local availableLen = exactDataEnd - pcmStart

    if availableLen > (startTrim + endTrim + 9600) then
        pcmStart = pcmStart + startTrim
        exactDataEnd = exactDataEnd - endTrim
    elseif availableLen > 2400 then
        pcmStart = pcmStart + 200
        exactDataEnd = exactDataEnd - 400
    end

    local pcmLen = exactDataEnd - pcmStart
    if pcmLen % 2 ~= 0 then
        pcmLen = pcmLen - 1
    end

    if pcmLen <= 0 then return 0, 0 end
    return pcmStart, pcmLen
end

function saveCleanChunkToDisk(index, rawByteArrays, chunkText, voice, style)
    if not chunksDir.exists() then chunksDir.mkdirs() end
    local chunkFile = getChunkFile(index)
    if chunkFile.exists() then chunkFile.delete() end

    local fos = FileOutputStream(chunkFile)
    local writtenBytes = 0
    local edgeSilence = byte[480]

    for i = 1, #rawByteArrays do
        local arr = rawByteArrays[i]
        local offset, pcmLen = extractCleanPcmSegment(arr)
        if pcmLen > 0 then
            fos.write(edgeSilence, 0, 480)
            fos.write(arr, offset, pcmLen)
            fos.write(edgeSilence, 0, 480)
            writtenBytes = writtenBytes + pcmLen + 960
        end
    end

    fos.flush()
    fos.close()

    if writtenBytes > 100 and chunkFile.exists() and chunkFile.length() > 100 then
        markChunkSaved(index, chunkText, voice, style)
        return true
    else
        if chunkFile.exists() then chunkFile.delete() end
        return false
    end
end

---------------------------------------------------------------------
-- Master Acoustic & Prosody Lock (Har Part ka Voice, Tone, Pitch aur Andaaz 100% Same Rakhne ke Liye)
---------------------------------------------------------------------
local MASTER_VOICE_CLONE_RULE = ". STRICT STUDIO CONTINUITY RULE: Keep the exact same vocal cords timbre, fixed fundamental pitch (F0), identical speaking rate (words per minute), flat baseline intonation, and exact microphone proximity from the first syllable to the last. Do not change voice character, do not shift accent, do not become dramatic, and read every paragraph in one uniform continuous take."

local STYLE_TEXT = {
    ["Default / Normal"] = "Deliver in a calm, steady, flat-baseline studio audiobook narrator voice with a strictly uniform medium pace, neutral emotion, and unchanging vocal pitch",
    ["Islamic: Tilawat (Sudais/Shuraim - Fixed Pace)"] = "Recite in a slow, melodic, deeply spiritual Quran recitation style at a strictly constant pace, stopping cleanly at sentence ends",
    ["Islamic: Hadees (Arabic + Tarjuma)"] = "Deliver as a dignified, respectful Islamic scholar in a calm, clear, slow, and strictly uniform tone and pace",
    ["Islamic: Dua (Humble & Crying)"] = "Deliver in a humble, pleading, prayerful voice at a slow, strictly consistent pace and pitch",
    ["Islamic: Naat / Kalam (Melodic)"] = "Deliver in a sweet, melodic, rhythmic Naat recitation style at a strictly constant tempo and pitch",
    ["Islamic: Waqia / Story (Deep & Serious)"] = "Deliver as a deep, serious, composed Islamic historical narrator at a strictly uniform medium-slow pace and fixed vocal depth",
    ["Dynamic Human (Auto-Emotion: Laugh/Cry)"] = "Deliver in a natural, warm human narrator voice while strictly keeping the exact same speaker identity, pitch baseline, and steady tempo",
    ["Cartoon: Thin & Squeaky (Patli Aawaz)"] = "Deliver in a high-pitched, squeaky cartoon character voice at a strictly constant pitch and pace",
    ["Cartoon: Thick & Goofy (Moti Aawaz)"] = "Deliver in a deep, thick, heavy goofy cartoon voice at a strictly constant slow pace and fixed low pitch",
    ["Storytelling (Expressive)"] = "Deliver as a warm, composed audiobook storyteller with a strictly steady medium pace and consistent vocal pitch",
    ["Poetry / Shayari (Deep & Rhythmic)"] = "Deliver as a deep, composed poet with measured pauses, constant tempo, and unchanging vocal depth",
    ["Horror / Scary / Suspense"] = "Deliver in a low, steady, suspenseful whisper at a strictly constant slow pace and fixed low volume",
    ["Angry / Aggressive (Gusse wala)"] = "Deliver in a firm, serious, forceful tone at a strictly controlled, constant pace and fixed pitch",
    ["Whispering / Secretive (Sargoshi)"] = "Deliver in a quiet, steady whisper at a strictly constant volume, pitch, and pace",
    ["Happy / Joyful (Khushi)"] = "Deliver in a warm, pleasant, cheerful voice at a strictly steady medium pace and consistent pitch",
    ["Comedy / Funny"] = "Deliver in a lighthearted, composed, playful narrator voice at a strictly steady pace and pitch",
    ["Romantic / Soft"] = "Deliver in a soft, warm, gentle voice at a strictly constant slow pace and fixed soft timbre",
    ["Dramatic / Thriller"] = "Deliver as a serious, focused, composed narrator at a strictly steady pace and fixed deep pitch",
    ["Sad / Emotional"] = "Deliver in a heavy, sorrowful, calm emotional voice at a strictly constant slow pace and uniform pitch",
    ["Sarcastic / Irony (Tanzana)"] = "Deliver in a dry, composed, ironic narrator voice at a strictly steady pace and flat pitch",
    ["Motivational / Inspiring"] = "Deliver as a strong, confident, composed speaker at a strictly steady, measured pace and fixed vocal tone",
    ["News / Professional"] = "Deliver as a clear, formal, professional news anchor at a strictly constant medium pace and neutral pitch",
    ["Documentary / Informative"] = "Deliver as a calm, serious, informative documentary narrator at a strictly constant pace and fixed vocal tone"
}

function getStyleText(style)
    local base = STYLE_TEXT[style]
    if not base or base == "" then
        base = STYLE_TEXT["Default / Normal"]
    end
    return base .. MASTER_VOICE_CLONE_RULE
end

---------------------------------------------------------------------
-- Text normalization & smart large-chunk splitting
---------------------------------------------------------------------
function normalizeChunkText(chunk)
    -- Punctuation jo voice ki pitch ya andaaz ko achanak badal dete hain (!, ?, ..., quotes) unhein smooth karein
    chunk = chunk:gsub("!+", ".")
    chunk = chunk:gsub("！+", ".")
    chunk = chunk:gsub("%?+", "?")
    chunk = chunk:gsub("؟+", "؟")
    chunk = chunk:gsub("%.%.%.+", ".")
    chunk = chunk:gsub("—", ", ")
    chunk = chunk:gsub("%-%-+", ", ")
    chunk = chunk:gsub("[\"\'“”‘’«»]", "")
    chunk = chunk:gsub("\n+", " ")
    chunk = chunk:gsub("%s+", " ")
    chunk = trim(chunk)

    local last1 = string.sub(chunk, -1)
    local last2 = string.sub(chunk, -2)
    local last3 = string.sub(chunk, -3)
    if last1 ~= "." and last1 ~= "?"
        and last2 ~= "۔" and last2 ~= "؟" and last3 ~= "।" then
        chunk = chunk .. "."
    end
    return chunk
end

function findSmartSplitPos(str, maxBytes)
    if #str <= maxBytes then return #str end

    local minSearch = math.floor(maxBytes * 0.65)

    for i = maxBytes, minSearch, -1 do
        local b1, b2, b3 = string.byte(str, i - 2, i)
        if (b2 == 219 and b3 == 148) or (b1 == 224 and b2 == 165 and b3 == 164) then
            return i
        end
    end

    for i = maxBytes, minSearch, -1 do
        local c = string.sub(str, i, i)
        if c == "." or c == "?" or c == "\n" then
            return i
        end
    end

    for i = maxBytes, minSearch, -1 do
        local c = string.sub(str, i, i)
        if c == "," or c == ";" or c == ":" then
            return i
        end
        local b1, b2 = string.byte(str, i - 1, i)
        if b1 == 216 and (b2 == 140 or b2 == 155) then
            return i
        end
    end

    for i = maxBytes, minSearch, -1 do
        local c = string.sub(str, i, i)
        if c == " " or c == "\t" then
            return i
        end
    end

    local pos = maxBytes
    while pos > 1 do
        local b = string.byte(str, pos + 1)
        if not b or b < 128 or b >= 192 then
            break
        end
        pos = pos - 1
    end
    return pos
end

function splitTextIntoChunks(text, maxBytes)
    local t = tostring(text or "")
    t = t:gsub("\r\n", "\n")
    t = trim(t)
    if t == "" then return {} end

    -- Agar text 5000 bytes tak hai to usay bilkul mat todein, 1 hi single part rakhein taake 100% ek hi audio bane!
    if #t <= 5000 then
        return { normalizeChunkText(t) }
    end

    local rawChunks = {}
    local remaining = t

    while #remaining > 0 do
        if #remaining <= maxBytes then
            table.insert(rawChunks, remaining)
            break
        else
            local splitPos = findSmartSplitPos(remaining, maxBytes)
            local chunk = trim(string.sub(remaining, 1, splitPos))
            if chunk ~= "" then
                table.insert(rawChunks, chunk)
            end
            remaining = trim(string.sub(remaining, splitPos + 1))
        end
    end

    -- Agar aakhri part 1200 bytes se chota ho to usay pichle part ke sath hi mila dein taake chote part par voice change na ho
    if #rawChunks > 1 and #rawChunks[#rawChunks] < 1200 then
        rawChunks[#rawChunks - 1] = rawChunks[#rawChunks - 1] .. " " .. rawChunks[#rawChunks]
        table.remove(rawChunks, #rawChunks)
    end

    local finalChunks = {}
    for i = 1, #rawChunks do
        table.insert(finalChunks, normalizeChunkText(rawChunks[i]))
    end

    return finalChunks
end

function getSavedProgressForCurrentText()
    local clean = tostring(userText or "")
    clean = clean:gsub("\r\n", "\n")
    clean = trim(clean)
    if clean == "" then return 0, 0 end

    local chunks = splitTextIntoChunks(clean, CHUNK_MAX_CHARS)
    local totalChunks = #chunks
    if totalChunks == 0 then return 0, 0 end

    local savedCount = 0
    for i = 1, totalChunks do
        if isChunkValidAndSaved(i, chunks[i], selectedVoice, selectedStyle) then
            savedCount = savedCount + 1
        else
            break
        end
    end
    return savedCount, totalChunks
end

function updateGenerateButtonStatus(generateBtn)
    if isGenerating or not generateBtn then return end

    local okP, savedCount, totalChunks = pcall(getSavedProgressForCurrentText)
    if not okP then savedCount, totalChunks = 0, 0 end

    runOnUi(function()
        local charLen = 0
        if textInputRef then
            charLen = textInputRef.getText().length()
        elseif userText then
            charLen = #userText
        end

        if charCounterRef then
            if savedCount > 0 and totalChunks > 0 then
                charCounterRef.setText("Saved: " .. tostring(savedCount) .. "/" .. tostring(totalChunks) .. " parts | " .. tostring(charLen) .. " / " .. MAX_CHAR_LIMIT)
            else
                charCounterRef.setText(tostring(charLen) .. " / " .. MAX_CHAR_LIMIT)
            end
        end

        generateBtn.setEnabled(true)
        if savedCount > 0 and savedCount < totalChunks then
            generateBtn.setText("RESUME (PART " .. tostring(savedCount + 1) .. " OF " .. tostring(totalChunks) .. ")")
            setBtnColor(generateBtn, "#FF8F00")
        elseif savedCount > 0 and savedCount == totalChunks then
            generateBtn.setText("MERGE SAVED (" .. tostring(totalChunks) .. "/" .. tostring(totalChunks) .. ")")
            setBtnColor(generateBtn, "#43A047")
        else
            generateBtn.setText("GENERATE")
            setBtnColor(generateBtn, "#2196F3")
        end
    end)
end

function extractApiError(content)
    local msg = nil
    pcall(function()
        local d = cjson.decode(content)
        if d and d.error and d.error.message then
            msg = d.error.message
        end
    end)
    return msg
end

function resetGenerateButton(generateBtn)
    isGenerating = false
    updateGenerateButtonStatus(generateBtn)
end

function cancelActiveRequest()
    if activeHttpRequest ~= nil then
        pcall(function() activeHttpRequest.cancel(true) end)
        activeHttpRequest = nil
    end
end

local function httpPost(url, body, headers, cb)
    local ok1, r1 = pcall(function() return Http.post(url, body, headers, cb) end)
    if ok1 then return true, r1 end
    local ok2, r2 = pcall(function() return Http.post(url, body, nil, "utf8", headers, cb) end)
    if ok2 then return true, r2 end
    return false, tostring(r1) .. " | " .. tostring(r2)
end

local function httpGet(url, cb)
    local ok1, r1 = pcall(function() return Http.get(url, cb) end)
    if ok1 then return true, r1 end
    local ok2, r2 = pcall(function() return Http.get(url, nil, cb) end)
    if ok2 then return true, r2 end
    return false, tostring(r1) .. " | " .. tostring(r2)
end

---------------------------------------------------------------------
-- Main generate
---------------------------------------------------------------------
function generateAudio(text, voice, style, apikey, model, generateBtn, playBtn, resultLayout)
    cancelActiveRequest()

    local chunks = splitTextIntoChunks(text, CHUNK_MAX_CHARS)
    local totalChunks = #chunks

    if totalChunks == 0 then
        resetGenerateButton(generateBtn)
        speakFeedback("Text khali hai.")
        return
    end

    local startChunkIndex = 1
    for i = 1, totalChunks do
        if isChunkValidAndSaved(i, chunks[i], voice, style) then
            startChunkIndex = i + 1
        else
            break
        end
    end

    isGenerating = true
    cancelRequested = false

    local apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent?key=" .. apikey
    local styleText = getStyleText(style)
    local headers = HashMap()
    headers.put("Content-Type", "application/json")

    local currentChunkIndex = startChunkIndex
    local retryCount = 0
    local lastProblem = ""

    local function failNow(msg)
        resetGenerateButton(generateBtn)
        speakFeedback(msg)
    end

    local function mergeAndFinish()
        local totalDurationSec = 0
        local okMerge, errMerge = pcall(function()
            deleteOldAudioFile()
            local tempPath = baseStorageDir.getPath() .. "/tts_final_" .. os.time() .. ".wav"
            local file = File(tempPath)
            local fos = FileOutputStream(file)

            local silenceBytesCount = (24000 * 2 * PAUSE_DURATION_MS) // 1000
            if silenceBytesCount % 2 ~= 0 then silenceBytesCount = silenceBytesCount + 1 end

            local validChunkFiles = {}
            local totalPcmBytes = 0

            for idx = 1, totalChunks do
                local cf = getChunkFile(idx)
                if cf.exists() and cf.length() > 100 then
                    local fLen = math.floor(cf.length())
                    if fLen % 2 ~= 0 then fLen = fLen - 1 end
                    table.insert(validChunkFiles, { file = cf, length = fLen })
                    totalPcmBytes = totalPcmBytes + fLen
                end
            end

            if #validChunkFiles > 1 then
                totalPcmBytes = totalPcmBytes + ((#validChunkFiles - 1) * silenceBytesCount)
            end

            totalDurationSec = totalPcmBytes / 48000.0

            writeWavHeader(fos, totalPcmBytes)

            local silenceBuffer = nil
            if #validChunkFiles > 1 and silenceBytesCount > 0 then
                silenceBuffer = byte[silenceBytesCount]
            end

            local copyBuffer = byte[8192]

            for idx = 1, #validChunkFiles do
                local item = validChunkFiles[idx]
                local fis = FileInputStream(item.file)
                local remaining = item.length
                while remaining > 0 do
                    local toRead = math.min(8192, remaining)
                    local readLen = fis.read(copyBuffer, 0, toRead)
                    if readLen == nil or readLen <= 0 then break end
                    fos.write(copyBuffer, 0, readLen)
                    remaining = remaining - readLen
                end
                fis.close()

                if idx < #validChunkFiles and silenceBuffer ~= nil then
                    fos.write(silenceBuffer, 0, silenceBytesCount)
                end
            end

            fos.flush()
            fos.close()
            generatedAudioPath = tempPath
        end)

        if not okMerge or not generatedAudioPath then
            failNow("Audio merge karne mein masla aaya: " .. tostring(errMerge))
            return
        end

        local shortDur, spokenDur = formatDurationText(totalDurationSec)
        currentDurationStr = shortDur

        runOnUi(function()
            local okPlay, errPlay = pcall(function()
                resultLayout.setVisibility(View.VISIBLE)
                initMediaPlayer()
                mediaPlayer.setDataSource(generatedAudioPath)
                mediaPlayer.prepare()

                local mpDurationMs = mediaPlayer.getDuration()
                if mpDurationMs and mpDurationMs > 0 then
                    shortDur, spokenDur = formatDurationText(mpDurationMs / 1000.0)
                    currentDurationStr = shortDur
                end

                if durationTextRef then
                    durationTextRef.setText("Audio Length: " .. currentDurationStr)
                end
                playBtn.setText("PLAY (" .. currentDurationStr .. ")")
                playBtn.setEnabled(true)
            end)

            isGenerating = false
            updateGenerateButtonStatus(generateBtn)

            if not okPlay then
                speakFeedback("Audio ban gayi lekin play nahi ho saki: " .. tostring(errPlay))
                return
            end

            pcall(function()
                playBtn.setFocusable(true)
                playBtn.setFocusableInTouchMode(true)
                playBtn.requestFocus()
                playBtn.sendAccessibilityEvent(AccessibilityEvent.TYPE_VIEW_FOCUSED)
            end)

            speakFeedback("Mukammal audio ek hi aawaz mein tayyar hai. Kul lambai " .. spokenDur .. " hai.")
        end)
    end

    if startChunkIndex > totalChunks then
        speakFeedback("Tamam " .. tostring(totalChunks) .. " hisse pehle se mehfooz hain, audio jodi ja rahi hai.")
        mergeAndFinish()
        return
    end

    if startChunkIndex > 1 then
        speakFeedback("Pehle " .. tostring(startChunkIndex - 1) .. " hisse save hain. Ab Hissa " .. tostring(startChunkIndex) .. " se aage ban raha hai.")
    elseif totalChunks == 1 then
        speakFeedback("Poori audio ek hi single part mein generate ho rahi hai, intezar karein.")
    else
        speakFeedback("Kul " .. tostring(totalChunks) .. " bade parts mein ek hi aawaz mein audio ban rahi hai.")
    end

    local processCurrentChunk

    local function handleResponse(code, content)
        activeHttpRequest = nil

        if cancelRequested then
            resetGenerateButton(generateBtn)
            return
        end

        local chunkText = chunks[currentChunkIndex]
        showStatus("Hissa " .. currentChunkIndex .. "/" .. totalChunks .. ": jawab mila, code = " .. tostring(code))

        -- Smart Config Fallback agar API kisi parameter par 400 de
        if code == 400 and configMode < 3 then
            configMode = configMode + 1
            showStatus("Hissa " .. currentChunkIndex .. ": compatible lock mode " .. tostring(configMode) .. " ke sath bheja ja raha hai...")
            delay(400, function() processCurrentChunk() end)
            return
        end

        if code == 200 then
            local ok, data = pcall(cjson.decode, content)
            local chunkByteArrays = {}
            lastProblem = ""

            if ok and data and data.candidates and #data.candidates > 0 then
                local candidate = data.candidates[1]
                if candidate.content and candidate.content.parts then
                    for i = 1, #candidate.content.parts do
                        local p = candidate.content.parts[i]
                        local inl = p.inlineData or p.inline_data
                        if inl and inl.data then
                            local okDec, audioBytes = pcall(function()
                                return Base64.decode(inl.data, Base64.DEFAULT)
                            end)
                            if okDec and audioBytes and #audioBytes > 0 then
                                table.insert(chunkByteArrays, audioBytes)
                            end
                        end
                    end
                end
                if #chunkByteArrays == 0 then
                    lastProblem = "Jawab mein audio nahi aayi. finishReason: " .. tostring(candidate.finishReason)
                end
            elseif ok and data and data.promptFeedback then
                lastProblem = "Request block hui: " .. tostring(data.promptFeedback.blockReason)
            else
                lastProblem = "Jawab samajh nahi aaya."
            end

            local savedOk = false
            if #chunkByteArrays > 0 then
                local okDisk, resDisk = pcall(function()
                    return saveCleanChunkToDisk(currentChunkIndex, chunkByteArrays, chunkText, voice, style)
                end)
                if okDisk and resDisk then
                    savedOk = true
                else
                    lastProblem = "Audio file save nahi ho saki: " .. tostring(resDisk)
                end
            end

            if savedOk then
                showStatus("Hissa " .. currentChunkIndex .. "/" .. totalChunks .. " save ho gaya.")
                runOnUi(function()
                    if charCounterRef and textInputRef then
                        charCounterRef.setText("Saved: " .. tostring(currentChunkIndex) .. "/" .. tostring(totalChunks) .. " parts | " .. tostring(textInputRef.getText().length()) .. " / " .. MAX_CHAR_LIMIT)
                    end
                end)

                if currentChunkIndex < totalChunks then
                    currentChunkIndex = currentChunkIndex + 1
                    retryCount = 0
                    delay(2500, function() processCurrentChunk() end)
                else
                    mergeAndFinish()
                end
                return
            else
                retryCount = retryCount + 1
                if retryCount <= MAX_RETRY then
                    showStatus("Hissa " .. currentChunkIndex .. ": dobara koshish " .. retryCount .. "/" .. MAX_RETRY .. ". " .. lastProblem)
                    delay(4000, function() processCurrentChunk() end)
                else
                    local done = currentChunkIndex - 1
                    failNow("Hissa " .. tostring(currentChunkIndex) .. " nahi ban saka. " .. lastProblem .. " Pehle " .. tostring(done) .. " hisse save hain.")
                end
            end

        elseif code == 429 or code == 500 or code == 503 or code == -1 then
            retryCount = retryCount + 1
            local apiMsg = extractApiError(content) or tostring(content)
            if retryCount <= MAX_RETRY then
                local waitMs = 2000 + (retryCount * 4000)
                runOnUi(function()
                    generateBtn.setText("WAITING SERVER (" .. currentChunkIndex .. "/" .. totalChunks .. ")...")
                end)
                showStatus("Server/network masla (code " .. tostring(code) .. "), dobara koshish " .. retryCount .. "/" .. MAX_RETRY .. ". " .. string.sub(tostring(apiMsg), 1, 150))
                delay(waitMs, function() processCurrentChunk() end)
            else
                local done = currentChunkIndex - 1
                if done > 0 then
                    failNow("Server busy ya network masla (code " .. tostring(code) .. "). Pehle " .. tostring(done) .. " hisse save hain. Thodi der baad button dabayein, Hissa " .. tostring(currentChunkIndex) .. " se aage shuru hoga. " .. string.sub(tostring(apiMsg), 1, 150))
                else
                    failNow("Server busy, quota khatam ya network masla (code " .. tostring(code) .. "): " .. string.sub(tostring(apiMsg), 1, 200))
                end
            end
        elseif code == 403 or code == 401 then
            local apiMsg = extractApiError(content)
            failNow("API key ya permission ka masla (code " .. tostring(code) .. "). " .. tostring(apiMsg or ""))
        elseif code == 404 then
            local apiMsg = extractApiError(content)
            failNow("Error 404: Model nahi mila. Setting mein dusra model chunein. " .. tostring(apiMsg or ""))
        else
            local apiMsg = extractApiError(content)
            failNow("Error " .. tostring(code) .. ": " .. tostring(apiMsg or string.sub(tostring(content), 1, 200)))
        end
    end

    local function doProcessChunk()
        if cancelRequested then
            resetGenerateButton(generateBtn)
            return
        end

        if isChunkValidAndSaved(currentChunkIndex, chunks[currentChunkIndex], voice, style) then
            if currentChunkIndex < totalChunks then
                currentChunkIndex = currentChunkIndex + 1
                processCurrentChunk()
            else
                mergeAndFinish()
            end
            return
        end

        runOnUi(function()
            if totalChunks > 1 then
                generateBtn.setText("GENERATING (" .. currentChunkIndex .. "/" .. totalChunks .. ")...")
            else
                generateBtn.setText("GENERATING (SINGLE TAKE)...")
            end
        end)

        local chunkText = chunks[currentChunkIndex]

        -- Mode 1: camelCase speechMetadata + temperature 0.0 + topK 1 + seed 424242
        -- Mode 2: snake_case speech_metadata + temperature 0.0
        -- Mode 3: Standard fallback
        local part = { text = chunkText }
        if configMode == 1 then
            part.speechMetadata = { style = styleText }
        else
            part.speech_metadata = { style = styleText }
        end

        local genConfig = {
            responseModalities = {"AUDIO"},
            speechConfig = {
                voiceConfig = {
                    voice = voice
                }
            }
        }

        if configMode == 1 then
            genConfig.temperature = 0.0
            genConfig.topP = 0.0
            genConfig.topK = 1
            genConfig.seed = 424242
        elseif configMode == 2 then
            genConfig.temperature = 0.0
            genConfig.seed = 424242
        end

        local requestBody = {
            contents = {
                {
                    role = "user",
                    parts = { part }
                }
            },
            generationConfig = genConfig
        }

        showStatus("Hissa " .. currentChunkIndex .. "/" .. totalChunks .. ": Google ko bheja ja raha hai...")

        local okPost, taskOrErr = httpPost(apiUrl, cjson.encode(requestBody), headers, function(code, content)
            local okCb, errCb = pcall(handleResponse, code, content)
            if not okCb then
                failNow("Code error (jawab): " .. tostring(errCb))
            end
        end)

        if okPost then
            activeHttpRequest = taskOrErr
        else
            failNow("Http request shuru nahi hui: " .. tostring(taskOrErr))
        end
    end

    processCurrentChunk = function()
        local ok, err = pcall(doProcessChunk)
        if not ok then
            failNow("Code error (hissa " .. tostring(currentChunkIndex) .. "): " .. tostring(err))
        end
    end

    processCurrentChunk()
end

---------------------------------------------------------------------
-- Download
---------------------------------------------------------------------
local function copyStream(input, output)
    local buffer = byte[8192]
    while true do
        local len = input.read(buffer)
        if len == nil or len == -1 then break end
        output.write(buffer, 0, len)
    end
end

function downloadAudio()
    if not generatedAudioPath then
        speakFeedback("Pehle audio generate karein.")
        return false
    end

    local sourceFile = File(generatedAudioPath)
    if not sourceFile.exists() then
        speakFeedback("Audio file nahi mili.")
        return false
    end

    local fileName = "Voice_" .. os.time() .. ".wav"
    local success = false
    local lastErr = ""

    if Build.VERSION.SDK_INT >= 29 then
        local ok, err = pcall(function()
            local input = FileInputStream(sourceFile)
            local values = ContentValues()
            values.put("_display_name", fileName)
            values.put("mime_type", "audio/x-wav")
            values.put("relative_path", Environment.DIRECTORY_DOWNLOADS)
            local resolver = context.getContentResolver()
            local DownloadsClass = luajava.bindClass("android.provider.MediaStore$Downloads")
            local uri = resolver.insert(DownloadsClass.EXTERNAL_CONTENT_URI, values)
            local output = resolver.openOutputStream(uri)
            copyStream(input, output)
            output.flush()
            output.close()
            input.close()
        end)
        if ok then success = true else lastErr = tostring(err) end
    end

    if not success then
        local ok, err = pcall(function()
            local downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            if not downloadDir.exists() then downloadDir.mkdirs() end
            local destFile = File(downloadDir, fileName)
            local input = FileInputStream(sourceFile)
            local output = FileOutputStream(destFile)
            copyStream(input, output)
            output.flush()
            output.close()
            input.close()
            pcall(function()
                local intent = Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE)
                intent.setData(Uri.fromFile(destFile))
                context.sendBroadcast(intent)
            end)
        end)
        if ok then success = true else lastErr = lastErr .. " | " .. tostring(err) end
    end

    if success then
        clearSavedChunks()
        userText = ""
        saveDraftText("")
        runOnUi(function()
            if textInputRef then textInputRef.setText("") end
            if charCounterRef then charCounterRef.setText("0 / " .. MAX_CHAR_LIMIT) end
            if generateBtnRef then
                generateBtnRef.setText("GENERATE")
                setBtnColor(generateBtnRef, "#2196F3")
            end
        end)

        speakFeedback("Audio Downloads folder mein save ho gayi hai, aur text box clear kar diya gaya hai.")
        return true
    else
        speakFeedback("Download fail ho gaya: " .. lastErr)
        return false
    end
end

---------------------------------------------------------------------
-- Dialogs
---------------------------------------------------------------------
function showSetApiDialog()
    local views = {}
    local layout = {
        LinearLayout,
        orientation = "vertical",
        padding = "20dp",
        layout_width = "fill",
        layout_height = "wrap",
        {
            EditText,
            id = "apiInput",
            hint = "API Key yahan paste karein",
            layout_width = "fill",
            layout_height = "wrap",
            backgroundColor = "#F5F5F5",
            padding = "10dp",
            textSize = 14,
            layout_marginBottom = "10dp"
        },
        {
            Button,
            id = "testBtn",
            text = "TEST API KEY",
            layout_width = "fill",
            layout_height = "wrap",
            backgroundColor = "#FF9800",
            textColor = "#FFFFFF",
            padding = "10dp",
            layout_marginBottom = "10dp"
        },
        {
            Button,
            id = "saveBtn",
            text = "SAVE API KEY",
            layout_width = "fill",
            layout_height = "wrap",
            backgroundColor = "#4CAF50",
            textColor = "#FFFFFF",
            padding = "10dp",
            layout_marginBottom = "5dp"
        }
    }

    apiDialog = LuaDialog(context)
    apiDialog.setTitle("Set API Key")
    apiDialog.setView(loadlayout(layout, views))
    apiDialog.setCancelable(true)

    views.apiInput.setText(googleApiKey)

    views.testBtn.onClick = safe("test", function()
        local key = trim(views.apiInput.getText().toString())
        if key == "" then
            speakFeedback("Pehle API key paste karein.")
            return
        end

        speakFeedback("API Key test ho rahi hai.")
        views.testBtn.setText("TESTING...")
        views.testBtn.setEnabled(false)

        local testUrl = "https://generativelanguage.googleapis.com/v1beta/models?key=" .. key
        local okGet, errGet = httpGet(testUrl, function(code, content)
            runOnUi(function()
                views.testBtn.setText("TEST API KEY")
                views.testBtn.setEnabled(true)
                if code == 200 then
                    speakFeedback("API key durust hai.")
                else
                    speakFeedback("API key durust nahi hai. Code: " .. tostring(code) .. " " .. tostring(extractApiError(content) or ""))
                end
            end)
        end)
        if not okGet then
            views.testBtn.setText("TEST API KEY")
            views.testBtn.setEnabled(true)
            speakFeedback("Test request shuru nahi hui: " .. tostring(errGet))
        end
    end)

    views.saveBtn.onClick = safe("saveKey", function()
        local apikey = trim(views.apiInput.getText().toString())
        if apikey == "" then
            speakFeedback("Pehle API key paste karein.")
            return
        end
        googleApiKey = apikey
        saveSettings()
        speakFeedback("API key save ho gayi hai.")
        apiDialog.dismiss()
    end)

    apiDialog.show()
end

function showSettingsDialog()
    local views = {}
    local layout = {
        LinearLayout,
        orientation = "vertical",
        padding = "20dp",
        layout_width = "fill",
        layout_height = "wrap",
        {
            Button,
            id = "setApiBtn",
            text = "SET API KEY",
            layout_width = "fill",
            layout_height = "wrap",
            backgroundColor = "#2196F3",
            textColor = "#FFFFFF",
            padding = "12dp",
            layout_marginBottom = "15dp"
        },
        {
            TextView,
            text = "Select Model:",
            textSize = 14,
            textColor = "#333333",
            paddingBottom = "5dp"
        },
        {
            Spinner,
            id = "modelSpin",
            layout_width = "fill",
            layout_height = "wrap",
            backgroundColor = "#F5F5F5",
            layout_marginBottom = "20dp"
        },
        {
            Button,
            id = "goBackBtn",
            text = "GO BACK",
            layout_width = "fill",
            layout_height = "wrap",
            backgroundColor = "#9E9E9E",
            textColor = "#FFFFFF",
            padding = "12dp"
        }
    }

    settingDialog = LuaDialog(context)
    settingDialog.setTitle("Settings")
    settingDialog.setView(loadlayout(layout, views))
    settingDialog.setCancelable(true)

    views.setApiBtn.onClick = safe("setApi", function()
        vibrate()
        showSetApiDialog()
    end)

    local modelAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, MODEL_LIST)
    modelAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
    views.modelSpin.setAdapter(modelAdapter)

    for i, m in ipairs(MODEL_LIST) do
        if m == selectedModel then
            views.modelSpin.setSelection(i - 1)
            break
        end
    end

    views.modelSpin.onItemSelectedListener = {
        onItemSelected = function(p, v, pos)
            local newModel = MODEL_LIST[pos + 1]
            if newModel and newModel ~= selectedModel then
                selectedModel = newModel
                saveSettings()
                if generateBtnRef then updateGenerateButtonStatus(generateBtnRef) end
            end
        end
    }

    views.goBackBtn.onClick = function()
        settingDialog.dismiss()
    end

    settingDialog.show()
end

---------------------------------------------------------------------
-- Main screen
---------------------------------------------------------------------
function showMain()
    isUiInitializing = true
    loadSettings()
    initMediaPlayer()

    local views = {}
    local mainLayout = {
        LinearLayout,
        orientation = "vertical",
        layout_width = "fill",
        layout_height = "fill",
        {
            ScrollView,
            layout_width = "fill",
            layout_height = "0dp",
            layout_weight = "1",
            {
                LinearLayout,
                orientation = "vertical",
                padding = "24dp",
                layout_width = "fill",
                layout_height = "wrap",
                {
                    TextView,
                    text = "Google Gemini Text to Speech",
                    textSize = 20,
                    textColor = "#2E7D32",
                    gravity = "center",
                    paddingBottom = "20dp",
                    typeface = Typeface.DEFAULT_BOLD
                },
                {
                    TextView,
                    text = "Select Voice:",
                    textSize = 13,
                    textColor = "#333333",
                    paddingBottom = "4dp"
                },
                {
                    Spinner,
                    id = "voiceSpin",
                    layout_width = "fill",
                    layout_height = "wrap",
                    backgroundColor = "#F5F5F5",
                    layout_marginBottom = "15dp"
                },
                {
                    TextView,
                    text = "Select Mood / Style:",
                    textSize = 13,
                    textColor = "#333333",
                    paddingBottom = "4dp"
                },
                {
                    Spinner,
                    id = "styleSpin",
                    layout_width = "fill",
                    layout_height = "wrap",
                    backgroundColor = "#F5F5F5",
                    layout_marginBottom = "15dp"
                },
                {
                    EditText,
                    id = "textInput",
                    hint = "Yahan apna text paste karein (Max 15,000 chars)...",
                    layout_width = "fill",
                    layout_height = "160dp",
                    backgroundColor = "#F5F5F5",
                    padding = "12dp",
                    gravity = Gravity.TOP,
                    textSize = 14,
                    layout_marginBottom = "6dp"
                },
                {
                    LinearLayout,
                    orientation = "horizontal",
                    layout_width = "fill",
                    layout_height = "wrap",
                    gravity = "center_vertical",
                    layout_marginBottom = "10dp",
                    {
                        Button,
                        id = "clearTextBtn",
                        text = "CLEAR TEXT",
                        layout_width = "wrap",
                        layout_height = "wrap",
                        backgroundColor = "#78909C",
                        textColor = "#FFFFFF",
                        textSize = 11,
                        paddingLeft = "12dp",
                        paddingRight = "12dp",
                        paddingTop = "6dp",
                        paddingBottom = "6dp"
                    },
                    {
                        TextView,
                        id = "charCounter",
                        text = "0 / " .. MAX_CHAR_LIMIT,
                        layout_width = "0dp",
                        layout_weight = "1",
                        textSize = 12,
                        textColor = "#888888",
                        gravity = "right"
                    }
                }
            }
        },
        {
            LinearLayout,
            orientation = "vertical",
            layout_width = "fill",
            layout_height = "wrap",
            paddingLeft = "24dp",
            paddingRight = "24dp",
            paddingTop = "10dp",
            paddingBottom = "30dp",
            {
                TextView,
                id = "statusText",
                text = "Tayyar hai.",
                layout_width = "fill",
                layout_height = "wrap",
                textSize = 12,
                textColor = "#1565C0",
                paddingBottom = "8dp"
            },
            {
                Button,
                id = "generateBtn",
                text = "GENERATE",
                layout_width = "fill",
                layout_height = "wrap",
                backgroundColor = "#2196F3",
                textColor = "#FFFFFF",
                padding = "14dp",
                textSize = 15,
                layout_marginBottom = "10dp"
            },
            {
                LinearLayout,
                id = "resultLayout",
                orientation = "vertical",
                layout_width = "fill",
                layout_height = "wrap",
                visibility = View.GONE,
                layout_marginBottom = "10dp",
                {
                    TextView,
                    id = "durationLabel",
                    text = "Audio Length: 0 min 00 sec",
                    textSize = 14,
                    textColor = "#1B5E20",
                    gravity = "center",
                    paddingBottom = "6dp",
                    typeface = Typeface.DEFAULT_BOLD
                },
                {
                    LinearLayout,
                    orientation = "horizontal",
                    layout_width = "fill",
                    layout_height = "wrap",
                    {
                        Button,
                        id = "playBtnID",
                        text = "PLAY",
                        layout_width = "0dp",
                        layout_weight = "1",
                        backgroundColor = "#4CAF50",
                        textColor = "#FFFFFF",
                        padding = "12dp",
                        layout_marginRight = "5dp",
                        enabled = false
                    },
                    {
                        Button,
                        id = "downloadBtn",
                        text = "DOWNLOAD",
                        layout_width = "0dp",
                        layout_weight = "1",
                        backgroundColor = "#FF9800",
                        textColor = "#FFFFFF",
                        padding = "12dp",
                        layout_marginLeft = "5dp"
                    }
                }
            },
            {
                LinearLayout,
                orientation = "horizontal",
                layout_width = "fill",
                layout_height = "wrap",
                {
                    Button,
                    id = "settingBtn",
                    text = "SETTING",
                    layout_width = "0dp",
                    layout_weight = "1",
                    backgroundColor = "#607D8B",
                    textColor = "#FFFFFF",
                    padding = "12dp",
                    layout_marginRight = "5dp"
                },
                {
                    Button,
                    id = "exitBtn",
                    text = "EXIT",
                    layout_width = "0dp",
                    layout_weight = "1",
                    backgroundColor = "#D32F2F",
                    textColor = "#FFFFFF",
                    padding = "12dp",
                    layout_marginLeft = "5dp"
                }
            }
        }
    }

    mainDialog = LuaDialog(context)
    mainDialog.setTitle("Google Gemini Text to Speech")
    mainDialog.setCancelable(false)
    mainDialog.setView(loadlayout(mainLayout, views))

    playBtnRef = views.playBtnID
    generateBtnRef = views.generateBtn
    textInputRef = views.textInput
    charCounterRef = views.charCounter
    resultLayoutRef = views.resultLayout
    durationTextRef = views.durationLabel
    statusTextRef = views.statusText

    pcall(function()
        views.textInput.setFilters({InputFilter.LengthFilter(MAX_CHAR_LIMIT)})
    end)

    if userText ~= nil and userText ~= "" then
        views.textInput.setText(userText)
    end

    views.textInput.addTextChangedListener({
        afterTextChanged = function(editable)
            if isUiInitializing then return end
            pcall(function()
                local newTxt = editable.toString()
                if newTxt ~= userText then
                    userText = newTxt
                    saveDraftText(userText)
                end
                updateGenerateButtonStatus(views.generateBtn)
            end)
        end
    })

    views.clearTextBtn.onClick = safe("clear", function()
        vibrate()
        if isGenerating then
            speakFeedback("Pehle audio banne ka intezar karein.")
            return
        end
        userText = ""
        saveDraftText("")
        clearSavedChunks()
        deleteOldAudioFile()
        views.textInput.setText("")
        views.charCounter.setText("0 / " .. MAX_CHAR_LIMIT)
        views.resultLayout.setVisibility(View.GONE)
        updateGenerateButtonStatus(views.generateBtn)
        speakFeedback("Text aur pichle tamam saved parts clear kar diye gaye hain.")
    end)

    local voiceAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, VOICE_LIST)
    voiceAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
    views.voiceSpin.setAdapter(voiceAdapter)

    for i, v in ipairs(RAW_VOICES) do
        if v == selectedVoice then
            views.voiceSpin.setSelection(i - 1)
            break
        end
    end

    views.voiceSpin.onItemSelectedListener = {
        onItemSelected = function(p, v, pos)
            local newVoice = RAW_VOICES[pos + 1]
            if not isUiInitializing and newVoice and newVoice ~= selectedVoice then
                selectedVoice = newVoice
                saveSettings()
                updateGenerateButtonStatus(views.generateBtn)
            end
        end
    }

    local styleAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, STYLE_LIST)
    styleAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
    views.styleSpin.setAdapter(styleAdapter)

    for i, s in ipairs(STYLE_LIST) do
        if s == selectedStyle then
            views.styleSpin.setSelection(i - 1)
            break
        end
    end

    views.styleSpin.onItemSelectedListener = {
        onItemSelected = function(p, v, pos)
            local newStyle = STYLE_LIST[pos + 1]
            if not isUiInitializing and newStyle and newStyle ~= selectedStyle then
                selectedStyle = newStyle
                saveSettings()
                updateGenerateButtonStatus(views.generateBtn)
            end
        end
    }

    views.playBtnID.onClick = safe("play", function()
        if not generatedAudioPath then
            speakFeedback("Pehle audio generate karein.")
            return
        end
        if mediaPlayer == nil then
            initMediaPlayer()
            mediaPlayer.setDataSource(generatedAudioPath)
            mediaPlayer.prepare()
        end
        togglePlayPause(views.playBtnID)
    end)

    views.downloadBtn.onClick = safe("download", function()
        vibrate()
        downloadAudio()
    end)

    views.generateBtn.onClick = safe("generate", function()
        if isGenerating then
            speakFeedback("Audio pehle se ban rahi hai, intezar karein.")
            return
        end

        local currentText = views.textInput.getText().toString()
        if currentText == "" or currentText:match("^%s*$") then
            speakFeedback("Pehle box mein text paste karein.")
            vibrate()
            return
        end

        if googleApiKey == "" then
            speakFeedback("API key set nahi hai. Pehle setting mein jakar API key set karein.")
            vibrate()
            return
        end

        userText = currentText
        saveDraftText(userText)
        currentDurationStr = ""

        if mediaPlayer ~= nil then
            if isPlaying then
                pcall(function() mediaPlayer.stop() end)
                isPlaying = false
            end
            pcall(function() mediaPlayer.release() end)
            mediaPlayer = nil
        end

        deleteOldAudioFile()

        views.playBtnID.setEnabled(false)
        views.playBtnID.setText("PLAY")
        views.durationLabel.setText("Audio Length: 0 min 00 sec")
        views.resultLayout.setVisibility(View.GONE)
        isPlaying = false

        views.generateBtn.setEnabled(false)
        views.generateBtn.setText("CHECKING SAVED PARTS...")
        setBtnColor(views.generateBtn, "#9E9E9E")

        generateAudio(userText, selectedVoice, selectedStyle, googleApiKey, selectedModel, views.generateBtn, views.playBtnID, views.resultLayout)
    end)

    views.settingBtn.onClick = safe("setting", function()
        vibrate()
        showSettingsDialog()
    end)

    views.exitBtn.onClick = function()
        cancelRequested = true
        isGenerating = false
        cancelActiveRequest()
        if mediaPlayer ~= nil then
            pcall(function()
                if isPlaying then mediaPlayer.stop() end
                mediaPlayer.release()
            end)
            mediaPlayer = nil
            isPlaying = false
        end
        pcall(function() saveDraftText(views.textInput.getText().toString()) end)
        mainDialog.dismiss()
    end

    mainDialog.show()

    delay(300, function()
        isUiInitializing = false
        updateGenerateButtonStatus(views.generateBtn)
    end)
end

local okMain, errMain = pcall(showMain)
if not okMain then
    pcall(function() Toast.makeText(context, "Script start error: " .. tostring(errMain), Toast.LENGTH_LONG).show() end)
    pcall(function() service.speak("Script start error: " .. tostring(errMain)) end)
end