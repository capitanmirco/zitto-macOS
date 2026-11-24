# Porting di zitto su macOS — piano

## 1. Cosa fa oggi zitto (analisi del repo)

zitto è un'app Windows in Python (~3.400 righe + 131 test) che separa i brani nelle loro parti
(voce principale, cori, batteria → cassa/rullante/tom/piatti, basso, chitarra, pianoforte,
fiati, altro), le suona con ogni parte accendibile/spegnibile dal vivo e salva il mix.

| Modulo | Ruolo | Dipendenze Windows/Python |
| --- | --- | --- |
| `gui.py` | finestra: libreria a sinistra (playlist, ricerca, rinomina, elimina, riprova), stato del lavoro in background | Tkinter, `ctypes.windll` (DPI) |
| `player.py` | player: righe delle parti, mute/solo/volume, loop, salvataggio, finestra MIDI "Assign" | Tkinter, `sounddevice` (WASAPI) |
| `parts.py` | canvas dei controlli delle parti (hit-testing, layout) | Tkinter |
| `waveform.py` + `surface.py` | forma d'onda a corsie, zoom, pan, righello, testina, selezione del loop | numpy + **GDI Win32** (`BitBlt`, DIB section) |
| `mixer.py` | trasporto, loop senza click (crossfade 128 campioni), rampe di volume, render in tempo reale | numpy, thread-safe con lock |
| `midi.py` | decodifica messaggi (note/CC/program/MMC/realtime), binding "learn", porta d'ingresso | `python-rtmidi` |
| `library.py` | libreria su disco: `song.json`, `download.json`, `stems.json`, `error.json`, `player.json`, `playlists.json`, stem in FLAC int16 | `soundfile`, numpy |
| `settings.py` | JSON atomici (`os.replace`) | — |
| `jobs.py` | avvia il worker come processo figlio, legge JSON per riga da stdout e le % di tqdm da stderr | `python.exe`, `CREATE_NO_WINDOW` |
| `worker.py` | processo in background: scarica/decodifica/separa le canzoni in attesa, una alla volta | **`msvcrt.locking`**, torch |
| `engine.py` + `models.py` | esegue i modelli (BS-Roformer, Mel-Roformer, MDX23C DrumSep, UVR VR, Open-Unmix) | **PyTorch + CUDA**, audio-separator |
| `audio.py` | decodifica/codifica via ffmpeg | ffmpeg (`winget`) |
| `source.py`, `plugins.py` | file o link via plugin Python (entry point) | importlib.metadata |
| `cli.py`, `remover.py`, `targets.py` | riga di comando "togli la voce/batteria/…" | — |

## 2. Il nodo centrale: i modelli di separazione

Tutto tranne la separazione si traduce bene in Swift nativo. La separazione no:

* I modelli sono checkpoint PyTorch (`.ckpt`/`.pth`) di architetture complesse (BS-Roformer,
  Mel-Band-Roformer con rotary embedding, MDX23C, rete VR di UVR, Open-Unmix), eseguiti tramite
  la libreria `audio-separator`, che fa anche STFT, chunking, overlap e ricostruzione.
* Portarli in Swift puro vuol dire **riscrivere ogni architettura** (in MLX-Swift o Metal
  Performance Shaders Graph) oppure **convertirli in Core ML** con `coremltools`: entrambe le
  strade richiedono un Mac per convertire e validare numericamente ogni modello (la differenza
  deve restare sotto −60 dB perché le parti vengono sottratte), e i pesi hanno licenze ignote,
  quindi i modelli convertiti non si potrebbero comunque distribuire con l'app.
* PyTorch su macOS gira sulla GPU Apple tramite **MPS**, e `audio-separator` lo supporta già.

**Scelta proposta (ibrida):** app macOS **100% Swift nativa** (UI, audio, MIDI, libreria,
mix, salvataggio), che per la sola separazione lancia il **worker Python esistente** come
processo in background, esattamente come fa già oggi la versione Windows (`jobs.py` ↔
`worker.py` parlano JSON per riga). Il confine c'è già ed è pulito: la GUI Python non carica mai
torch. Il worker va solo reso portabile (lock POSIX, MPS al posto di CUDA, percorsi).

Il motore nativo Core ML/MLX resta possibile in una fase successiva (§8), dietro la stessa
interfaccia `SeparationBackend`, senza toccare il resto dell'app.

## 3. Architettura dell'app Swift

