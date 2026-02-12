import os

app = defines.get("app", "TypeWhisper")
app_path = defines.get("app_path")

files = [app_path] if app_path else []

symlinks = {
    "Applications": "/Applications",
}

background = defines.get("background") or os.path.join(os.getcwd(), ".github", "dmg-background.png")

icon_locations = {
    f"{app}.app": (140, 156),
    "Applications": (336, 156),
}

window_rect = ((100, 100), (580, 442))
icon_size = 80
text_size = 12
format = "UDZO"
