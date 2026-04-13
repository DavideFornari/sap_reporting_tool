CLASS zcl_ticket_http_client DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES zif_ticket_provider.

    METHODS:
      "! @parameter iv_api_url   | Full REST endpoint URL
      "! @parameter iv_api_token | Bearer token for Authorization header
      "! @parameter iv_timeout   | HTTP send timeout in seconds (default 30)
      constructor
        IMPORTING
          iv_api_url   TYPE char255
          iv_api_token TYPE char255
          iv_timeout   TYPE i DEFAULT 30.

  PRIVATE SECTION.
    TYPES:
      BEGIN OF ty_create_payload,
        title       TYPE string,
        description TYPE string,
        priority    TYPE string,
        system_id   TYPE string,
        object_key  TYPE string,
        job_type    TYPE string,
        failed_at   TYPE string,
      END OF ty_create_payload,

      BEGIN OF ty_update_payload,
        comment TYPE string,
        status  TYPE string,
      END OF ty_update_payload.

    DATA:
      mv_api_url   TYPE char255,
      mv_api_token TYPE char255,
      mv_timeout   TYPE i.

    METHODS:
      build_create_payload
        IMPORTING
          is_job         TYPE zbtw_fail_job
        RETURNING
          VALUE(rv_json) TYPE string,

      build_update_payload
        IMPORTING
          iv_message     TYPE char255
        RETURNING
          VALUE(rv_json) TYPE string,

      execute_http_post
        IMPORTING
          iv_url             TYPE char255
          iv_payload         TYPE string
        RETURNING
          VALUE(rv_response) TYPE string
        RAISING
          cx_static_check,

      parse_ticket_id
        IMPORTING
          iv_response  TYPE string
        RETURNING
          VALUE(rv_id) TYPE char50.

ENDCLASS.


CLASS zcl_ticket_http_client IMPLEMENTATION.

  METHOD constructor.
    mv_api_url   = iv_api_url.
    mv_api_token = iv_api_token.
    mv_timeout   = iv_timeout.
  ENDMETHOD.


  METHOD zif_ticket_provider~create_ticket.
    DATA(lv_json)     = build_create_payload( is_job ).
    DATA(lv_response) = execute_http_post( iv_url     = mv_api_url
                                           iv_payload = lv_json ).
    rv_ticket_id = parse_ticket_id( lv_response ).
  ENDMETHOD.


  METHOD zif_ticket_provider~update_ticket.
    DATA(lv_url)  = |{ mv_api_url }/{ iv_ticket_id }|.
    DATA(lv_json) = build_update_payload( iv_message ).
    execute_http_post( iv_url     = lv_url
                       iv_payload = lv_json ).
  ENDMETHOD.


  METHOD zif_ticket_provider~get_ticket_status.
    DATA: lo_http_client TYPE REF TO if_http_client,
          lv_status_code TYPE i,
          lv_reason      TYPE string.

    cl_http_client=>create_by_url(
      EXPORTING
        url                = |{ mv_api_url }/{ iv_ticket_id }|
      IMPORTING
        client             = lo_http_client
      EXCEPTIONS
        argument_not_found = 1
        plugin_not_active  = 2
        internal_error     = 3
        OTHERS             = 4 ).

    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE cx_static_check.
    ENDIF.

    lo_http_client->request->set_method( 'GET' ).
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

    " Extract "status" field value from JSON response
    FIND REGEX '"status"\s*:\s*"([^"]+)"'
      IN lv_response
      SUBMATCHES rv_status.
  ENDMETHOD.


  METHOD build_create_payload.
    DATA: ls_payload   TYPE ty_create_payload,
          lv_system_id TYPE char50.

    SELECT SINGLE config_value FROM zbwjob_config
      INTO lv_system_id
      WHERE config_key = 'SYSTEM_ID'.
    IF sy-subrc <> 0.
      lv_system_id = sy-sysid.
    ENDIF.

    ls_payload-title       = |BW Job Failed: { is_job-jobname }|.
    ls_payload-description = is_job-error_msg.
    ls_payload-priority    = is_job-priority.
    ls_payload-system_id   = lv_system_id.
    ls_payload-object_key  = is_job-object_key.
    ls_payload-job_type    = is_job-job_type.
    ls_payload-failed_at   = |{ is_job-fail_tstamp }|.

    rv_json = /ui2/cl_json=>serialize( data = ls_payload ).
  ENDMETHOD.


  METHOD build_update_payload.
    DATA ls_payload TYPE ty_update_payload.

    ls_payload-comment = iv_message.
    ls_payload-status  = 'OPEN'.

    rv_json = /ui2/cl_json=>serialize( data = ls_payload ).
  ENDMETHOD.


  METHOD execute_http_post.
    DATA: lo_http_client TYPE REF TO if_http_client,
          lv_status_code TYPE i,
          lv_reason      TYPE string.

    cl_http_client=>create_by_url(
      EXPORTING
        url                = iv_url
      IMPORTING
        client             = lo_http_client
      EXCEPTIONS
        argument_not_found = 1
        plugin_not_active  = 2
        internal_error     = 3
        OTHERS             = 4 ).

    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE cx_static_check.
    ENDIF.

    lo_http_client->request->set_method( 'POST' ).
    lo_http_client->request->set_header_field(
      name  = 'Content-Type'
      value = 'application/json' ).
    lo_http_client->request->set_header_field(
      name  = 'Authorization'
      value = |Bearer { mv_api_token }| ).
    lo_http_client->request->set_cdata( iv_payload ).

    " Suppress interactive logon popup in background jobs
    lo_http_client->propertytype_logon_popup = lo_http_client->co_disabled.

    lo_http_client->send(
      EXPORTING
        timeout                    = mv_timeout
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

    lo_http_client->response->get_status(
      IMPORTING
        code   = lv_status_code
        reason = lv_reason ).

    rv_response = lo_http_client->response->get_cdata( ).
    lo_http_client->close( ).

    IF lv_status_code <> 200 AND lv_status_code <> 201.
      RAISE EXCEPTION TYPE cx_static_check.
    ENDIF.
  ENDMETHOD.


  METHOD parse_ticket_id.
    " Try string "id" first
    FIND REGEX '"id"\s*:\s*"([^"]+)"'
      IN iv_response
      SUBMATCHES rv_id.

    IF rv_id IS INITIAL.
      FIND REGEX '"ticket_id"\s*:\s*"([^"]+)"'
        IN iv_response
        SUBMATCHES rv_id.
    ENDIF.

    " Fallback: numeric id field
    IF rv_id IS INITIAL.
      FIND REGEX '"id"\s*:\s*(\d+)'
        IN iv_response
        SUBMATCHES rv_id.
    ENDIF.
  ENDMETHOD.

ENDCLASS.
