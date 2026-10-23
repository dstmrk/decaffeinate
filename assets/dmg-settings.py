# dmgbuild settings for the release .dmg. CI runs:
#   dmgbuild -s assets/dmg-settings.py -D app=... -D icon=... -D background=... Decaffeinate <out.dmg>
# Window size and icon positions must match assets/render-dmg-background.swift.
format = "UDZO"
files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # volume icon
background = defines["background"]
window_rect = ((200, 120), (660, 400))
icon_size = 128
text_size = 14
icon_locations = {"Decaffeinate.app": (170, 180), "Applications": (490, 180)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
