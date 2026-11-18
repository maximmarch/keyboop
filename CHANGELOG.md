# Changelog

## Unreleased

- Keyboop focuses on keyboard and voice input. The manual actions for selected text, Paste Queue and standalone Paste Plain are retired on the cleanup branch.
- Clipboard monitoring is removed. Previously saved clipboard entries remain encrypted and exportable as `.kbclip`; voice-history retention and ordinary clearing leave them intact.
- KB-MIG-008 is merged. Installed-app acceptance remains open.
- Voice history commits encrypted changes before updating its list or removing audio. Failed saves are reported in dictation, import and call recording.
- Added a fresh-path development build and read-only bundle validation. Replacement builds still require a conclusive process check.
