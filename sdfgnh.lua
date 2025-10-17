
--// SERVICES
local HttpService = game:GetService("HttpService")

--// MAIN WEBHOOK FUNCTION
function SendDiscordWebhook(url, embedData)
    local headers = {["Content-Type"] = "application/json"}

    local payload = {
        ["content"] = embedData.content or nil,
        ["embeds"] = {
            {
                ["title"] = embedData.title or "VaderHug",
                ["description"] = embedData.description or "No description",
                ["color"] = embedData.color or 65280,
                ["thumbnail"] = {
                    ["url"] = embedData.thumbnail or "https://cdn.discordapp.com/attachments/1371886936314216550/1428757579131129856/IMG_5599-removebg-preview.png"
                },
                ["footer"] = {
                    ["text"] = embedData.footer or ("")
                }
            }
        }
    }

    local body = HttpService:JSONEncode(payload)
    local success, response = pcall(function()
        return request({
            Url = url,
            Method = "POST",
            Headers = headers,
            Body = body
        })
    end)

    if success then
        print("✅ Webhook Sent!")
    else
        warn("❌ Webhook Error:", response)
    end
end

local p = game.Players.LocalPlayer

SendDiscordWebhook(_G.webhookURL, {
    title = "VaderHug",
    description = string.format("Username : %s\nGems : %s", p.Name, tostring(p:GetAttribute("Diamonds"))),
    color = 16711680, -- red example
    thumbnail = "https://cdn.discordapp.com/attachments/1371886936314216550/1428757579131129856/IMG_5599-removebg-preview.png",
})
