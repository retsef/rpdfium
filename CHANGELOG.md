# Changelog

Tutte le modifiche notevoli a questo progetto.
Il formato segue [Keep a Changelog](https://keepachangelog.com/it/1.1.0/).

## [0.3.10] - bugfix: ordine char nelle celle con `top` quasi-uguale

### Risolto: parole scrambled tipo `iCategora` invece di `Categoria`

Su alcuni PDF (esempio: CR Banca d'Italia, pag. 199+ con font piccolo)
le celle delle tabelle uscivano con char riordinati in modo errato:

| Atteso        | Output errato        |
| ------------- | -------------------- |
| `Categoria`   | `iCategora`          |
| `Localizzazione` | `iLoca li zzazone i` |
| `Tipo Attività` | `iTpo i Attvt i i à` |

Pattern: il char `i` (e occasionalmente altri con `x-height` sottile)
veniva spostato all'inizio della parola o disperso.

### Causa

Regressione dell'ottimizzazione 0.3.9 in `WordExtractor#extract_words`.

L'ottimizzazione partiva dal presupposto che, dopo `chars.sort_by { |c|
[c[:top], c[:x0]] }` + `Cluster.cluster_objects(:top)`, ogni cluster
"riga" fosse già ordinato internamente per x0 — quindi il `row.sort_by
{ |c| c[:x0] }` interno era eliminato come ridondante.

Il presupposto è **falso** quando due char della stessa riga visiva hanno
`top` leggermente diversi (es. la `i` minuscola di `Categoria` ha
`top=414.9789`, le altre lettere `top=414.9869`, differenza 0.008pt).
PDFium spesso assegna alle bbox di char ascender/descender top
leggermente diversi per ragioni di hinting/anti-aliasing. La
differenza è invisibile graficamente ma rilevante per il sort.

Effetto: il sort globale `[top, x0]` mette la `i` (top minore) **prima
di tutte le altre lettere** della parola, indipendentemente da x0. Il
`cluster_objects` poi raggruppa tutti i char nella stessa riga (entro
y_tolerance=3.0), ma non riordina internamente. Quindi all'iterazione
della riga, la `i` viene letta per prima e finisce all'inizio.

### Fix

Ripristinato il `row_sorted = row.sort_by { |c| c[:x0] }` dentro il
loop delle righe. L'ottimizzazione 0.3.9 era valida solo per il caso
di top perfettamente identici; non lo è in generale.

Il costo computazionale aggiunto è marginale: un sort O(n log n) su
righe corte (~50 char), dominato dall'overhead dell'FFI roundtrip per
char nella fase precedente. Verificato empiricamente: tempo
`extract_text` su 20 pagine di complex.pdf invariato (~80ms).

### Test di non-regressione

Tutti i PDF di test continuano a funzionare correttamente:

- ✅ busta_paga.pdf: numeri (`1.993,00`, `2.895,26`), spazi parole (`COGNOME E NOME`, `NETTO BUSTA`)
- ✅ sample.pdf: Lorem ipsum (2913 char)
- ✅ complex.pdf (85 pag): 224.645 char totali
- ✅ cu.pdf pag. 1 (rotation 90°): `BANCA NAZIONALE DEL LAVORO`, `Categoria`, valori numerici
- ✅ **cu.pdf pag. 199** (rotation 0°, font piccolo): `Categoria`, `Localizzazione`, `Tipo Attività`, `Accordato Operativo` — tutti integri

## [0.3.8] - supporto pagine ruotate (90°, 180°, 270°)

### Risolto: estrazione completamente errata su PDF con `Page#rotation != 0`

Su PDF con pagine ruotate (esempio: CU Banca d'Italia, certificate
ruotate 90° CW per essere visualizzate landscape ma "logicamente"
portrait), `Page#chars` ritornava bbox nel sistema **raw** PDFium
(pre-rotazione), mentre PDFium stesso esponeva `width`/`height`
**post-rotazione**. Il mismatch causava:

- `top` dei char tutti uguali nella stessa colonna ma `top` diverso
  tra char della stessa parola (perché il testo era "verticale" nel
  sistema raw)
- L'estrazione tabelle produceva celle illeggibili: testo letto
  carattere per carattere a rovescio (`.A/.P/.S/O/R/O/V/A/L/L/E/D/E/L/A`
  invece di `BANCA NAZIONALE DEL LAVORO S.P.A.`)
- I segmenti di linea (`line_segments`) erano nel sistema raw, mentre
  i char erano (parzialmente) nel sistema post-rotation, rendendo
  impossibile il match cellule/contenuti

### Fix

Tre interventi simmetrici per uniformare il sistema di coordinate:

1. **`compute_chars`**: applica la rotazione della pagina a ogni bbox di
   char (e all'origin point) prima di restituirli. Le coord sono ora
   sempre top-down nel sistema della pagina post-rotazione, allineate
   col rendering visivo. Coerente con pdfplumber.

2. **`line_segments`**: stesso trattamento agli endpoint dei segmenti.
   Il `build_segment` ora riceve un `rotation_ctx` invece del solo
   `page_h`, e trasforma entrambi i punti del segmento.

3. **Helper `apply_page_rotation_to_char` e `apply_page_rotation_to_point`**:
   centralizzano la matematica delle 4 rotazioni canoniche (0°, 90° CW,
   180°, 270° CW). Per rotation = 0 il comportamento è identico al pre-
    0.3.8 (semplice bottom-up → top-down).

### Verifica

Test di non-regressione su 4 PDF:

| PDF | Rotation | Risultato |
| --- | -------: | --------- |
| busta_paga.pdf (cedolino TeamSystem) | 0° | Invariato — tutti i valori critici (`1.993,00`, `COGNOME E NOME`, `NETTO BUSTA`) preservati |
| sample.pdf | 0° | Invariato (Lorem ipsum, 2913 char) |
| complex.pdf (85 pag) | 0° | Invariato (224.645 char totali) |
| **cu.pdf (CR Banca d'Italia, 226 pag)** | **90° CW** | **Estrazione ora corretta** |

Esempio CU pagina 1 dopo il fix:

```
=== Tabella 0 ===
  ['ntermediario:', 'BANCA NAZIONALE DEL LAVORO S.P.A.']

=== Tabella 1 ===
  Header: ['Categoria', 'Localizzazione', 'Durata/Residua', 'Divisa',
           'Import Export', 'Tipo Attività', 'Stato Rapporto',
           'Tipo/Garanzia', 'Ruolo/Affidato', 'Accordato',
           'Accordato/Operativo', 'Utilizzato', 'Importo/Garantito']
  Row 1:  ['RISCHI/AUTOLIQUIDANTI', 'TERMOLI', 'FINO A 1/ANNO', ...,
           '0', '172.136', '172.136', '172.136', '0']
```

Coincide cella-per-cella con pdfplumber sullo stesso PDF.

### API: nessuna breaking change

Le API pubbliche `Page#chars`, `Page#words`, `Page#text`,
`Page#line_segments`, `Page#extract_tables` mantengono la stessa
firma. I valori restituiti **cambiano per i PDF ruotati**: prima
erano in coord raw (sbagliate), ora in coord post-rotation (corrette,
allineate al rendering visivo). Per PDF con rotation = 0 (la stragrande
maggioranza) non c'è alcuna differenza.

## [0.3.7] - bugfix critico: buffer overrun in `read_text_obj_text_from`

### Risolto: IndexError "Memory access offset=0 size=N out of bounds"

`Page#chars` (e di conseguenza `extract_text` / `extract_tables`) crashava
con `IndexError` quando un text object PDF conteneva una stringa più
lunga di 128 byte (parole come `consectetuer`, `Phasellus`, frasi intere
da rivista). Lo stack trace tipico:

```
IndexError: Memory access offset=0 size=158 out of bounds
  page.rb:429 in FFI::AbstractMemory#read_bytes
  page.rb:429 in Page#read_text_obj_text_from
  page.rb:343 in block in Page#compute_chars
```

Sui PDF tipici di gestionali italiani (cedolini TeamSystem) il bug NON
si manifestava perché ogni text object lì contiene 1-4 char (sotto-soglia).
Si attivava su PDF con text run più lunghi (riviste, articoli, qualsiasi
PDF generato da TeX/Word/InDesign con kerning conservato a livello di
parola).

### Causa

Errore mio nell'introdurre `:text_obj_ends_with_space` nella 0.3.4. La
firma C di `FPDFTextObj_GetText` è:

```c
unsigned long FPDFTextObj_GetText(FPDF_PAGEOBJECT, FPDF_TEXTPAGE,
                                  FPDF_WCHAR* buffer, unsigned long length);
```

dove **`length` è in BYTE** (non in count di uint16) e il return è il
numero di byte **totali necessari** per scrivere il testo, anche se il
buffer è troppo piccolo. Stavamo allocando 64 uint16 (= 128 byte),
passando `64` come length (interpretato da PDFium come 64 BYTE = 32
uint16!), e poi leggendo `(nbytes - 1) * 2` byte dal buffer dove `nbytes`
era il return-value, che eccedeva il buffer allocato. Tre bug
sovrapposti.

### Fix

Pattern probe-then-fetch con clamp difensivo:

1. Provo con buffer ragionevole (256 byte = 128 char UTF-16, copre ~99%
   dei text obj reali).
2. Se PDFium ne richiede di più (`needed > buf_capacity`), rialloco
   esatto e rileggo.
3. Clamp finale: leggo `min(needed - 2, buf_capacity - 2)` byte, mai
   oltre quanto effettivamente allocato. Difesa-in-profondità.

Il costo extra di FFI nei casi tipici è zero (il buffer iniziale basta);
solo per text obj > 256 byte serve una seconda chiamata.

### Bug latenti collaterali fixati

Stesso pattern di buffer-overrun era presente in 3 altri helper aggiunti
nella 0.3.6:

- `read_mark_name` (buffer 128 uint16)
- `read_mark_param_key` (buffer 64 uint16)
- `read_mark_param_string` (buffer 256 uint16)

Mai stati hit in produzione perché i mark name / param sono tipicamente
brevi ("Span", "Artifact", "MCID"), ma la patologia esisteva.
Risolti tutti con lo stesso clamp.

Anche `Structure::Attachment#bytes` aveva un pattern analogo: leggeva
`buf.read_bytes(out_size.read_ulong)` dopo la seconda chiamata, dove
`out_size` poteva eccedere il buffer. Cambiato a `buf.read_bytes(n)`
con `n` = dimensione effettivamente allocata.

### Test

Smoke test esteso su `sample.pdf`, `complex.pdf` (60 MB / 85 pagine),
e `busta_paga.pdf`: tutte le API pubbliche (`chars`, `words`, `text`,
`line_segments`, `mediabox`, `cropbox`, `annotations`, `images`,
`marked_content_regions`, `marked_content_inventory`, `extract_tables`,
`attachments`) verdi su tutti e tre i PDF.

Tutti i valori critici di non-regressione preservati:
`1.993,00`, `2.895,26`, `COGNOME E NOME`, `MATRICOLA INPS`,
`NETTO BUSTA`, Lorem ipsum su sample, 224.645 char su complex.

## [0.3.6] - copertura binding pubbliche PDFium

### Aggiunto: 52 binding pubbliche PDFium mancanti

L'inventario sistematico dell'API pubblica PDFium (455 simboli esportati
dal binario ufficiale) ha rivelato 319 funzioni non ancora attaccate.
Selezionate 52 ad alto valore per una libreria di estrazione PDF generalista,
escludendo i setter (mutation), gli event handler form-fill (mouse/keyboard)
e API niche (thumbnail, JS actions). Tutte sono getter e tutti i tipi
ritornati sono FFI-safe.

Distribuzione per categoria:

| Categoria              | Binding | Aiuta a... |
| ---------------------- | ------: | ---------- |
| Page geometry          | 5       | Sapere mediabox/cropbox/bleed/trim/art (pdfplumber-compat) |
| PageObject state       | 5       | Filtrare oggetti nascosti, distinguere linee tratteggiate |
| Marked Content         | 9       | Raggruppare semanticamente char in PDF tagged (PDF/UA) |
| Catalog/Doc metadata   | 2       | Language, PageMode |
| Links + hit-test       | 7       | API posizionale `link_at(x, y)`, mapping link → text range |
| Actions/Destinations   | 6       | Outline navigation completa |
| Font extras            | 4       | Font data raw, glyph path vettoriale |
| Text page extras       | 3       | Char ↔ text index mapping per ricerca |
| Annotation extras      | 7       | Flags/colors/border/AP/file attachment / quad points |
| Attachment metadata    | 4       | Subtype, key-value custom metadata |

### Nuove API pubbliche di alto livello

- **`Page#mediabox / cropbox / bleedbox / trimbox / artbox`** — accessor
  pdfplumber-compatibili. Ritornano tuple `[x0, top, x1, bottom]` in
  coordinate top-down (coerenti con `chars`, `edges`, `cells`). `cropbox`
  fa fallback automatico su mediabox se assente, come prescrive PDF spec
  14.11.2. Ritornano `nil` se il box non è definito.

- **`Page#marked_content_regions`** → Hash `{mcid => [page_objects]}`.
  Raggruppa gli oggetti per Marked Content ID. Vuoto su PDF non-tagged
  (gestionali italiani); su PDF tagged è il modo più affidabile di
  ottenere unità semantiche (paragrafi, span, celle tabella).

- **`Page#marked_content_inventory`** → Array di marks con `:obj`,
  `:mark_name`, `:params`. Per inspection di Tagged PDF (nomi tipici:
  "Span", "P", "TR", "TD", "Artifact", "Figure").

- **`Page#link_at(x, y)`** — hit-test posizionale: ritorna l'Annotation
  link che contiene il punto, o `nil`. Per il mapping click sul rendering
  → URL.

- **`Page#line_segments(include_curves: false, include_dashed: false)`**
  — nuovo flag `include_dashed`. **Default cambiato a `false`**: le
  linee tratteggiate sono spesso "guide non-printing" che confondono la
  detection di cellule tabella. Chi le vuole esplicitamente (drawing
  extraction completo) passa `include_dashed: true`. I segment hanno
  ora il campo `:dashed` (bool).

- **PageObject inactive automaticamente skippati** in line_segments:
  oggetti con Optional Content disabilitato non finiscono più nell'output.
  Su PDF normali (sempre attivi) il comportamento è invariato.

### Bug fix collaterali

- Rimossa duplicazione di `FPDFText_GetMatrix` (era attached due volte;
  FFI dava warning ma una sola definizione era effettiva). La binding
  resta solo nella sezione Text page (riga ~351 di `raw.rb`).
- Tutti gli helper `read_*` per marked content sono in `begin/rescue
  Rpdfium::LoadError` per supportare build PDFium più vecchi senza
  introdurre regressioni.

### Casi border-line text extraction

**Non risolti** sui PDF da gestionali italiani (TeamSystem, Zucchetti):
parole come `Sede pr i nc` (`Sede principale`), `Imp i ega to`
(`Impiegato`), `IMPONIBILE INAILMESE` (`IMPONIBILE INAIL MESE`) restano
spezzate o fuse perché il content stream PDF emette quei char con
kerning interno (operatori `TJ` con valori intermedi) che PDFium consuma
internamente per il rendering ma non espone via API C pubblica.

Le binding `FPDFDICT_*` che permetterebbero di accedere al content stream
raw (e ottenere il kerning, come fa pdfminer.six) **non esistono nel
PDFium ufficiale di Google/Chromium**. Esistono solo nel fork commerciale
Pdfium.NET di Patagames Software, non utilizzabile sotto licenza
open-source. Le 421 simboli `FPDF*` esportati dal binario bblanchon
sono stati verificati: nessun `FPDFDICT_*`.

I marked content (`FPDFPageObj_GetMark` / `CountMarks`) **sono** la via
ufficiale per accedere alla struttura semantica, ma richiedono che il
PDF sia stato generato come Tagged PDF. I PDF da gestionali italiani
non lo sono. Per PDF da Word/InDesign/InEsign-style tagged, le nuove
API ora coprono il caso.

## [0.3.5] - Ottimizzazioni

### Migliorato: ridotta computazione e semplificati branch condizionali

## [0.3.4] - advance del glifo, identità text-object, segnale fine-token

### Aggiunto: bindings e nuove proprietà sui char

Tre binding PDFium fondamentali che mancavano:

- **`FPDFFont_GetGlyphWidth(font, glyph_cp, font_size, *float)`** — larghezza
  nominale del glifo nel font program. Equivale concettualmente alla
  metric che pdfminer.six legge dal font dictionary del PDF.

- **`FPDFFont_GetAscent` / `FPDFFont_GetDescent`** — metriche font in
  unità del font program, utili per baseline e leading detection.

- **`FPDFText_GetMatrix(textpage, char_index, *FS_MATRIX)`** — matrice di
  trasformazione (CTM) applicata al char. Componente `:a` è la scala
  orizzontale font→pagina.

Queste binding sono ora esposte come API pubbliche di `Rpdfium::Raw` ed
utilizzate internamente per arricchire ogni char con tre nuove proprietà:

| Proprietà                  | Tipo     | Significato |
| -------------------------- | -------- | ----------- |
| `:advance`                 | Float?   | Larghezza nominale del glifo in coordinate pagina, calcolata come `glyph_width × |CTM.a|`. Più stabile della `bbox_width` per char con kerning post-applied. |
| `:text_obj_id`             | Integer? | Identificatore stabile (pointer address) del text object contenente questo char. Tutti i char dello stesso text obj condividono lo stesso ID — utile per raggruppare semanticamente char correlati a livello content-stream. |
| `:text_obj_ends_with_space` | bool?  | True se il content stream PDF ha emesso uno spazio finale dopo questo char (es. fine di un token testuale). Segnale di "fine token" dichiarato dal PDF — non sempre coincidente con fine parola visiva, ma utile come indizio. |

### Migliorato: rebuild_word_separators usa i nuovi segnali

`Page#chars` (con `inject_spaces: true`, default) ora ricostruisce i word
boundary combinando:

1. **Veto duro**: se `prev[:text_obj_ends_with_space] == false`, nessuno
   spazio viene inserito anche con gap geometrico grande. È kerning
   interno a un token dichiarato dal PDF.

2. **Threshold dinamica**: per i candidati ammessi (prev fine-token o
   segnale assente), uso soglia geometrica `gap > 0.3 × max_advance`
   come default, alzata a `0.7 × max_advance` se il contesto è numerico
   (cifre o punteggiatura `.`/`,`). Questa euristica preserva i numeri
   `2.895,26`/`1.993,00` interi mentre recupera la maggior parte degli
   spazi tra parole.

### Confronto con pdfplumber sul PDF di test

Recuperi netti rispetto alla 0.3.3:

| Cella                  | rpdfium 0.3.3 | rpdfium 0.3.4 | pdfplumber |
| ---------------------- | ------------: | ------------: | ---------: |
| COGNOME E NOME         | `COGNOME ENOME` | `COGNOME E NOME` ✓ | `COGNOME E NOME` |
| MATRICOLA INPS         | `MATRICOLAINPS` | `MATRICOLA INPS` ✓ | `MATRICOLA INPS` |
| POSIZIONE INAIL        | `POSIZIONE INAIL` ✓ | `POSIZIONE INAIL` ✓ | `POSIZIONE INAIL` |
| DATA NASCITA           | `DATANASCITA` | `DATA NASCITA` ✓ | `DATA NASCITA` |
| CODICE FISCALE         | `CODICE FISCALE` ✓ | `CODICE FISCALE` ✓ | `CODICE FISCALE` |
| COMUNE DI RESIDENZA    | `COMUNEDI RESIDENZA` | `COMUNE DI RESIDENZA` ✓ | `COMUNE DI RESIDENZA` |
| DATA ASSUNZIONE        | `DATAASSUNZIONE` | `DATA ASSUNZIONE` ✓ | `DATA ASSUNZIONE` |
| QUALIFICA INPS         | `QUALIFICAINPS` | `QUALIFICA INPS` ✓ | `QUALIFICA INPS` |
| TIPO RAPPORTO          | `TIPORAPPORTO` | `TIPO RAPPORTO` ✓ | `TIPO RAPPORTO` |
| RETR. DI FATTO         | `RETR.DI FATTO` | `RETR. DI FATTO` ✓ | `RETR. DI FATTO` |
| CCNL APPLICATO         | `CCNLAPPLICATO` | `CCNL APPLICATO` ✓ | `CCNL APPLICATO` |
| ADD. REG. ANNO DOVUTA  | `ADD. REG.ANNODOVUTA` | `ADD. REG. ANNO DOVUTA` ✓ | `ADD. REG. ANNO DOVUTA` |
| ADD. COM. ANNO DOVUTA  | `ADD. COM.ANNODOVUTA` | `ADD. COM. ANNO DOVUTA` ✓ | `ADD. COM. ANNO DOVUTA` |
| BONUS IRPEF ANNO       | `BONUS IRPEFANNO` | `BONUS IRPEF ANNO` ✓ | `BONUS IRPEF ANNO` |
| 2.857,15 (e altri num) | `2.857,15` ✓ | `2.857,15` ✓ | `2.857,15` |

Casi border-line residui (PDFium non emette il segnale fine-token):
`Sede pr i nc`, `Imp i ega to`, `IMPONIBILE INAILMESE`. Pdfminer.six li
gestisce perché legge gli operatori `TJ` con kerning dal content stream
raw, info che PDFium consuma internamente e non espone via API pubblica.

### Test

- 30 unit test + 8 test di integrazione su PDF reale, tutti verdi.
- Nuovi test: presenza di `:advance`, `:text_obj_id`,
  `:text_obj_ends_with_space` su char reali.

## [0.3.3] - ricostruzione word boundary geometry-based

### Risolto

**`Page#chars` ricostruisce gli spazi tra parole basandosi sulla geometria
dei char**, invece di affidarsi agli spazi sintetici di PDFium (che sono
inaffidabili: PDFium li emette aggressivamente anche tra cifre di numeri).

#### Perché era un problema

PDFium ha due comportamenti patologici sui spazi sintetici:

1. **Bbox degenere**: gli spazi tra parole hanno `top == bottom == baseline`,
   non in linea con i char circostanti. Il cluster per riga in
   `extract_text` li scartava, e parole adiacenti come `COGNOME E NOME`
   si fondevano in `COGNOMEENOME`.

2. **Falsi positivi sui numeri**: PDFium inserisce uno spazio sintetico
   tra OGNI cifra e la punteggiatura di un numero. `2.895,26` aveva
   spazi tra `2/.`, `./8`, `5/,`, `,/2`. Se li accettavamo, l'output
   diventava `2 . 895 , 26`.

#### La fix

Ho buttato via tutti gli spazi sintetici di PDFium e ricostruito i
word boundary basandomi solo sulla geometria dei char "veri":
`gap > 0.4 × max(prev_width, next_width)` → spazio. La soglia 0.4 con
`max_w` (non `avg_w`) è cruciale: i char di punteggiatura come `.` e `,`
sono più stretti delle cifre, e usare la media gonfierebbe i ratio dei
gap intra-numero. Usando il max delle due larghezze, il numero
`2.895,26` ha tutti i gap intra-numero con ratio < 0.35, mentre i veri
gap inter-parola hanno ratio > 0.45.

Soglia 0.4 tarata empiricamente sui dati TeamSystem reali (1400 casi
intra + 663 inter), con classificazione corretta al 100% sui casi
non-borderline.

#### Confronto col PDF di test

| Cella                    | rpdfium 0.3.2 | rpdfium 0.3.3 | pdfplumber  |
| ------------------------ | ------------: | ------------: | ----------: |
| Imponibile IRPEF Mese    |    `2.618,84` |    `2.618,84` |  `2.618,84` |
| Netto Busta              | `NETTOBUSTA/1.993,00` | `NETTOBUSTA/1.993,00` | `NETTO BUSTA/1.993,00` |
| COGNOME E NOME           | `COGNOMEENOME` | `COGNOME ENOME` | `COGNOME E NOME` |
| MATRICOLA INPS           | `MATRICOLAINPS` | `MATRICOLAINPS` | `MATRICOLA INPS` |
| POSIZIONE INAIL          | `POSIZIONEINAIL` | `POSIZIONE INAIL` | `POSIZIONE INAIL` |
| RETR. DI FATTO           | `RETR.DIFATTO` | `RETR.DI FATTO` | `RETR. DI FATTO` |
| GIORNO DI RIPOSO         | `GIORNODIRIPOSO` | `GIORNO DI RIPOSO` | `GIORNO DI RIPOSO` |
| ONERI DED.               |   `ONERIDED.` |    `ONERIDED.` |  `ONERI DED.` |

La 0.3.3 recupera la maggior parte degli spazi inter-parola (vedi
`POSIZIONE INAIL`, `GIORNO DI RIPOSO`, `RETR.DI FATTO`). Restano persi
alcuni casi border-line dove il gap visivo è genuinamente piccolo
(`COGNOME E NOME` che ha `E` molto vicina a `NOME`). Questi sono al
limite delle possibilità di un algoritmo geometrico puro: pdfminer
risolve usando l'advance del font dal content stream PDF, info non
esposta da PDFium.

### API

- **`Page#chars(inject_spaces: true)` ora è il default**. Chi vuole il
  comportamento "raw PDFium" (tutti i char inclusi gli spazi sintetici
  aggressivi) passa `inject_spaces: false`.
- Il vecchio metodo privato `inject_synthetic_spaces` è stato rimosso e
  rimpiazzato da `rebuild_word_separators` (più descrittivo del nuovo
  approccio).

## [0.3.2] - punteggiatura preservata nelle celle tabellari

### Risolto

**`Page#chars` ora ritorna bbox "loose" di default** (`loose: true`),
allineando il comportamento a quello di `pdfminer.six`. Le bbox loose
sono uniformi per riga: tutti i char della stessa linea logica condividono
top/bottom proporzionali alla font-size, invece dei tight glyph box che
PDFium darebbe nativamente.

#### Perché era un problema

Le bbox tight rispettano il singolo glifo. Un `.` (punto decimale) ha
una bbox alta ~0.85pt, mentre un `5` accanto ne ha ~7pt sulla stessa
linea. I loro midpoint verticali differiscono di ~3pt — quanto basta a
far cadere il `.` fuori dalla bbox cella nel filtro `Table#extract`,
che usa il midpoint per decidere quali char appartengono alla cella
(stessa scelta di pdfplumber).

Effetto sul cedolino TeamSystem: valori come `1.993,00`, `2.857,15`,
`7.788,60` venivano estratti come `1 993 00`, `2 857 15`, `7 788 60` —
la punteggiatura cadeva fuori. Con loose box, tutti i char della riga
hanno lo stesso midpoint verticale, e i punti/virgole arrivano dentro
la cella.

#### Confronto con pdfplumber

Sul cedolino di test `busta_paga.pdf`:

| Cella                | rpdfium 0.3.1 | rpdfium 0.3.2 | pdfplumber |
| -------------------- | ------------: | ------------: | ---------: |
| Netto Busta          |       `1 993 00` |   `1.993,00` |  `1.993,00` |
| Imponibile IRPEF MESE |    `2 618 84` |   `2.618,84` |  `2.618,84` |
| TFR Spettante        |       `3 446 15` |   `3.446,15` |  `3.446,15` |
| Retr. di Fatto       |       `2 857 15` |   `2.857,15` |  `2.857,15` |

### Aggiunto

- **`Page#chars(inject_spaces: true)`**: opt-in che inietta spazi
  sintetici nei gap orizzontali significativi (gap > 0.85 × char width)
  della stessa riga. Approssima il comportamento di pdfminer.six per
  parole adiacenti che PDFium fonderebbe per via del kerning. Può
  produrre falsi positivi su font condensati. **Default `false`**:
  preferiamo "non spezzare parole valide" rispetto a "catturare ogni
  spazio mancante", in linea con la filosofia "quello che PDFium emette
  è la verità".

- Helper privato `Page#inject_synthetic_spaces` esposto come API
  pubblica per chi vuole post-processare i char.

- Cache di `Page#chars` per (loose, inject_spaces): ricostruire
  l'array di char è O(n) di chiamate FFI, costoso su pagine grosse.

### Limitazioni note

- Sul cedolino di test, `inject_spaces: true` recupera ~80% degli
  spazi inter-parola persi (es. `NETTO BUSTA`), ma introduce qualche
  falso positivo (es. `Sede pr incipale`). Questo è un trade-off
  intrinseco di PDFium che non espone l'advance del font dal content
  stream, l'unica metrica davvero affidabile per decidere "spazio o no".
  Per estrazione testuale che richiede spazi perfetti, considerare
  pdfminer.six (e quindi pdfplumber); per estrazione tabellare con
  punteggiatura preservata, rpdfium è ora allineato.

## [0.3.1] - discesa nei Form XObjects

### Risolto

**`Page#line_segments` ora discende ricorsivamente nei Form XObjects**
applicando la matrice di trasformazione affine che li posiziona nello spazio
pagina. Prima di questa fix, su PDF dove la grafica della pagina era
incapsulata in un singolo Form XObject (PDF generati da TeamSystem,
Zucchetti e altri gestionali italiani; molti template Word/Excel),
`line_segments` ritornava un Array vuoto anche se visivamente la pagina
era piena di linee e bordi cella.

Conseguenza diretta: `Page#vertical_lines`, `Page#horizontal_lines`, e la
strategia `:lines` di `Table::Extractor` ora funzionano correttamente su
questi PDF.

Per il cedolino TeamSystem di test (`busta_paga.pdf`), i numeri:

| Metrica           | prima 0.3.1 | dopo 0.3.1 | pdfplumber |
| ----------------- | ----------: | ---------: | ---------: |
| line_segments     |           0 |        525 |   420 (\*) |
| horizontal_lines  |           0 |        375 |        210 |
| vertical_lines    |           0 |        437 |        210 |
| tabelle estratte  |           1 (\*\*) |     1 |          1 |
| dimensione tab    |   1×N nonsens |  28×44 |      28×44 |

(\*) pdfplumber decompone i 105 rettangoli in 4 lati ciascuno =
420 edges; rpdfium attualmente li conta con duplicazione (le 4 linee del
contour + il close-path), per questo 525 invece di 420. La detection di
celle non ne risente perché lo snap+join collassa i duplicati.
(\*\*) Senza linee, rpdfium 0.3.0 con strategia `:lines` non trovava
tabelle e cadeva nel fallback `:text`, producendo una "tabella" gigantesca
che copriva l'intera pagina.

### Aggiunto

- Bindings `FPDFFormObj_CountObjects` e `FPDFFormObj_GetObject` per
  iterare i child di un Form XObject.
- Helpers privati `compose_matrix`, `apply_matrix`, `read_object_matrix`
  per la composizione di trasformazioni affini PDF.
- Test di integrazione su PDF reale (`busta_paga.pdf`) che verifica:
  numero minimo di line_segments, struttura della tabella anagrafica,
  conteggio chars nel range atteso.

### Compatibilità

- Nessuna API breaking. `line_segments` mantiene la stessa firma e lo
  stesso formato di output.
- I PDF già funzionanti in 0.3.0 (con grafica top-level) continuano a
  funzionare identici: la discesa nei Form XObjects parte dal CTM
  identità, quindi a livello top non c'è cambiamento di coordinate.

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
  reali di un cedolino italiano in formato TeamSystem).

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
