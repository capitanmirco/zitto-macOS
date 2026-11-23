# Notice

Required Notice: Copyright 2026 danmigdev (https://github.com/danmigdev/zitto)

zitto is licensed under the PolyForm Noncommercial License 1.0.0: see [LICENSE.md](LICENSE.md).

This repository contains only the code and the documents of zitto. It does not contain, and
does not distribute, the models and the libraries below: they are downloaded from their own
sources to the computer of whoever installs zitto, each under its own terms.

## Models

- **Ultimate Vocal Remover** (UVR-MDX-NET Main, 6_HP-Karaoke, 17_HP-Wind_Inst), by Anjok07 and
  aufr33 and the other developers of UVR. Their README asks: "For all third-party application
  developers who wish to use our models, please honor the MIT license by providing credit to
  UVR and its developers." https://github.com/Anjok07/ultimatevocalremovergui
- **Open-Unmix UMX-L**, by Fabian-Robert Stöter, Stefan Uhlich, Antoine Liutkus and Yuki
  Mitsufuji. Creative Commons Attribution Non Commercial Share Alike 4.0 International: not
  for commercial use. https://zenodo.org/records/5069601

## Libraries

Most of the libraries that setup.bat installs are under permissive licences (MIT, BSD, ISC,
Apache 2.0). Those with other conditions:

| Library | Licence | Needed by |
| --- | --- | --- |
| diffq-fixed | CC BY-NC 4.0: not for commercial use | audio-separator |
| soxr | LGPL 2.1 or later | librosa |
| certifi, tqdm | MPL 2.0 | requests, audio-separator |

The versions of PyTorch for NVIDIA GPUs include CUDA libraries, under the terms of NVIDIA.
ffmpeg is a separate program, installed by the user and run as such; its licence (LGPL or GPL)
depends on the build.

Thanks to [audio-separator](https://github.com/nomadkaraoke/python-audio-separator) (MIT),
which runs most of the models, and to
[Open-Unmix](https://github.com/sigsep/open-unmix-pytorch) (MIT).
