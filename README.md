# KOReader.patches

User patches for KOReader. I use them on a Kindle Paperwhite, mostly for reading manga through Rakuyomi. There are longer notes at the top of each file.

### [🞂 How to install a user patch?](https://koreader.rocks/user_guide/#L2-userpatches)

Tested on KOReader 2026.07.

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
