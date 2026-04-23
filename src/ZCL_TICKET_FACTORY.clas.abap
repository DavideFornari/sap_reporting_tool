"*----------------------------------------------------------------------*
"* Classe ZCL_TICKET_FACTORY  —  Factory per il provider di ticketing
"*
"* Scopo:
"*   Centralizza la costruzione del provider di ticketing leggendo
"*   i parametri di configurazione da ZBWJOB_CONFIG e istanziando
"*   la classe concreta appropriata.
"*
"* Pattern:
"*   Factory Method — il chiamante riceve un riferimento all'interfaccia
"*   ZIF_TICKET_PROVIDER senza conoscere l'implementazione concreta.
"*   Questo consente di sostituire il sistema di ticketing aggiungendo
"*   solo la nuova classe e aggiornando questa factory.
"*
"* Visibilità:
"*   CREATE PRIVATE — non istanziabile direttamente.
"*   L'unico punto di accesso è il metodo di classe GET_PROVIDER().
"*
"* Parametri letti da ZBWJOB_CONFIG:
"*   SM59_DEST   → nome della destinazione RFC HTTP in SM59 (host + SSL)
"*   API_PATH    → path base dell'endpoint REST (es. /api/v1/tickets)
"*   API_TOKEN   → Bearer token di autenticazione
"*   TIMEOUT_SEC → timeout HTTP in secondi (default 30 se assente o zero)
"*
"* Sicurezza:
"*   API_TOKEN è ancora in chiaro in ZBWJOB_CONFIG.
"*   TODO #5 (BASSA): migrare in SECSTORE / CL_SECURE_STORE_SMC.
"*
"* Estensione futura:
"*   Aggiungere CONFIG_KEY = 'PROVIDER_TYPE' (es. 'JIRA', 'SERVICENOW')
"*   e un CASE nella GET_PROVIDER() per scegliere l'implementazione.
"*----------------------------------------------------------------------*
CLASS zcl_ticket_factory DEFINITION
  PUBLIC
  FINAL
  CREATE PRIVATE.

  PUBLIC SECTION.
    "! Factory method: legge ZBWJOB_CONFIG e istanzia il provider corretto.
    "! Attualmente restituisce sempre ZCL_TICKET_HTTP_CLIENT.
    "!
    "! Estensione futura: leggere CONFIG_KEY = 'PROVIDER_TYPE' e usare
    "! un CASE per selezionare l'implementazione (JIRA, SERVICENOW, ecc.).
    "!
    "! @parameter ro_provider | Istanza del provider (tipata su ZIF_TICKET_PROVIDER)
    CLASS-METHODS:
      get_provider
        RETURNING
          VALUE(ro_provider) TYPE REF TO zif_ticket_provider.

ENDCLASS.


CLASS zcl_ticket_factory IMPLEMENTATION.

  METHOD get_provider.
    DATA: lv_destination TYPE char50,
          lv_api_path    TYPE char255,
          lv_api_token   TYPE char255,
          lv_timeout_str TYPE char255,
          lv_timeout     TYPE i.

    " Legge il nome della destinazione SM59 (tipo G — HTTP connection to external server).
    " SM59 gestisce centralmente host, porta e certificati SSL,
    " evitando di memorizzare URL completi in tabelle trasportabili.
    SELECT SINGLE config_value FROM zbwjob_config
      INTO lv_destination
      WHERE config_key = 'SM59_DEST'.

    " Legge il path base dell'endpoint REST (es. /api/v1/tickets).
    " Viene impostato come header '~request_uri' nelle chiamate HTTP.
    SELECT SINGLE config_value FROM zbwjob_config
      INTO lv_api_path
      WHERE config_key = 'API_PATH'.

    " Legge il Bearer token per l'autenticazione HTTP.
    " TODO #5 (BASSA): migrare in SECSTORE per evitare esposizione in SM30.
    SELECT SINGLE config_value FROM zbwjob_config
      INTO lv_api_token
      WHERE config_key = 'API_TOKEN'.

    " Legge il timeout HTTP in secondi (stringa → intero).
    SELECT SINGLE config_value FROM zbwjob_config
      INTO lv_timeout_str
      WHERE config_key = 'TIMEOUT_SEC'.

    " Converte la stringa in intero. Se assente, vuota o zero → default 30 secondi.
    lv_timeout = CONV i( lv_timeout_str ).
    IF lv_timeout = 0.
      lv_timeout = 30.
    ENDIF.

    " Istanzia il provider HTTP generico con i parametri letti dalla configurazione.
    " Il chiamante riceve il riferimento tipato su ZIF_TICKET_PROVIDER:
    " non conosce e non dipende dall'implementazione concreta.
    ro_provider = NEW zcl_ticket_http_client(
      iv_destination = lv_destination
      iv_api_path    = lv_api_path
      iv_api_token   = lv_api_token
      iv_timeout     = lv_timeout ).
  ENDMETHOD.

ENDCLASS.
