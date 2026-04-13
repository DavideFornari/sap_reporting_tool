INTERFACE zif_ticket_provider
  PUBLIC.

  METHODS:
    create_ticket
      IMPORTING
        is_job              TYPE zbtw_fail_job
      RETURNING
        VALUE(rv_ticket_id) TYPE char50
      RAISING
        cx_static_check,

    update_ticket
      IMPORTING
        iv_ticket_id TYPE char50
        iv_message   TYPE char255
      RAISING
        cx_static_check,

    get_ticket_status
      IMPORTING
        iv_ticket_id     TYPE char50
      RETURNING
        VALUE(rv_status) TYPE char20
      RAISING
        cx_static_check.

ENDINTERFACE.
