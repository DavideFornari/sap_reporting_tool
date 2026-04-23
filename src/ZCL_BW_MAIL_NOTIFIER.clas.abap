"*----------------------------------------------------------------------*
"* Classe ZCL_BW_MAIL_NOTIFIER  —  Notifiche email per incident aperti
"*
"* Scopo:
"*   Invia una email di notifica ai destinatari configurati in
"*   ZBWJOB_MAILLIST ogni volta che viene aperto un NUOVO ticket.
"*   Non viene invocata su UPDATE o CLOSE: le notifiche riguardano
"*   solo l'apertura di un nuovo incident.
"*
"* Dipendenze SAP:
"*   CL_BCS                  — Send Request (punto di ingresso per l'invio)
"*   CL_DOCUMENT_BCS         — Documento email (oggetto, corpo)
"*   CL_INTERNET_ADDRESS_BCS — Indirizzo destinatario email internet
"*   Prerequisito: il sistema SAP deve essere configurato per l'invio
"*   email tramite transazione SCOT (SAP Connect). Coinvolgere Basis.
"*
"* Logica di matching destinatari (ZBWJOB_MAILLIST):
"*   1. SELECT di tutte le righe con ACTIVE='X' e JOB_TYPE IN ('*', tipo)
"*   2. Filtraggio per CHAIN_PATTERN con operatore CP (wildcard '*'/'+')
"*   3. Deduplicazione indirizzi (SORT + DELETE ADJACENT DUPLICATES)
"*
"* Gestione errori:
"*   CX_BCS viene catturata internamente e loggata con WRITE [MAIL-ERR].
"*   L'eccezione non viene MAI propagata al report chiamante:
"*   un problema SMTP non deve bloccare o annullare la creazione del ticket.
"*----------------------------------------------------------------------*
CLASS zcl_bw_mail_notifier DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    "! Entry point: invia notifica email per un nuovo ticket appena aperto.
    "!
    "! Chiamato da ZBW_JOB_MONITOR dopo COMMIT WORK AND WAIT nel ramo CREATE.
    "! Se non esistono destinatari attivi in ZBWJOB_MAILLIST, il metodo
    "! termina silenziosamente senza inviare nulla.
    "!
    "! @parameter is_job       | Job fallito (job_type, jobname/chain_id, error_msg, priority)
    "! @parameter iv_ticket_id | ID del ticket assegnato dal sistema esterno
    METHODS:
      notify_new_ticket
        IMPORTING
          is_job       TYPE zbtw_fail_job
          iv_ticket_id TYPE char50.

  PRIVATE SECTION.
    METHODS:
      "! Recupera la lista dei destinatari email attivi per questo job.
      "!
      "! Logica:
      "!   1. SELECT su ZBWJOB_MAILLIST con ACTIVE='X' e JOB_TYPE IN ('*', tipo)
      "!   2. Filtraggio per CHAIN_PATTERN tramite CP (wildcard SAP)
      "!   3. Deduplicazione (lo stesso indirizzo può matchare più regole)
      "!
      "! @parameter is_job      | Job fallito — usati job_type e nome (jobname/chain_id)
      "! @parameter rt_emails   | Tabella di indirizzi email univoci e attivi
      get_recipients
        IMPORTING
          is_job              TYPE zbtw_fail_job
        RETURNING
          VALUE(rt_emails)    TYPE STANDARD TABLE OF char241,

      "! Determina il nome display del job in base al tipo.
      "!
      "! Priorità:
      "!   1. chain_id  (CHAIN)  → es. "ZBW_FINANCE_CLOSE"
      "!   2. jobname   (BGDJOB, DTP) → es. "ZBW_HR_LOAD" o nome DTP
      "!   3. object_key (fallback)
      "!
      "! @parameter is_job    | Job fallito
      "! @parameter rv_name   | Nome display del job/chain/DTP
      get_job_name
        IMPORTING
          is_job            TYPE zbtw_fail_job
        RETURNING
          VALUE(rv_name)    TYPE char100,

      "! Costruisce il corpo testuale dell'email come tabella di righe (BCSY_TEXT).
      "! Formato: blocco testuale con tutti i campi rilevanti dell'incident.
      "!
      "! @parameter is_job       | Job fallito (tutti i campi dell'incident)
      "! @parameter iv_ticket_id | ID del ticket da includere nel corpo
      "! @parameter iv_job_name  | Nome display del job (da GET_JOB_NAME)
      "! @parameter rt_body      | Tabella di righe SOLISTI1 (tipo per CL_BCS)
      build_mail_body
        IMPORTING
          is_job             TYPE zbtw_fail_job
          iv_ticket_id       TYPE char50
          iv_job_name        TYPE char100
        RETURNING
          VALUE(rt_body)     TYPE bcsy_text.

