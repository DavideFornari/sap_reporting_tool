"*----------------------------------------------------------------------*
"* Interfaccia ZIF_TICKET_PROVIDER
"*
"* Scopo:
"*   Definisce il contratto (Strategy Pattern) che ogni implementazione
"*   di sistema di ticketing deve rispettare. Consente di sostituire
"*   il backend di ticketing (es. REST generico, Jira, ServiceNow)
"*   senza modificare la logica orchestrante in ZBW_JOB_MONITOR.
"*
"* Implementazioni attuali:
"*   - ZCL_TICKET_HTTP_CLIENT  (REST generico via SM59)
"*
"* Implementazioni future:
"*   - ZCL_JIRA_CLIENT
"*   - ZCL_SERVICENOW_CLIENT
"*
"* Tutti i metodi sollevano CX_STATIC_CHECK in caso di:
"*   - Errore di connessione HTTP
"*   - Risposta con status code inatteso (non 200/201)
"*   - Errore interno di configurazione
"*----------------------------------------------------------------------*
INTERFACE zif_ticket_provider
  PUBLIC.

  METHODS:
    "! Apre un nuovo ticket nel sistema di ticketing esterno.
    "!
    "! Il metodo deve:
    "!   1. Costruire il payload JSON a partire da IS_JOB
    "!   2. Eseguire una chiamata HTTP POST all'endpoint del ticketing
    "!   3. Estrarre il ticket ID dalla risposta e restituirlo
    "!
    "! @parameter is_job         | Struttura con tutti i dati del job fallito
    "!                           |   (jobname, error_msg, priority, object_key, ecc.)
    "! @parameter rv_ticket_id   | ID del ticket creato (es. "TKT-00123" o "42")
    "!                           |   Può essere vuoto se il parsing della risposta fallisce
    "! @raising   cx_static_check | Errore HTTP o di configurazione
    create_ticket
      IMPORTING
        is_job              TYPE zbtw_fail_job
      RETURNING
        VALUE(rv_ticket_id) TYPE char50
      RAISING
        cx_static_check,

    "! Aggiunge un commento/aggiornamento a un ticket esistente.
    "!
    "! Chiamato quando il job fallisce di nuovo e un ticket OPEN è già presente
    "! nel log di deduplication. Serve a tenere aggiornato il ticket esterno
    "! con il messaggio di errore più recente.
    "!
    "! @parameter iv_ticket_id   | ID del ticket da aggiornare (ottenuto da ZBTW_TICKET_LOG)
    "! @parameter iv_message     | Messaggio di errore corrente da allegare come commento
    "! @raising   cx_static_check | Errore HTTP o di configurazione
    update_ticket
      IMPORTING
        iv_ticket_id TYPE char50
        iv_message   TYPE char255
      RAISING
        cx_static_check,

    "! Recupera lo stato corrente del ticket dal sistema esterno.
    "!
    "! Usato da ZBW_JOB_MONITOR per rilevare se un ticket è stato chiuso
    "! esternamente (es. dall'operatore nel portale di ticketing) mentre
    "! il log SAP lo mostra ancora come OPEN.
    "! Se la risposta contiene "CLOSE" nel valore dello stato, il monitor
    "! sincronizza il record locale tramite ZCL_TICKET_DEDUP→mark_ticket_closed().
    "!
    "! @parameter iv_ticket_id   | ID del ticket di cui recuperare lo stato
    "! @parameter rv_status      | Stringa di stato restituita dal sistema (es. "OPEN", "CLOSED")
    "! @raising   cx_static_check | Errore HTTP o di configurazione
    get_ticket_status
      IMPORTING
        iv_ticket_id     TYPE char50
      RETURNING
        VALUE(rv_status) TYPE char20
      RAISING
        cx_static_check.

ENDINTERFACE.
