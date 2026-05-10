# Changelog

Tutte le modifiche notevoli a questo progetto.
Il formato segue [Keep a Changelog](https://keepachangelog.com/it/1.1.0/).

## [0.3.0] - estrazione tabelle riallineata 1:1 a pdfplumber

### Riscritto da zero

L'intero pipeline tabellare è stato riscritto seguendo il sorgente di
[pdfplumber/table.py](https://github.com/jsvine/pdfplumber/blob/stable/pdfplumber/table.py)
e [pdfplumber/utils/text.py](https://github.com/jsvine/pdfplumber/blob/stable/pdfplumber/utils/text.py).
La versione 0.2.x aveva una serie di approssimazioni che producevano errori
sistematici di estrazione su PDF con layout free-form (es. cedolini
TeamSystem). I bug fix specifici:

1. **`words_to_edges_v` clusterizza ora tre coordinate (`x0`, `x1`, centro)**
   invece di solo `x0`. Le colonne numeriche right-aligned (importi
   `1.234,56` allineati a destra) erano invisibili al clustering basato su
   `x0`. Aggiunta dedupe per overlap di bbox: cluster sovrapposti tengono
   solo il più popolato.

2. **`words_to_edges_h` emette DUE edges per riga** (top + bottom della
   bbox del cluster). Senza il bottom edge, l'ultima riga di una tabella
   rilevata da text-strategy non veniva mai chiusa.

3. **`intersections_to_cells` usa l'algoritmo `find_smallest_cell`** di
   pdfplumber con verifica `edge_connect` su identità d'oggetto degli
   edge, non su sole coordinate. Due intersezioni con la stessa `x` ma
   appartenenti a edge verticali distinti non producono più cella spuria.

4. **`cells_to_tables` usa il fixed-point su corner condivisi**, non più
   adjacency check coordinate-based. Filtro single-cell per scartare rumore.

5. **Estrazione testo da cella usa midpoint del char**, non bbox-clip via
   `FPDFText_GetBoundedText`. Il midpoint è il criterio identico di
   pdfplumber, e risolve la concatenazione cross-cell ("RETRIBUZIONEUTILE")
   che si verificava su PDF dove i char di celle adiacenti hanno bbox
   leggermente sovrapposti.

### Aggiunto

- **`Rpdfium::Util::Cluster`** (nuovo modulo): primitive di clustering 1D
  agglomerativo single-linkage usate da tutto il pipeline (`cluster_list`,
  `cluster_objects`, `objects_to_bbox`, `bbox_overlap`).

- **`Rpdfium::Util::WordExtractor`** (nuova classe): estrazione words da
  char fedele a `pdfplumber.WordExtractor`. Supporta `x_tolerance`,
  `y_tolerance`, `keep_blank_chars`, `extra_attrs` (split su cambio
  font/size).

- **`Rpdfium::Util::TextExtraction.extract_text`** (nuovo modulo): converte
  un Array di char in stringa, raggruppando per riga via clustering del
  `top` e per parola via gap orizzontale > x_tolerance. Equivalente a
  `pdfplumber.utils.text.extract_text(layout=False)`.

- **`Rpdfium::Table::Table`** (nuova classe): rappresenta una tabella
  estratta. Espone `.cells`, `.rows`, `.columns`, `.bbox`, `.extract`.
  L'API combacia con `pdfplumber.table.Table`.

- **`edge_min_length_prefilter`** (default 1.0): filtra edges troppo corti
  prima dello snap+join, per ridurre rumore da micro-segmenti vettoriali.

- **`Rpdfium.extract_tables(..., keep_blank_rows: false)`** filtra di
  default le righe completamente vuote che la strategia `:text` produce
  per costruzione (effetto del doppio edge top+bottom).

### API: breaking changes minori

- Le strategy del `Extractor` validano l'input: `vertical_strategy` e
  `horizontal_strategy` accettano solo `:lines` / `:lines_strict` /
  `:text` / `:explicit`. Valori invalidi alzano `ArgumentError`.

- L'oggetto restituito da `Extractor#tables` (e dall'alias `find`) non è
  più un Hash con `:bbox`/`:rows`/`:cols`/`:grid`, ma un'istanza di
  `Rpdfium::Table::Table`. Chi usa `Rpdfium.extract_tables` (top-level)
  vede solo strutture base (Hash con `:page` e `:rows`), invariato.

- `Edges.snap_horizontal` / `Edges.snap_vertical` / `Edges.join_horizontal`
  / `Edges.join_vertical` / `Edges.intersections` (firma vecchia) /
  `Cells.from_intersections` / `Cells.group_into_tables` rimossi. I
  rimpiazzi sono `snap_edges`, `join_edge_group`, `merge_edges`,
  `filter_edges`, `edges_to_intersections`, `intersections_to_cells`,
  `cells_to_tables` con segnature 1:1 da pdfplumber.

### Fix lifecycle (race finalizer)

Document/Page/TextPage/Annotation/Search/Form::Environment usano ora un
**state Hash condiviso tra istanza e finalizer**. Tre proprietà
acquisite:

- **Idempotenza** (`@state[:closed]` flag): nessuna doppia chiamata a
  `FPDF_CloseDocument`/`FPDF_ClosePage`/etc anche se sia `close()`
  esplicito che il GC partono.
- **No-leak della closure**: il finalizer cattura un Hash, non `self`.
  L'istanza può essere raccolta liberamente dal GC.
- **Disarmo esplicito**: `close()` chiama `ObjectSpace.undefine_finalizer`
  per impedire qualsiasi esecuzione tardiva del finalizer su un handle
  già liberato.

Risolve il segfault `FPDF_CloseDocument` durante introspezione del
debugger su una collection di tabelle (riportato dall'utente con
ruby-debug-ide).

### Fix `candidate_paths` (FFI)

Su macOS, FFI auto-appendeva `.dylib` a path `.so`, causando il fallimento
del caricamento. Ora `candidate_paths` filtra i nomi di sistema per OS
host: solo `.dylib` su macOS, solo `.so` su Linux, solo `.dll` su Windows.
Inoltre se `ENV["PDFIUM_LIBRARY_PATH"]` o `Rpdfium::Binary.library_path`
è impostato, viene usato come unico path: nessun fallback automatico.

### Test

- 30 unit test (60 asserzioni) coprono cluster primitives, word
  extraction, edges (snap/join/filter/intersections/words_to_edges_v/h),
  cells (smallest-cell + edge identity check), table (rows/columns/bbox/
  extract con midpoint), extractor end-to-end con FakePage, regressione
  TeamSystem (no più cross-cell concatenation; words_to_edges_v sui dati
  reali di un cedolino).

## [0.2.1] - allineamento PDFium chromium/6611+

### Cambiato

- **`FPDFText_GetTextRenderMode(text_page, char_index)` rimossa dalle
  bindings.** Era stata rimossa upstream da PDFium in chromium/6611
  (luglio 2024) — chiamarla causa `undefined symbol` con i build recenti
  di pdfium-binaries. Riferimenti:
  [pypdfium2#335](https://github.com/pypdfium2-team/pypdfium2/issues/335),
  [pdfium-render#151](https://github.com/ajrcarey/pdfium-render/issues/151).
- `Page#chars` ora ottiene `:render_mode` via il path nuovo: prima
  risolve il text object che contiene il char con
  `FPDFText_GetTextObject`, poi legge il render mode con
  `FPDFTextObj_GetTextRenderMode` (che era già presente nella binding
  ma non utilizzato a char-level). Una cache interna evita lookup
  ripetuti — overhead invariato anche su pagine con migliaia di char.
- Su build PDFium antichi (< chromium/6611) che non espongono
  `FPDFText_GetTextObject`, `:render_mode` ricade a `nil` invece di
  far esplodere l'estrazione.

### Aggiunto

- Binding di **`FPDFText_GetTextObject(text_page, char_index)`** —
  rimpiazzo upstream per ottenere il text object di un char.
- Binding di **`FPDFFont_GetBaseFontName(font, buffer, size)`** —
  ritorna il `BaseFont` entry dal dict del font (può includere prefissi
  di subset come `ABCDEF+Helvetica`). Firma `c_size_t` invece di
  `c_ulong`, secondo l'header pubblico aggiornato.
- Binding di **`FPDFFont_GetFamilyName(font, buffer, size)`** — ritorna
  il nome famiglia "pulito".
- `FPDFFont_GetFontName` mantenuta come fallback per compatibilità con
  build PDFium più vecchi.

## [0.2.0] - parità con pypdfium2

Espansione massiccia. La superficie di API copre ora i casi d'uso principali
di pypdfium2 più l'estrazione tabellare in stile pdfplumber.

### Aggiunto — bindings FFI

- **Path segments reali** via `FPDFPath_CountSegments`,
  `FPDFPath_GetPathSegment`, `FPDFPathSegment_GetPoint/GetType/GetClose`.
  Iterazione MOVETO/LINETO/BEZIERTO con state-machine corretta per
  `closepath`, sostituendo l'approccio "bbox del path" della 0.1.0.
- **Image objects**: `FPDFImageObj_GetImageMetadata`,
  `GetImagePixelSize`, `GetBitmap`, `GetRenderedBitmap`,
  `GetImageDataDecoded`, `GetImageDataRaw`, `GetImageFilterCount`,
  `GetImageFilter`.
- **Annotazioni**: `FPDFPage_GetAnnotCount/GetAnnot/CloseAnnot`,
  `FPDFAnnot_GetSubtype/GetRect/GetStringValue/HasKey/GetLink`,
  `FPDFLink_GetAction/GetDest/GetURL`, `FPDFAction_GetType/GetURIPath`.
- **Form fields** (read-only): `FPDFDOC_InitFormFillEnvironment` con
  `FPDF_FORMFILLINFO` versione 2 minimale, `FPDF_FFLDraw`,
  `FPDFAnnot_GetFormFieldType/Name/Value/Flags/IsChecked`,
  `GetOptionCount/GetOptionLabel`.
- **Bookmarks** (outline): `FPDFBookmark_GetFirstChild/GetNextSibling/
  GetTitle/GetDest`, `FPDFDest_GetDestPageIndex`.
- **Attachments**: `FPDFDoc_GetAttachmentCount/GetAttachment`,
  `FPDFAttachment_GetName/GetFile`.
- **Structure tree** (PDF tagged): `FPDF_StructTree_GetForPage`,
  `CountChildren`, `GetChildAtIndex`, `GetType`, `GetTitle`.
- **Search interna**: `FPDFText_FindStart/FindNext/FindPrev/FindClose`,
  `GetSchResultIndex`, `GetSchCount`.
- **Char metadata estesa**: `FPDFText_GetLooseCharBox`,
  `GetCharOrigin`, `GetCharAngle`, `IsGenerated`, `IsHyphen`,
  `HasUnicodeMapError`, `GetFontInfo`, `GetTextRenderMode`, `GetMatrix`.
- **Document**: `FPDF_GetMetaText`, `GetDocPermissions`, `GetFileVersion`,
  `GetFormType`, `GetPageLabel`.
- **Bitmap**: `CreateEx`, `RenderPageBitmapWithMatrix`, format detection.
- **Page boxes**: `MediaBox`, `CropBox`, `BleedBox`, `TrimBox`, `ArtBox`.

### Aggiunto — wrapper di alto livello

- `Rpdfium::Document` ora espone: `metadata` (Title/Author/Producer/...),
  `permissions` (hash di booleans per print/copy/modify/...), `file_version`,
  `form_type`, `has_forms?`, `outline`, `attachments`, `page_label(idx)`.
- `Rpdfium::Page` ora espone:
  - `box(:media|:crop|:bleed|:trim|:art)`
  - `chars(loose: false)` — array di hash con `char`, `codepoint`, bbox,
    `origin_x/y`, `angle`, `fontsize`, `font`, `weight`, `render_mode`,
    `generated`, `hyphen`, `unicode_error`
  - `words(x_tolerance:, y_tolerance:)` — clustering layout-aware
  - `text_in_bbox(left:, top:, right:, bottom:)` — top-down coords
  - `line_segments` — segmenti vettoriali REALI dai path objects
  - `horizontal_lines`, `vertical_lines` — derivati da `line_segments`
  - `images` — `Image::Embedded` array
  - `annotations`, `links`, `form_fields`
  - `render(scale:, rotate:, output: :rgba|:bgra|:gray, include_annotations:,
    include_forms:, background:)`
  - `render_to_png(path)` — pure-Ruby, zero dipendenze esterne
  - `search(query, **opts)` — internal full-text search
- `Rpdfium::Image::Embedded` con `metadata`, `pixel_size`, `bbox`,
  `filters`, `raw_bytes`, `decoded_bytes`, `render_bitmap`, `save(path)`
  (passthrough JPEG quando il filter è `DCTDecode`).
- `Rpdfium::Annotation` con `subtype`, `bbox`, `[]`, `link_uri`,
  `link_dest_page`.
- `Rpdfium::Form::{Environment, Field}` con tipi mappati (textfield,
  checkbox, radiobutton, combobox, listbox, signature, ...) e
  `readonly?`, `required?`, `checked?`, `options`.
- `Rpdfium::Search` con `Enumerable`, ogni match include rects per riga.
- `Rpdfium::Outline` con tree ricorsivo, `flatten` preorder, `to_h`.
- `Rpdfium::Attachment` con `name`, `bytes`, `save(path)`.

### Aggiunto — estrazione tabellare

- Pipeline pdfplumber-style:
  1. raccolta edges (strategie `:lines`, `:text`, `:explicit`,
     `:lines_strict`)
  2. snap (cluster collineari → coord media)
  3. join (segmenti contigui → unico edge)
  4. filter per `edge_min_length`
  5. intersezioni h × v entro `intersection_tolerance`
  6. costruzione celle (4 angoli intersezioni)
  7. raggruppamento celle adiacenti (union-find) in tabelle
  8. estrazione testo per cella via `FPDFText_GetBoundedText`
- Tutti i parametri di pdfplumber supportati: `snap_tolerance` (con
  varianti `_x`, `_y`), `join_tolerance`, `intersection_tolerance`,
  `edge_min_length`, `min_words_vertical`, `min_words_horizontal`,
  `text_tolerance`, `keep_blank_chars`.
- `auto_fallback` opzionale: se `:lines` non produce nulla, riprova con
  `:text`.
- `Rpdfium::Table::Debugger.visualize(page, output_path)` — overlay
  visivo (linee rosse, intersezioni verdi, tabelle blu trasparenti)
  equivalente di `pdfplumber.Page.debug_tablefinder()`. Implementato in
  Ruby puro con canvas RGBA, Bresenham, alpha blending.

### Aggiunto — utility

- `Rpdfium::IO::PNG` — writer PNG puro Ruby (zero deps), supporta
  RGBA 8bpc. CRC32 corretti, deflate via stdlib `zlib`.
- `Raw.read_utf16_string` helper centralizzato per il pattern
  probe-then-fetch di PDFium (che ritorna stringhe UTF-16LE).

### Cambiato

- Coordinate top-down ovunque nelle API pubbliche (PDFium internamente
  è bottom-up; conversione fatta una volta sola per evitare confusione).
- Il documento mantiene una cache delle pagine: `doc.page(0)` ritorna
  sempre la stessa istanza (le pagine sono read-only nel nostro modello).
- Init/destroy della libreria ora è thread-safe (`Mutex`) e idempotente.
- `Document#close` rilascia in cascata: form env → pagine cached → doc.

## [0.1.0]

Prima release: bindings minimali, text/render base, table extractor
embrionale.
