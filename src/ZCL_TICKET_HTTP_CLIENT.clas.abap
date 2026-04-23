"*----------------------------------------------------------------------*
"* Classe ZCL_TICKET_HTTP_CLIENT  —  Provider REST generico per ticketing
"*
"* Scopo:
"*   Implementazione concreta di ZIF_TICKET_PROVIDER che comunica con
"*   qualsiasi sistema di ticketing tramite chiamate HTTP REST generiche.
"*   Non contiene logica specifica di Jira, ServiceNow o altri sistemi.
"*
"* Pattern:
"*   Strategy (implementa ZIF_TICKET_PROVIDER) — sostituibile senza
"*   modificare la logica orchestrante in ZBW_JOB_MONITOR.
"*
"* Connessione HTTP:
"*   Usa CL_HTTP_CLIENT=>CREATE_BY_DESTINATION con una destinazione SM59
"*   di tipo G (HTTP connection to external server).
"*   Questo centralizza host, porta e SSL in SM59, senza esporre URL
"*   completi in tabelle applicative.
"*   Il path specifico viene impostato con l'header pseudo '~request_uri'.
"*
"* Serializzazione JSON:
"*   Usa /UI2/CL_JSON=>SERIALIZE() su strutture tipizzate.
"*   Questo garantisce l'escape corretto di tutti i caratteri speciali
"*   JSON (", \, newline, tab, ecc.) senza logica manuale.
"*
"* Autenticazione:
"*   Header HTTP: Authorization: Bearer <token>
"*   Il token viene letto da ZBWJOB_CONFIG tramite ZCL_TICKET_FACTORY.
"*----------------------------------------------------------------------*
CLASS zcl_ticket_http_client DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES zif_ticket_provider.

    METHODS:
      "! Costruttore: memorizza i parametri di connessione come attributi privati.
      "!
      "! @parameter iv_destination | Nome della destinazione SM59 (tipo G)
      "!                           |   Gestisce host, porta e SSL centralmente
      "! @parameter iv_api_path    | Path base dell'endpoint tickets (es. /api/v1/tickets)
      "!                           |   Impostato come '~request_uri' in ogni richiesta
      "! @parameter iv_api_token   | Bearer token per header Authorization
      "! @parameter iv_timeout     | Timeout HTTP in secondi per ogni send() (default 30)
      constructor
        IMPORTING
          iv_destination TYPE char50
          iv_api_path    TYPE char255
          iv_api_token   TYPE char255
          iv_timeout     TYPE i DEFAULT 30.

  PRIVATE SECTION.
    " Struttura del payload JSON per la creazione di un nuovo ticket.
    " I nomi dei campi diventano le chiavi JSON dopo la serializzazione.
    TYPES:
      BEGIN OF ty_create_payload,
        title       TYPE string,   " "BW Job Failed: <JOBNAME>"
        description TYPE string,   " messaggio di errore
        priority    TYPE string,   " HIGH | MEDIUM | LOW
        system_id   TYPE string,   " identificativo del sistema SAP (da ZBWJOB_CONFIG)
        object_key  TYPE string,   " chiave univoca del job/chain/DTP
        job_type    TYPE string,   " BGDJOB | CHAIN | DTP
        failed_at   TYPE string,   " timestamp UTC del fallimento
      END OF ty_create_payload,

      " Struttura del payload JSON per l'aggiornamento di un ticket esistente.
      BEGIN OF ty_update_payload,
        comment TYPE string,   " messaggio di errore corrente
        status  TYPE string,   " sempre "OPEN" — il ticket è ancora in lavorazione
      END OF ty_update_payload.

    " Attributi privati: impostati nel costruttore, usati in tutti i metodi HTTP.
    DATA:
      mv_destination TYPE char50,    " nome destinazione SM59
      mv_api_path    TYPE char255,   " path base endpoint
      mv_api_token   TYPE char255,   " Bearer token
      mv_timeout     TYPE i.         " timeout in secondi

    METHODS:
      "! Costruisce il payload JSON per la creazione di un nuovo ticket.
      "! Legge SYSTEM_ID da ZBWJOB_CONFIG; se assente usa sy-sysid.
      "!
      "! @parameter is_job     | Job fallito con tutti i campi necessari
      "! @parameter rv_json    | Stringa JSON pronta per l'invio HTTP
      build_create_payload
        IMPORTING
          is_job         TYPE zbtw_fail_job
        RETURNING
          VALUE(rv_json) TYPE string,

      "! Costruisce il payload JSON per l'aggiornamento di un ticket esistente.
      "!
      "! @parameter iv_message | Messaggio di errore corrente da includere come commento
      "! @parameter rv_json    | Stringa JSON pronta per l'invio HTTP
      build_update_payload
        IMPORTING
          iv_message     TYPE char255
        RETURNING
          VALUE(rv_json) TYPE string,

      "! Esegue una chiamata HTTP POST verso il path indicato con il payload JSON.
      "! Gestisce l'intero ciclo: CREATE_BY_DESTINATION → SET_METHOD → SEND → RECEIVE.
      "! Solleva CX_STATIC_CHECK se la connessione fallisce o se
      "! il codice HTTP di risposta non è 200 o 201.
      "!
      "! @parameter iv_path     | Path completo dell'endpoint (es. /api/v1/tickets o /api/v1/tickets/42)
      "! @parameter iv_payload  | Corpo della richiesta in formato JSON
      "! @parameter rv_response | Corpo della risposta HTTP come stringa
      "! @raising cx_static_check | Errore di connessione o status code inatteso
      execute_http_post
        IMPORTING
          iv_path            TYPE string
          iv_payload         TYPE string
        RETURNING
          VALUE(rv_response) TYPE string
        RAISING
          cx_static_check,

      "! Estrae il ticket ID dalla risposta JSON dell'API.
      "! Cerca in sequenza tre pattern per massimizzare la compatibilità:
      "!   1. "id": "string"       → ID stringa nel campo 'id'
      "!   2. "ticket_id": "string" → ID stringa nel campo 'ticket_id'
      "!   3. "id": 12345          → ID numerico nel campo 'id'
      "!
      "! @parameter iv_response | Corpo della risposta HTTP
      "! @parameter rv_id       | Ticket ID estratto (spazio se non trovato)
      parse_ticket_id
        IMPORTING
          iv_response  TYPE string
        RETURNING
          VALUE(rv_id) TYPE char50.

