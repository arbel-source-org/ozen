# Publishing a Whisper model as release assets

WhisperKit's model hub only carries OpenAI's own Whisper. A model trained
elsewhere (ivrit.ai's Hebrew Whisper) is published as the assets of a
GitHub release of this repository instead, and the app downloads it from
there (`ReleaseModelDownloader`).

1. Convert the checkpoint to WhisperKit's Core ML layout and compress it.
   The conversion was done on Linux with `whisperkittools`, which leaves
   `.mlpackage` bundles; the phone compiles them on first use.
2. `manifest.py pack <model-folder> <assets>` flattens the folder into
   assets and writes `manifest.json` (path, asset, size, SHA-256).
3. `gh release create <tag> --title ... --notes ... <assets>/*` uploads
   them. One release per model version; the catalog names the tag.
4. Run the "Verify model release" workflow with that tag. It rebuilds the
   folder on a Mac, compiles it, transcribes the five clips in `clips/`
   with WhisperKit and scores them (`wer.py`).
5. Add the model to `WhisperModelCatalog` with `source: .ozenRelease(tag:)`
   and the folder name the release was packed from.

The clips are from Google's FLEURS Hebrew test set (CC BY 4.0), with their
transcripts in `refs.jsonl`.
