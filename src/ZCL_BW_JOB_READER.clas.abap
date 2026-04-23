"*----------------------------------------------------------------------*
"* Classe ZCL_BW_JOB_READER  —  Lettore job/chain/DTP falliti da SAP
"*
"* Scopo:
"*   Legge le tabelle SAP standard (TBTCO, RSPCLOGCHAIN, RSBKREQUEST)
"*   e trasforma i record falliti nella struttura di trasferimento
"*   ZBTW_FAIL_JOB, consumata poi da ZBW_JOB_MONITOR.
"*
"* Pattern:
"*   Data Reader — separa la lettura dei dati SAP dalla logica di business.
"*   Nessuna scrittura su DB: la classe è puramente read-only.
"*
"* Ottimizzazione N+1:
"*   I messaggi di errore (TBTCP, RSPCLOGENTRY) vengono recuperati con
"*   una singola SELECT FOR ALL ENTRIES prima del loop principale,
"*   evitando un SELECT SINGLE per ogni riga iterata.
"*   I risultati vengono caricati in SORTED TABLE con chiave definita
"*   per consentire READ TABLE con ricerca binaria (O(log n)).
"*
"* Nota su DTP e pacchetti paralleli:
"*   RSBKREQUEST contiene un record per ogni pacchetto parallelo fallito.
"*   Per generare un solo ticket per DTP (non uno per pacchetto), la SELECT
"*   aggrega per DTPNAME con GROUP BY e MAX() sulle colonne non chiave.
"*   L'OBJECT_KEY usa solo il DTPNAME, senza il REQUID.
"*----------------------------------------------------------------------*
CLASS zcl_bw_job_reader DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    TYPES: tt_failed_jobs TYPE STANDARD TABLE OF zbtw_fail_job WITH DEFAULT KEY.

    METHODS:
      constructor,

      "! Legge i background job abortiti da TBTCO nella finestra temporale indicata.
      "! I messaggi di errore vengono recuperati in bulk da TBTCP (no N+1).
      "!
      "! @parameter iv_lookback_min | Minuti a ritroso rispetto all'ora corrente (default 60)
      "! @parameter rt_jobs         | Tabella di job falliti con tipo BGDJOB
      get_failed_jobs
        IMPORTING
          iv_lookback_min TYPE i DEFAULT 60
        RETURNING
          VALUE(rt_jobs)  TYPE tt_failed_jobs,

      "! Legge le process chain con stato errore/aborted da RSPCLOGCHAIN.
      "! I messaggi di errore vengono recuperati in bulk da RSPCLOGENTRY (no N+1).
      "!
      "! @parameter iv_lookback_min | Minuti a ritroso rispetto all'ora corrente (default 60)
      "! @parameter rt_jobs         | Tabella di job falliti con tipo CHAIN
      get_failed_chains
        IMPORTING
          iv_lookback_min TYPE i DEFAULT 60
        RETURNING
          VALUE(rt_jobs)  TYPE tt_failed_jobs,

      "! Legge i Data Transfer Process falliti da RSBKREQUEST.
      "! Aggrega per DTPNAME: un solo record per DTP anche in presenza
      "! di più pacchetti paralleli falliti (GROUP BY).
      "!
      "! @parameter iv_lookback_min | Minuti a ritroso rispetto all'ora corrente (default 60)
      "! @parameter rt_jobs         | Tabella di job falliti con tipo DTP
      get_failed_dtps
        IMPORTING
          iv_lookback_min TYPE i DEFAULT 60
        RETURNING
          VALUE(rt_jobs)  TYPE tt_failed_jobs.

  PRIVATE SECTION.
    METHODS:
      "! Costruisce la chiave univoca dell'oggetto concatenando nome e contatore.
      "! Formato: "<IV_NAME>_<IV_COUNT>"
      "! Esempi:
      "!   BGDJOB  → "ZBW_FINANCE_LOAD_00001234"
      "!   CHAIN   → "ZBW_FIN_CHAIN_000000987654"
      "!
      "! @parameter iv_name  | Nome del job/chain/DTP
      "! @parameter iv_count | Jobcount, logid o requid
      "! @parameter rv_key   | Chiave risultante (CHAR100)
      build_object_key
        IMPORTING
          iv_name       TYPE char100
          iv_count      TYPE char10
        RETURNING
          VALUE(rv_key) TYPE char100,

      "! Determina la priorità del job cercando una corrispondenza in ZBWJOB_PRIORITY.
      "!
      "! Logica in ordine:
      "!   1. SELECT SINGLE con corrispondenza esatta su CHAIN_PATTERN
      "!   2. Loop sulle righe ACTIVE=X con operatore CP (wildcard '*' e '+')
      "!   3. Default "MEDIUM" se nessuna regola corrisponde
      "!
      "! @parameter iv_chain_name | Nome del job/chain/DTP da classificare
      "! @parameter rv_prio       | "HIGH" | "MEDIUM" | "LOW"
      get_priority
        IMPORTING
          iv_chain_name  TYPE char100
        RETURNING
          VALUE(rv_prio) TYPE char10,

      "! Calcola il timestamp UTC di cutoff per la finestra di lookback.
      "! Formula: timestamp_corrente_UTC - (iv_lookback_min * 60 secondi)
      "!
      "! @parameter iv_lookback_min | Minuti da sottrarre al timestamp corrente
      "! @parameter rv_from_ts      | Timestamp UTC di inizio finestra
      calc_from_timestamp
        IMPORTING
          iv_lookback_min   TYPE i
        RETURNING
          VALUE(rv_from_ts) TYPE timestamp.

