# dmgbuild settings for the SILLOG install window: the app on the left, Applications on the right, the arrow in the background.
# make-dmg.sh passes -D app=<SILLOG.app> -D background=<tiff>. Toolbar, sidebar and status bar are off by default in dmgbuild.
import os.path

app = defines["app"]
name = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [name]
icon_locations = {name: (180, 165), "Applications": (480, 165)}

background = defines["background"]
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13

format = "UDZO"
