# Changelog

## Unreleased

### Added

- Built-in llama.cpp for dictation post-processing with downloadable Qwen2.5 Instruct models. Apple Intelligence and custom OpenAI-compatible servers remain available.

### Fixed

- Aligned the model management link with the rest of the dictation proofreading card.

## 0.6.0 — 2026-11-19

### Added

- Local Russian dictation proofreading with SAGE Distilled 95M for spelling, punctuation and grammar.
- A Models settings section for enabling features and selecting, downloading and removing Keyboop-managed speech, completion and proofreading models.
- Russian and English typing suggestions with configurable Tab acceptance, a glossary and an opt-in local typing history.
- An opt-in pilot for single-word suggestions inside a sentence using llama.cpp infill. The bundled Qwen models currently fail the quality check for this mode.

### Changed

- Adopted separate OpenCorpora and wordfreq data for Russian word completion. Calibrated the Qwen3-0.6B completion and next-word thresholds.
- Added fresh-path development builds and read-only bundle validation.

### Fixed

- Voice history commits encrypted changes before updating its list or deleting associated audio. Dictation, audio import and call recording report failed saves.
- Inline suggestions revalidate the active field, caret and text before insertion.

### Removed

- Clipboard monitoring, Paste Queue and standalone Paste Plain. Legacy clipboard entries remain encrypted and exportable as `.kbclip`.
- Manual layout conversion, translation, case change and typography commands for selected text. SAGE proofreading keeps its own explicit selection command.

[Prediction benchmarks](Tests/PredictionEval/README.md) · [Clipboard migration](docs/migrations/clipboard-transfer.md)
