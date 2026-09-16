# KOReader.patches

User patches for KOReader. I use them on a Kindle Paperwhite, mostly for reading manga through Rakuyomi. There are longer notes at the top of each file.

### [🞂 How to install a user patch?](https://koreader.rocks/user_guide/#L2-userpatches)

Tested on KOReader 2026.07. Each patch has its own version number, on its first line.

### [🞂 2-bubblezoom-overlay.lua](2-bubblezoom-overlay.lua)

For [Bubble Zoom](https://github.com/anezih/bubblezoom.koplugin). Enlarges just the bubble, with its outline and a thin white edge, instead of a rectangle cut out of the page, and keeps it on the screen and clear of the status bar. When a balloon is joined to another, both are enlarged, so no lettering gets cut off. If the bubble's shape can't be found cleanly, you get the rectangle as before.

It also makes Bubble Zoom work with a White Threshold below 255 (in the reader's bottom menu), and keeps the enlarged bubble right when the screen is redrawn. Works with or without the patch below. Tested with Bubble Zoom 1.2.1.

### [🞂 2-bubblezoom-panelsplus.lua](2-bubblezoom-panelsplus.lua)

For [Bubble Zoom](https://github.com/anezih/bubblezoom.koplugin) and [Panels+](https://github.com/KristanLaimon/PanelsPlus). Long-press a speech bubble to enlarge it, or long-press anywhere else on the page to open that panel. Without it, Bubble Zoom takes every long-press on a comic page, so a long-press never opens a panel.

Bubble Zoom finds a bubble by filling the light area you press, so faces, clothes and sky come back as bubbles too. Before anything is enlarged, the patch checks that the area isn't too big or touching the edge of the page, has lettering inside it, and has a fairly smooth, rounded outline. On test pages from five series it wasn't tuned on, about 93% of long-presses on bubbles enlarged them, and about 2% of long-presses elsewhere enlarged something, down from about half. Balloons with very little lettering, like "..." or "?", open the panel instead.

Bubble Zoom needs to be switched on in its menu. Tested with Bubble Zoom 1.2.1 and Panels+ 1.4.0.

### [🞂 2-manga-nightmode.lua](2-manga-nightmode.lua)

Shows comic pages in their normal colours in night mode, while menus and Rakuyomi's screens stay dark. Night mode stays on: comic pages are drawn already inverted, the same as the reader's **Invert Document** option (always on for comics), so the two inversions cancel out. Page margins and the gaps between pages keep their day colours. It doesn't change night mode, warmth or brightness, so AutoWarmth, other schedules and the night mode toggle work as usual. Turn night mode off and comics show normally.

If you use [Panels+](https://github.com/KristanLaimon/PanelsPlus), its panel viewer shows comic panels in their normal colours too. Tested with Panels+ 1.4.0.

### [🞂 2-manga-no-history.lua](2-manga-no-history.lua)

Keeps comics out of History, so a comic never becomes the last opened book. Comics already in History are removed the first time KOReader starts with this patch.

### [🞂 2-manga-no-stats.lua](2-manga-no-stats.lua)

Stops the Reading statistics plugin from recording comics. Anything recorded before you install it stays in the statistics database.

The three manga patches treat .cbz, .cbr and .cbt files as comics. If you change that list, change it in all three files.

### [🞂 2-rakuyomi-sleep-cover.lua](2-rakuyomi-sleep-cover.lua)

For the [tachibana-shin fork of Rakuyomi](https://github.com/tachibana-shin/rakuyomi). When a chapter is open, the sleep screen shows the manga's cover instead of the chapter's first page.

If Wi-Fi is on when you open a chapter, it downloads a full-size cover from [MangaDex](https://mangadex.org), using the cover for the volume the chapter is in when it can work that out. Until then it uses Rakuyomi's own smaller cover. It also gets the next volume's cover, so chapters Rakuyomi downloads ahead still show the right cover when you read them offline. That only reaches one volume ahead, so if you download chapters from several volumes at once, the later volumes show the series cover until you open them with Wi-Fi on. If a cover can't be found, it tries at most three times, a day apart, and then waits a month before looking again, so it doesn't keep using Wi-Fi and battery on it.

Needs **Wallpaper → Show book cover on sleep screen** in the Sleep screen menu. Tested with Rakuyomi 1.41.8.

### [🞂 X-Ray timeline presence map](https://github.com/Pixxel123/xray-timeline-patch)

Adds a character presence map to the X-Ray plugin's timeline. It lives in its own repo.
