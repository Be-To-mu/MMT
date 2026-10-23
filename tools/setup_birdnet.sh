#!/bin/sh
# Downloads BirdNET v2.4 (CC BY-NC-SA 4.0), converts it to Core ML and puts the model and
# labels in MMT/Resources. Needs uv (brew install uv). Run from the repo root.
set -eu

WORK="${TMPDIR:-/tmp}/mmt-birdnet"
BASE=https://huggingface.co/sammlapp/BirdNET_v2.4/resolve/main/V2.4
MODEL=BirdNET_GLOBAL_6K_V2.4_Model

mkdir -p "$WORK/V2.4/$MODEL/variables"
for f in BirdNET_GLOBAL_6K_V2.4_Labels.txt "$MODEL/saved_model.pb" \
         "$MODEL/variables/variables.data-00000-of-00001" "$MODEL/variables/variables.index"; do
  [ -f "$WORK/V2.4/$f" ] || curl -fL -o "$WORK/V2.4/$f" "$BASE/$f"
done

[ -d "$WORK/venv" ] || uv venv -q -p 3.11 "$WORK/venv"
VIRTUAL_ENV="$WORK/venv" uv pip install -q "tensorflow==2.15.*" "coremltools==8.*" "numpy<2"
"$WORK/venv/bin/python" -I tools/convert_birdnet.py "$WORK" "$WORK/out"

mkdir -p MMT/Resources
rm -rf MMT/Resources/BirdNET.mlpackage
cp -R "$WORK/out/BirdNET.mlpackage" MMT/Resources/
cp "$WORK/out/BirdNET_Labels.txt" MMT/Resources/
echo "BirdNET ready in MMT/Resources"
