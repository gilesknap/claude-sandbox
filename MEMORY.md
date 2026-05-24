# Session memory

## Mobile / Claude Code on web

- User accesses Claude Code on mobile phone but **new sessions always fail to connect to GitHub** on mobile — only existing sessions started on a PC can be resumed on mobile.
- As a result, mobile sessions often involve questions unrelated to the current repo.
- **Do not use file delivery or downloads for sharing content on mobile** — the download button doesn't surface reliably on phones.
- **Preferred mobile-friendly sharing approach**: output content as a fenced code block directly in the chat response. It's visible, selectable, and copy-pasteable without any download step.
- Saving a file to a repo branch is an acceptable fallback if needed — use a dedicated `temp-<topic>` branch (e.g. `temp-gbrain-plan`) rather than a feature/PR branch, to keep scratch files out of PR diffs. Inline code block is still cleanest.
