CLASS zcl_ticket_dedup DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    METHODS:
      "! Check whether an OPEN ticket already exists for the given job today.
      "! @parameter is_job        | Failed job structure
      "! @parameter rv_ticket_id  | Ticket ID if open ticket found, else initial
      has_open_ticket
        IMPORTING
          is_job              TYPE zbtw_fail_job
        RETURNING
          VALUE(rv_ticket_id) TYPE char50,

      "! Persist a newly created ticket into the dedup log.
      save_new_ticket
        IMPORTING
          is_job       TYPE zbtw_fail_job
          iv_ticket_id TYPE char50,

      "! Set ticket status to UPDATED and refresh the error message.
      mark_ticket_updated
        IMPORTING
          iv_object_key TYPE char100
          iv_message    TYPE char255,

      "! Set ticket status to CLOSED for the given object key (external sync).
      mark_ticket_closed
        IMPORTING
          iv_object_key TYPE char100,

      "! Delete log entries older than iv_days_to_keep days.
      cleanup_old_entries
        IMPORTING
          iv_days_to_keep TYPE i DEFAULT 30.

ENDCLASS.


CLASS zcl_ticket_dedup IMPLEMENTATION.

  METHOD has_open_ticket.
    " Date-independent: one open ticket per object_key regardless of when it was opened.
    SELECT SINGLE ticket_id FROM zbtw_ticket_log
      INTO rv_ticket_id
      WHERE object_key    = is_job-object_key
        AND ticket_status = 'OPEN'.
  ENDMETHOD.


  METHOD save_new_ticket.
    DATA ls_log TYPE zbtw_ticket_log.

    ls_log-object_key    = is_job-object_key.
    ls_log-log_date      = sy-datum.
    ls_log-ticket_id     = iv_ticket_id.
    ls_log-ticket_status = 'OPEN'.
    ls_log-chain_name    = is_job-jobname.
    ls_log-error_msg     = is_job-error_msg.
    GET TIME STAMP FIELD ls_log-created_at.
    ls_log-updated_at    = ls_log-created_at.

    " MODIFY handles both new entries and re-failures (overwriting a prior CLOSED record).
    MODIFY zbtw_ticket_log FROM ls_log.
  ENDMETHOD.


  METHOD mark_ticket_updated.
    DATA lv_ts TYPE timestamp.
    GET TIME STAMP FIELD lv_ts.

    UPDATE zbtw_ticket_log
      SET ticket_status = 'UPDATED'
          error_msg     = iv_message
          updated_at    = lv_ts
      WHERE object_key = iv_object_key.
  ENDMETHOD.


  METHOD mark_ticket_closed.
    DATA lv_ts TYPE timestamp.
    GET TIME STAMP FIELD lv_ts.

    UPDATE zbtw_ticket_log
      SET ticket_status = 'CLOSED'
          updated_at    = lv_ts
      WHERE object_key = iv_object_key.
  ENDMETHOD.


  METHOD cleanup_old_entries.
    DATA(lv_cutoff) = sy-datum - iv_days_to_keep.

    DELETE FROM zbtw_ticket_log
      WHERE log_date < lv_cutoff.
  ENDMETHOD.

ENDCLASS.
