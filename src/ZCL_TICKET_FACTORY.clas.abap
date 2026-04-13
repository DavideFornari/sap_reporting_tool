CLASS zcl_ticket_factory DEFINITION
  PUBLIC
  FINAL
  CREATE PRIVATE.

  PUBLIC SECTION.
    "! Factory method: reads ZBWJOB_CONFIG and instantiates the correct provider.
    "! Currently always returns ZCL_TICKET_HTTP_CLIENT.
    "! Future: read CONFIG_KEY = 'PROVIDER_TYPE' to switch implementations.
    CLASS-METHODS:
      get_provider
        RETURNING
          VALUE(ro_provider) TYPE REF TO zif_ticket_provider.

ENDCLASS.


CLASS zcl_ticket_factory IMPLEMENTATION.

  METHOD get_provider.
    DATA: lv_api_url     TYPE char255,
          lv_api_token   TYPE char255,
          lv_timeout_str TYPE char255,
          lv_timeout     TYPE i.

    SELECT SINGLE config_value FROM zbwjob_config
      INTO lv_api_url
      WHERE config_key = 'API_URL'.

    SELECT SINGLE config_value FROM zbwjob_config
      INTO lv_api_token
      WHERE config_key = 'API_TOKEN'.

    SELECT SINGLE config_value FROM zbwjob_config
      INTO lv_timeout_str
      WHERE config_key = 'TIMEOUT_SEC'.

    lv_timeout = CONV i( lv_timeout_str ).
    IF lv_timeout = 0.
      lv_timeout = 30.
    ENDIF.

    ro_provider = NEW zcl_ticket_http_client(
      iv_api_url   = lv_api_url
      iv_api_token = lv_api_token
      iv_timeout   = lv_timeout ).
  ENDMETHOD.

ENDCLASS.
