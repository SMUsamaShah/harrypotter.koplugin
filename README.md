# Harry Potter Riddle for KOReader

A local, no-network KOReader proof of concept inspired by [Riddle](https://github.com/MaximeRivest/Riddle).

The animation and font-to-stroke approach are based on [MaximeRivest/Riddle](https://github.com/MaximeRivest/Riddle), adapted as a separate KOReader/Lua plugin.

Write a question with a finger or passive stylus. After the writing pauses, the ink dissolves in place and a fixed demo answer is drawn below, stroke by stroke, with a bundled Dancing Script font.

## Install

Copy the `harrypotter.koplugin` directory into KOReader's `plugins` directory and restart KOReader. In a book, open:

`Menu -> More tools -> Harry Potter Riddle -> Start local riddle`

Write with one finger/stylus, then lift it. The question is submitted automatically after about 2.6 seconds of inactivity. Two-finger gestures are passed through to KOReader.

The final `update plugin` menu item downloads the current `harrypotter.koplugin` folder from this repository through KOReader's network manager, keeps a backup during installation, and asks you to restart KOReader when it finishes.

The demo answer is deliberately local and fixed:

> The magic is already in your ink.

There is no AI endpoint, network request, credential, or answer persistence in this version. The answer-generation seam is `buildAnswerPlan` in `main.lua`, so an endpoint can be added later without changing touch capture or animation.

## Notes

- Intended for touch-enabled KOReader devices, including a Kindle Paperwhite 4.
- A passive stylus is treated like a finger by the device; it does not provide pressure data.
- Use the plugin's cancel action from KOReader's dispatcher if a gesture needs to be returned to the reader.

The bundled font is Dancing Script, distributed under the SIL Open Font License; see `harrypotter.koplugin/DancingScript-OFL.txt`.
