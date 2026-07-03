# Shorthand

A native macOS text expander. A TextBlaze replacement that works in every app on your Mac, not just Chrome.

Type a trigger like `/sig` anywhere (Mail, Slack, Chrome, Notes, anywhere you can type) and Shorthand instantly replaces it with your snippet, including rich text formatting like bold and links.

## Build and run

```
./build.sh
open dist/Shorthand.app
```

First launch asks for **Accessibility** permission (System Settings > Privacy & Security > Accessibility). Shorthand needs it to see what you type and to perform the replacement. Expansion starts automatically once you grant it, no restart needed.

A lightning bolt icon appears in the menu bar. From there you can open the Command Center, pause expansion, view or copy snippets, and enable Start at Login.

## Command Center

The main way to manage snippets. Open it from the menu bar icon (Open Command Center). No HTML knowledge needed.

- Left sidebar: searchable snippet list, + and - buttons to add and delete, right-click to duplicate.
- Trigger and Name fields, plus a Rich Text / Plain Text toggle.
- A true rich text editor with a built-in formatting bar: fonts, sizes, bold, italic, underline, colors, highlights, alignment, and lists.
- Add Link… turns selected text into a clickable link (handles emails as mailto: automatically). Remove Link undoes it.
- Insert Placeholder menu drops in `{date}`, `{time}`, `{clipboard}`, or `{cursor}` tokens.
- Everything auto-saves as you type. The header shows expansion status with an on/off switch.

## Snippets file

Under the hood, snippets live in `~/Library/Application Support/Shorthand/snippets.json`. You can still hand-edit it (menu bar: Edit snippets.json…) and it hot-reloads on save. Each snippet looks like:

```json
{
  "trigger": "/sig",
  "name": "Email signature",
  "format": "html",
  "body": "<p>Best,<br><b>Matt Marcotte</b><br><a href=\"https://marcotte.ink\">marcotte.ink</a></p>"
}
```

- `trigger`: the text you type. Anything works, but a leading `/` avoids accidental expansions.
- `format`: `"html"` for rich text (bold, links, lists, colors), `"plain"` or omitted for plain text.
- `name`: optional label shown in the menu.
- `body`: the replacement. For HTML snippets, use standard HTML tags.

### Placeholders

| Placeholder | Result |
|---|---|
| `{date}` | Today's date, long style (July 3, 2026) |
| `{date:MM/dd/yy}` | Date with a custom format (07/03/26) |
| `{time}` | Current time (2:41 PM) |
| `{clipboard}` | Current clipboard contents |
| `{cursor}` | Where the cursor lands after expansion |

Date formats use Apple/Unicode patterns: `yyyy` year, `MMMM` full month, `MMM` short month, `dd` day, `EEEE` weekday, `h:mm a` time.

## Notes

- Rich text pastes wherever rich text is accepted (Mail, Gmail in Chrome, Notes, Slack). Plain-text fields automatically get the plain version.
- Expansion works by briefly using the clipboard; your previous clipboard contents are restored about a second later.
- Passwords are safe: secure input fields are invisible to the app by design.
- If expansion stops working after a rebuild, macOS is being strict about the new signature: remove Shorthand from Accessibility (minus button) and re-add it, or toggle it off and on.
- Pause anytime from the menu bar icon.
