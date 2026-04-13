*&---------------------------------------------------------------------*
*& Report  ZBW_JOB_MONITOR
*& BW4HANA Failed-Job Monitor - schedule every 30 min in SM36
*&---------------------------------------------------------------------*
REPORT zbw_job_monitor.

"----------------------------------------------------------------------
" Selection screen
"----------------------------------------------------------------------
PARAMETERS:
  p_lkbk TYPE i     DEFAULT 60  OBLIGATORY,   " Look-back window (minutes)
  p_test TYPE xfeld DEFAULT space.             " X = test mode (no tickets)

"----------------------------------------------------------------------
" Main processing
"----------------------------------------------------------------------
START-OF-SELECTION.

  DATA: lo_reader      TYPE REF TO zcl_bw_job_reader,
        lo_dedup       TYPE REF TO zcl_ticket_dedup,
        lo_provider    TYPE REF TO zif_ticket_provider,
        lt_all_jobs    TYPE STANDARD TABLE OF zbtw_fail_job WITH DEFAULT KEY,
        ls_job         TYPE zbtw_fail_job,
        lv_existing    TYPE char50,
        lv_new_id      TYPE char50,
        lv_ext_status  TYPE char20,
        lv_packet_str  TYPE char10,
        lv_packet      TYPE i,
        lv_processed   TYPE i.

  IF p_test = abap_true.
    WRITE: / '*** TEST MODE - no tickets will be created or updated ***'.
    SKIP.
  ENDIF.

  TRY.
      lo_reader = NEW zcl_bw_job_reader( ).

      " --- 1. Collect failed objects from all three sources ---
      APPEND LINES OF lo_reader->get_failed_jobs( p_lkbk )    TO lt_all_jobs.
      APPEND LINES OF lo_reader->get_failed_chains( p_lkbk )  TO lt_all_jobs.
      APPEND LINES OF lo_reader->get_failed_dtps( p_lkbk )    TO lt_all_jobs.

      IF lt_all_jobs IS INITIAL.
        WRITE: / |No failed jobs found in the last { p_lkbk } minute(s).|.
        RETURN.
      ENDIF.

      WRITE: / |Found { lines( lt_all_jobs ) } failed object(s). Processing...|.
      SKIP.

      " --- 2. Instantiate dedup manager and ticket provider ---
      lo_dedup    = NEW zcl_ticket_dedup( ).
      lo_provider = zcl_ticket_factory=>get_provider( ).

      " --- 2b. Read optional processing cap from config (0 = unlimited) ---
      SELECT SINGLE config_value FROM zbwjob_config
        INTO lv_packet_str
        WHERE config_key = 'PACKET_SIZE'.
      IF sy-subrc = 0 AND lv_packet_str IS NOT INITIAL.
        lv_packet = lv_packet_str.
      ENDIF.

      " --- 3. Process each failed object ---
      LOOP AT lt_all_jobs INTO ls_job.
        TRY.
            " Enforce PACKET_SIZE cap before each job
            lv_processed = lv_processed + 1.
            IF lv_packet > 0 AND lv_processed > lv_packet.
              WRITE: / |[LIMIT] PACKET_SIZE ({ lv_packet }) reached. Remaining jobs deferred to next run.|.
              EXIT.
            ENDIF.

            lv_existing = lo_dedup->has_open_ticket( ls_job ).

            IF lv_existing IS NOT INITIAL.
              " Ticket open in SAP - verify external status before updating
              IF p_test IS INITIAL.
                lv_ext_status = 'OPEN'.
                TRY.
                    lv_ext_status = lo_provider->get_ticket_status( lv_existing ).
                  CATCH cx_static_check.
                    " Status check failed - assume open and proceed with update
                ENDTRY.

                IF lv_ext_status CS 'CLOSE'.
                  " Ticket was closed externally - sync local record, skip update
                  lo_dedup->mark_ticket_closed( ls_job-object_key ).
                  COMMIT WORK AND WAIT.
                  WRITE: / |[SYNC]   Ticket { lv_existing } closed externally, local status synced for { ls_job-object_key }|.
                ELSE.
                  lo_provider->update_ticket(
                    iv_ticket_id = lv_existing
                    iv_message   = ls_job-error_msg ).
                  lo_dedup->mark_ticket_updated(
                    iv_object_key = ls_job-object_key
                    iv_message    = ls_job-error_msg ).
                  COMMIT WORK AND WAIT.
                  WRITE: / |[UPDATE] Ticket { lv_existing } - { ls_job-object_key }|.
                ENDIF.
              ELSE.
                WRITE: / |[UPDATE] Ticket { lv_existing } - { ls_job-object_key }|.
              ENDIF.

            ELSE.
              " No open ticket exists - create a new one
              IF p_test IS INITIAL.
                lv_new_id = lo_provider->create_ticket( ls_job ).
                lo_dedup->save_new_ticket(
                  is_job       = ls_job
                  iv_ticket_id = lv_new_id ).
                COMMIT WORK AND WAIT.
              ELSE.
                lv_new_id = '[TEST - not created]'.
              ENDIF.
              WRITE: / |[CREATE] Ticket { lv_new_id } - { ls_job-object_key } (prio: { ls_job-priority })|.
            ENDIF.

          CATCH cx_static_check INTO DATA(lx_job).
            " Log error per job but continue processing the rest
            WRITE: / |[ERROR] { ls_job-object_key }: { lx_job->get_text( ) }|.
            MESSAGE lx_job->get_text( ) TYPE 'I'.
        ENDTRY.
      ENDLOOP.

      " --- 4. Housekeeping: remove entries older than 30 days ---
      SKIP.
      lo_dedup->cleanup_old_entries( 30 ).
      WRITE: / 'Housekeeping complete. Processing finished.'.

    CATCH cx_static_check INTO DATA(lx_global).
      " Fatal error (e.g. config missing, HTTP setup failed)
      WRITE: / |[FATAL] { lx_global->get_text( ) }|.
      MESSAGE lx_global->get_text( ) TYPE 'I'.
  ENDTRY.
