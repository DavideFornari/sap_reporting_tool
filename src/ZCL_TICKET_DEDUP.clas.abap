"*----------------------------------------------------------------------*
"* Classe ZCL_TICKET_DEDUP  —  Repository per la deduplication ticket
"*
"* Scopo:
"*   Isola completamente l'accesso alla tabella ZBTW_TICKET_LOG dal
"*   report principale ZBW_JOB_MONITOR. Implementa il pattern Repository:
"*   tutta la logica di persistenza (INSERT/UPDATE/DELETE) risiede qui.
"*
"* Strategia di deduplication:
"*   La chiave di deduplication è OBJECT_KEY (indipendente dalla data).
"*   Un solo record per job/chain/DTP può essere OPEN in qualsiasi momento.
"*   Questo elimina il "Midnight Duplicate": se un job inizia prima e
"*   termina dopo la mezzanotte, la data cambia ma l'OBJECT_KEY rimane
"*   lo stesso, quindi nessun secondo ticket viene aperto.
"*
"* Gestione dei re-fallimenti:
"*   Se un job fallisce di nuovo dopo che il relativo ticket è già CLOSED,
"*   save_new_ticket() usa MODIFY (non INSERT) per sovrascrivere il record
"*   CLOSED con un nuovo record OPEN. Questo garantisce che ci sia sempre
"*   al massimo una riga per OBJECT_KEY in ZBTW_TICKET_LOG.
"*
"* Confini LUW:
"*   Questa classe non emette COMMIT WORK. La responsabilità del commit
"*   appartiene al report chiamante (ZBW_JOB_MONITOR), che usa
"*   COMMIT WORK AND WAIT dopo ogni chiamata ai metodi di scrittura.
"*----------------------------------------------------------------------*
CLASS zcl_ticket_dedup DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    METHODS:
      "! Verifica se esiste già un ticket OPEN per il job indicato.
      "!
      "! La ricerca è basata su OBJECT_KEY senza filtro sulla data:
      "! evita falsi negativi nei job che attraversano la mezzanotte.
      "!
      "! @parameter is_job        | Job fallito — viene usato solo il campo OBJECT_KEY
      "! @parameter rv_ticket_id  | TICKET_ID se trovato un record OPEN, spazio altrimenti
      has_open_ticket
        IMPORTING
          is_job              TYPE zbtw_fail_job
        RETURNING
          VALUE(rv_ticket_id) TYPE char50,

      "! Persiste un nuovo ticket appena creato nel log di deduplication.
      "!
      "! Usa MODIFY (non INSERT) per gestire i re-fallimenti:
      "! se esiste già un record CLOSED per lo stesso OBJECT_KEY,
      "! viene sovrascritto con il nuovo OPEN invece di generare un errore.
      "!
      "! @parameter is_job       | Job fallito (object_key, jobname, error_msg)
      "! @parameter iv_ticket_id | ID del ticket restituito dall'API esterna
      save_new_ticket
        IMPORTING
          is_job       TYPE zbtw_fail_job
          iv_ticket_id TYPE char50,

      "! Aggiorna il record a UPDATED con il messaggio di errore più recente.
      "!
      "! Chiamato quando il job fallisce di nuovo e un ticket OPEN esiste già:
      "! il ticket esterno viene commentato, il log SAP viene aggiornato di conseguenza.
      "!
      "! @parameter iv_object_key | Chiave univoca del job/chain
      "! @parameter iv_message    | Nuovo messaggio di errore da registrare
      mark_ticket_updated
        IMPORTING
          iv_object_key TYPE char100
          iv_message    TYPE char255,

      "! Imposta lo stato del ticket a CLOSED (sincronizzazione esterna).
      "!
      "! Chiamato quando get_ticket_status() rileva che il ticket è già stato
      "! chiuso nel sistema esterno dall'operatore. Allinea il record SAP
      "! allo stato reale senza tentare un ulteriore aggiornamento.
      "!
      "! @parameter iv_object_key | Chiave univoca del job/chain da chiudere
      mark_ticket_closed
        IMPORTING
          iv_object_key TYPE char100,

      "! Elimina le righe di log più vecchie di IV_DAYS_TO_KEEP giorni.
      "!
      "! Chiamato automaticamente da ZBW_JOB_MONITOR alla fine di ogni run
      "! (default: 30 giorni). Mantiene contenuta la dimensione della tabella
      "! ZBTW_TICKET_LOG senza intervento manuale.
      "!
      "! @parameter iv_days_to_keep | Numero di giorni di retention (default 30)
      cleanup_old_entries
        IMPORTING
          iv_days_to_keep TYPE i DEFAULT 30.