ENDCLASS.


CLASS zcl_ticket_http_client IMPLEMENTATION.

  METHOD constructor.
    " Memorizza i parametri di connessione come attributi privati dell'istanza.
    " Vengono usati da tutti i metodi HTTP successivi.
    mv_destination = iv_destination.
    mv_api_path    = iv_api_path.
    mv_api_token   = iv_api_token.
    mv_timeout     = iv_timeout.
  ENDMETHOD.


  METHOD zif_ticket_provider~create_ticket.
    " Costruisce il payload JSON con i dati del job fallito.
    DATA(lv_json)     = build_create_payload( is_job ).

    " Esegue il POST verso il path base (es. /api/v1/tickets).
    " In caso di errore HTTP, CX_STATIC_CHECK viene propagata al chiamante.
    DATA(lv_response) = execute_http_post( iv_path    = mv_api_path
                                           iv_payload = lv_json ).

    " Estrae il ticket ID dalla risposta JSON.
    rv_ticket_id = parse_ticket_id( lv_response ).
  ENDMETHOD.


  METHOD zif_ticket_provider~update_ticket.
    " Costruisce il path specifico del ticket: <base>/<ticket_id>
    DATA(lv_path) = |{ mv_api_path }/{ iv_ticket_id }|.

    " Costruisce il payload JSON con il commento di aggiornamento.
    DATA(lv_json) = build_update_payload( iv_message ).

    " Esegue il POST verso il ticket specifico.
    " La risposta non viene usata: il successo è confermato dallo status code HTTP.
    execute_http_post( iv_path    = lv_path
                       iv_payload = lv_json ).
  ENDMETHOD.


  METHOD zif_ticket_provider~get_ticket_status.
    DATA: lo_http_client TYPE REF TO if_http_client,
          lv_status_code TYPE i,
          lv_reason      TYPE string.

    " Crea il client HTTP dalla destinazione SM59.
    " La destinazione SM59 gestisce host, porta e SSL centralmente.
    cl_http_client=>create_by_destination(
      EXPORTING
        destination              = mv_destination
      IMPORTING
        client                   = lo_http_client
      EXCEPTIONS
        argument_not_found       = 1
        destination_not_found    = 2
        destination_no_authority = 3
        plugin_not_active        = 4
        internal_error           = 5
        OTHERS                   = 6 ).

    IF sy-subrc <> 0.
      " La destinazione SM59 non è configurata o non è raggiungibile.
      RAISE EXCEPTION TYPE cx_static_check.
    ENDIF.

    " Imposta metodo GET e il path specifico del ticket.
    lo_http_client->request->set_method( 'GET' ).
    lo_http_client->request->set_header_field(
      name  = '~request_uri'
      value = |{ mv_api_path }/{ iv_ticket_id }| ).

    " Aggiunge il Bearer token per l'autenticazione.
    lo_http_client->request->set_header_field(
      name  = 'Authorization'
      value = |Bearer { mv_api_token }| ).

    lo_http_client->send(
      EXCEPTIONS
        http_communication_failure = 1
        http_invalid_state         = 2
        OTHERS                     = 3 ).

    IF sy-subrc <> 0.
      lo_http_client->close( ).
      RAISE EXCEPTION TYPE cx_static_check.
    ENDIF.

    lo_http_client->receive(
      EXCEPTIONS
        http_communication_failure = 1
        http_invalid_state         = 2
        http_processing_failed     = 3
        OTHERS                     = 4 ).

    IF sy-subrc <> 0.
      lo_http_client->close( ).
      RAISE EXCEPTION TYPE cx_static_check.
    ENDIF.

    DATA(lv_response) = lo_http_client->response->get_cdata( ).
    lo_http_client->close( ).

    " Estrae il campo "status" dalla risposta JSON con un'espressione regolare.
    " Il pattern cattura la stringa dopo "status": es. "status": "CLOSED" → "CLOSED".
    " ZBW_JOB_MONITOR usa CS 'CLOSE' per rilevare qualsiasi variante (CLOSED, CLOSE, ecc.).
    FIND REGEX '"status"\s*:\s*"([^"]+)"'
      IN lv_response
      SUBMATCHES rv_status.
  ENDMETHOD.


  METHOD build_create_payload.
    DATA: ls_payload   TYPE ty_create_payload,
          lv_system_id TYPE char50.

    " Legge l'identificativo di sistema da ZBWJOB_CONFIG.
    " Se non configurato, usa il SID del sistema corrente (sy-sysid).
    SELECT SINGLE config_value FROM zbwjob_config
      INTO lv_system_id
      WHERE config_key = 'SYSTEM_ID'.
    IF sy-subrc <> 0.
      lv_system_id = sy-sysid.
    ENDIF.

    " Popola la struttura tipizzata — i nomi dei campi diventano le chiavi JSON.
    ls_payload-title       = |BW Job Failed: { is_job-jobname }|.
    ls_payload-description = is_job-error_msg.
    ls_payload-priority    = is_job-priority.
    ls_payload-system_id   = lv_system_id.
    ls_payload-object_key  = is_job-object_key.
    ls_payload-job_type    = is_job-job_type.
    ls_payload-failed_at   = |{ is_job-fail_tstamp }|.  " timestamp come stringa

    " Serializza la struttura in JSON.
    " /UI2/CL_JSON gestisce automaticamente l'escape di tutti i caratteri speciali:
    " virgolette ("), backslash (\), newline (\n), tab (\t), ecc.
    rv_json = /ui2/cl_json=>serialize( data = ls_payload ).
  ENDMETHOD.


  METHOD build_update_payload.
    DATA ls_payload TYPE ty_update_payload.

    ls_payload-comment = iv_message.
    ls_payload-status  = 'OPEN'.   " il ticket è ancora aperto — solo commento aggiunto

    " Serializza la struttura in JSON con escape automatico dei caratteri speciali.
    rv_json = /ui2/cl_json=>serialize( data = ls_payload ).
  ENDMETHOD.


  METHOD execute_http_post.
    DATA: lo_http_client TYPE REF TO if_http_client,
          lv_status_code TYPE i,
          lv_reason      TYPE string.

    " Crea il client HTTP dalla destinazione SM59.
    " ARGUMENT_NOT_FOUND / DESTINATION_NOT_FOUND → destinazione non configurata.
    " DESTINATION_NO_AUTHORITY → utente non ha S_RFC su questa destinazione.
    cl_http_client=>create_by_destination(
      EXPORTING
        destination              = mv_destination
      IMPORTING
        client                   = lo_http_client
      EXCEPTIONS
        argument_not_found       = 1
        destination_not_found    = 2
        destination_no_authority = 3
        plugin_not_active        = 4
        internal_error           = 5
        OTHERS                   = 6 ).

    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE cx_static_check.
    ENDIF.

    " Imposta il metodo HTTP e il path endpoint.
    lo_http_client->request->set_method( 'POST' ).
    lo_http_client->request->set_header_field(
      name  = '~request_uri'     " pseudo-header SAP per impostare il path sulla destinazione SM59
      value = iv_path ).

    " Imposta gli header obbligatori.
    lo_http_client->request->set_header_field(
      name  = 'Content-Type'
      value = 'application/json' ).
    lo_http_client->request->set_header_field(
      name  = 'Authorization'
      value = |Bearer { mv_api_token }| ).

    " Imposta il corpo della richiesta (payload JSON).
    lo_http_client->request->set_cdata( iv_payload ).

    " Disabilita il popup di logon interattivo.
    " Essenziale per l'esecuzione in background (SM36): senza questo,
    " il job si bloccherebbe in attesa di un input utente impossibile.
    lo_http_client->propertytype_logon_popup = lo_http_client->co_disabled.

    " Invia la richiesta HTTP con il timeout configurato.
    lo_http_client->send(
      EXPORTING
        timeout                    = mv_timeout
      EXCEPTIONS
        http_communication_failure = 1
        http_invalid_state         = 2
        OTHERS                     = 3 ).

    IF sy-subrc <> 0.
      lo_http_client->close( ).  " chiude sempre la connessione prima di sollevare
      RAISE EXCEPTION TYPE cx_static_check.
    ENDIF.

    " Riceve e legge la risposta HTTP.
    lo_http_client->receive(
      EXCEPTIONS
        http_communication_failure = 1
        http_invalid_state         = 2
        http_processing_failed     = 3
        OTHERS                     = 4 ).

    IF sy-subrc <> 0.
      lo_http_client->close( ).
      RAISE EXCEPTION TYPE cx_static_check.
    ENDIF.

    " Legge il codice di stato HTTP per validare il risultato.
    lo_http_client->response->get_status(
      IMPORTING
        code   = lv_status_code
        reason = lv_reason ).

    rv_response = lo_http_client->response->get_cdata( ).
    lo_http_client->close( ).

    " Valida lo status code: solo 200 (OK) e 201 (Created) sono accettati.
    " Qualsiasi altro codice (400, 401, 403, 404, 500, ecc.) solleva eccezione.
    IF lv_status_code <> 200 AND lv_status_code <> 201.
      RAISE EXCEPTION TYPE cx_static_check.
    ENDIF.
  ENDMETHOD.


  METHOD parse_ticket_id.
    " Tenta il parsing del ticket ID con tre pattern in ordine di preferenza.
    " L'ordine riflette i formati più comuni restituiti dai sistemi di ticketing.

    " Pattern 1: campo "id" con valore stringa (es. "id": "TKT-00123")
    FIND REGEX '"id"\s*:\s*"([^"]+)"'
      IN iv_response
      SUBMATCHES rv_id.

    IF rv_id IS INITIAL.
      " Pattern 2: campo "ticket_id" con valore stringa (es. "ticket_id": "INC-456")
      " Usato da alcuni sistemi che non seguono la convenzione REST standard.
      FIND REGEX '"ticket_id"\s*:\s*"([^"]+)"'
        IN iv_response
        SUBMATCHES rv_id.
    ENDIF.

    IF rv_id IS INITIAL.
      " Pattern 3: campo "id" con valore numerico (es. "id": 42)
      " Fallback per API che restituiscono ID interi invece di stringhe.
      FIND REGEX '"id"\s*:\s*(\d+)'
        IN iv_response
        SUBMATCHES rv_id.
    ENDIF.

    " Se nessun pattern corrisponde, rv_id rimane spazio.
    " ZCL_TICKET_DEDUP salverà il record con ticket_id vuoto — il ticket
    " è stato creato ma l'ID non è recuperabile dalla risposta ricevuta.
  ENDMETHOD.

ENDCLASS.
