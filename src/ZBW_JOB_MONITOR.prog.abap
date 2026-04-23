*&---------------------------------------------------------------------*
*& Report  ZBW_JOB_MONITOR
*& BW4HANA Failed-Job Monitor — da schedulare ogni 30 min in SM36
*&
*& Scopo:
*&   Orchestratore principale del sistema ZBW Job Monitor.
*&   Raccoglie i job/chain/DTP falliti nelle ultime P_LKBK minuti,
*&   e per ognuno decide se aprire un nuovo ticket, aggiornare un ticket
*&   esistente o sincronizzare una chiusura avvenuta esternamente.
*&
*& Flusso:
*&   1. ZCL_BW_JOB_READER legge TBTCO, RSPCLOGCHAIN, RSBKREQUEST
*&   2. ZCL_TICKET_DEDUP verifica se esiste già un ticket OPEN per l'oggetto
*&   3. ZCL_TICKET_HTTP_CLIENT crea/aggiorna il ticket nel sistema esterno
*&   4. ZCL_BW_MAIL_NOTIFIER invia email ai destinatari configurati (solo su CREATE)
*&   5. COMMIT WORK AND WAIT dopo ogni scrittura su ZBTW_TICKET_LOG
*&
*& Gestione errori:
*&   - TRY esterno: cattura errori fatali (config mancante, SM59 non trovata)
*&   - TRY per-job: cattura errori sul singolo ticket senza fermare il loop
*&
*& Modalità TEST (P_TEST = X):
*&   Esegue tutti i SELECT e la logica di rilevamento senza aprire ticket
*&   o scrivere in ZBTW_TICKET_LOG. Utile per validare la configurazione.
*&---------------------------------------------------------------------*
REPORT zbw_job_monitor.

"----------------------------------------------------------------------
" Selection screen
"----------------------------------------------------------------------
PARAMETERS:
  p_lkbk TYPE i     DEFAULT 60  OBLIGATORY,   " finestra di lookback in minuti
  p_test TYPE xfeld DEFAULT space.             " X = modalità test (nessun ticket reale)