ENDCLASS.


CLASS zcl_ticket_dedup IMPLEMENTATION.

  METHOD has_open_ticket.
    " Cerca un solo record con OBJECT_KEY e stato OPEN.
    " Nessun filtro su LOG_DATE: la deduplication è date-independent.
    SELECT SINGLE ticket_id FROM zbtw_ticket_log
      INTO rv_ticket_id
      WHERE object_key    = is_job-object_key
        AND ticket_status = 'OPEN'.
    " Se sy-subrc <> 0 (nessun record trovato), rv_ticket_id rimane spazio (initial).
  ENDMETHOD.


  METHOD save_new_ticket.
    DATA ls_log TYPE zbtw_ticket_log.

    " Popolamento del record da inserire/sovrascrivere.
    ls_log-object_key    = is_job-object_key.
    ls_log-log_date      = sy-datum.           " data di primo rilevamento (solo housekeeping)
    ls_log-ticket_id     = iv_ticket_id.
    ls_log-ticket_status = 'OPEN'.
    ls_log-chain_name    = is_job-jobname.     " nome leggibile del job/chain
    ls_log-error_msg     = is_job-error_msg.
    GET TIME STAMP FIELD ls_log-created_at.    " timestamp UTC corrente
    ls_log-updated_at    = ls_log-created_at.  " alla creazione, i due timestamp coincidono

    " MODIFY invece di INSERT:
    "   - Se non esiste alcun record → equivalente a INSERT.
    "   - Se esiste un record CLOSED per lo stesso OBJECT_KEY (re-fallimento) → UPDATE.
    " Questo garantisce la regola "al massimo una riga per OBJECT_KEY".
    MODIFY zbtw_ticket_log FROM ls_log.
  ENDMETHOD.


  METHOD mark_ticket_updated.
    DATA lv_ts TYPE timestamp.
    GET TIME STAMP FIELD lv_ts.   " timestamp UTC del momento dell'aggiornamento

    " Aggiorna solo i campi pertinenti; non tocca TICKET_ID o LOG_DATE.
    " Nessun filtro su LOG_DATE: la chiave è solo OBJECT_KEY.
    UPDATE zbtw_ticket_log
      SET ticket_status = 'UPDATED'
          error_msg     = iv_message
          updated_at    = lv_ts
      WHERE object_key = iv_object_key.
  ENDMETHOD.


  METHOD mark_ticket_closed.
    DATA lv_ts TYPE timestamp.
    GET TIME STAMP FIELD lv_ts.   " timestamp UTC della chiusura

    " Porta lo stato a CLOSED e aggiorna il timestamp.
    " Non modifica ERROR_MSG: si conserva il messaggio dell'ultima rilevazione.
    UPDATE zbtw_ticket_log
      SET ticket_status = 'CLOSED'
          updated_at    = lv_ts
      WHERE object_key = iv_object_key.
  ENDMETHOD.


  METHOD cleanup_old_entries.
    " Calcola la data di cutoff: tutto ciò che è precedente viene eliminato.
    " Esempio: iv_days_to_keep = 30, sy-datum = 20260513 → cutoff = 20260413.
    DATA(lv_cutoff) = sy-datum - iv_days_to_keep.

    DELETE FROM zbtw_ticket_log
      WHERE log_date < lv_cutoff.
    " sy-subrc viene ignorato: se non ci sono righe da eliminare non è un errore.
  ENDMETHOD.

ENDCLASS.
