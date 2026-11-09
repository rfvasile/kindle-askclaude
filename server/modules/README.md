# Help modules

Each `*.md` file here is one pluggable tip for the Ask Claude reading companion.

```
---
label: Who is this?      # button text on the Kindle (only used if there is a prompt)
scope: selection         # selection | page | any  (when the button is shown)
order: 22                # sorts both the menu and the guidance in the system prompt
enabled: true            # false = unplugged
skip_if_spoilers_ok: false  # true = left out for books marked "Spoilers OK"
---
## guidance
Rules added to Claude's system prompt for every question.

## prompt
The question this module's button asks. Leave the section out for guidance-only modules.
```

- **Add a tip:** create a new file. It's picked up on the next question, with no restart needed.
- **Unplug a tip:** set `enabled: false`, or delete the file.
- The Kindle menu updates itself after the next answer. You can also use Ask Claude → Refresh menu.
- **From the Kindle:** Ask Claude menu → *Modules* lists every module. Tap one to read it, turn it
  off or on, or delete it. *Create a module with Claude…* drafts a new one from your description,
  using this book's question history as a hint, and shows it to you before adding it.
- `drafts/` holds generated modules waiting for Add/Discard. `trash/` holds deleted modules, so
  you can move one back here to restore it.
- `scope: selection` buttons appear when you've highlighted text. `page` buttons appear when nothing
  is selected, from the gesture or the main menu. `any` buttons appear in both cases.
- To preview the full system prompt: `python3 ../kindle_ask.py show-prompt`
