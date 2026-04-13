CLASS zcl_bw_mail_notifier DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    "! Send a notification e-mail to all matching recipients in ZBWJOB_MAILLIST.
    "! Called only when a NEW ticket is created (not on update/close).
    "! @parameter is_job       | Failed job structure (job_type, jobname/chain_id, error_msg, priority)
    "! @parameter iv_ticket_id | Ticket ID assigned by the external ticketing system
    METHODS:
      notify_new_ticket
        IMPORTING
          is_job       TYPE zbtw_fail_job
          iv_ticket_id TYPE char50.

  PRIVATE SECTION.
    METHODS:
      get_recipients
        IMPORTING
          is_job              TYPE zbtw_fail_job
        RETURNING
          VALUE(rt_emails)    TYPE STANDARD TABLE OF char241,

      get_job_name
        IMPORTING
          is_job            TYPE zbtw_fail_job
        RETURNING
          VALUE(rv_name)    TYPE char100,

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

    lt_emails   = get_recipients( is_job ).
    IF lt_emails IS INITIAL.
      RETURN.
    ENDIF.

    lv_job_name = get_job_name( is_job ).
    lt_body     = build_mail_body(
                    is_job       = is_job
                    iv_ticket_id = iv_ticket_id
                    iv_job_name  = lv_job_name ).

    lv_subject = |[BW Monitor] Incident opened: { lv_job_name } - Ticket { iv_ticket_id }|.

    TRY.
        lo_send_req = cl_bcs=>create_persistent( ).

        lo_doc = cl_document_bcs=>create_document(
          i_type    = 'RAW'
          i_text    = lt_body
          i_subject = lv_subject ).

        lo_send_req->set_document( lo_doc ).

        LOOP AT lt_emails INTO lv_email.
          lo_rec = cl_internet_address_bcs=>create_internet_address( lv_email ).
          lo_send_req->add_recipient(
            i_recipient = lo_rec
            i_express   = abap_true ).
        ENDLOOP.

        lo_send_req->set_send_immediately( abap_true ).
        lo_send_req->send( ).
        COMMIT WORK AND WAIT.

      CATCH cx_bcs INTO DATA(lx_bcs).
        " Log but do not propagate - mail failure must not block ticket creation
        WRITE: / |[MAIL-ERR] Failed to send notification for { lv_job_name }: { lx_bcs->get_text( ) }|.
    ENDTRY.
  ENDMETHOD.


  METHOD get_recipients.
    DATA: lt_maillist TYPE STANDARD TABLE OF zbwjob_maillist,
          ls_entry    TYPE zbwjob_maillist,
          lv_job_name TYPE char100.

    lv_job_name = get_job_name( is_job ).

    " Fetch all active entries matching this job type or wildcard type
    SELECT * FROM zbwjob_maillist
      INTO TABLE lt_maillist
      WHERE job_type IN ('*', is_job-job_type)
        AND active   = 'X'.

    " Filter by chain pattern using CP (contains pattern) operator
    LOOP AT lt_maillist INTO ls_entry.
      IF ls_entry-chain_pattern = '*' OR lv_job_name CP ls_entry-chain_pattern.
        APPEND ls_entry-email TO rt_emails.
      ENDIF.
    ENDLOOP.

    " Remove duplicates (same address may match multiple rules)
    SORT rt_emails.
    DELETE ADJACENT DUPLICATES FROM rt_emails.
  ENDMETHOD.


  METHOD get_job_name.
    " Determine the display name based on job type:
    " BGDJOB -> jobname, CHAIN -> chain_id, DTP -> jobname (dtpname stored in jobname)
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

    DEFINE append_line.
      ls_line-line = &1.
      APPEND ls_line TO rt_body.
    END-OF-DEFINITION.

    append_line |BW4HANA Job Monitor - Incident Notification|.
    append_line |----------------------------------------------|.
    append_line ||.
    append_line |Ticket ID  : { iv_ticket_id }|.
    append_line |Job Name   : { iv_job_name }|.
    append_line |Job Type   : { is_job-job_type }|.
    append_line |Priority   : { is_job-priority }|.
    append_line |Failed at  : { is_job-fail_tstamp }|.
    append_line ||.
    append_line |Error Message:|.
    append_line |{ is_job-error_msg }|.
    append_line ||.
    append_line |Object Key : { is_job-object_key }|.
    append_line ||.
    append_line |This is an automated message from ZBW_JOB_MONITOR.|.
  ENDMETHOD.

ENDCLASS.
