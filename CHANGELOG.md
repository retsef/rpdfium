# Changelog

Tutte le modifiche notevoli a questo progetto.
Il formato segue [Keep a Changelog](https://keepachangelog.com/it/1.1.0/).

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