```
macos/
  Package.swift                 Swift Package (macOS 13+)
  Sources/
    ZittoCore/                  logica pura, solo Foundation: testabile anche fuori da Xcode
      Library.swift             stesso formato su disco della versione Python
      JSONStore.swift           letture/scritture atomiche
      Settings.swift
      Mixer.swift               port fedele di mixer.py, render real-time senza allocazioni
      Parts.swift               controls(), heard(), levels, mixName()
      Models.swift              NAMES, LABELS, PIECES, STEMS, colori
      MIDIMessages.swift        trigger(), describe(), Bindings
      Peaks.swift               peaks(), columns(), clock()
      Text.swift                plain(), matches(), fullName(), safeFilename()
      WorkerProtocol.swift      eventi JSON del worker, parsing % di tqdm
    ZittoApp/                   AppKit + SwiftUI
      ZittoApp.swift            @main, menu, scorciatoie
      AppModel.swift            stato della finestra (equivalente di gui.App)
      PlayerModel.swift         equivalente di PlayerView (senza UI)
      Sidebar/LibraryView.swift lista con playlist, ricerca, menu contestuale, drag&drop
      Player/PlayerView.swift   intestazione, barra trasporto, footer MIDI
      Player/PartControlsView.swift
      Player/WaveformView.swift NSView + Core Graphics/CALayer (sostituisce surface.py)
      Player/MIDIAssignView.swift
      Audio/AudioOutput.swift   AVAudioEngine + AVAudioSourceNode → Mixer.render
      Audio/StemLoader.swift    FLAC int16 → buffer (AVAudioFile, in parallelo)
      Audio/Exporter.swift      mixdown → WAV nativo; MP3/FLAC via ffmpeg con i tag
      MIDI/MIDIInput.swift      CoreMIDI, notifiche hot-plug invece del polling
      Work/WorkerProcess.swift  Process + Pipe: equivalente di jobs.py
      Work/PythonRuntime.swift  trova il Python del worker
  Tests/ZittoCoreTests/         port dei test Python della logica
  scripts/
    build-app.sh                swift build -c release + bundle Zitto.app (Info.plist, icona)
    setup-worker.sh             venv in ~/Library/Application Support/zitto, torch per MPS, requisiti
```

### Corrispondenze tecniche

