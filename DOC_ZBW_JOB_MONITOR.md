# ZBW Job Monitor — Documentazione Tecnica

**Sistema:** SAP BW4HANA  
**Versione ABAP target:** 7.5+  
**Autore:** David  
**Data:** Aprile 2026  

---

## Indice

1. [Panoramica del sistema](#1-panoramica-del-sistema)
2. [Architettura](#2-architettura)
3. [Oggetti Dictionary (SE11)](#3-oggetti-dictionary-se11)
4. [Interfacce e Classi ABAP](#4-interfacce-e-classi-abap)
5. [Report e Programmi](#5-report-e-programmi)
6. [Configurazione](#6-configurazione)
7. [Deploy e Sequenza di Attivazione](#7-deploy-e-sequenza-di-attivazione)
8. [Schedulazione SM36](#8-schedulazione-sm36)
9. [Gestione Errori](#9-gestione-errori)
10. [Manutenzione e Operatività](#10-manutenzione-e-operatività)
11. [Estendibilità](#11-estendibilità)
12. [Glossario Oggetti](#12-glossario-oggetti)

---

## 1. Panoramica del sistema

Il sistema **ZBW Job Monitor** monitora automaticamente i job falliti su SAP BW4HANA e crea o aggiorna ticket sul sistema di ticketing aziendale tramite REST API.

### Obiettivi principali

| Obiettivo | Soluzione |
|-----------|-----------|
| Rilevare job falliti in tempo quasi-reale | Schedulazione ogni 30 min in SM36 |
| Coprire tutti i tipi di oggetti BW | Background Jobs, Process Chains, DTP |
| Evitare ticket duplicati per lo stesso errore | Tabella di deduplication `ZBTW_TICKET_LOG` |
| Assegnare priorità differenziate | Tabella customizing `ZBWJOB_PRIORITY` |
| Essere indipendente dal sistema di ticketing | Interfaccia `ZIF_TICKET_PROVIDER` + factory |
| Non abortire il job in caso di errore parziale | Gestione eccezioni per-item con log |

### Flusso operativo ad alto livello

```
SM36 (ogni 30 min)
       │
       ▼
ZBW_JOB_MONITOR
       │
       ├──► ZCL_BW_JOB_READER ──► TBTCO / RSPCLOGCHAIN / RSBKREQUEST
       │         │
       │         └──► ZBWJOB_PRIORITY  (priorità per pattern)
       │
       ├──► ZCL_TICKET_DEDUP ──► ZBTW_TICKET_LOG  (deduplication)
       │
       └──► ZCL_TICKET_FACTORY
                  │
                  └──► ZCL_TICKET_HTTP_CLIENT ──► REST API esterna
                             │
                             └── ZBWJOB_CONFIG  (URL, token, timeout)
```

---

## 2. Architettura

### 2.1 Diagramma delle dipendenze

```
┌─────────────────────────────────────────────────────────┐
│                    LAYER: PRESENTAZIONE                  │
│   ZBW_JOB_MONITOR (report schedulato)                   │
│   ZBW_TICKET_STATUS (report consultazione ALV)          │
└────────────────────────┬────────────────────────────────┘
                         │ usa
┌────────────────────────▼────────────────────────────────┐
│                    LAYER: BUSINESS LOGIC                 │
│                                                         │
│  ZCL_BW_JOB_READER      ZCL_TICKET_DEDUP               │
│  (lettura job falliti)   (deduplication log)            │
│                                                         │
│  ZCL_TICKET_FACTORY                                     │
│  (creazione provider)                                   │
└────────────────────────┬────────────────────────────────┘
                         │ implementa
┌────────────────────────▼────────────────────────────────┐
│                    LAYER: INTEGRAZIONE                   │
│  ZIF_TICKET_PROVIDER (interfaccia)                      │
│       └── ZCL_TICKET_HTTP_CLIENT (REST generico)        │
│       └── (futuro) ZCL_JIRA_CLIENT                      │
│       └── (futuro) ZCL_SERVICENOW_CLIENT                │
└────────────────────────┬────────────────────────────────┘
                         │ legge/scrive
┌────────────────────────▼────────────────────────────────┐
│                    LAYER: PERSISTENZA (SE11)             │
│  ZBTW_FAIL_JOB    ZBTW_TICKET_LOG                       │
│  ZBWJOB_PRIORITY  ZBWJOB_CONFIG                         │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Pattern architetturali utilizzati

| Pattern | Dove applicato | Motivazione |
|---------|---------------|-------------|
| **Interface / Strategy** | `ZIF_TICKET_PROVIDER` | Sostituire il sistema di ticketing senza toccare la logica core |
| **Factory Method** | `ZCL_TICKET_FACTORY` | Centralizza la costruzione del provider leggendo la configurazione |
| **Repository** | `ZCL_TICKET_DEDUP` | Isola l'accesso a `ZBTW_TICKET_LOG` dal resto della logica |
| **Data Reader** | `ZCL_BW_JOB_READER` | Separa la lettura dei dati SAP dalla logica di business |
| **Value Object** | `ZBTW_FAIL_JOB` | Struttura immutabile che trasporta i dati del job tra i layer |

---

## 3. Oggetti Dictionary (SE11)

### 3.1 Struttura `ZBTW_FAIL_JOB`

**Tipo:** Structure (INTTAB) — non fisica, usata solo come tipo di trasferimento dati tra classi.

| Campo | Tipo SAP | Lung. | Descrizione |
|-------|----------|-------|-------------|
| `JOBNAME` | `BTCJOB` | 32 | Nome del background job (da TBTCO) |
| `JOBCOUNT` | `BTCJOBCNT` | 8 | Contatore univoco del job run |
| `CHAIN_ID` | `RSPC_CHAIN` | 30 | ID della Process Chain BW |
| `JOB_TYPE` | `CHAR10` | 10 | `BGDJOB` \| `CHAIN` \| `DTP` |
| `ERROR_MSG` | `CHAR255` | 255 | Messaggio errore estratto dal log |
| `FAIL_TSTAMP` | `TIMESTAMP` | 15 | Timestamp UTC del fallimento |
| `PRIORITY` | `CHAR10` | 10 | `HIGH` \| `MEDIUM` \| `LOW` |
| `OBJECT_KEY` | `CHAR100` | 100 | Chiave univoca: `JOBNAME_JOBCOUNT` o `CHAIN_ID_LOGID` |

> `OBJECT_KEY` è la chiave di correlazione usata per deduplication e ticketing.

---

### 3.2 Tabella `ZBTW_TICKET_LOG`

**Tipo:** Transparent Table — Categoria A (Application Data), Delivery Class A.

**Chiave primaria:** `MANDT` + `OBJECT_KEY`

| Campo | Tipo | Ch. | Descrizione |
|-------|------|-----|-------------|
| `MANDT` | `MANDT` | ✓ | Client SAP |
| `OBJECT_KEY` | `CHAR100` | ✓ | Chiave univoca del job/chain |
| `LOG_DATE` | `DATS` | | Data di primo rilevamento (non chiave — storico) |
| `TICKET_ID` | `CHAR50` | | ID ticket restituito dalla REST API |
| `TICKET_STATUS` | `CHAR20` | | `OPEN` \| `UPDATED` \| `CLOSED` |
| `CREATED_AT` | `TIMESTAMP` | | Timestamp prima apertura ticket |
| `UPDATED_AT` | `TIMESTAMP` | | Timestamp ultimo aggiornamento |
| `ERROR_MSG` | `CHAR255` | | Ultimo messaggio errore registrato |
| `CHAIN_NAME` | `CHAR100` | | Nome leggibile del job/chain |

**Logica di deduplication:** un ticket viene creato una sola volta per `OBJECT_KEY`, indipendentemente dalla data. Se lo stesso oggetto fallisce più volte (anche a cavallo di mezzanotte), il ticket esistente viene aggiornato con un commento (`UPDATED`). `LOG_DATE` registra la data del primo rilevamento ed è usato solo per housekeeping.

> **Nota tecnica:** `LOG_DATE` è stato rimosso dalla chiave primaria per eliminare il rischio di ticket duplicati su fallimenti che attraversano la mezzanotte ("Midnight Duplicate"). La tabella ora ha al massimo una riga per `OBJECT_KEY`; i re-fallimenti su ticket già `CLOSED` sovrascrivono la riga esistente tramite `MODIFY` (vedi `ZCL_TICKET_DEDUP`).

---

### 3.3 Tabella `ZBWJOB_PRIORITY`

**Tipo:** Transparent Table — Categoria C (Customizing), Delivery Class G.  
**Manutenzione:** SM30 → vista da creare in SE54.

**Chiave primaria:** `MANDT` + `CHAIN_PATTERN`

| Campo | Tipo | Ch. | Descrizione |
|-------|------|-----|-------------|
| `MANDT` | `MANDT` | ✓ | Client SAP |
| `CHAIN_PATTERN` | `CHAR100` | ✓ | Nome esatto o pattern con `*` (es. `ZBW_FIN*`) |
| `PRIORITY` | `CHAR10` | | `HIGH` \| `MEDIUM` \| `LOW` |
| `ACTIVE` | `XFELD` | | `X` = regola attiva |
| `NOTE` | `CHAR255` | | Descrizione della regola |

**Logica di matching in `ZCL_BW_JOB_READER→get_priority()`:**
1. Cerca corrispondenza esatta su `CHAIN_PATTERN` (case-sensitive)
2. Se non trovato, itera le righe con `Active = X` e usa `CP` (contains pattern) per il wildcard
3. Default: `MEDIUM`

**Esempio di configurazione:**

| CHAIN_PATTERN | PRIORITY | NOTE |
|---------------|----------|------|
| `ZBW_FINANCE_CLOSE` | `HIGH` | Chiusura mese Finance |
| `ZBW_FIN*` | `HIGH` | Tutti i job Finance |
| `ZBW_MASTER*` | `MEDIUM` | Master data loads |
| `ZBW_TEST*` | `LOW` | Ambienti di test |

---

### 3.4 Tabella `ZBWJOB_CONFIG`

**Tipo:** Transparent Table — Categoria C (Customizing), Delivery Class G.  
**Manutenzione:** SM30 → stessa vista di `ZBWJOB_PRIORITY` o vista separata.

**Chiave primaria:** `MANDT` + `CONFIG_KEY`

| Campo | Tipo | Ch. | Descrizione |
|-------|------|-----|-------------|
| `MANDT` | `MANDT` | ✓ | Client SAP |
| `CONFIG_KEY` | `CHAR50` | ✓ | Nome del parametro |
| `CONFIG_VALUE` | `CHAR255` | | Valore del parametro |
| `DESCRIPTION` | `CHAR100` | | Descrizione uso parametro |

**Parametri previsti:**

| CONFIG_KEY | Valore esempio | Descrizione |
|------------|---------------|-------------|
| `SM59_DEST` | `ZBWJOB_TICKETS` | Nome della destinazione RFC HTTP creata in SM59 (sostituisce `API_URL`) |
| `API_PATH` | `/api/v1/tickets` | Path base dell'endpoint REST (separato dall'host gestito in SM59) |
| `API_TOKEN` | `eyJhbGci...` | Bearer token di autenticazione (candidato a migrazione in SECSTORE) |
| `TIMEOUT_SEC` | `30` | Timeout HTTP in secondi |
| `MAX_RETRY` | `3` | Numero massimo di tentativi (informativo) |
| `SYSTEM_ID` | `BW4PRD` | Identificativo sistema nel payload ticket |
| `PACKET_SIZE` | `20` | Numero massimo di job elaborati per run (0 = illimitato). Limita il tempo di esecuzione in caso di mass failure. |

---

## 4. Interfacce e Classi ABAP

### 4.1 Interfaccia `ZIF_TICKET_PROVIDER`

**Scopo:** Contratto che ogni implementazione del sistema di ticketing deve rispettare. Permette di sostituire il backend di ticketing senza modificare la logica orchestrante.

**File:** [src/ZIF_TICKET_PROVIDER.intf.abap](src/ZIF_TICKET_PROVIDER.intf.abap)

| Metodo | Direzione | Descrizione |
|--------|-----------|-------------|
| `create_ticket(is_job)` | → `rv_ticket_id` | Apre un nuovo ticket, ritorna l'ID assegnato |
| `update_ticket(iv_ticket_id, iv_message)` | — | Aggiunge un commento/update a ticket esistente |
| `get_ticket_status(iv_ticket_id)` | → `rv_status` | Recupera lo stato corrente del ticket |

Tutti i metodi sollevano `cx_static_check` in caso di errore (HTTP failure, risposta non valida, ecc.).

---

### 4.2 Classe `ZCL_BW_JOB_READER`

**Scopo:** Legge i job/chain/DTP falliti dalle tabelle SAP standard e li trasforma in oggetti `ZBTW_FAIL_JOB`.

**File:** [src/ZCL_BW_JOB_READER.clas.abap](src/ZCL_BW_JOB_READER.clas.abap)

**Visibilità:** `PUBLIC FINAL CREATE PUBLIC`

#### Metodi pubblici

| Metodo | Parametri | Sorgente dati SAP |
|--------|-----------|-------------------|
| `get_failed_jobs(iv_lookback_min)` | `rt_jobs TYPE tt_failed_jobs` | `TBTCO` (STATUS=`A`) + `TBTCP` per error msg |
| `get_failed_chains(iv_lookback_min)` | `rt_jobs TYPE tt_failed_jobs` | `RSPCLOGCHAIN` (LOGSTATE=`E`/`A`) + `RSPCLOGENTRY` |
| `get_failed_dtps(iv_lookback_min)` | `rt_jobs TYPE tt_failed_jobs` | `RSBKREQUEST` (STATUS=`E`) |

**Parametro `iv_lookback_min`:** finestra temporale a ritroso da `sy-uzeit` corrente. Default 60 minuti. Il timestamp di cutoff viene calcolato da `calc_from_timestamp()`.

#### Metodi privati

| Metodo | Descrizione |
|--------|-------------|
| `build_object_key(iv_name, iv_count)` | Concatena `NAME_COUNT` come chiave univoca |
| `get_priority(iv_chain_name)` | Match su `ZBWJOB_PRIORITY` con fallback `MEDIUM` |
| `calc_from_timestamp(iv_lookback_min)` | Restituisce `GET TIME STAMP - (min * 60)` |

#### Dettaglio sorgenti dati

**Background Jobs (`TBTCO` / `TBTCP`):**
```
TBTCO:  STATUS = 'A' (aborted)
        STRTDATE >= data calcolata da lookback
FOR ALL ENTRIES
TBTCP:  JOBNAME + JOBCOUNT → campo DYNDTEXT come ERROR_MSG
        (bulk SELECT, poi READ TABLE con SORTED KEY per evitare N+1)
```

**Process Chains (`RSPCLOGCHAIN` / `RSPCLOGENTRY`):**
```
RSPCLOGCHAIN:  LOGSTATE IN ('E', 'A')
               STARTTIME >= timestamp lookback
FOR ALL ENTRIES
RSPCLOGENTRY:  LOGID + SEVERITY = 'E' → MESSAGE come ERROR_MSG
               (bulk SELECT in SORTED TABLE con NON-UNIQUE KEY logid)
```

**Data Transfer Processes (`RSBKREQUEST`):**
```
RSBKREQUEST:  STATUS = 'E'
              TIMESTAMP >= timestamp lookback
              DTPNAME → JOBNAME, REQUID → parte dell'OBJECT_KEY
              MSGV1 → ERROR_MSG
```

---

### 4.3 Classe `ZCL_TICKET_DEDUP`

**Scopo:** Gestisce la deduplication dei ticket leggendo e scrivendo la tabella `ZBTW_TICKET_LOG`. Isola completamente la logica di persistenza dal report principale.

**File:** [src/ZCL_TICKET_DEDUP.clas.abap](src/ZCL_TICKET_DEDUP.clas.abap)

**Visibilità:** `PUBLIC FINAL CREATE PUBLIC`

| Metodo | Logica |
|--------|--------|
| `has_open_ticket(is_job)` | `SELECT SINGLE` su `ZBTW_TICKET_LOG` per `OBJECT_KEY` + `TICKET_STATUS = 'OPEN'` — senza filtro data, per evitare duplicati a cavallo della mezzanotte. Ritorna `TICKET_ID` se trovato, spazio altrimenti. |
| `save_new_ticket(is_job, iv_ticket_id)` | `MODIFY` su `ZBTW_TICKET_LOG` con STATUS=`OPEN` e timestamp corrente. Usa `MODIFY` (non `INSERT`) per gestire i re-fallimenti: se il job fallisce di nuovo dopo la chiusura del ticket, la riga `CLOSED` preesistente viene sovrascritta con il nuovo ticket. |
| `mark_ticket_updated(iv_object_key, iv_message)` | `UPDATE` imposta STATUS=`UPDATED`, aggiorna `ERROR_MSG` e `UPDATED_AT` — senza filtro data. |
| `mark_ticket_closed(iv_object_key)` | `UPDATE` imposta STATUS=`CLOSED` e aggiorna `UPDATED_AT`. Chiamato dal report quando il sistema esterno segnala il ticket come chiuso (sync esterno). |
| `cleanup_old_entries(iv_days_to_keep)` | `DELETE` righe con `LOG_DATE < sy-datum - iv_days_to_keep` |

> `cleanup_old_entries` è chiamato automaticamente alla fine di ogni run del monitor con `iv_days_to_keep = 30`.

---

### 4.4 Classe `ZCL_TICKET_HTTP_CLIENT`

**Scopo:** Implementazione concreta di `ZIF_TICKET_PROVIDER` che comunica con il sistema di ticketing tramite chiamate HTTP REST generiche.

**File:** [src/ZCL_TICKET_HTTP_CLIENT.clas.abap](src/ZCL_TICKET_HTTP_CLIENT.clas.abap)

**Visibilità:** `PUBLIC FINAL CREATE PUBLIC`  
**Implementa:** `ZIF_TICKET_PROVIDER`

#### Constructor

```abap
NEW zcl_ticket_http_client(
  iv_destination = 'ZBWJOB_TICKETS'   " SM59 RFC destination name
  iv_api_path    = '/api/v1/tickets'  " base path, set via ~request_uri
  iv_api_token   = 'eyJ...'
  iv_timeout     = 30 ).
```

#### Payload JSON inviato su `create_ticket`

```json
{
  "title": "BW Job Failed: <JOBNAME>",
  "description": "<ERROR_MSG>",
  "priority": "<HIGH|MEDIUM|LOW>",
  "system_id": "<SYSTEM_ID da ZBWJOB_CONFIG>",
  "object_key": "<OBJECT_KEY>",
  "job_type": "<BGDJOB|CHAIN|DTP>",
  "failed_at": "<FAIL_TSTAMP>"
}
```

#### Payload JSON inviato su `update_ticket`

```json
{
  "comment": "<ERROR_MSG>",
  "status": "OPEN"
}
```

#### Parsing del `ticket_id` dalla risposta

Il metodo `parse_ticket_id()` cerca in sequenza:
1. `"id": "string"`
2. `"ticket_id": "string"`
3. `"id": 12345` (numerico)

#### Gestione HTTP

| Aspetto | Implementazione |
|---------|----------------|
| Client HTTP | `cl_http_client=>create_by_destination()` — host, porta e SSL gestiti in SM59 |
| Path endpoint | Header `~request_uri` impostato su `mv_api_path` (o `mv_api_path/ticket_id` per update/get) |
| Header Auth | `Authorization: Bearer <token>` |
| Content-Type | `application/json` |
| Popup logon | `co_disabled` — disabilitato per esecuzione background |
| Timeout | Passato a `send( EXPORTING timeout = mv_timeout )` |
| Codici successo | 200 e 201; qualsiasi altro codice → `RAISE cx_static_check` |
| Serializzazione JSON | `/ui2/cl_json=>serialize()` su strutture tipizzate (`ty_create_payload`, `ty_update_payload`). Garantisce escape corretto di `"`, `\`, newline, tab e tutti i caratteri di controllo. |

---

### 4.5 Classe `ZCL_TICKET_FACTORY`

**Scopo:** Factory che legge `ZBWJOB_CONFIG` e istanzia il provider corretto. Punto di estensione per future implementazioni multi-provider.

**File:** [src/ZCL_TICKET_FACTORY.clas.abap](src/ZCL_TICKET_FACTORY.clas.abap)

**Visibilità:** `PUBLIC FINAL CREATE PRIVATE` (Singleton-like, solo `CLASS-METHODS`)

```abap
DATA(lo_provider) = zcl_ticket_factory=>get_provider( ).
```

**Logica interna di `get_provider()`:**
1. Legge `ZBWJOB_CONFIG` per `SM59_DEST`, `API_PATH`, `API_TOKEN`, `TIMEOUT_SEC`
2. Se `TIMEOUT_SEC` è vuoto o zero → default 30 secondi
3. Istanzia e ritorna `ZCL_TICKET_HTTP_CLIENT` con destinazione SM59 e path

> **Sicurezza:** `API_TOKEN` è ancora letto da `ZBWJOB_CONFIG`. Per ambienti produttivi, migrarlo in `SECSTORE` / `CL_SECURE_STORE_SMC` e aggiornare la factory di conseguenza.

> **Estensione futura:** aggiungere `CONFIG_KEY = 'PROVIDER_TYPE'` (es. `JIRA`, `SERVICENOW`) e un `CASE` nella factory per scegliere l'implementazione.

---

## 5. Report e Programmi

### 5.1 Report `ZBW_JOB_MONITOR`

**File:** [src/ZBW_JOB_MONITOR.prog.abap](src/ZBW_JOB_MONITOR.prog.abap)  
**Tipo:** ABAP Report (schedulato in SM36)

#### Parametri di selezione

| Parametro | Tipo | Default | Descrizione |
|-----------|------|---------|-------------|
| `P_LKBK` | `I` | 60 | Finestra di lookback in minuti |
| `P_TEST` | `XFELD` | ` ` | Modalità test: nessun ticket viene aperto/aggiornato |

#### Flusso di esecuzione

```
START-OF-SELECTION
  │
  ├─ 1. ZCL_BW_JOB_READER:
  │       get_failed_jobs(P_LKBK)    → TBTCO
  │       get_failed_chains(P_LKBK)  → RSPCLOGCHAIN
  │       get_failed_dtps(P_LKBK)    → RSBKREQUEST
  │       └─ APPEND LINES → LT_ALL_JOBS
  │
  ├─ 2. Se LT_ALL_JOBS è vuota → WRITE messaggio → RETURN
  │
  ├─ 3. Istanzia ZCL_TICKET_DEDUP e ZCL_TICKET_FACTORY=>get_provider()
  │       Legge PACKET_SIZE da ZBWJOB_CONFIG (0 = illimitato)
  │
  ├─ 4. LOOP AT LT_ALL_JOBS:
  │       │
  │       ├─ [PACKET_SIZE] Se job elaborati > PACKET_SIZE → WRITE [LIMIT] → EXIT
  │       │
  │       ├─ has_open_ticket()  →  ticket aperto in SAP?
  │       │     │
  │       │     ├─ SÌ:  [se P_TEST=' ']
  │       │     │         get_ticket_status()  → stato nel sistema esterno?
  │       │     │           ├─ CLOSED: mark_ticket_closed() → COMMIT WORK AND WAIT
  │       │     │           │          WRITE: [SYNC] ticket chiuso esternamente
  │       │     │           └─ OPEN:   update_ticket() + mark_ticket_updated()
  │       │     │                      COMMIT WORK AND WAIT
  │       │     │                      WRITE: [UPDATE] ticket_id - object_key
  │       │     │         [se P_TEST='X'] WRITE: [UPDATE] (simulato)
  │       │     │
  │       │     └─ NO:  create_ticket() + save_new_ticket()  [se P_TEST=' ']
  │       │             COMMIT WORK AND WAIT
  │       │             WRITE: [CREATE] ticket_id - object_key (prio)
  │       │
  │       └─ CATCH cx_static_check → WRITE [ERROR] + MESSAGE 'I'
  │
  └─ 5. cleanup_old_entries(30)
         WRITE: 'Housekeeping complete.'
```

#### Modalità TEST

Con `P_TEST = X`:
- Tutti i SELECT e la logica di rilevamento girano normalmente
- Nessuna chiamata HTTP viene effettuata
- Nessun record viene scritto in `ZBTW_TICKET_LOG`
- L'output mostra `[TEST - not created]` al posto del ticket ID reale

Utile per validare la lettura dei log SAP senza effetti collaterali.

---

### 5.2 Report `ZBW_TICKET_STATUS`

**File:** [src/ZBW_TICKET_STATUS.prog.abap](src/ZBW_TICKET_STATUS.prog.abap)  
**Tipo:** ABAP Report interattivo (ALV)

#### Parametri di selezione

| Parametro | Tipo | Default | Descrizione |
|-----------|------|---------|-------------|
| `P_DAYFR` | `DATS` | `sy-datum` | Data inizio filtro |
| `P_DAYTO` | `DATS` | `sy-datum` | Data fine filtro |
| `S_STATUS` | Select-option | `OPEN` | Filtro su `TICKET_STATUS` |

#### Funzionalità ALV

- Display ottimizzato con tutte le colonne di `ZBTW_TICKET_LOG`
- Toolbar standard attiva (export Excel/PDF, filtri, sort)
- **Pulsante custom "Close Ticket"** nella toolbar destra:
  1. Recupera le righe selezionate via `cl_salv_selections`
  2. Esegue `UPDATE ZBTW_TICKET_LOG SET TICKET_STATUS = 'CLOSED'` per ogni riga (WHERE `OBJECT_KEY` — non usa più `LOG_DATE` che non è più chiave)
  3. Aggiorna `UPDATED_AT` con il timestamp corrente
  4. Emette `COMMIT WORK` per persistere tutte le modifiche prima del refresh
  5. Chiama `go_alv->refresh()` per riflettere i cambiamenti in-place
  6. Mostra un messaggio `'N ticket(s) closed.'`

---

## 6. Configurazione

### 6.1 Prima configurazione (SM30 → ZBWJOB_CONFIG)

Aprire la transazione SM30, inserire il nome della vista di manutenzione di `ZBWJOB_CONFIG` e popolare i seguenti record:

```
CONFIG_KEY    │ CONFIG_VALUE                              │ DESCRIPTION
──────────────┼───────────────────────────────────────────┼─────────────────────────
SM59_DEST     │ ZBWJOB_TICKETS                            │ SM59 RFC destination name
API_PATH      │ /api/v1/tickets                           │ Base path REST endpoint
API_TOKEN     │ eyJhbGciOiJIUzI1NiIs...                  │ Bearer auth token
TIMEOUT_SEC   │ 30                                        │ HTTP timeout (seconds)
MAX_RETRY     │ 3                                         │ Max retry attempts
SYSTEM_ID     │ BW4PRD                                    │ System ID in ticket payload
PACKET_SIZE   │ 20                                        │ Max jobs per run (0 = no limit)
```

> Il token deve avere i permessi di **creazione** e **aggiornamento** ticket nel sistema esterno.

> **SM59 setup:** creare la destinazione RFC HTTP in SM59 → tipo `G` (HTTP connection to external server). Configurare host, numero porta, eventuale path prefix e certificato SSL nel tab "Logon & Security". Il nome della destinazione deve corrispondere al valore di `SM59_DEST`.

### 6.2 Configurazione priorità (SM30 → ZBWJOB_PRIORITY)

Inserire le regole di priorità dalla più specifica alla più generica. Il motore di matching valuta le regole nell'ordine in cui le trova (esatto prima, poi wildcard):

```
CHAIN_PATTERN         │ PRIORITY │ ACTIVE │ NOTE
──────────────────────┼──────────┼────────┼──────────────────────
ZBW_FINANCE_CLOSE_EOD │ HIGH     │ X      │ Chiusura giornata Finance
ZBW_FIN*              │ HIGH     │ X      │ Tutti i job Finance
ZBW_HR*               │ HIGH     │ X      │ HR critical loads
ZBW_MASTER_DATA*      │ MEDIUM   │ X      │ Master data load
ZBW_DELTA*            │ MEDIUM   │ X      │ Delta loads standard
ZBW_TEST*             │ LOW      │ X      │ Job di test/sviluppo
```

---

## 7. Deploy e Sequenza di Attivazione

Seguire rigorosamente questa sequenza per evitare errori di dipendenza:

### Step 1 — DDIC (SE11)

1. Aprire SE11
2. Creare e attivare `ZBTW_FAIL_JOB` (Structure) — importare da `src/ddic/ZBTW_FAIL_JOB.xml` via abapGit o creare manualmente
3. Creare e attivare `ZBTW_TICKET_LOG` (Tabella)
4. Creare e attivare `ZBWJOB_PRIORITY` (Tabella)
5. Creare e attivare `ZBWJOB_CONFIG` (Tabella)
6. Eseguire conversione dati (SE14) se necessario

### Step 2 — Destinazione SM59

1. SM59 → Creare destinazione RFC di tipo `G` (HTTP connection to external server) con il nome che sarà inserito in `SM59_DEST`
2. Configurare host, porta, SSL e certificato nel tab "Logon & Security"
3. Eseguire il connection test integrato in SM59 per validare raggiungibilità

### Step 3 — Dati di configurazione

1. SM30 → Vista `ZBWJOB_CONFIG`: inserire almeno `SM59_DEST`, `API_PATH`, `API_TOKEN`, `SYSTEM_ID`
2. SM30 → Vista `ZBWJOB_PRIORITY`: inserire le regole di priorità base

### Step 4 — Interfaccia (SE24)

1. Creare `ZIF_TICKET_PROVIDER` con i tre metodi definiti

### Step 5 — Classi (SE24), in ordine

1. `ZCL_BW_JOB_READER` — nessuna dipendenza su altre classi Z
2. `ZCL_TICKET_DEDUP` — dipende da `ZBTW_TICKET_LOG`
3. `ZCL_TICKET_HTTP_CLIENT` — implementa `ZIF_TICKET_PROVIDER`
4. `ZCL_TICKET_FACTORY` — dipende da `ZCL_TICKET_HTTP_CLIENT` e `ZBWJOB_CONFIG`

### Step 6 — Report (SE38)

1. `ZBW_JOB_MONITOR` — dipende da tutte le classi precedenti
2. `ZBW_TICKET_STATUS` — dipende da `ZBTW_TICKET_LOG`

### Step 7 — Test isolato

```
SE38 → ZBW_JOB_MONITOR → Eseguire con P_TEST = X
```
Verificare che l'output mostri i job falliti senza errori di sintassi o runtime.

### Step 8 — Test integrazione (facoltativo)

Configurare la destinazione SM59 puntando a un mock server (es. Postman Mock, RequestBin) e rieseguire con `P_TEST = ' '` per validare il payload HTTP e il parsing del ticket ID.

---

## 8. Schedulazione SM36

### Variante PROD (produzione)

```
Job Name:   ZBW_JOB_MONITOR_PROD
Step 1:     ABAP Program = ZBW_JOB_MONITOR
Variante:   PROD
  P_LKBK  = 60
  P_TEST  = (spazio)
Schedule:   Periodico — ogni 30 minuti
            Start time: immediatamente dopo l'attivazione
```

> Con lookback 60 minuti e run ogni 30 minuti c'è una sovrapposizione intenzionale: garantisce che nessun job fallito venga saltato in caso di ritardo del ciclo precedente. La deduplication evita ticket doppi.

### Variante TEST

```
Job Name:   ZBW_JOB_MONITOR_TEST
Step 1:     ABAP Program = ZBW_JOB_MONITOR
Variante:   TEST
  P_LKBK  = 60
  P_TEST  = X
Schedule:   Manuale (on-demand)
```

### Autorizzazioni richieste

| Oggetto autorizzazione | Campo | Valore |
|------------------------|-------|--------|
| `S_BTCH_JOB` | `JOBACTION` | `RELE` |
| `S_RFC` | `FUGR` | (per chiamate HTTP) |
| `S_TABU_DIS` | `ACTVT` | `02`, `03` su gruppo tabella Z |

---

## 9. Gestione Errori

### Filosofia

Il report `ZBW_JOB_MONITOR` **non deve abortire** per un errore su un singolo job. La gestione è a due livelli:

```
TRY  (esterno — errori fatali: configurazione mancante, HTTP setup)
  │
  LOOP AT lt_all_jobs
    TRY  (per-job — errori su singolo ticket)
    CATCH cx_static_check
      → WRITE [ERROR] + MESSAGE 'I'  ← non interrompe il loop
    ENDTRY
  ENDLOOP
  │
  cleanup_old_entries()
│
CATCH cx_static_check  ← errori fatali
  → WRITE [FATAL] + MESSAGE 'I'
ENDTRY
```

### Tipi di errore e comportamento

| Scenario | Comportamento |
|----------|--------------|
| Job SAP senza error message in TBTCP | `ERROR_MSG` resta vuoto; ticket aperto senza descrizione |
| API non raggiungibile (timeout) | `cx_static_check` catturata per-job; log su WRITE; job continua |
| HTTP status code != 200/201 | Come sopra |
| `parse_ticket_id` non trova ID | `rv_ticket_id` = spazio; `save_new_ticket` persiste record con ticket ID vuoto |
| `ZBWJOB_CONFIG` mancante | `ZCL_TICKET_FACTORY` usa fallback per timeout; URL/token restano vuoti → errore HTTP |
| Ticket chiuso esternamente, SAP ancora `OPEN` | `get_ticket_status()` rileva lo stato `CLOSED`; il report chiama `mark_ticket_closed()` e logga `[SYNC]`. Il fallimento della sola chiamata di status check (eccezione) è gestito silenziosamente: si procede con l'update standard. |
| PACKET_SIZE raggiunto | Il loop termina con `[LIMIT]`; i job rimanenti vengono elaborati al prossimo run del monitor. |
| Job fallisce di nuovo dopo chiusura ticket | `has_open_ticket()` non trova ticket `OPEN`; `save_new_ticket()` sovrascrive la riga `CLOSED` tramite `MODIFY` e apre un nuovo ticket. |

> **Nota:** controllare `sy-subrc` dopo `MODIFY` in `ZCL_TICKET_DEDUP→save_new_ticket()` è un miglioramento raccomandato per ambienti produttivi.

### Log applicativo (opzionale — produzione)

Per un log persistente consultabile via SLG1, sostituire i `WRITE` con:

```abap
CALL FUNCTION 'APPL_LOG_WRITE_MESSAGE'
  EXPORTING
    object    = 'ZBWMONITOR'
    subobject = 'TICKETS'
    ...
```

---

## 10. Manutenzione e Operatività

### Consultazione ticket aperti

1. Eseguire `ZBW_TICKET_STATUS` in SE38 o tramite transazione dedicata
2. Filtrare per data e status desiderato
3. Selezionare le righe e cliccare **"Close Ticket"** per chiuderle manualmente

### Housekeeping automatico

Il report `ZBW_JOB_MONITOR` chiama automaticamente `cleanup_old_entries(30)` al termine di ogni run. Modifica il parametro direttamente nel sorgente se serve una retention diversa.

### Pulizia manuale

Per svuotare la log manualmente (es. in sistemi di test):

```sql
-- SM30 o SE16N
DELETE FROM zbtw_ticket_log WHERE log_date < '20260101'.
```

### Monitoraggio del job stesso

Il job `ZBW_JOB_MONITOR_PROD` deve essere monitorato tramite SM37. In caso di abend, verificare:
1. Configurazione `ZBWJOB_CONFIG` (token scaduto, URL cambiato)
2. Raggiungibilità rete del sistema di ticketing dall'application server SAP
3. Autorizzazioni ABAP per le SELECT sulle tabelle standard (TBTCO, RSPCLOGCHAIN, ecc.)

---

## 11. Estendibilità

### Aggiungere un nuovo sistema di ticketing (es. Jira)

1. Creare una nuova classe `ZCL_JIRA_CLIENT` che implementa `ZIF_TICKET_PROVIDER`
2. Implementare i tre metodi (`create_ticket`, `update_ticket`, `get_ticket_status`) con le API Jira
3. In `ZBWJOB_CONFIG`, aggiungere `CONFIG_KEY = 'PROVIDER_TYPE'` con valore `JIRA`
4. In `ZCL_TICKET_FACTORY→get_provider()`, aggiungere:

```abap
CASE lv_provider_type.
  WHEN 'JIRA'.
    ro_provider = NEW zcl_jira_client( ... ).
  WHEN OTHERS.
    ro_provider = NEW zcl_ticket_http_client( ... ).
ENDCASE.
```

Nessuna modifica al report `ZBW_JOB_MONITOR` o alle altre classi.

### Aggiungere un nuovo tipo di oggetto BW monitorato

1. Aggiungere un metodo `get_failed_<tipo>()` in `ZCL_BW_JOB_READER`
2. Implementare la logica di SELECT sulla tabella SAP corrispondente
3. In `ZBW_JOB_MONITOR`, aggiungere `APPEND LINES OF lo_reader->get_failed_<tipo>( p_lkbk ) TO lt_all_jobs`

### Notifiche email aggiuntive

Aggiungere un secondo step nel LOOP di `ZBW_JOB_MONITOR` che chiama `SO_NEW_DOCUMENT_SEND_API1` per i job con `PRIORITY = 'HIGH'`, senza modificare la logica di ticketing.

---

## 12. Glossario Oggetti

| Oggetto SAP | Tipo | Descrizione |
|-------------|------|-------------|
| `ZBTW_FAIL_JOB` | Structure (SE11) | Struttura dati per job fallito |
| `ZBTW_TICKET_LOG` | Transparent Table | Log deduplication ticket |
| `ZBWJOB_PRIORITY` | Transparent Table | Regole di priorità per pattern |
| `ZBWJOB_CONFIG` | Transparent Table | Parametri connessione API |
| `ZIF_TICKET_PROVIDER` | Interface | Contratto provider ticketing |
| `ZCL_BW_JOB_READER` | Class | Lettore job falliti da SAP standard |
| `ZCL_TICKET_DEDUP` | Class | Gestore deduplication ticket |
| `ZCL_TICKET_HTTP_CLIENT` | Class | Implementazione REST generica |
| `ZCL_TICKET_FACTORY` | Class | Factory per il provider |
| `ZBW_JOB_MONITOR` | Report | Orchestratore principale (SM36) |
| `ZBW_TICKET_STATUS` | Report | Consultazione ALV + close manuale |

---

*Documentazione generata il 13 aprile 2026.*