"----------------------------------------------------------------------
" Main processing
"----------------------------------------------------------------------
START-OF-SELECTION.

  DATA: lo_reader      TYPE REF TO zcl_bw_job_reader,
        lo_dedup       TYPE REF TO zcl_ticket_dedup,
        lo_provider    TYPE REF TO zif_ticket_provider,
        lo_notifier    TYPE REF TO zcl_bw_mail_notifier,
        lt_all_jobs    TYPE STANDARD TABLE OF zbtw_fail_job WITH DEFAULT KEY,
        ls_job         TYPE zbtw_fail_job,
        lv_existing    TYPE char50,   " ticket ID se già OPEN in ZBTW_TICKET_LOG
        lv_new_id      TYPE char50,   " ticket ID restituito dall'API su CREATE
        lv_ext_status  TYPE char20,   " stato del ticket nel sistema esterno (per sync)
        lv_packet_str  TYPE char10,   " PACKET_SIZE come stringa da ZBWJOB_CONFIG
        lv_packet      TYPE i,        " PACKET_SIZE come intero (0 = illimitato)
        lv_processed   TYPE i.        " contatore job elaborati nel run corrente

  " Segnala modalità test all'inizio dell'output per chiarezza.
  IF p_test = abap_true.
    WRITE: / '*** TEST MODE - no tickets will be created or updated ***'.
    SKIP.
  ENDIF.

  TRY.
      " -------------------------------------------------------------------
      " 1. Raccolta job falliti da tutte e tre le sorgenti
      " -------------------------------------------------------------------
      lo_reader = NEW zcl_bw_job_reader( ).

      " Legge job background abortiti (TBTCO STATUS='A').
      APPEND LINES OF lo_reader->get_failed_jobs( p_lkbk )    TO lt_all_jobs.

      " Legge process chain in errore/aborted (RSPCLOGCHAIN LOGSTATE IN ('E','A')).
      APPEND LINES OF lo_reader->get_failed_chains( p_lkbk )  TO lt_all_jobs.

      " Legge DTP falliti (RSBKREQUEST STATUS='8'), aggregati per DTPNAME.
      APPEND LINES OF lo_reader->get_failed_dtps( p_lkbk )    TO lt_all_jobs.

      " Se non ci sono oggetti falliti nella finestra di lookback, termina.
      IF lt_all_jobs IS INITIAL.
        WRITE: / |No failed jobs found in the last { p_lkbk } minute(s).|.
        RETURN.
      ENDIF.

      WRITE: / |Found { lines( lt_all_jobs ) } failed object(s). Processing...|.
      SKIP.

      " -------------------------------------------------------------------
      " 2. Istanzia i servizi condivisi usati nel loop
      " -------------------------------------------------------------------
      lo_dedup    = NEW zcl_ticket_dedup( ).
      lo_provider = zcl_ticket_factory=>get_provider( ).  " legge SM59_DEST, API_PATH, API_TOKEN
      lo_notifier = NEW zcl_bw_mail_notifier( ).          " legge ZBWJOB_MAILLIST a runtime

      " -------------------------------------------------------------------
      " 2b. Legge il limite opzionale di job per run (PACKET_SIZE)
      " -------------------------------------------------------------------
      " PACKET_SIZE limita il numero di job elaborati per run per contenere
      " il tempo di esecuzione in caso di mass failure (molti errori contemporanei).
      " Se assente o 0 → nessun limite.
      SELECT SINGLE config_value FROM zbwjob_config
        INTO lv_packet_str
        WHERE config_key = 'PACKET_SIZE'.
      IF sy-subrc = 0 AND lv_packet_str IS NOT INITIAL.
        lv_packet = lv_packet_str.  " conversione implicita stringa → intero
      ENDIF.

      " -------------------------------------------------------------------
      " 3. Loop principale: elabora ogni oggetto fallito
      " -------------------------------------------------------------------
      LOOP AT lt_all_jobs INTO ls_job.
        TRY.
            " Incrementa il contatore e verifica il limite PACKET_SIZE.
            lv_processed = lv_processed + 1.
            IF lv_packet > 0 AND lv_processed > lv_packet.
              " Limite raggiunto: i job rimanenti verranno elaborati al prossimo run.
              " La sovrapposizione intenzionale del lookback (60 min, run ogni 30 min)
              " garantisce che vengano ripresi.
              WRITE: / |[LIMIT] PACKET_SIZE ({ lv_packet }) reached. Remaining jobs deferred to next run.|.
              EXIT.
            ENDIF.

            " Controlla se esiste già un ticket OPEN per questo OBJECT_KEY.
            " La verifica è date-independent: evita duplicati su job a cavallo della mezzanotte.
            lv_existing = lo_dedup->has_open_ticket( ls_job ).

            IF lv_existing IS NOT INITIAL.
              " -----------------------------------------------------------
              " RAMO UPDATE: esiste già un ticket OPEN in ZBTW_TICKET_LOG
              " -----------------------------------------------------------
              IF p_test IS INITIAL.
                " Prima di aggiornare, verifica se il ticket è già stato chiuso
                " nel sistema esterno (es. dall'operatore nel portale di ticketing).
                " In caso di errore della chiamata di status (eccezione), si assume OPEN
                " e si procede con l'update standard.
                lv_ext_status = 'OPEN'.
                TRY.
                    lv_ext_status = lo_provider->get_ticket_status( lv_existing ).
                  CATCH cx_static_check.
                    " Errore nel recupero dello stato esterno — ignorato silenziosamente.
                    " Comportamento: procede con l'update come se il ticket fosse OPEN.
                ENDTRY.

                IF lv_ext_status CS 'CLOSE'.
                  " Il ticket è stato chiuso esternamente: sincronizza il record SAP.
                  " CS 'CLOSE' cattura sia "CLOSED" che "CLOSE" o altre varianti.
                  lo_dedup->mark_ticket_closed( ls_job-object_key ).
                  COMMIT WORK AND WAIT.  " LUW separato per ogni scrittura su DB
                  WRITE: / |[SYNC]   Ticket { lv_existing } closed externally, local status synced for { ls_job-object_key }|.
                ELSE.
                  " Il ticket è ancora aperto: aggiorna con il messaggio di errore corrente.
                  lo_provider->update_ticket(
                    iv_ticket_id = lv_existing
                    iv_message   = ls_job-error_msg ).
                  lo_dedup->mark_ticket_updated(
                    iv_object_key = ls_job-object_key
                    iv_message    = ls_job-error_msg ).
                  COMMIT WORK AND WAIT.  " LUW separato per ogni scrittura su DB
                  WRITE: / |[UPDATE] Ticket { lv_existing } - { ls_job-object_key }|.
                ENDIF.
              ELSE.
                " Modalità TEST: simula l'update senza scrivere nulla.
                WRITE: / |[UPDATE] Ticket { lv_existing } - { ls_job-object_key }|.
              ENDIF.

            ELSE.
              " -----------------------------------------------------------
              " RAMO CREATE: nessun ticket OPEN — apre un nuovo ticket
              " -----------------------------------------------------------
              IF p_test IS INITIAL.
                " Crea il ticket nel sistema esterno e ottiene l'ID assegnato.
                lv_new_id = lo_provider->create_ticket( ls_job ).

                " Persiste il nuovo ticket nel log di deduplication.
                " MODIFY gestisce anche i re-fallimenti (sovrascrive record CLOSED).
                lo_dedup->save_new_ticket(
                  is_job       = ls_job
                  iv_ticket_id = lv_new_id ).
                COMMIT WORK AND WAIT.  " LUW separato: il ticket è persistito prima della mail

                " Invia notifica email ai destinatari configurati in ZBWJOB_MAILLIST.
                " Gli errori email sono catturati internamente — non propagano mai qui.
                " Il COMMIT WORK del ticket precede la mail: anche se la mail fallisce,
                " il ticket è già creato e salvato correttamente.
                lo_notifier->notify_new_ticket(
                  is_job       = ls_job
                  iv_ticket_id = lv_new_id ).
              ELSE.
                " Modalità TEST: simula la creazione senza chiamate HTTP.
                lv_new_id = '[TEST - not created]'.
              ENDIF.
              WRITE: / |[CREATE] Ticket { lv_new_id } - { ls_job-object_key } (prio: { ls_job-priority })|.
            ENDIF.

          CATCH cx_static_check INTO DATA(lx_job).
            " Errore sul singolo job (HTTP failure, SM59 non raggiungibile, ecc.).
            " Viene loggato ma il loop continua con il job successivo.
            " Filosofia: un job non deve bloccare il processing degli altri.
            WRITE: / |[ERROR] { ls_job-object_key }: { lx_job->get_text( ) }|.
            MESSAGE lx_job->get_text( ) TYPE 'I'.
        ENDTRY.
      ENDLOOP.

      " -------------------------------------------------------------------
      " 4. Housekeeping: elimina righe più vecchie di 30 giorni
      " -------------------------------------------------------------------
      " Chiamato a ogni run per mantenere contenuta la dimensione di ZBTW_TICKET_LOG.
      SKIP.
      lo_dedup->cleanup_old_entries( 30 ).
      WRITE: / 'Housekeeping complete. Processing finished.'.

    CATCH cx_static_check INTO DATA(lx_global).
      " Errore fatale: es. SM59_DEST non configurata, SM59 non trovata,
      " errore nell'istanziazione delle classi.
      " Il report non può continuare → log e terminazione.
      WRITE: / |[FATAL] { lx_global->get_text( ) }|.
      MESSAGE lx_global->get_text( ) TYPE 'I'.
  ENDTRY.
