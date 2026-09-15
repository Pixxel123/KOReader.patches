# KOReader.patches

User patches for KOReader. I use them on a Kindle Paperwhite, mostly for reading manga through Rakuyomi. There are longer notes at the top of each file.

### [🞂 How to install a user patch?](https://koreader.rocks/user_guide/#L2-userpatches)

Tested on KOReader 2026.07.

### [🞂 2-manga-nightmode.lua](2-manga-nightmode.lua)

Turns night mode off while a comic is open and turns it back on when you close it, so artwork isn't shown inverted. AutoWarmth's night mode schedule can't switch it back on while you're reading a comic, but you can still turn it on by hand from the menu or with a gesture. Night mode schedules from other plugins might not be held off.

### [🞂 2-manga-no-history.lua](2-manga-no-history.lua)

Keeps comics out of History, so a comic never becomes the last opened book. Comics already in History are removed the first time KOReader starts with this patch.

### [🞂 2-manga-no-stats.lua](2-manga-no-stats.lua)

Stops the Reading statistics plugin from recording comics. Anything recorded before you install it stays in the statistics database.

The three manga patches treat .cbz, .cbr and .cbt files as comics. If you change that list, change it in all three files.

### [🞂 2-rakuyomi-sleep-cover.lua](2-rakuyomi-sleep-cover.lua)

For the [tachibana-shin fork of Rakuyomi](https://github.com/tachibana-shin/rakuyomi). When a chapter is open, the sleep screen shows the manga's cover instead of the chapter's first page.

If Wi-Fi is on when you open a chapter, it downloads a full-size cover from [MangaDex](https://mangadex.org), using the cover for the volume the chapter is in when it can work that out. Until then it uses Rakuyomi's own smaller cover.

Needs **Wallpaper → Show book cover on sleep screen** in the Sleep screen menu. Tested with Rakuyomi 1.41.8.

### [🞂 X-Ray timeline presence map](https://github.com/Pixxel123/xray-timeline-patch)

Adds a character presence map to the X-Ray plugin's timeline. It lives in its own repo.