| Python / Windows | Swift / macOS |
| --- | --- |
| Tkinter, ttk.Treeview | SwiftUI `NavigationSplitView` + `List` con sezioni (playlist), `.searchable`, `.contextMenu`, `.onDrop` |
| `surface.py` (GDI BitBlt) | `NSView` con `CGContext` su bitmap per le corsie + `CALayer` separato per la testina (muoverla non ridisegna nulla) |
| `parts.py` canvas | SwiftUI: righe allineate alle corsie della forma d'onda, `DragGesture` per il volume |
| `sounddevice` WASAPI, latency 50 ms | `AVAudioEngine` + `AVAudioSourceNode`; latenza = `outputNode.presentationLatency` + buffer |
| `threading.Lock` nel mixer | `os_unfair_lock` (sezioni brevissime, nessuna allocazione nel callback) |
| numpy int16 (samples, 2) | `[Int16]` interleaved contiguo; somma in `Float` con vDSP dove conviene |
| `python-rtmidi` + polling ogni 2 s | CoreMIDI: `MIDIClientCreateWithBlock` (notifiche di setup) + porta d'ingresso; su macOS più app possono condividere un ingresso |
| `soundfile` FLAC | `AVAudioFile` (legge FLAC nativamente) |
| ffmpeg per tutto | `AVAudioFile`/`ExtAudioFile` per WAV; ffmpeg (Homebrew) per MP3 e FLAC con copia dei tag, come oggi |
| `msvcrt.locking` | `fcntl.flock` (nel worker) |
| `filedialog`, `messagebox`, `simpledialog` | `NSSavePanel`, `NSOpenPanel` (`.fileImporter`), `alert`, sheet per Rinomina |
| `library\` accanto al programma | `~/Library/Application Support/zitto/library` (o `ZITTO_LIBRARY`), passato al worker per variabile d'ambiente |
| `settings.json` accanto al programma | `~/Library/Application Support/zitto/settings.json` (stesse chiavi) |
| `Ctrl+S`, `Ctrl+F` | `⌘S`, `⌘F`; Spazio, Home, L, Esc, 1–8 invariati |

### Compatibilità del formato su disco

Il worker Python scrive `download.json`, `stems.json`, `error.json` e gli stem FLAC; l'app
Swift scrive `song.json`, `player.json`, `playlists.json`. Swift deve quindi leggere e
scrivere **esattamente gli stessi JSON** (stessi nomi di campo, `order` come `Double`
`time.time()`, `wanted`, `single`, `name`). Così una libreria creata su Windows si apre sul
Mac e viceversa, e i test Python del worker restano validi.

Le chiavi delle canzoni: `sha1("<path>|<size>|<mtime_ns>")[:16]` per i file — in Swift con
CryptoKit, con `mtime_ns` ricavato da `stat()` per essere identico al Python.

### Link e plugin

I plugin per i link sono codice Python e devono restare tali. L'app chiede al worker:

* `python -m zitto.worker --info` → etichette dei plugin di link, problemi di caricamento,
  parti fornite dai modelli correnti
* `python -m zitto.worker --link LINK` → `kind`, `key`, `clean` del link (al posto delle chiamate
  in-process di `source.kind`/`library.add`)
* `--add LINK` (playlist) esiste già.

Senza plugin installati il campo per i link non appare, come oggi.

## 4. Modifiche al codice Python (solo il worker e i suoi moduli)

1. `worker.py`: lock con `fcntl.flock` su macOS/Linux, `msvcrt` su Windows; comandi `--info` e
   `--link`.
2. `engine.py`: `MODELS_DIR` da `ZITTO_MODELS_DIR`; `_park` svuota la cache MPS
   (`torch.mps.empty_cache()`) oltre a quella CUDA; Open-Unmix su `mps` quando disponibile.
3. `audio.py`: messaggio "ffmpeg non trovato" con `brew install ffmpeg` su macOS.
4. `settings.py`: percorso da `ZITTO_SETTINGS` quando dato.
5. `requirements-macos.txt` (torch da PyPI, già con MPS) e `scripts/setup-worker.sh`.
6. Test Python esistenti: devono continuare a passare.

## 5. Fasi di implementazione

| # | Fase | Contenuto | Verifica |
| --- | --- | --- | --- |
| 1 | Worker portabile | modifiche §4 | `pytest` (qui, su Linux) |
| 2 | ZittoCore | Text, JSONStore, Settings, Library, Models, Parts, MIDIMessages, Peaks, Mixer, WorkerProtocol | XCTest: port dei test Python su libreria, mixer, heard/mixName, MIDI |
| 3 | Audio | AudioOutput, StemLoader, Exporter | ascolto, salvataggio wav/mp3/flac |
| 4 | Worker bridge | WorkerProcess, PythonRuntime, eventi, playlist | coda di canzoni, kill all'eliminazione, riavvio dopo crash |
| 5 | UI | finestra, sidebar, player, forma d'onda, controlli parti, MIDI Assign, scorciatoie, menu | uso manuale |
| 6 | MIDI | CoreMIDI, learn, ricollegamento automatico | controller fisico |
| 7 | Packaging | `build-app.sh`, Info.plist, tipi di file per "Apri con", README macOS | `open Zitto.app` |

## 6. Rischi

* **Non c'è un Mac in questo ambiente** e la rete blocca il download del toolchain Swift:
  il codice Swift non può essere compilato qui. ZittoCore è scritto in Swift portabile (solo
  Foundation) proprio per poterlo compilare e testare anche su Linux se si apre l'accesso a
  `download.swift.org`; la parte AppKit/AVFoundation va compilata su un Mac (Xcode 15+).
* Memoria: gli stem stanno in RAM come int16 come in Python (~10 MB/min per stem).
* MPS: alcune operazioni dei Roformer possono ricadere sulla CPU; il worker resta più lento
  che su una GPU NVIDIA, ma è in background.
* App non sandboxed (deve lanciare Python e ffmpeg): distribuzione fuori dal Mac App Store,
  firma Developer ID + notarizzazione opzionale.

## 7. Cosa non cambia

Formato della libreria, scelta dei modelli e `ZITTO_MODELS=stated`, plugin, CLI Python
(`zitto song.mp3 -r drums`), licenza PolyForm Noncommercial e NOTICE.

## 8. Dopo (opzionale): separazione nativa

Interfaccia `SeparationBackend` in Swift con due implementazioni: `PythonWorkerBackend` (ora) e
`CoreMLBackend` (in futuro), da attivare un modello alla volta dopo conversione con
`coremltools` e confronto numerico con PyTorch sul Mac.
