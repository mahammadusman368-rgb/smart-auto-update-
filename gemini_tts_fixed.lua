require "import"
import "com.androlua.Http"
import "cjson"
import "com.androlua.LuaDialog"
import "android.widget.*"
import "android.view.*"
import "android.content.Context"
import "android.content.Intent"
import "android.net.Uri"
import "android.media.MediaPlayer"
import "android.util.Base64"
import "android.os.*"
import "android.graphics.Typeface"
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

pcall(function()
    Http.setConnTimeout(60000)
    Http.setReadTimeout(120000)
end)

local VOICE_LIST = {
    "Puck (Male)", "Kore (Female)", "Charon (Male)", "Zephyr (Female)",
    "Fenrir (Male)", "Leda (Female)", "Orus (Male)", "Aoede (Female)",
    "Callirrhoe (Female)", "Autonoe (Female)", "Enceladus (Male)", "Iapetus (Male)",
    "Umbriel (Male)", "Algieba (Female)", "Despina (Female)", "Erinome (Female)",
    "Algenib (Male)", "Rasalgethi (Male)", "Laomedeia (Female)", "Achernar (Male)",
    "Alnilam (Male)", "Schedar (Male)", "Gacrux (Male)", "Pulcherrima (Female)"
}

local RAW_VOICES = {
    "Puck", "Kore", "Charon", "Zephyr", "Fenrir", "Leda",
    "Orus", "Aoede", "Callirrhoe", "Autonoe", "Enceladus", "Iapetus",
    "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi",
    "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima"
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

-- Sirf wohi models jo abhi chal rahe hain (Gemini 3.8 TTS)
local MODEL_LIST = {
    "gemini-3.8-flash-tts",
    "gemini-3.8-flash-lite-tts"
}
local DEFAULT_MODEL = "gemini-3.8-flash-tts"

local MAX_CHAR_LIMIT = 4000
local selectedVoice = "Puck"
local selectedStyle = "Default / Normal"
local selectedModel = DEFAULT_MODEL
local userText = ""
local generatedAudioPath = nil
local mediaPlayer = nil
local isPlaying = false
local googleApiKey = ""

local activeHttpRequest = nil
local retryCount = 0
local MAX_RETRY = 3

local PREFS_NAME = "Jieshuo_Gemini_TTS_Pro_Max"
local prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

function showToast(msg)
    mainHandler.post(Runnable({ run = function()
        Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
    end }))
end

function speakFeedback(msg)
    local success = pcall(function()
        service.speak(msg)
    end)
    if not success then
        showToast(msg)
    end
end

function runOnUi(callback)
    mainHandler.post(Runnable({ run = callback }))
end

function delay(ms, callback)
    local handler = Handler(Looper.getMainLooper())
    handler.postDelayed(Runnable({ run = callback }), ms)
end

function vibrate()
    local vibrator = context.getSystemService(Context.VIBRATOR_SERVICE)
    if vibrator then pcall(function() vibrator.vibrate(35) end) end
end

function saveSettings()
    local editor = prefs.edit()
    editor.putString("voice", selectedVoice)
    editor.putString("style", selectedStyle)
    editor.putString("model", selectedModel)
    editor.putString("apikey", googleApiKey)
    editor.apply()
end

function loadSettings()
    selectedVoice = prefs.getString("voice", "Puck")
    selectedStyle = prefs.getString("style", "Default / Normal")
    selectedModel = prefs.getString("model", DEFAULT_MODEL)
    googleApiKey = prefs.getString("apikey", "")

    -- Purana/band model save ho to default par wapas
    local valid = false
    for _, m in ipairs(MODEL_LIST) do
        if m == selectedModel then valid = true break end
    end
    if not valid then
        selectedModel = DEFAULT_MODEL
        saveSettings()
    end
end

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
                if playBtnRef then playBtnRef.setText("PLAY") end
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
        runOnUi(function() playBtn.setText("PLAY") end)
    else
        pcall(function()
            mediaPlayer.start()
            isPlaying = true
            runOnUi(function() playBtn.setText("PAUSE") end)
        end)
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

-- Sirf tab chalta hai jab API raw PCM de (Gemini 3.8 poori WAV file deta hai)
function writeWavHeader(outStream, totalAudioLen)
    local sampleRate = 24000
    local channels = 1
    local bitsPerSample = 16
    local byteRate = sampleRate * channels * (bitsPerSample // 8)
    local blockAlign = channels * (bitsPerSample // 8)

    local totalSize = totalAudioLen + 36

    local function getBytes(val)
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

-- Gemini 3.8 TTS mein style "speechMetadata.style" mein jaata hai (text mein nahi),
-- warna model instruction ko bhi parh deta hai.
local STYLE_TEXT = {
    ["Islamic: Tilawat (Sudais/Shuraim - Fixed Pace)"] = "Recite in the style of Qari Abdur Rahman As-Sudais or Saud Al-Shuraim: slow, melodic, deeply spiritual, steady pace. Do not stretch the final word of any sentence beyond 1.5 to 2 seconds; stop cleanly.",
    ["Islamic: Hadees (Arabic + Tarjuma)"] = "Dignified Islamic scholar. Read Arabic with accurate pronunciation and deep respect. For the translation, use a calm, clear, slow, respectful scholarly tone.",
    ["Islamic: Dua (Humble & Crying)"] = "Deeply humble believer. Read Arabic with reverence. For the translation, use an emotional, pleading, tearful voice like someone crying out to Allah in prayer.",
    ["Islamic: Naat / Kalam (Melodic)"] = "Naat Khawan style: beautiful, sweet, melodic and rhythmic, like a poetic Kalam, with no background music.",
    ["Islamic: Waqia / Story (Deep & Serious)"] = "Captivating storyteller narrating a profound Islamic historical event, in a deep, moving and serious tone.",
    ["Dynamic Human (Auto-Emotion: Laugh/Cry)"] = "Highly expressive human. Change emotion with the text context: laugh and sound joyful when happy, sound emotional and heavy when sad. React naturally.",
    ["Cartoon: Thin & Squeaky (Patli Aawaz)"] = "Very high-pitched, squeaky, fast and funny cartoon voice, like a cute baby or animated character.",
    ["Cartoon: Thick & Goofy (Moti Aawaz)"] = "Very deep, thick, heavy, goofy and funny cartoon voice, like a big friendly giant.",
    ["Storytelling (Expressive)"] = "Engaging, dramatic and expressive storyteller.",
    ["Poetry / Shayari (Deep & Rhythmic)"] = "Passionate poet: deep, rhythmic tone with artistic pauses and intense emotion.",
    ["Horror / Scary / Suspense"] = "Terrified, breathless, creepy whisper, as if hiding from something dangerous.",
    ["Angry / Aggressive (Gusse wala)"] = "Extremely angry and furious: loud, aggressive and fast-paced.",
    ["Whispering / Secretive (Sargoshi)"] = "Quiet, secretive, whispering voice.",
    ["Happy / Joyful (Khushi)"] = "Extreme joy, laughter and high energy. Incredibly happy.",
    ["Comedy / Funny"] = "Humorous, upbeat, playful comedy style.",
    ["Romantic / Soft"] = "Soft, warm, gentle and deeply romantic tone.",
    ["Dramatic / Thriller"] = "Dramatic, intense, fast-paced and thrilling.",
    ["Sad / Emotional"] = "Broken, crying voice, devastated and in deep pain.",
    ["Sarcastic / Irony (Tanzana)"] = "Highly sarcastic, mocking and ironic tone.",
    ["Motivational / Inspiring"] = "Powerful motivational speaker: strong, confident, loud and uplifting.",
    ["News / Professional"] = "Clear, formal, fast, professional news anchor.",
    ["Documentary / Informative"] = "Calm, steady, serious and informative documentary narrator."
}

function getStyleText(style)
    return STYLE_TEXT[style]
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
    runOnUi(function()
        generateBtn.setEnabled(true)
        generateBtn.setText("GENERATE")
        generateBtn.setBackgroundColor(0xFF2196F3)
    end)
end

function generateAudio(text, voice, style, apikey, model, generateBtn, playBtn, resultLayout)
    if activeHttpRequest ~= nil then
        pcall(function()
            if activeHttpRequest.cancel then activeHttpRequest.cancel() end
        end)
        activeHttpRequest = nil
    end

    retryCount = 0

    -- v1beta: Gemini 3.8 TTS GA models yahin par hain
    local apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent?key=" .. apikey

    local part = { text = text }
    local styleText = getStyleText(style)
    if styleText then
        part.speechMetadata = { style = styleText }
    end

    local requestBody = {
        contents = {
            {
                role = "user",
                parts = { part }
            }
        },
        generationConfig = {
            responseModalities = {"AUDIO"},
            speechConfig = { voiceConfig = { voice = voice } }
        }
    }

    local headers = HashMap()
    headers.put("Content-Type", "application/json")

    speakFeedback("Audio generate ho rahi hai, intezar karein.")

    local function makeRequest()
        activeHttpRequest = Http.post(apiUrl, cjson.encode(requestBody), headers, function(code, content)
            activeHttpRequest = nil

            if code == 200 then
                local ok, data = pcall(cjson.decode, content)
                if ok and data and data.candidates and #data.candidates > 0 then
                    local candidate = data.candidates[1]
                    local base64Audio = nil

                    if candidate.content and candidate.content.parts then
                        for i = 1, #candidate.content.parts do
                            local p = candidate.content.parts[i]
                            local inl = p.inlineData or p.inline_data
                            if inl and inl.data then
                                base64Audio = inl.data
                                break
                            end
                        end
                    end

                    if base64Audio then
                        local audioBytes = Base64.decode(base64Audio, Base64.DEFAULT)
                        deleteOldAudioFile()
                        local tempPath = context.getCacheDir().getPath() .. "/tts_" .. os.time() .. ".wav"
                        local file = File(tempPath)
                        local fos = FileOutputStream(file)

                        -- Agar data pehle se WAV hai ("RIFF") to seedha likho, warna header lagao
                        local isWav = (#audioBytes > 4)
                            and (audioBytes[0] == 82) and (audioBytes[1] == 73)
                            and (audioBytes[2] == 70) and (audioBytes[3] == 70)
                        if not isWav then
                            writeWavHeader(fos, #audioBytes)
                        end
                        fos.write(audioBytes)
                        fos.close()
                        generatedAudioPath = tempPath

                        runOnUi(function()
                            local okPlay, err = pcall(function()
                                resultLayout.setVisibility(View.VISIBLE)
                                initMediaPlayer()
                                mediaPlayer.setDataSource(generatedAudioPath)
                                mediaPlayer.prepare()
                                playBtn.setEnabled(true)
                            end)
                            generateBtn.setEnabled(true)
                            generateBtn.setText("GENERATE")
                            generateBtn.setBackgroundColor(0xFF2196F3)
                            if not okPlay then
                                speakFeedback("Audio ban gayi lekin play nahi ho saki.")
                                return
                            end

                            pcall(function()
                                playBtn.setFocusable(true)
                                playBtn.setFocusableInTouchMode(true)
                                playBtn.requestFocus()
                                playBtn.sendAccessibilityEvent(AccessibilityEvent.TYPE_VIEW_FOCUSED)
                            end)
                        end)

                        speakFeedback("Audio successfully generate ho gayi hai.")
                        return
                    end
                end
                resetGenerateButton(generateBtn)
                speakFeedback("API ne audio nahi di. Text block ho sakta hai ya model ne sirf text bheja.")

            elseif code == 429 or code == 500 or code == 503 then
                retryCount = retryCount + 1
                if retryCount <= MAX_RETRY then
                    delay(4000, function() makeRequest() end)
                else
                    resetGenerateButton(generateBtn)
                    speakFeedback("Server busy hai ya quota khatam hai, kuch der baad koshish karein.")
                end
            elseif code == 403 or code == 401 then
                resetGenerateButton(generateBtn)
                speakFeedback("API key ya permission ka masla hai.")
            elseif code == 404 then
                resetGenerateButton(generateBtn)
                speakFeedback("Error 404: Yeh model nahi mila. Setting mein dusra model chunein.")
            else
                resetGenerateButton(generateBtn)
                local apiMsg = extractApiError(content)
                if apiMsg then
                    speakFeedback("Error " .. tostring(code) .. ": " .. apiMsg)
                else
                    speakFeedback("Network masla. Error code: " .. tostring(code))
                end
            end
        end)
    end

    makeRequest()
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
    local downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)

    if not downloadDir.exists() then downloadDir.mkdirs() end

    local destFile = File(downloadDir, fileName)
    local success = false

    pcall(function()
        local input = FileInputStream(sourceFile)
        local output = FileOutputStream(destFile)
        local buffer = byte[8192]
        local len
        while true do
            len = input.read(buffer)
            if len == -1 then break end
            output.write(buffer, 0, len)
        end
        output.close()
        input.close()
        success = true
    end)

    if success then
        speakFeedback("Audio storage mein download ho gayi hai.")
        pcall(function()
            local intent = Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE)
            intent.setData(Uri.fromFile(destFile))
            context.sendBroadcast(intent)
        end)
        return true
    else
        speakFeedback("Download fail ho gaya.")
        return false
    end
end

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

    views.testBtn.onClick = function()
        local key = views.apiInput.getText().toString()
        if key == "" then
            speakFeedback("Pehle API key paste karein.")
            return
        end

        speakFeedback("API Key test ho rahi hai.")
        views.testBtn.setText("TESTING...")
        views.testBtn.setEnabled(false)

        local testUrl = "https://generativelanguage.googleapis.com/v1beta/models?key=" .. key
        Http.get(testUrl, nil, function(code, content)
            runOnUi(function()
                views.testBtn.setText("TEST API KEY")
                views.testBtn.setEnabled(true)
                if code == 200 then
                    speakFeedback("API key durust hai.")
                else
                    speakFeedback("API key durust nahi hai.")
                end
            end)
        end)
    end

    views.saveBtn.onClick = function()
        local apikey = views.apiInput.getText().toString()
        if apikey == "" then
            speakFeedback("Pehle API key paste karein.")
            return
        end
        googleApiKey = apikey
        saveSettings()
        speakFeedback("API key save ho gayi hai.")
        apiDialog.dismiss()
    end

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

    views.setApiBtn.onClick = function()
        vibrate()
        showSetApiDialog()
    end

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
            selectedModel = MODEL_LIST[pos + 1]
            saveSettings()
        end
    }

    views.goBackBtn.onClick = function()
        settingDialog.dismiss()
    end

    settingDialog.show()
end

function showMain()
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
                    hint = "Yahan apna text paste karein...",
                    layout_width = "fill",
                    layout_height = "160dp",
                    backgroundColor = "#F5F5F5",
                    padding = "12dp",
                    gravity = Gravity.TOP,
                    textSize = 14,
                    layout_marginBottom = "4dp"
                },
                {
                    TextView,
                    id = "charCounter",
                    text = "0 / " .. MAX_CHAR_LIMIT,
                    textSize = 12,
                    textColor = "#888888",
                    gravity = "right",
                    paddingBottom = "15dp"
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
                orientation = "horizontal",
                layout_width = "fill",
                layout_height = "wrap",
                visibility = View.GONE,
                layout_marginBottom = "10dp",
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
                    layout_marginRight = "5dp",
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

    pcall(function()
        views.textInput.setFilters({InputFilter.LengthFilter(MAX_CHAR_LIMIT)})
    end)

    views.textInput.addTextChangedListener({
        afterTextChanged = function(editable)
            userText = editable.toString()
            views.charCounter.setText(#userText .. " / " .. MAX_CHAR_LIMIT)
        end
    })

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
            selectedVoice = RAW_VOICES[pos + 1]
            saveSettings()
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
            selectedStyle = STYLE_LIST[pos + 1]
            saveSettings()
        end
    }

    views.playBtnID.onClick = function()
        if not generatedAudioPath then
            speakFeedback("Pehle audio generate karein.")
            return
        end
        if mediaPlayer == nil then
            initMediaPlayer()
            pcall(function()
                mediaPlayer.setDataSource(generatedAudioPath)
                mediaPlayer.prepare()
            end)
        end
        togglePlayPause(views.playBtnID)
    end

    views.downloadBtn.onClick = function()
        vibrate()
        downloadAudio()
    end

    views.generateBtn.onClick = function()
        local currentText = views.textInput.getText().toString()
        if currentText == "" then
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
        views.resultLayout.setVisibility(View.GONE)
        isPlaying = false

        views.generateBtn.setEnabled(false)
        views.generateBtn.setText("GENERATING...")
        views.generateBtn.setBackgroundColor(0xFF9E9E9E)

        generateAudio(userText, selectedVoice, selectedStyle, googleApiKey, selectedModel, views.generateBtn, views.playBtnID, views.resultLayout)
    end

    views.settingBtn.onClick = function()
        vibrate()
        showSettingsDialog()
    end

    views.exitBtn.onClick = function()
        if activeHttpRequest ~= nil then
            pcall(function() activeHttpRequest.cancel() end)
            activeHttpRequest = nil
        end
        if mediaPlayer ~= nil then
            pcall(function() mediaPlayer.release() end)
            mediaPlayer = nil
        end
        deleteOldAudioFile()
        mainDialog.dismiss()
    end

    mainDialog.show()
end

showMain()