ENDCLASS.


CLASS zcl_bw_job_reader IMPLEMENTATION.

  METHOD constructor.
    " Nessuna inizializzazione necessaria: la classe è stateless.
  ENDMETHOD.


  METHOD get_failed_jobs.
    DATA: lt_tbtco TYPE STANDARD TABLE OF tbtco,
          lt_tbtcp TYPE SORTED TABLE OF tbtcp WITH NON-UNIQUE KEY jobname jobcount,
          ls_tbtco TYPE tbtco,
          ls_tbtcp TYPE tbtcp,
          ls_job   TYPE zbtw_fail_job,
          lv_date  TYPE sy-datum,
          lv_time  TYPE sy-uzeit.

    " Calcola il timestamp UTC di inizio della finestra di lookback.
    DATA(lv_from) = calc_from_timestamp( iv_lookback_min ).

    " Converte il timestamp UTC in data/ora locale per confrontarlo con STRTDATE di TBTCO,
    " che memorizza la data nell'ora locale del server (non UTC).
    CONVERT TIME STAMP lv_from TIME ZONE sy-zonlo
      INTO DATE lv_date
           TIME lv_time.

    " Legge tutti i job con stato 'A' (Aborted) a partire dalla data calcolata.
    " STATUS = 'A' corrisponde ai job terminati in errore in SM37.
    SELECT * FROM tbtco
      INTO TABLE lt_tbtco
      WHERE status   = 'A'
        AND strtdate >= lv_date.

    " Ottimizzazione N+1: recupera in una sola SELECT tutti i record di passo (TBTCP)
    " per tutti i job trovati. Senza questo, il loop successivo eseguirebbe
    " un SELECT SINGLE per ogni job, moltiplicando le chiamate al DB.
    " La SORTED TABLE con chiave jobname+jobcount consente READ TABLE binario (O(log n)).
    IF lt_tbtco IS NOT INITIAL.
      SELECT * FROM tbtcp
        INTO TABLE lt_tbtcp
        FOR ALL ENTRIES IN lt_tbtco
        WHERE jobname  = lt_tbtco-jobname
          AND jobcount = lt_tbtco-jobcount.
    ENDIF.

    LOOP AT lt_tbtco INTO ls_tbtco.
      CLEAR ls_job.
      ls_job-jobname    = ls_tbtco-jobname.
      ls_job-jobcount   = ls_tbtco-jobcount.
      ls_job-job_type   = 'BGDJOB'.

      " La chiave univoca combina nome e contatore job.
      ls_job-object_key = build_object_key(
                            iv_name  = |{ ls_tbtco-jobname }|
                            iv_count = |{ ls_tbtco-jobcount }| ).

      " Converte data/ora di fine job (ora locale) in timestamp UTC.
      CONVERT DATE ls_tbtco-enddate
              TIME ls_tbtco-endtime
        TIME ZONE sy-zonlo
        INTO TIME STAMP ls_job-fail_tstamp.

      " Cerca il messaggio di errore nella SORTED TABLE con ricerca binaria.
      " DYNDTEXT contiene il testo dinamico del passo visualizzato in SM37.
      " TODO #4: verificare che DYNDTEXT sia popolato in produzione per i job abortiti.
      READ TABLE lt_tbtcp INTO ls_tbtcp
        WITH KEY jobname  = ls_tbtco-jobname
                 jobcount = ls_tbtco-jobcount.
      IF sy-subrc = 0.
        ls_job-error_msg = ls_tbtcp-dyndtext(255).  " troncato a 255 caratteri
      ENDIF.

      ls_job-priority = get_priority( |{ ls_tbtco-jobname }| ).

      APPEND ls_job TO rt_jobs.
    ENDLOOP.
  ENDMETHOD.


  METHOD get_failed_chains.
    " Tipo locale che proietta solo i campi necessari da RSPCLOGENTRY,
    " riducendo il volume di dati trasferito dal DB.
    TYPES: BEGIN OF ty_logentry,
             logid   TYPE rspclogentry-logid,
             message TYPE rspclogentry-message,
           END OF ty_logentry.

    DATA: lt_chains     TYPE STANDARD TABLE OF rspclogchain,
          lt_logentries TYPE SORTED TABLE OF ty_logentry WITH NON-UNIQUE KEY logid,
          ls_chain      TYPE rspclogchain,
          ls_job        TYPE zbtw_fail_job.

    " Calcola il timestamp UTC di inizio della finestra di lookback.
    DATA(lv_from) = calc_from_timestamp( iv_lookback_min ).

    " Legge le process chain con stato errore ('E') o abortite ('A').
    " STARTTIME in RSPCLOGCHAIN è già un timestamp UTC: il confronto con lv_from è diretto.
    SELECT * FROM rspclogchain
      INTO TABLE lt_chains
      WHERE logstate IN ('E', 'A')
        AND starttime >= lv_from.

    " Ottimizzazione N+1: recupera in una sola SELECT i messaggi di errore (severity='E')
    " di tutte le chain trovate.
    " Vengono letti solo LOGID e MESSAGE per minimizzare il traffico DB.
    IF lt_chains IS NOT INITIAL.
      SELECT logid message FROM rspclogentry
        INTO CORRESPONDING FIELDS OF TABLE lt_logentries
        FOR ALL ENTRIES IN lt_chains
        WHERE logid    = lt_chains-logid
          AND severity = 'E'.
    ENDIF.

    LOOP AT lt_chains INTO ls_chain.
      CLEAR ls_job.
      ls_job-chain_id    = ls_chain-chain_id.
      ls_job-job_type    = 'CHAIN'.
      ls_job-fail_tstamp = ls_chain-starttime.

      " La chiave univoca combina chain_id e logid della sessione di log.
      ls_job-object_key  = build_object_key(
                             iv_name  = |{ ls_chain-chain_id }|
                             iv_count = |{ ls_chain-logid }| ).

      " Cerca il primo messaggio di errore per questo logid (ricerca binaria).
      READ TABLE lt_logentries
        WITH KEY logid = ls_chain-logid
        INTO DATA(ls_entry).
      IF sy-subrc = 0.
        ls_job-error_msg = ls_entry-message.
      ENDIF.

      ls_job-priority = get_priority( |{ ls_chain-chain_id }| ).

      APPEND ls_job TO rt_jobs.
    ENDLOOP.
  ENDMETHOD.


  METHOD get_failed_dtps.
    DATA ls_job TYPE zbtw_fail_job.

    " Calcola il timestamp UTC di inizio della finestra di lookback.
    DATA(lv_from) = calc_from_timestamp( iv_lookback_min ).

    " Aggrega per DTPNAME per evitare un ticket per ogni pacchetto parallelo fallito.
    " Senza GROUP BY, ogni REQUID fallito produce una riga separata con lo stesso DTPNAME,
    " causando N ticket per la stessa esecuzione DTP (uno per pacchetto).
    " MAX(timestamp) → il pacchetto più recente come riferimento temporale.
    " MAX(requid)    → un REQUID rappresentativo (non usato nell'OBJECT_KEY).
    " MAX(msgv1)    → un messaggio di errore rappresentativo tra quelli disponibili.
    "
    " TODO #1 (ALTA): verificare che status = '8' sia il valore corretto per errore.
    "   Percorso: SE11 → RSBKREQUEST → campo status → dominio → valori fissi.
    " TODO #2 (ALTA): verificare che il nome tecnico del campo sia 'STATUS' (non RSTSTATUS).
    SELECT dtpname,
           MAX( timestamp ) AS timestamp,
           MAX( requid )    AS requid,
           MAX( msgv1 )     AS msgv1
      FROM rsbkrequest
      INTO TABLE @DATA(lt_req)
      WHERE status    = '8'
        AND timestamp >= @lv_from
      GROUP BY dtpname.

    LOOP AT lt_req INTO DATA(ls_req).
      CLEAR ls_job.
      ls_job-jobname     = ls_req-dtpname.
      ls_job-job_type    = 'DTP'.
      ls_job-fail_tstamp = ls_req-timestamp.

      " OBJECT_KEY usa solo DTPNAME, senza REQUID.
      " Questo garantisce che tutti i pacchetti dello stesso DTP condividano
      " la stessa chiave di deduplication → un solo ticket per DTP.
      ls_job-object_key  = ls_req-dtpname.

      ls_job-error_msg   = ls_req-msgv1.
      ls_job-priority    = get_priority( ls_req-dtpname ).

      APPEND ls_job TO rt_jobs.
    ENDLOOP.
  ENDMETHOD.


  METHOD build_object_key.
    " Concatena nome e contatore con underscore come separatore.
    " Il risultato identifica univocamente una specifica esecuzione di un job/chain.
    rv_key = |{ iv_name }_{ iv_count }|.
  ENDMETHOD.


  METHOD get_priority.
    DATA: lt_prio TYPE STANDARD TABLE OF zbwjob_priority,
          ls_prio TYPE zbwjob_priority.

    " --- Passo 1: corrispondenza esatta ---
    " Cerca una riga con CHAIN_PATTERN identico al nome del job (case-sensitive).
    " La corrispondenza esatta ha sempre precedenza sulle regole wildcard.
    SELECT SINGLE * FROM zbwjob_priority
      INTO ls_prio
      WHERE chain_pattern = iv_chain_name
        AND active        = 'X'.
    IF sy-subrc = 0.
      rv_prio = ls_prio-priority.
      RETURN.
    ENDIF.

    " --- Passo 2: corrispondenza wildcard ---
    " Recupera tutte le righe attive con potenziali pattern wildcard.
    " L'operatore ABAP CP (Contains Pattern) supporta:
    "   '*' → zero o più caratteri qualsiasi (equivalente a '%' in SQL LIKE)
    "   '+' → esattamente un carattere qualsiasi (equivalente a '_' in SQL LIKE)
    " Si ferma alla prima corrispondenza trovata — l'ordine delle righe in tabella
    " determina la precedenza tra regole wildcard sovrapposte.
    SELECT * FROM zbwjob_priority
      INTO TABLE lt_prio
      WHERE active = 'X'.

    LOOP AT lt_prio INTO ls_prio.
      IF iv_chain_name CP ls_prio-chain_pattern.
        rv_prio = ls_prio-priority.
        RETURN.
      ENDIF.
    ENDLOOP.

    " --- Passo 3: default ---
    " Nessuna regola corrisponde → priorità MEDIUM come valore sicuro di fallback.
    rv_prio = 'MEDIUM'.
  ENDMETHOD.


  METHOD calc_from_timestamp.
    " Converte i minuti in secondi e sottrae dal timestamp UTC corrente.
    " I timestamp ABAP (tipo TIMESTAMP) sono interi a 15 cifre nel formato YYYYMMDDHHmmss,
    " quindi la sottrazione di secondi funziona direttamente come aritmetica intera.
    " Esempio: 30 minuti = 1800 secondi; 60 minuti = 3600 secondi.
    DATA(lv_seconds) = iv_lookback_min * 60.
    GET TIME STAMP FIELD DATA(lv_now).   " timestamp UTC del momento corrente
    rv_from_ts = lv_now - lv_seconds.
  ENDMETHOD.

ENDCLASS.