ENDCLASS.


CLASS zcl_bw_mail_notifier IMPLEMENTATION.

  METHOD notify_new_ticket.
    DATA: lt_emails   TYPE STANDARD TABLE OF char241,
          lv_email    TYPE char241,
          lv_job_name TYPE char100,
          lt_body     TYPE bcsy_text,
          lo_send_req TYPE REF TO cl_bcs,
          lo_doc      TYPE REF TO cl_document_bcs,
          lo_rec      TYPE REF TO if_recipient_bcs,
          lv_subject  TYPE so_obj_des.

    " Recupera la lista dei destinatari attivi per questo job/tipo.
    lt_emails   = get_recipients( is_job ).

    " Se nessun destinatario è configurato, esce silenziosamente.
    " Non è un errore: ZBWJOB_MAILLIST può essere vuota per design.
    IF lt_emails IS INITIAL.
      RETURN.
    ENDIF.

    " Determina il nome display del job da usare nell'oggetto e nel corpo.
    lv_job_name = get_job_name( is_job ).

    " Costruisce il corpo testuale dell'email.
    lt_body     = build_mail_body(
                    is_job       = is_job
                    iv_ticket_id = iv_ticket_id
                    iv_job_name  = lv_job_name ).

    " Oggetto email: identificativo immediato dell'incident.
    lv_subject = |[BW Monitor] Incident opened: { lv_job_name } - Ticket { iv_ticket_id }|.

    TRY.
        " CREATE_PERSISTENT: il send request viene scritto nel database SOST/SOIN
        " e l'invio avviene tramite il servizio SCOT (SAP Connect).
        lo_send_req = cl_bcs=>create_persistent( ).

        " Crea il documento email con tipo RAW (testo semplice).
        " Tipo RAW = testo senza formattazione HTML — massima compatibilità.
        lo_doc = cl_document_bcs=>create_document(
          i_type    = 'RAW'
          i_text    = lt_body
          i_subject = lv_subject ).

        lo_send_req->set_document( lo_doc ).

        " Aggiunge ogni destinatario come indirizzo internet.
        " I_EXPRESS = ABAP_TRUE → invio prioritario (dipende dalla configurazione SCOT).
        LOOP AT lt_emails INTO lv_email.
          lo_rec = cl_internet_address_bcs=>create_internet_address( lv_email ).
          lo_send_req->add_recipient(
            i_recipient = lo_rec
            i_express   = abap_true ).
        ENDLOOP.

        " SET_SEND_IMMEDIATELY = TRUE: l'invio avviene subito nel send request,
        " senza attendere il job periodico di SCOT.
        lo_send_req->set_send_immediately( abap_true ).
        lo_send_req->send( ).

        " COMMIT WORK necessario per persistere il send request nel DB.
        " Questo commit riguarda solo la parte email — il ticket è già committato
        " con COMMIT WORK AND WAIT nel report chiamante prima di questa chiamata.
        COMMIT WORK AND WAIT.

      CATCH cx_bcs INTO DATA(lx_bcs).
        " Cattura qualsiasi errore CL_BCS (SCOT non configurato, indirizzo non valido,
        " errore di rete SMTP, ecc.) e logga senza propagare.
        " REGOLA: un errore email non deve mai annullare la creazione del ticket.
        WRITE: / |[MAIL-ERR] Failed to send notification for { lv_job_name }: { lx_bcs->get_text( ) }|.
    ENDTRY.
  ENDMETHOD.


  METHOD get_recipients.
    DATA: lt_maillist TYPE STANDARD TABLE OF zbwjob_maillist,
          ls_entry    TYPE zbwjob_maillist,
          lv_job_name TYPE char100.

    lv_job_name = get_job_name( is_job ).

    " Recupera tutte le righe attive che corrispondono a questo tipo di job.
    " JOB_TYPE IN ('*', tipo): gestisce sia le regole globali ('*') sia quelle specifiche.
    " Nota: IN con valori letterali non è SQL standard ABAP — la clausola WHERE
    " qui usa una OR implicita tramite la sintassi SAP OpenSQL.
    SELECT * FROM zbwjob_maillist
      INTO TABLE lt_maillist
      WHERE job_type IN ('*', is_job-job_type)
        AND active   = 'X'.

    " Filtraggio per CHAIN_PATTERN tramite operatore CP (contains pattern).
    " CP supporta wildcard SAP:
    "   '*' → zero o più caratteri qualsiasi
    "   '+' → esattamente un carattere qualsiasi
    " Esempio: CHAIN_PATTERN = 'ZBW_FIN*' corrisponde a 'ZBW_FINANCE_LOAD'.
    " CHAIN_PATTERN = '*' corrisponde a qualsiasi nome.
    LOOP AT lt_maillist INTO ls_entry.
      IF ls_entry-chain_pattern = '*' OR lv_job_name CP ls_entry-chain_pattern.
        APPEND ls_entry-email TO rt_emails.
      ENDIF.
    ENDLOOP.

    " Deduplicazione: lo stesso indirizzo può matchare più regole
    " (es. una regola generica '*' e una specifica per Finance).
    " SORT + DELETE ADJACENT DUPLICATES garantisce che ogni destinatario
    " riceva una sola email per incident.
    SORT rt_emails.
    DELETE ADJACENT DUPLICATES FROM rt_emails.
  ENDMETHOD.


  METHOD get_job_name.
    " Restituisce il nome più significativo in base al tipo di job:
    "   CHAIN  → chain_id  (es. "ZBW_FINANCE_CLOSE")
    "   BGDJOB → jobname   (es. "ZBW_HR_PAYROLL_LOAD")
    "   DTP    → jobname   (il dtpname viene memorizzato in jobname)
    "   fallback → object_key (sempre valorizzato)
    IF is_job-chain_id IS NOT INITIAL.
      rv_name = is_job-chain_id.
    ELSEIF is_job-jobname IS NOT INITIAL.
      rv_name = is_job-jobname.
    ELSE.
      rv_name = is_job-object_key.
    ENDIF.
  ENDMETHOD.


  METHOD build_mail_body.
    DATA: ls_line TYPE solisti1.

    " Macro locale per aggiungere righe al corpo email senza ripetere APPEND.
    DEFINE append_line.
      ls_line-line = &1.
      APPEND ls_line TO rt_body.
    END-OF-DEFINITION.

    " Intestazione del messaggio.
    append_line |BW4HANA Job Monitor - Incident Notification|.
    append_line |----------------------------------------------|.
    append_line ||.

    " Dati principali dell'incident.
    append_line |Ticket ID  : { iv_ticket_id }|.
    append_line |Job Name   : { iv_job_name }|.
    append_line |Job Type   : { is_job-job_type }|.       " BGDJOB | CHAIN | DTP
    append_line |Priority   : { is_job-priority }|.       " HIGH | MEDIUM | LOW
    append_line |Failed at  : { is_job-fail_tstamp }|.    " timestamp UTC YYYYMMDDHHmmss
    append_line ||.

    " Messaggio di errore (può essere vuoto se non disponibile in DB SAP).
    append_line |Error Message:|.
    append_line |{ is_job-error_msg }|.
    append_line ||.

    " Chiave tecnica per riferimento/ricerca.
    append_line |Object Key : { is_job-object_key }|.
    append_line ||.

    " Footer standard.
    append_line |This is an automated message from ZBW_JOB_MONITOR.|.
  ENDMETHOD.

ENDCLASS.
