# R2M third-party components

R2M includes independent open-source runtime components and their license notices.
The installed application is self-contained; downloadable neural model weights
are stored separately. `runtime-packages.json` lists the exact bundled Python
package versions and paths to their original METADATA. Their license and NOTICE
files remain inside each package and `.dist-info` directory.

## Runtime and native libraries

- **CPython 3.11**: Python Software Foundation license, with bundled third-party
  notices at `runtime/lib/python3.11/LICENSE.txt`. Source: https://www.python.org/downloads/source/
  The relocatable Python distribution is based on python-build-standalone:
  https://github.com/astral-sh/python-build-standalone
- **Kokoro 0.9.4 and Misaki 0.9.4**: Apache-2.0. Package licenses are retained in
  the runtime metadata. Source: https://github.com/hexgrad/kokoro and
  https://github.com/hexgrad/misaki
- **PyTorch**: its complete packaged LICENSE and third-party notices are retained
  in the torch distribution metadata. Exact version is in `runtime-packages.json`.
  Source: https://github.com/pytorch/pytorch
- **MLX and MLX-LM**: MIT. Their license files are retained in `chat-packages`.
  R2M uses the macOS 14 MLX 0.32.4 wheels rather than the alternative macOS 26.2
  wheels. Exact download URLs and SHA256 checksums are in
  `chat-runtime-provenance.json`. Sources: https://github.com/ml-explore/mlx and
  https://github.com/ml-explore/mlx-lm
- **spaCy English language data**: `en_core_web_sm` 3.8.0, MIT. This small linguistic
  resource is part of the speech runtime, separate from the optional neural
  models downloaded by R2M. Source: https://github.com/explosion/spacy-models
- **truststore 0.10.5**: MIT. Model downloads use its macOS Security framework
  integration to verify server certificates against the native trust store,
  including IT-managed certificates. The original license is retained in
  `runtime/lib/python3.11/site-packages/truststore-0.10.5.dist-info/licenses/LICENSE`.
  Its official wheel URL and SHA256 digest are pinned in `network-runtime.json`.
  Source: https://github.com/sethmlarson/truststore

## Copyleft components and source locations

These components retain their original licenses; the source locations below
identify their upstream implementations and build instructions. Free or internal
use does not change their license terms.

- **FFmpeg 7.1**, including its enabled GPL codecs/libraries: GPLv3 build. Full
  license: `Licenses/FFmpeg-GPLv3.txt`; imageio-ffmpeg's wrapper license:
  `Licenses/imageio-ffmpeg-LICENSE.txt`. The original configuration is available
  by running `bin/ffmpeg -version`. FFmpeg source archive:
  https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz
  and build scripts for the imageio-provided binaries:
  https://github.com/imageio/imageio-binaries/tree/master/ffmpeg
  Linked libraries carry their own notices and source references in that build
  project. No FFmpeg source has been modified by R2M.
- **PyMuPDF 2.0 / MuPDF 1.28.5**: AGPLv3 (or a separately obtained Artifex commercial
  license). R2M uses the open-source distribution. Full license:
  `Licenses/PyMuPDF-AGPLv3.txt`. Source and build instructions:
  https://github.com/pymupdf/PyMuPDF/tree/2.0
  and https://mupdf.com/releases/
  No PyMuPDF/MuPDF source has been modified by R2M.
- **eSpeak NG 1.52.0**, included by espeakng-loader 0.2.4: GPLv3. Full license:
  `Licenses/eSpeak-NG-GPLv3.txt`. Source:
  https://github.com/espeak-ng/espeak-ng/tree/1.52.0
  Loader/build package: https://pypi.org/project/espeakng-loader/0.2.4/
  Packaging removes an unused build-machine RPATH from the copied eSpeak shared
  libraries; their code and data are otherwise unmodified.

## Downloadable model sets

The app's pinned `models.json` records repositories, revisions, filenames, byte
sizes, digests and license references. Model cards are downloaded with each set.

- Kokoro-82M: Apache-2.0, https://huggingface.co/hexgrad/Kokoro-82M
- DeBERTa-v3-large zero-shot cleanup classifier: MIT,
  https://huggingface.co/MoritzLaurer/deberta-v3-large-zeroshot-v2.0
- Qwen3.5-9B MLX 4-bit: Apache-2.0,
  https://huggingface.co/mlx-community/Qwen3.5-9B-MLX-4bit
  and https://huggingface.co/Qwen/Qwen3.5-9B

`R2M-source.zip` contains the R2M Swift, Python, build scripts, model manifest and
notices corresponding to this app build. It excludes user documents, chat
history, model weights and generated audio. When passing this build to someone
else, retain its source snapshot and all third-party notices.
